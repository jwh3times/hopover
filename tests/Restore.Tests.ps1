# Pester 6 tests for Restore.ps1 restoring from a Backup (seam 3 of spec #12), in a child
# PowerShell whose per-user folders (LOCALAPPDATA, USERPROFILE, TEMP) are inside the test drive.
# Like Backup.Tests.ps1, they download the pinned 7zr.exe, so every run needs the network.

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Backup.ps1')
    $SevenZip = Get-SevenZip -CacheDir (Join-Path $TestDrive 'bin')
    $Restore = Join-Path $root 'Restore.ps1'
    $Shell = (Get-Process -Id $PID).Path
    $pw = (New-Object System.Net.NetworkCredential('', 'correct horse battery')).SecurePassword

    # The restore runs the steps of this prompt's pass only, and GitHub's Windows runners are
    # elevated: so the tests restore app-data, which runs in both passes, from an item of this pass.
    $Elevated = Test-IsAdmin
    $PromptKind = if ($Elevated) { 'elevated' } else { 'normal' }

    # A version-1 Backup, packed by hand from a frozen hopover.json so it stays a version-1
    # Backup whatever version New-Backup writes later: the exports under data\, an app-data item
    # in extras\ that restores %LOCALAPPDATA%\FixtureApp.
    $staging = Join-Path $TestDrive 'staging'
    New-Item -ItemType Directory -Path (Join-Path $staging 'data\settings\dev'), (Join-Path $staging 'extras'), (Join-Path $TestDrive 'app\FixtureApp') | Out-Null
    Set-Content -LiteralPath (Join-Path $staging 'hopover.json') -Encoding ASCII -Value (
        '{ "formatVersion": 1, "hopoverVersion": "v0.3.0", "created": "2026-11-27T09:00:00.0000000Z", "sourceOs": "windows", ' +
        '"computerName": "FIXTURE-PC", "encrypted": true, "includesPasswordsAndKeys": false, "captured": ["settings", "extras"], ' +
        '"groups": ["settings"], "apps": [] }')
    Set-Content -LiteralPath (Join-Path $staging 'data\settings\dev\gitconfig') -Value "[user]`n`tname = Fixture User" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $TestDrive 'app\FixtureApp\settings.txt') -Value 'fixture settings' -Encoding ASCII
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -a -c -f (Join-Path $staging 'extras\app-fixture.zip') -C (Join-Path $TestDrive 'app') FixtureApp
    $item = @{ Name = 'app-fixture'; File = 'app-fixture.zip'; Status = 'ok'; Kind = 'folder'; Admin = $Elevated; RestoreTo = '%LOCALAPPDATA%\FixtureApp' }
    Set-Content -LiteralPath (Join-Path $staging 'extras\manifest.json') -Value (ConvertTo-Json @{ Items = @($item) } -Depth 4) -Encoding UTF8
    $BackupFile = Join-Path $TestDrive 'Fixture PC.hopover.7z'
    Push-Location $staging
    try { & $SevenZip a -t7z '-pcorrect horse battery' -mhe=on $BackupFile * | Out-Null } finally { Pop-Location }

    # A profile: the per-user folders a child PowerShell gets, with the 7zr.exe these tests downloaded.
    function New-Profile {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($sub in 'appdata\Hopover\bin', 'home', 'temp') { New-Item -ItemType Directory -Path (Join-Path $d $sub) | Out-Null }
        Copy-Item -LiteralPath $SevenZip -Destination (Join-Path $d 'appdata\Hopover\bin')
        return [pscustomobject]@{ AppData = (Join-Path $d 'appdata'); Home = (Join-Path $d 'home'); Temp = (Join-Path $d 'temp')
            Unpacked = (Join-Path $d 'appdata\Hopover\restore\Fixture PC') }
    }

    # Restore.ps1 -Backup in a child PowerShell, the password piped in, in that profile.
    function Invoke-Restore($Where, [string]$Phrase = 'correct horse battery', [string[]]$Arguments = @('-DryRun', '-Steps', 'app-data')) {
        $saved = @{ LOCALAPPDATA = $env:LOCALAPPDATA; USERPROFILE = $env:USERPROFILE; TEMP = $env:TEMP; TMP = $env:TMP }
        $env:LOCALAPPDATA = $Where.AppData; $env:USERPROFILE = $Where.Home; $env:TEMP = $Where.Temp; $env:TMP = $Where.Temp
        $ErrorActionPreference = 'Continue'   # the child's own errors are output to read, not to throw
        try {
            $out = $Phrase | & $Shell -NoProfile -ExecutionPolicy Bypass -File $Restore -Backup $BackupFile @Arguments 2>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        } finally {
            foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] }
        }
    }
}

Describe 'Restore.ps1 -Backup -DryRun' {
    BeforeAll {
        $p = New-Profile
        $run = Invoke-Restore $p
    }

    It 'restores a version-1 Backup from an unpacked copy: its data folder and its extras' {
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'unpacked for this dry run'
        $run.Output | Should -Match ([regex]::Escape("\data  ($PromptKind prompt, DRY RUN)"))
        $run.Output | Should -Match ([regex]::Escape("would: extract app-fixture.zip -> $($p.AppData)"))
    }

    It 'changes nothing, and removes the copy it unpacked for the dry run' {
        $run.Output | Should -Match '== app-data'   # the step ran, and only reported
        Join-Path $p.AppData 'FixtureApp' | Should -Not -Exist
        $p.Unpacked | Should -Not -Exist
        @(Get-ChildItem -LiteralPath $p.Temp -Recurse -File | Where-Object { $_.FullName -match 'hopover' }).Count | Should -Be 0
    }

    It 'reports every restore step, here or as one for the other kind of prompt' {
        $all = Invoke-Restore (New-Profile) -Arguments @('-DryRun')
        $all.ExitCode | Should -Be 0
        $steps = @((& $Restore -List -AsJson) | ConvertFrom-Json | ForEach-Object { $_ } | ForEach-Object name)
        $steps.Count | Should -BeGreaterThan 10
        $summary = $all.Output.Substring($all.Output.IndexOf('Summary'))
        foreach ($s in $steps) { $summary | Should -Match "(?m)(^\s+$([regex]::Escape($s))\s|for:.*\b$([regex]::Escape($s))\b)" -Because "step $s" }
    }
}

Describe 'Restore.ps1 -Backup, for real' {
    BeforeAll {
        $p = New-Profile
        $run = Invoke-Restore $p -Arguments @('-Steps', 'app-data')
    }

    It 'restores from the Backup into this profile' {
        $run.ExitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $p.AppData 'FixtureApp\settings.txt') -Raw) | Should -Match 'fixture settings'
    }

    It 'keeps the unpacked copy for the next run, and says where it is and what it holds' {
        Join-Path $p.Unpacked 'data\settings\dev\gitconfig' | Should -Exist
        $run.Output | Should -Match ([regex]::Escape($p.Unpacked))
        $run.Output | Should -Match 'unencrypted'
    }

    It 'reuses that copy on the next run, a dry run included' {
        $again = Invoke-Restore $p
        $again.ExitCode | Should -Be 0
        $again.Output | Should -Match 'already unpacked'
        Join-Path $p.Unpacked 'data\settings\dev\gitconfig' | Should -Exist
    }
}

Describe 'Restore.ps1 -Backup with the password piped in' {
    It 'uses the password piped in, without the BOM a UTF-8 console puts in front of it' {
        # Windows PowerShell 5.1 pipes into a PowerShell it starts with a UTF-8 BOM in front when the
        # console is UTF-8 (code page 65001, as on GitHub's Windows runners), and PowerShell 7 reads
        # it as the password's first character. The child's input here is those bytes, from a file.
        $p = New-Profile
        $stdin = Join-Path $p.Temp 'stdin.txt'
        [IO.File]::WriteAllBytes($stdin, [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::ASCII.GetBytes("correct horse battery`r`n")))
        $stdout = Join-Path $p.Home 'stdout.txt'
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', """$Restore""", '-Backup', """$BackupFile""", '-DryRun', '-Steps', 'app-data')
        $saved = @{ LOCALAPPDATA = $env:LOCALAPPDATA; USERPROFILE = $env:USERPROFILE; TEMP = $env:TEMP; TMP = $env:TMP }
        $savedEncoding = [Console]::InputEncoding
        try { [Console]::InputEncoding = [Text.Encoding]::UTF8 } catch { Set-ItResult -Skipped -Because 'this host has no console whose encoding can be set'; return }
        try {
            $env:LOCALAPPDATA = $p.AppData; $env:USERPROFILE = $p.Home; $env:TEMP = $p.Temp; $env:TMP = $p.Temp
            $child = Start-Process -FilePath $Shell -ArgumentList $arguments -RedirectStandardInput $stdin -RedirectStandardOutput $stdout `
                -RedirectStandardError (Join-Path $p.Home 'stderr.txt') -NoNewWindow -Wait -PassThru
        } finally {
            [Console]::InputEncoding = $savedEncoding
            foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] }
        }
        $out = Get-Content -LiteralPath $stdout -Raw
        $child.ExitCode | Should -Be 0 -Because $out
        $out | Should -Match 'unpacked for this dry run'
    }
}

Describe 'Restore.ps1 -Backup refusing' {
    It 'stops on a wrong password in plain words, before any step, unpacking nothing' {
        $p = New-Profile
        $run = Invoke-Restore $p -Phrase 'wrong horse battery'
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match ([regex]::Escape("That password doesn't open the Backup ""Fixture PC"". Nothing was restored."))
        $run.Output | Should -Not -Match '\.ps1:\d'   # a message, not a script error from any file
        $run.Output | Should -Not -Match '== [a-z-]+: '   # no step ran
        $p.Unpacked | Should -Not -Exist
        @(Get-ChildItem -LiteralPath $p.Temp -Recurse -File).Count | Should -Be 0
    }

    It 'says so in plain words when a folder that is not Hopover''s is in the way' {
        $p = New-Profile
        New-Item -ItemType Directory -Path $p.Unpacked | Out-Null
        Set-Content -LiteralPath (Join-Path $p.Unpacked 'keep.txt') -Value 'mine' -Encoding ASCII
        $run = Invoke-Restore $p -Arguments @('-Steps', 'app-data')
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match "in the way and wasn't unpacked by Hopover; move it, then try again\. Nothing was restored\."
        $run.Output | Should -Not -Match '\.ps1:\d'   # a message, not a script error from any file
        Join-Path $p.Unpacked 'keep.txt' | Should -Exist
    }

    It 'refuses -DataDir alongside -Backup, since the Backup holds the data folder' {
        $p = New-Profile
        $run = Invoke-Restore $p -Arguments @('-DryRun', '-DataDir', (Join-Path $p.Home 'elsewhere'))
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match 'leave out -DataDir and -MigrationRoot'
        $run.Output | Should -Not -Match '== [a-z-]+: '   # no step ran
    }
}
