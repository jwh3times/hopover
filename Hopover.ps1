<#
    Hopover.ps1
    Hopover's home page: Back up, Check I'm ready and Restore, in your browser
    (docs/adr/0003-powershell-and-a-browser-page.md). Hopover.cmd starts it; double-click that.

        powershell -ExecutionPolicy Bypass -File .\Hopover.ps1
        powershell -ExecutionPolicy Bypass -File .\Hopover.ps1 -Port 8800 -NoBrowser

    A Back up runs as a job in a child process. Closing the browser tab doesn't stop it, and
    opening Hopover again reconnects to it; closing this window, or a confirmed Stop on the page,
    ends it. While it runs, starting Hopover again just opens the page again.

    The page is served on http://localhost only, and every request has to carry a token that
    changes each run, so other sites in the browser can't use it. Hopover makes no network request
    of its own except downloading 7-Zip (and, when restoring, apps).

    Options:
        -Port n          first port to try (default 8765; the next ten are tried after it)
        -NoBrowser       don't open the page
        -BackupScript    for tests: the script a Back up runs instead of New-Backup.ps1
                         (same parameters, the password on standard input)

    Works in Windows PowerShell 5.1 (a fresh install) and PowerShell 7.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 8765,
    [switch]$NoBrowser,
    [string]$BackupScript
)

$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$scriptDir = $scriptDir.TrimEnd('\')
. (Join-Path $scriptDir 'lib\Common.ps1')
. (Join-Path $scriptDir 'lib\Backup.ps1')
. (Join-Path $scriptDir 'lib\Server.ps1')
. (Join-Path $scriptDir 'lib\Jobs.ps1')
if (-not $BackupScript) { $BackupScript = Join-Path $scriptDir 'New-Backup.ps1' }
$PagePath   = Join-Path $scriptDir 'ui\index.html'
$HopoverDir = Get-HopoverHome
$ServerFile = Join-Path $HopoverDir 'server.json'
if (-not (Test-Path -LiteralPath $PagePath)) { throw "Missing $PagePath." }

# ---------------------------------------------------------------------------
# One Hopover per user: a named mutex says one is running, whether or not it answers just now (its
# folder dialog may be open). A second start opens that one's page, and never touches its jobs.
# ---------------------------------------------------------------------------
$mutexKey = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($Utf8.GetBytes($HopoverDir.ToLowerInvariant()))).Replace('-', '')
$script:Mutex = New-Object System.Threading.Mutex($false, "Local\Hopover-$($mutexKey.Substring(0, 32))")
$owned = $false
try { $owned = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    # It may be starting this moment: give it a few seconds to say where it is.
    $running = $null
    $deadline = (Get-Date).AddSeconds(10)
    while (-not $running -and (Get-Date) -lt $deadline) {
        try { $running = Read-JsonFile $ServerFile } catch { }
        if (-not ($running -and $running.url -and $running.token)) { $running = $null; Start-Sleep -Milliseconds 250 }
    }
    if ($running) {
        Write-Host "Hopover is already running: $($running.url)" -ForegroundColor Cyan
        if (-not $NoBrowser) { Start-Process "$($running.url)#token=$($running.token)" }
        exit 0
    }
    Write-Host 'Hopover is already running, but its page address can''t be read. Close its window ("Hopover is running"), then start Hopover again.' -ForegroundColor Red
    exit 1
}
try { $Host.UI.RawUI.WindowTitle = "Hopover is running $([char]0x2014) close this to stop" } catch { }

# ---------------------------------------------------------------------------
# Jobs (lib\Jobs.ps1)
# ---------------------------------------------------------------------------
$script:Running = @{}   # job id -> the process and job object of a job this server started

# A job's summary, once any end it didn't say is recorded: a job of this server whose process
# exited without a job-finished event, or a job of an earlier run, whose processes ended with it.
function Sync-Job([string]$Dir) {
    $job = Read-Job $Dir
    if (-not $job) { return $null }
    $events = Get-JobEventsPath $Dir
    $mine = $script:Running[$job.id]
    if ($mine -and $mine.Process.HasExited) {
        [void](Close-EndedJob $Dir 'job-ended' @{ exitCode = $mine.Process.ExitCode })
        Remove-JobStaging $Dir
        Close-JobProcess $mine
        $script:Running.Remove($job.id)
    } elseif (-not $mine) {
        [void](Close-EndedJob $Dir 'job-interrupted')
    }
    $status = Get-JobStatusFromEvents (Read-JobEvents $events).Events
    [ordered]@{ id = $job.id; kind = $job.kind; status = $status; started = $job.started; name = $job.name; destination = $job.destination }
}

function Get-ActiveJob {
    foreach ($dir in Get-JobDirs) {
        $s = Sync-Job $dir
        if ($s -and $s.status -eq 'running') { return $s }
    }
    return $null
}

function Get-LastJob {
    $dir = @(Get-JobDirs) | Select-Object -First 1
    if ($dir) { return Sync-Job $dir }
    return $null
}

# Jobs an earlier run left unfinished ended with it: say so, and clear what they left behind.
function Close-InterruptedJobs { foreach ($dir in Get-JobDirs) { [void](Sync-Job $dir) } }

# A name Windows keeps for a device: a file called that (with any extension) can't be made.
function Test-DeviceName([string]$Name) { $Name.Split('.')[0].Trim() -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$' }

# A Back up from the page: the same New-Backup.ps1 the command line runs.
function Start-BackupJob($Ctx, $Body) {
    if (Get-ActiveJob) { Send-Error $Ctx 409 'job-running'; return }
    $name = ([string]$Body.name).Trim()
    $destination = [Environment]::ExpandEnvironmentVariables(([string]$Body.destination).Trim())
    $password = [string]$Body.password
    if (-not $name) { Send-Error $Ctx 400 'name-missing'; return }
    if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $name.Trim('.') -ne $name -or (Test-DeviceName $name)) { Send-Error $Ctx 400 'name-invalid' @{ name = $name }; return }
    if (-not $destination) { Send-Error $Ctx 400 'destination-missing'; return }
    # A whole path: a drive (E:\) or a network share (\\server\share). Anything else would be
    # taken from wherever Hopover happens to run.
    if ($destination -notmatch '^([A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)') { Send-Error $Ctx 400 'destination-not-whole' @{ path = $destination }; return }
    try { $destination = [IO.Path]::GetFullPath($destination) } catch { Send-Error $Ctx 400 'destination-not-found' @{ path = $destination }; return }
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) { Send-Error $Ctx 400 'destination-not-found' @{ path = $destination }; return }
    if (@(Get-BackupFiles $destination $name).Count) { Send-Error $Ctx 400 'backup-exists' @{ name = $name; path = $destination }; return }
    if ($password.Length -lt 8) { Send-Error $Ctx 400 'password-too-short'; return }
    if ($password -cne [string]$Body.passwordAgain) { Send-Error $Ctx 400 'passwords-differ'; return }

    $id = New-JobId
    $dir = Join-Path (Get-JobsRoot) $id
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $job = [ordered]@{ id = $id; kind = 'backup'; started = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); name = $name; destination = $destination }
    [IO.File]::WriteAllText((Join-Path $dir 'job.json'), (ConvertTo-Json -InputObject $job), $Utf8)
    $events = Get-JobEventsPath $dir
    Add-JobEvent -Path $events -Type 'job-started' -Code 'backup-started' -Details @{ name = $name; destination = $destination }

    $arguments = @('-Destination', $destination, '-Name', $name, '-StagingDir', (Join-Path $dir 'staging'), '-EventLog', $events)
    # The command line's -Steps, which the tests use to make a quick Backup; the page sends none,
    # so every step runs. A trailing comma keeps an empty list a list: New-Backup.ps1 runs no step.
    if ($Body.PSObject.Properties.Name -contains 'steps') {
        $list = (@($Body.steps) | ForEach-Object { [string]$_ }) -join ','
        $arguments += @('-Steps', "$list,")
    }
    $secure = (New-Object System.Net.NetworkCredential('', $password)).SecurePassword
    try {
        $script:Running[$id] = Start-JobProcess $BackupScript $arguments $secure
    } catch {
        [void](Close-EndedJob $dir 'backup-failed' @{ reason = $_.Exception.Message })
        throw
    }
    Write-Host "Back up started: $name -> $destination" -ForegroundColor Cyan
    Send-Json $Ctx @{ job = (Sync-Job $dir) }
}

# A confirmed Stop. A job that finished just before it was stopped stays finished.
function Stop-HopoverJob($Ctx, [string]$Dir, $Body) {
    if (-not ($Body -and $Body.confirm -eq $true)) { Send-Error $Ctx 400 'confirm-needed'; return }
    $job = Read-Job $Dir
    $mine = $script:Running[$job.id]
    if ($mine) {
        Stop-JobProcess $mine
        $script:Running.Remove($job.id)
        if (Close-EndedJob $Dir 'job-stopped') { Write-Host "Stopped the $($job.kind): $($job.name)" -ForegroundColor Yellow }
    }
    Send-Json $Ctx @{ job = (Sync-Job $Dir) }
}

# The events from ?since=n on, each as the job wrote it.
function Send-JobEvents($Ctx, [string]$Dir) {
    $since = 0
    [void][int]::TryParse([string]$Ctx.Request.QueryString['since'], [ref]$since)
    $summary = Sync-Job $Dir
    $read = Read-JobEvents (Get-JobEventsPath $Dir) $since
    $json = '{"job":' + (ConvertTo-Json -InputObject $summary -Compress) + ',"events":[' + ($read.Raw -join ',') + '],"next":' + $read.Next + '}'
    Send-Text $Ctx 200 'application/json; charset=utf-8' $json
}

# A folder chosen in Windows' own dialog, shown in front of the browser. It runs in a separate
# Windows PowerShell, since the dialog needs a single-threaded apartment.
function Get-PickedFolder([string]$Start) {
    $picker = @'
Add-Type -AssemblyName System.Windows.Forms
$owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{ Description = 'Where to save the Backup'; ShowNewFolderButton = $true }
if ($env:HOPOVER_PICK_START -and (Test-Path -LiteralPath $env:HOPOVER_PICK_START)) { $dialog.SelectedPath = $env:HOPOVER_PICK_START }
if ($dialog.ShowDialog($owner) -eq 'OK') { [Console]::Out.Write($dialog.SelectedPath) }
'@
    $env:HOPOVER_PICK_START = $Start
    try {
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($picker))
        $out = & $exe -NoProfile -STA -ExecutionPolicy Bypass -EncodedCommand $encoded
    } finally { Remove-Item Env:\HOPOVER_PICK_START -ErrorAction SilentlyContinue }
    $path = (@($out) -join '').Trim()
    if ($path) { return $path }
    return $null
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
$Token = [guid]::NewGuid().ToString('N')

function Invoke-Request($Ctx) {
    $req = $Ctx.Request
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod

    # The page goes out without the token: it takes it from the address this server opened.
    if ($path -eq '/' -and $method -eq 'GET') { Send-Page $Ctx $PagePath '' 'home'; return }
    if (-not $path.StartsWith('/api/')) { Send-Text $Ctx 404 'text/plain' 'Not found'; return }
    if (-not (Test-RequestToken $Ctx $Token)) { Send-Text $Ctx 403 'text/plain' 'Forbidden'; return }

    $body = $null
    if ($method -eq 'POST') {
        $text = Read-Body $Ctx
        if ($text.Trim()) {
            try { $body = $text | ConvertFrom-Json } catch { Send-Error $Ctx 400 'not-json'; return }
        }
    }

    if ($path -match '^/api/jobs/([^/]+)/(events|stop)$') {
        $dir = Get-JobDir $Matches[1]
        $action = $Matches[2]
        if (-not $dir) { Send-Error $Ctx 404 'job-not-found'; return }
        if ($action -eq 'events' -and $method -eq 'GET') { Send-JobEvents $Ctx $dir; return }
        if ($action -eq 'stop' -and $method -eq 'POST') { Stop-HopoverJob $Ctx $dir $body; return }
        Send-Error $Ctx 405 'wrong-method'
        return
    }

    switch ("$method $path") {
        'GET /api/ping' { Send-Json $Ctx @{ ok = $true } }
        'GET /api/state' {
            $options = Get-Options (Resolve-DataDir $null)
            $suggested = Expand-ConfigPath $options.migrationRoot
            Send-Json $Ctx ([ordered]@{
                computer             = $env:COMPUTERNAME
                version              = Get-HopoverVersion
                suggestedName        = "$env:COMPUTERNAME $(Get-Date -Format 'yyyy-MM-dd')"
                suggestedDestination = $(if ($suggested -and (Test-Path -LiteralPath $suggested -PathType Container)) { $suggested } else { '' })
                activeJob            = Get-ActiveJob
                lastJob              = Get-LastJob
            })
        }
        'POST /api/backup' { if ($null -eq $body) { Send-Error $Ctx 400 'not-json' } else { Start-BackupJob $Ctx $body } }
        'POST /api/pick-folder' { Send-Json $Ctx @{ path = (Get-PickedFolder ([string]$body.start)) } }
        default { Send-Error $Ctx 404 'not-found' }
    }
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Path $HopoverDir -Force | Out-Null
Close-InterruptedJobs

$server = Start-LocalListener $Port
$url = "http://localhost:$($server.Port)/"
[IO.File]::WriteAllText($ServerFile, (ConvertTo-Json -InputObject ([ordered]@{ port = $server.Port; token = $Token; pid = $PID; url = $url })), $Utf8)
Write-Host "Hopover: $url" -ForegroundColor Cyan
Write-Host 'Leave this window open while Hopover works. Closing it stops Hopover, and anything it is doing.'
if (-not $NoBrowser) { Start-Process "$url#token=$Token" }
try {
    Invoke-LocalServer $server.Listener { param($ctx) Invoke-Request $ctx } { $true }
} finally {
    Remove-Item -LiteralPath $ServerFile -Force -ErrorAction SilentlyContinue
}
