# Pester 6 tests for Hopover.ps1's page API (seam 2 of spec #12). The shared cases in
# api-cases.json run against a real server in a child PowerShell, one per case, whose per-user
# folders (LOCALAPPDATA, TEMP, the data folder) are inside the test drive and whose Back up runs
# tests\fixtures\Stub-Backup.ps1. The tests after them are this server's own: the password's way to
# the job, what closing the window does, and a real Back up made from the page. They download the
# pinned 7zr.exe, so every run needs the network.

BeforeDiscovery {
    $file = Join-Path $PSScriptRoot 'api-cases.json'
    $ApiCases = @((Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).cases | ForEach-Object { @{ Title = $_.name; Case = $_ } })
}

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Backup.ps1')
    . (Join-Path $root 'lib\Jobs.ps1')
    $SevenZip = Get-SevenZip -CacheDir (Join-Path $TestDrive 'bin')
    $Hopover = Join-Path $root 'Hopover.ps1'
    $Stub = Join-Path $PSScriptRoot 'fixtures\Stub-Backup.ps1'
    $StubHelper = Join-Path $PSScriptRoot 'fixtures\Stub-AdminSteps.ps1'
    $Shell = (Get-Process -Id $PID).Path
    Add-Type -AssemblyName System.Net.Http
    $Http = New-Object System.Net.Http.HttpClient
    $Http.Timeout = [TimeSpan]::FromSeconds(60)

    # A user with nothing on record: their own per-user folders, the 7zr.exe these tests
    # downloaded, an empty data folder and an empty folder to save Backups in.
    function New-Profile {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($sub in 'appdata\Hopover\bin', 'temp', 'data', 'out') { New-Item -ItemType Directory -Path (Join-Path $d $sub) | Out-Null }
        Copy-Item -LiteralPath $SevenZip -Destination (Join-Path $d 'appdata\Hopover\bin')
        [pscustomobject]@{ Dir = $d; AppData = (Join-Path $d 'appdata'); Temp = (Join-Path $d 'temp'); Data = (Join-Path $d 'data'); Out = (Join-Path $d 'out') }
    }

    # Runs $Block with that user's per-user folders as the environment, then puts it back. $Mode
    # and $HelperMode tell the stand-in Back up and the stand-in helper what to do.
    function Invoke-AsUser($Where, [scriptblock]$Block, [string]$Mode, [string]$HelperMode) {
        $names = 'LOCALAPPDATA', 'TEMP', 'TMP', 'HOPOVER_DATA', 'HOPOVER_STUB', 'HOPOVER_STUB_HELPER', 'HOPOVER_OPTIONS'
        $saved = @{}; foreach ($k in $names) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
        $env:LOCALAPPDATA = $Where.AppData; $env:TEMP = $Where.Temp; $env:TMP = $Where.Temp; $env:HOPOVER_DATA = $Where.Data; $env:HOPOVER_STUB = $Mode
        $env:HOPOVER_STUB_HELPER = $HelperMode; $env:HOPOVER_OPTIONS = $null
        try { & $Block }
        finally { foreach ($k in $names) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    }

    # Hopover.ps1 for that user, with the stand-in Back up unless $Real, and always the stand-in
    # elevated helper. Returns once it is serving.
    function Start-Server($Where, [string]$Mode = 'finishes', [switch]$Real, [string]$HelperMode) {
        $port = Get-Random -Minimum 20000 -Maximum 45000
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', """$Hopover""", '-NoBrowser', '-Port', $port, '-AdminHelper', """$StubHelper""")
        if (-not $Real) { $arguments += @('-BackupScript', """$Stub""") }
        $p = Invoke-AsUser $Where { Start-Process -FilePath $Shell -ArgumentList $arguments -WindowStyle Hidden -PassThru } $Mode $HelperMode
        $file = Join-Path $Where.AppData 'Hopover\server.json'
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            $s = Read-JsonFile $file
            if ($s -and $s.pid -eq $p.Id) { return [pscustomobject]@{ Process = $p; Base = "http://localhost:$($s.port)"; Token = $s.token; Where = $Where } }
            if ($p.HasExited) { throw "Hopover.ps1 exited with $($p.ExitCode) before serving." }
            Start-Sleep -Milliseconds 200
        }
        throw 'Hopover.ps1 did not start serving within a minute.'
    }

    # Ends the server as closing its window does.
    function Stop-Server($Server) {
        if ($Server -and -not $Server.Process.HasExited) { Stop-Process -Id $Server.Process.Id -Force; $Server.Process.WaitForExit(20000) | Out-Null }
    }

    function Invoke-Api($Server, [string]$Method, [string]$Path, $Body, [bool]$Token = $true) {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Server.Base + $Path)
        if ($Token) { $req.Headers.Add('X-Token', $Server.Token) }
        if ($null -ne $Body) { $req.Content = [System.Net.Http.StringContent]::new((ConvertTo-Json -InputObject $Body -Depth 10 -Compress), $Utf8, 'application/json') }
        $res = $Http.SendAsync($req).GetAwaiter().GetResult()
        $text = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $json = $null
        if ($res.Content.Headers.ContentType -and $res.Content.Headers.ContentType.MediaType -eq 'application/json') { $json = $text | ConvertFrom-Json }
        $headers = @{}
        foreach ($h in @($res.Headers) + @($res.Content.Headers)) { $headers[$h.Key] = ($h.Value -join ', ') }
        [pscustomobject]@{ Status = [int]$res.StatusCode; Headers = $headers; Text = $text; Json = $json }
    }

    # Does $Actual hold $Expected? The rules are in api-cases.json's $comment.
    function Test-Subset($Expected, $Actual) {
        if ($null -eq $Expected) { return $null -eq $Actual }
        if ($Expected -is [System.Management.Automation.PSCustomObject]) {
            if ($Actual -isnot [System.Management.Automation.PSCustomObject]) { return $false }
            foreach ($p in $Expected.PSObject.Properties) {
                $a = $Actual.PSObject.Properties[$p.Name]
                if (-not (Test-Subset $p.Value $(if ($a) { $a.Value } else { $null }))) { return $false }
            }
            return $true
        }
        if ($Expected -is [array]) {
            # @() around the whole if: assigning an if's output unrolls a one-item array to the item.
            $items = @(if ($null -eq $Actual) { } else { $Actual })
            if ($Expected.Count -eq 0) { return $items.Count -eq 0 }
            $i = 0
            foreach ($e in $Expected) {
                while ($i -lt $items.Count -and -not (Test-Subset $e $items[$i])) { $i++ }
                if ($i -ge $items.Count) { return $false }
                $i++
            }
            return $true
        }
        if ($Expected -is [string]) { return $null -ne $Actual -and ([string]$Actual) -clike $Expected }
        if ($Expected -is [bool]) { return $Actual -is [bool] -and $Actual -eq $Expected }
        return $null -ne $Actual -and $Actual -eq $Expected
    }

    # A step with every {name} filled in, as JSON text so each string is escaped once.
    function Expand-Step($Step, $Vars) {
        $text = ConvertTo-Json -InputObject $Step -Depth 30 -Compress
        foreach ($k in $Vars.Keys) { $text = $text.Replace("{$k}", (ConvertTo-Json -InputObject ([string]$Vars[$k]) -Compress).Trim('"')) }
        $text | ConvertFrom-Json
    }

    function Get-JsonPath($Json, [string]$Path) {
        $v = $Json
        foreach ($part in $Path.Split('.')) { $v = $v.$part }
        $v
    }

    function Invoke-Case($Case) {
        $where = New-Profile
        if ($Case.options) {
            [IO.File]::WriteAllText((Join-Path $where.AppData 'Hopover\options.json'), (ConvertTo-Json -InputObject $Case.options -Depth 10), $Utf8)
        }
        $stubMode = if ($Case.backup) { $Case.backup } else { 'finishes' }
        $server = Start-Server $where $stubMode -Real:($stubMode -eq 'real') -HelperMode ([string]$Case.helper)
        try {
            $vars = @{ destination = $where.Out; missing = (Join-Path $where.Dir 'nowhere') }
            $n = 0
            foreach ($raw in @($Case.steps)) {
                $n++
                $step = Expand-Step $raw $vars
                $r = $step.request
                $token = -not ($r.PSObject.Properties.Name -contains 'token' -and $r.token -eq $false)
                $body = if ($r.PSObject.Properties.Name -contains 'body') { $r.body } else { $null }
                $res = Invoke-Api $server $r.method $r.path $body $token
                if ($step.until) {
                    $deadline = (Get-Date).AddSeconds(30)
                    while (-not (Test-Subset $step.until $res.Json) -and (Get-Date) -lt $deadline) {
                        Start-Sleep -Milliseconds 250
                        $res = Invoke-Api $server $r.method $r.path $body $token
                    }
                }
                $where_ = "step $n ($($r.method) $($r.path)), which answered $($res.Status) $($res.Text)"
                $res.Status | Should -Be $step.expect.status -Because $where_
                if ($step.expect.headers) { foreach ($h in $step.expect.headers.PSObject.Properties) { $res.Headers[$h.Name] | Should -BeLikeExactly $h.Value -Because $where_ } }
                if ($step.expect.PSObject.Properties.Name -contains 'json') { Test-Subset $step.expect.json $res.Json | Should -BeTrue -Because $where_ }
                if ($step.save) { foreach ($s in $step.save.PSObject.Properties) { $vars[$s.Name] = Get-JsonPath $res.Json $s.Value } }
                if ($step.files) {
                    foreach ($f in @($step.files.present | Where-Object { $_ })) { $f | Should -Exist -Because $where_ }
                    foreach ($f in @($step.files.absent | Where-Object { $_ })) { $f | Should -Not -Exist -Because $where_ }
                }
            }
        } finally { Stop-Server $server }
    }

    function Start-Backup($Server, [string]$Name, [string]$Phrase = 'correct horse battery', $Extra = @{}) {
        $body = @{ name = $Name; password = $Phrase; passwordAgain = $Phrase; destination = $Server.Where.Out } + $Extra
        $res = Invoke-Api $Server 'POST' '/api/backup' $body
        $res.Status | Should -Be 200 -Because $res.Text
        $res.Json.job.id
    }

    # The paths a Backup holds, sorted, and its hopover.json without the time it was made.
    $BackupPassword = (New-Object System.Net.NetworkCredential('', 'correct horse battery')).SecurePassword
    function Get-BackupListing([string]$File) {
        @((Invoke-SevenZip -SevenZip $SevenZip -Arguments @('l', '-ba', '-slt', '-sccUTF-8', $File) -Password $BackupPassword).Stdout -split "`r?`n" |
            Where-Object { $_ -like 'Path = *' } | ForEach-Object { $_.Substring(7) } | Sort-Object)
    }
    function Get-BackupManifest([string]$File) {
        $m = (Read-BackupManifest -Path $File -Password $BackupPassword -SevenZip $SevenZip).Manifest
        $m.PSObject.Properties.Remove('created')
        $m
    }

    function Wait-HopoverJob($Server, [string]$Id, [scriptblock]$Until) {
        $deadline = (Get-Date).AddSeconds(60)
        do {
            $r = (Invoke-Api $Server 'GET' "/api/jobs/$Id/events?since=0").Json
            if (& $Until $r) { return $r }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $deadline)
        throw "Job $Id didn't get there in a minute: $(ConvertTo-Json -InputObject $r -Depth 6 -Compress)"
    }
}

Describe 'The page API (api-cases.json)' {
    It '<Title>' -ForEach $ApiCases {
        Invoke-Case $Case
    }
}

Describe 'The page''s string table' {
    It 'words every message code the scripts and the server send' {
        $page = Get-Content -LiteralPath (Join-Path $root 'ui\index.html') -Raw
        $codes = foreach ($f in 'Hopover.ps1', 'New-Backup.ps1', 'Invoke-AdminSteps.ps1', 'lib\Jobs.ps1', 'lib\Server.ps1') {
            $text = Get-Content -LiteralPath (Join-Path $root $f) -Raw
            [regex]::Matches($text, "-Code '([a-z-]+)'|Send-Error \`$\w+ \d+ '([a-z-]+)'|Close-EndedJob \`$\w+ '([a-z-]+)'") |
                ForEach-Object { @($_.Groups[1].Value, $_.Groups[2].Value, $_.Groups[3].Value) | Where-Object { $_ } }
        }
        $codes = @($codes | Sort-Object -Unique)
        $codes.Count | Should -BeGreaterThan 15
        foreach ($c in $codes) { $page | Should -Match "'$([regex]::Escape($c))':" -Because "the code $c" }
    }
}

Describe 'Hopover.ps1 jobs' {
    BeforeEach { $server = $null }
    AfterEach { Stop-Server $server }

    It 'gives a Back up its password on standard input, never on its command line' {
        $server = Start-Server (New-Profile)
        $id = Start-Backup $server 'Test PC' 'correct horse battery'
        [void](Wait-HopoverJob $server $id { param($r) $r.job.status -eq 'finished' })
        $received = Read-JsonFile (Join-Path $server.Where.AppData "Hopover\jobs\$id\received.json")
        $received.stdin | Should -BeExactly 'correct horse battery'
        $received.commandLine | Should -Not -Match 'horse'
        $received.commandLine | Should -Match ([regex]::Escape('-Name "Test PC"'))
    }

    It 'removes the job''s staging copy when the job is stopped' {
        $server = Start-Server (New-Profile) 'waits'
        $id = Start-Backup $server 'Waiting PC'
        [void](Wait-HopoverJob $server $id { param($r) @($r.events | Where-Object { $_.type -eq 'step-started' }).Count })
        $staging = Join-Path $server.Where.AppData "Hopover\jobs\$id\staging"
        Join-Path $staging 'unencrypted.txt' | Should -Exist
        $stub = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($server.Process.Id)" | Where-Object { $_.CommandLine -match 'Stub-Backup' })
        $stub.Count | Should -Be 1
        (Invoke-Api $server 'POST' "/api/jobs/$id/stop" @{ confirm = $true }).Status | Should -Be 200
        $staging | Should -Not -Exist
        Get-Process -Id $stub[0].ProcessId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'Stop ends the job''s processes'
    }

    It 'ends a job when Hopover''s window closes, and says so when Hopover starts again' {
        $where = New-Profile
        $server = Start-Server $where 'waits'
        $id = Start-Backup $server 'Waiting PC'
        [void](Wait-HopoverJob $server $id { param($r) @($r.events | Where-Object { $_.type -eq 'step-started' }).Count })
        $stub = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($server.Process.Id)" | Where-Object { $_.CommandLine -match 'Stub-Backup' })
        $stub.Count | Should -Be 1
        Stop-Server $server
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Process -Id $stub[0].ProcessId -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        Get-Process -Id $stub[0].ProcessId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty

        $server = Start-Server $where 'waits'
        # Cleared as Hopover starts, before anything asks: the staging copy is unencrypted.
        Join-Path $where.Out 'Waiting PC.hopover.7z' | Should -Not -Exist
        Join-Path $where.AppData "Hopover\jobs\$id\staging" | Should -Not -Exist
        $state = (Invoke-Api $server 'GET' '/api/state').Json
        $state.activeJob | Should -BeNullOrEmpty
        $state.lastJob.id | Should -Be $id
        $state.lastJob.status | Should -Be 'failed'
        $events = (Invoke-Api $server 'GET' "/api/jobs/$id/events?since=0").Json.events
        @($events | Where-Object { $_.type -eq 'job-finished' -and $_.code -eq 'job-interrupted' }).Count | Should -Be 1
        Join-Path $where.Out 'Waiting PC.hopover.7z' | Should -Not -Exist
        Join-Path $where.AppData "Hopover\jobs\$id\staging" | Should -Not -Exist
    }

    It 'keeps a Backup that was made before Hopover''s window closed, though the job hadn''t said so' {
        $where = New-Profile
        $server = Start-Server $where 'packed'
        $id = Start-Backup $server 'Packed PC'
        [void](Wait-HopoverJob $server $id { param($r) @($r.events | Where-Object { $_.type -eq 'step-finished' -and $_.step -eq 'pack' }).Count })
        Stop-Server $server
        $server = Start-Server $where 'packed'
        (Invoke-Api $server 'GET' '/api/state').Json.lastJob.status | Should -Be 'failed'
        Join-Path $where.Out 'Packed PC.hopover.7z' | Should -Exist
    }

    It 'reads past an event the job was killed in the middle of writing' {
        $server = Start-Server (New-Profile) 'torn'
        $id = Start-Backup $server 'Torn PC'
        [void](Wait-HopoverJob $server $id { param($r) @($r.events | Where-Object { $_.type -eq 'step-started' }).Count })
        Start-Sleep -Milliseconds 500
        (Invoke-Api $server 'POST' "/api/jobs/$id/stop" @{ confirm = $true }).Status | Should -Be 200
        $r = Invoke-Api $server 'GET' "/api/jobs/$id/events?since=0"
        $r.Status | Should -Be 200 -Because $r.Text
        $r.Json.job.status | Should -Be 'stopped'
        @($r.Json.events | Where-Object { $_.code -eq 'job-stopped' }).Count | Should -Be 1
    }

    It 'doesn''t lose an event the job was still writing when the page asked' {
        $server = Start-Server (New-Profile) 'slow'
        $id = Start-Backup $server 'Slow PC'
        [void](Wait-HopoverJob $server $id { param($r) @($r.events | Where-Object { $_.type -eq 'step-started' }).Count })
        Start-Sleep -Milliseconds 800   # the event's first half is on disk now, its second isn't
        $first = (Invoke-Api $server 'GET' "/api/jobs/$id/events?since=0").Json
        @($first.events | Where-Object { $_.type -eq 'message' }).Count | Should -Be 0
        Start-Sleep -Seconds 4
        $then = (Invoke-Api $server 'GET' "/api/jobs/$id/events?since=$($first.next)").Json
        @($then.events | Where-Object { $_.type -eq 'message' -and $_.code -eq 'only-some-steps' }).Count | Should -Be 1
    }

    It 'starts despite a job folder whose records it can''t read' {
        $where = New-Profile
        $bad = Join-Path $where.AppData 'Hopover\jobs\20260101-000000-abcdef'
        New-Item -ItemType Directory -Path $bad -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bad 'job.json') -Value '' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $bad 'events.jsonl') -Value '{"type":"job-sta' -Encoding ASCII
        # JSON, but not a job's record.
        $odd = Join-Path $where.AppData 'Hopover\jobs\20260101-000001-abcdef'
        New-Item -ItemType Directory -Path $odd -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $odd 'job.json') -Value '{ "kind": "backup", "name": "Odd" }' -Encoding ASCII
        $server = Start-Server $where
        $r = Invoke-Api $server 'GET' '/api/state'
        $r.Status | Should -Be 200 -Because $r.Text
        $r.Json.activeJob | Should -BeNullOrEmpty
    }

    It 'keeps its token out of the page, which another user on this PC could fetch' {
        $server = Start-Server (New-Profile)
        $page = Invoke-Api $server 'GET' '/' $null $false
        $page.Status | Should -Be 200
        $page.Text | Should -Not -Match $server.Token
    }

    It 'opens the Hopover already running instead of starting a second one' {
        $where = New-Profile
        $server = Start-Server $where
        $before = Get-Content -LiteralPath (Join-Path $where.AppData 'Hopover\server.json') -Raw
        $ErrorActionPreference = 'Continue'   # the child's own errors are output to read, not to throw
        $out = Invoke-AsUser $where { & $Shell -NoProfile -ExecutionPolicy Bypass -File $Hopover -NoBrowser -Port 1 2>&1 | Out-String }
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match ([regex]::Escape("already running: $($server.Base)/"))
        Get-Content -LiteralPath (Join-Path $where.AppData 'Hopover\server.json') -Raw | Should -BeExactly $before
    }

    It 'never starts a second Hopover over a running one it can''t reach, nor touches its job' {
        $where = New-Profile
        $server = Start-Server $where 'waits'
        $id = Start-Backup $server 'Waiting PC'
        [void](Wait-HopoverJob $server $id { param($r) @($r.events | Where-Object { $_.type -eq 'step-started' }).Count })
        # As when the first is busy (its folder dialog open) and doesn't answer.
        Remove-Item -LiteralPath (Join-Path $where.AppData 'Hopover\server.json')
        $ErrorActionPreference = 'Continue'
        $out = Invoke-AsUser $where { & $Shell -NoProfile -ExecutionPolicy Bypass -File $Hopover -NoBrowser -Port 1 2>&1 | Out-String }
        $LASTEXITCODE | Should -Not -Be 0 -Because $out
        $out | Should -Match 'already running'
        (Invoke-Api $server 'GET' "/api/jobs/$id/events?since=0").Json.job.status | Should -Be 'running'
        Join-Path $where.AppData "Hopover\jobs\$id\staging\unencrypted.txt" | Should -Exist
    }

    It 'says why, in plain words, when New-Backup.ps1 fails' {
        $server = Start-Server (New-Profile) -Real
        $id = Start-Backup $server 'Failing PC' 'correct horse battery' @{ steps = @('nonsense') }
        $done = Wait-HopoverJob $server $id { param($r) $r.job.status -ne 'running' }
        $done.job.status | Should -Be 'failed'
        $end = @($done.events | Where-Object { $_.type -eq 'job-finished' })
        $end.Count | Should -Be 1
        $end[0].code | Should -Be 'backup-failed'
        $end[0].details.reason | Should -Match 'Unknown step\(s\): nonsense'
    }

    It 'makes, from the page, the same Backup as the command line' {
        $where = New-Profile
        $server = Start-Server $where -Real
        $id = Start-Backup $server 'From the page' 'correct horse battery' @{ steps = @() }
        $done = Wait-HopoverJob $server $id { param($r) $r.job.status -ne 'running' }
        $done.job.status | Should -Be 'finished' -Because (ConvertTo-Json -InputObject $done.events -Depth 6)
        $made = @($done.events | Where-Object { $_.type -eq 'job-finished' })[0].details.path
        $made | Should -Be (Join-Path $where.Out 'From the page.hopover.7z')
        # New-Backup.ps1's own events: packing, the file it made, and the end.
        $types = @($done.events | ForEach-Object { "$($_.type):$($_.step)$($_.code)" })
        $types | Should -Contain 'step-started:pack'
        $types | Should -Contain 'step-finished:pack'
        $types | Should -Contain 'item:backup-file'
        $types | Should -Contain 'message:only-some-steps'
        $types | Should -Not -Contain 'message:helper-given' -Because 'no step needed administrator rights, so nothing asked for them'
        @($done.events | Where-Object { $_.type -eq 'percent' })[-1].percent | Should -Be 100
        # Once the job's process has exited, Hopover removes its staging folder too.
        $staging = Join-Path $where.AppData "Hopover\jobs\$id\staging"
        $deadline = (Get-Date).AddSeconds(15)
        while ((Test-Path -LiteralPath $staging) -and (Get-Date) -lt $deadline) { [void](Invoke-Api $server 'GET' "/api/jobs/$id/events?since=0"); Start-Sleep -Milliseconds 250 }
        $staging | Should -Not -Exist

        $ErrorActionPreference = 'Continue'
        $out = Invoke-AsUser $where { 'correct horse battery' | & $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'New-Backup.ps1') -Destination $where.Out -Name 'From the command line' -Steps ',' 2>&1 | Out-String }
        $LASTEXITCODE | Should -Be 0 -Because $out

        $page = Get-BackupListing $made
        $page.Count | Should -BeGreaterThan 0
        $page | Should -Be (Get-BackupListing (Join-Path $where.Out 'From the command line.hopover.7z'))
        $manifests = foreach ($f in $made, (Join-Path $where.Out 'From the command line.hopover.7z')) { ConvertTo-Json -InputObject (Get-BackupManifest $f) -Depth 6 -Compress }
        $manifests[0] | Should -BeExactly $manifests[1]
    }

    It 'puts the drivers the administrator helper saved in a Back up made from the page' {
        $server = Start-Server (New-Profile) -Real
        $id = Start-Backup $server 'With drivers' 'correct horse battery' @{ steps = @('drivers') }
        $done = Wait-HopoverJob $server $id { param($r) $r.job.status -ne 'running' }
        $done.job.status | Should -Be 'finished' -Because (ConvertTo-Json -InputObject $done.events -Depth 6)
        @($done.events | Where-Object { $_.code -eq 'helper-given' }).Count | Should -Be 1 -Because 'one helper runs every administrator step'
        @($done.events | Where-Object { $_.type -eq 'percent' })[0].percent | Should -Be 50 -Because 'the drivers are one of the two shares, packing the other'
        $made = @($done.events | Where-Object { $_.type -eq 'job-finished' })[0].details.path
        Get-BackupListing $made | Should -Contain 'drivers\README.md'
        @((Get-BackupManifest $made).captured) | Should -Contain 'drivers'
    }

    It 'leaves the drivers out of the Backup when the administrator helper <Why>' -ForEach @(
        @{ Why = 'is declined'; Mode = 'declines' }
        @{ Why = 'fails before saving them'; Mode = 'fails' }
    ) {
        $server = Start-Server (New-Profile) -Real -HelperMode $Mode
        $id = Start-Backup $server 'Without drivers' 'correct horse battery' @{ steps = @('drivers') }
        $done = Wait-HopoverJob $server $id { param($r) $r.job.status -ne 'running' }
        $done.job.status | Should -Be 'finished' -Because (ConvertTo-Json -InputObject $done.events -Depth 6)
        @($done.events | Where-Object { $_.type -eq 'step-started' -and $_.step -eq 'drivers' }).Count | Should -Be 0
        $made = @($done.events | Where-Object { $_.type -eq 'job-finished' })[0].details.path
        @(Get-BackupListing $made | Where-Object { $_ -like 'drivers*' }).Count | Should -Be 0
        @((Get-BackupManifest $made).captured) | Should -Not -Contain 'drivers'
    }
}
