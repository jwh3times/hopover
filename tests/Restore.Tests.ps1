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

    # A version-1 Backup, packed by hand from a frozen hopover.json so it stays a version-1
    # Backup whatever version New-Backup writes later: the exports under data\, an app-data item
    # in extras\.
    $staging = Join-Path $TestDrive 'staging'
    New-Item -ItemType Directory -Path (Join-Path $staging 'data\settings\dev'), (Join-Path $staging 'extras') | Out-Null
    Set-Content -LiteralPath (Join-Path $staging 'hopover.json') -Encoding ASCII -Value (
        '{ "formatVersion": 1, "hopoverVersion": "v0.3.0", "created": "2026-11-27T09:00:00.0000000Z", "sourceOs": "windows", ' +
        '"computerName": "FIXTURE-PC", "encrypted": true, "includesPasswordsAndKeys": false, "captured": ["settings", "extras"], ' +
        '"groups": ["settings"], "apps": [] }')
    Set-Content -LiteralPath (Join-Path $staging 'data\settings\dev\gitconfig') -Value "[user]`n`tname = Fixture User" -Encoding ASCII
    [IO.File]::WriteAllBytes((Join-Path $staging 'extras\app-fixture.zip'), (New-Object byte[] 22))
    $item = @{ Name = 'app-fixture'; File = 'app-fixture.zip'; Status = 'ok'; Kind = 'folder'; Admin = $false; RestoreTo = '%LOCALAPPDATA%\FixtureApp' }
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
    function Invoke-Restore($Where, [string]$Phrase = 'correct horse battery', [string[]]$Arguments = @('-DryRun', '-Steps', 'git-config,app-data')) {
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
        $run.Output | Should -Match ([regex]::Escape('\data  (normal prompt, DRY RUN)'))
        $run.Output | Should -Match ([regex]::Escape("would: copy gitconfig -> $($p.Home)\.gitconfig"))
        $run.Output | Should -Match ([regex]::Escape('would: extract app-fixture.zip'))
    }

    It 'changes nothing, and removes the copy it unpacked for the dry run' {
        $run.Output | Should -Match '== git-config'   # the steps ran, and only reported
        Join-Path $p.Home '.gitconfig' | Should -Not -Exist
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
        $run = Invoke-Restore $p -Arguments @('-Steps', 'git-config')
    }

    It 'restores from the Backup into this profile' {
        $run.ExitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $p.Home '.gitconfig') -Raw) | Should -Match 'Fixture User'
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

Describe 'Restore.ps1 -Backup refusing' {
    It 'stops on a wrong password in plain words, before any step, unpacking nothing' {
        $p = New-Profile
        $run = Invoke-Restore $p -Phrase 'wrong horse battery'
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match ([regex]::Escape("That password doesn't open the Backup ""Fixture PC"". Nothing was restored."))
        $run.Output | Should -Not -Match '\.ps1:\d'   # a message, not a script error from any file
        $run.Output | Should -Not -Match '== git-config'
        $p.Unpacked | Should -Not -Exist
        @(Get-ChildItem -LiteralPath $p.Temp -Recurse -File).Count | Should -Be 0
    }

    It 'says so in plain words when a folder that is not Hopover''s is in the way' {
        $p = New-Profile
        New-Item -ItemType Directory -Path $p.Unpacked | Out-Null
        Set-Content -LiteralPath (Join-Path $p.Unpacked 'keep.txt') -Value 'mine' -Encoding ASCII
        $run = Invoke-Restore $p -Arguments @('-Steps', 'git-config')
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
        $run.Output | Should -Not -Match '== git-config'
    }
}
