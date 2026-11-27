# Pester 6 tests for lib\Backup.ps1, the Backup module (seam 1 of spec #12). They use the real,
# pinned 7zr.exe, downloaded into each run's TestDrive like Hopover downloads it, so every run
# needs the network.

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Backup.ps1')
    $pinFile = Join-Path $root 'lib\7zip.json'
    $Pin = Get-Content -LiteralPath $pinFile -Raw | ConvertFrom-Json
    $SevenZip = Get-SevenZip -CacheDir (Join-Path $TestDrive 'bin')

    # A password as the module takes it, without ConvertTo-SecureString -AsPlainText.
    function New-TestPassword([string]$Text) { (New-Object System.Net.NetworkCredential('', $Text)).SecurePassword }

    # A staging tree like the one the Backup command builds: data\ (the exports) and extras\.
    function New-TestStaging {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir 'data\settings\dev'), (Join-Path $dir 'data\settings\windows'), (Join-Path $dir 'extras') | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'data\settings\windows\hosts') -Value '127.0.0.1 secret-project.local' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir 'extras\manifest.json') -Value '{ "Items": [] }' -Encoding UTF8
        return $dir
    }
    function New-TestDestination { $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $d | Out-Null; $d }
}

Describe 'New-Backup and Test-Backup' {
    It 'makes a .hopover.7z named by the user that opens with its password and refuses any other' {
        $out = New-TestDestination
        $made = New-Backup -Source (New-TestStaging) -Destination $out -Name 'Test PC 2026-11-26' -Password (New-TestPassword 'correct horse battery') -SevenZip $SevenZip
        $made.Path | Should -Be (Join-Path $out 'Test PC 2026-11-26.hopover.7z')
        $made.Path | Should -Exist

        (Test-Backup -Path $made.Path -Password (New-TestPassword 'correct horse battery') -SevenZip $SevenZip).Result | Should -Be 'ok'
        (Test-Backup -Path $made.Path -Password (New-TestPassword 'wrong horse battery') -SevenZip $SevenZip).Result | Should -Be 'wrong-password'
        (Test-Backup -Path $made.Path -SevenZip $SevenZip).Result | Should -Be 'password-needed'
    }

    It 'hides the file names of an encrypted Backup from anyone without the password' {
        $made = New-Backup -Source (New-TestStaging) -Destination (New-TestDestination) -Name 'names' -Password (New-TestPassword 'correct horse battery') -SevenZip $SevenZip
        $listing = cmd /c "`"$SevenZip`" l `"$($made.Path)`" < nul 2>&1" | Out-String
        $listing | Should -Not -Match 'hosts'
        $listing | Should -Not -Match 'settings'
    }

    It 'makes an unprotected Backup only when asked, which opens with no password' {
        $made = New-Backup -Source (New-TestStaging) -Destination (New-TestDestination) -Name 'open' -NoEncryption -SevenZip $SevenZip
        $made.Encrypted | Should -BeFalse
        (Test-Backup -Path $made.Path -SevenZip $SevenZip).Result | Should -Be 'ok'
        (cmd /c "`"$SevenZip`" l `"$($made.Path)`" < nul 2>&1" | Out-String) | Should -Match 'hosts'
    }

    It 'takes a password with accented and non-Latin letters' {
        $pw = "p$([char]0x00E4)ssw$([char]0x00F6)rd-$([char]0x65E5)$([char]0x672C)"
        $made = New-Backup -Source (New-TestStaging) -Destination (New-TestDestination) -Name 'unicode' -Password (New-TestPassword $pw) -SevenZip $SevenZip
        (Test-Backup -Path $made.Path -Password (New-TestPassword $pw) -SevenZip $SevenZip).Result | Should -Be 'ok'
        (Test-Backup -Path $made.Path -Password (New-TestPassword "passw$([char]0x00F6)rd-$([char]0x65E5)$([char]0x672C)") -SevenZip $SevenZip).Result | Should -Be 'wrong-password'
        # 7-Zip itself, given the same password the ordinary way, opens it too: the Backup isn't
        # locked to Hopover's way of passing the password.
        & $SevenZip t "-p$pw" $made.Path | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'gives 7-Zip exactly the password typed when the console is UTF-8' {
        # Windows PowerShell 5.1's .NET writes the console input encoding's preamble into a
        # started process's standard input: under code page 65001, a UTF-8 BOM that 7-Zip would
        # take as the start of the password. GitHub's Windows runners have such a console.
        $saved = [Console]::InputEncoding
        try { [Console]::InputEncoding = [Text.Encoding]::UTF8 } catch { Set-ItResult -Skipped -Because 'this host has no console whose encoding can be set'; return }
        try {
            $made = New-Backup -Source (New-TestStaging) -Destination (New-TestDestination) -Name 'utf8 console' -Password (New-TestPassword 'correct horse battery') -SevenZip $SevenZip
        } finally { [Console]::InputEncoding = $saved }
        & $SevenZip t '-pcorrect horse battery' $made.Path | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'refuses to make a Backup with no password unless -NoEncryption says so' {
        { New-Backup -Source (New-TestStaging) -Destination (New-TestDestination) -Name 'nopw' -SevenZip $SevenZip } | Should -Throw '*password*'
    }

    It 'splits a Backup into pieces of the given size that open as one' {
        $staging = New-TestStaging
        $bytes = New-Object byte[] 300000
        (New-Object Random 42).NextBytes($bytes)
        [IO.File]::WriteAllBytes((Join-Path $staging 'extras\big.bin'), $bytes)
        $out = New-TestDestination
        $pw = New-TestPassword 'correct horse battery'
        $made = New-Backup -Source $staging -Destination $out -Name 'split' -Password $pw -SplitBytes 65536 -SevenZip $SevenZip

        $made.Path | Should -Be (Join-Path $out 'split.hopover.7z.001')
        $pieces = @(Get-ChildItem -LiteralPath $out -File)
        $pieces.Count | Should -BeGreaterThan 3
        ($pieces | Where-Object Length -gt 65536).Count | Should -Be 0
        (Test-Backup -Path $made.Path -Password $pw -SevenZip $SevenZip).Result | Should -Be 'ok'

        $unpacked = New-TestDestination
        & $SevenZip x '-pcorrect horse battery' "-o$unpacked" $made.Path | Out-Null
        (Get-FileHash -LiteralPath (Join-Path $unpacked 'extras\big.bin')).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $staging 'extras\big.bin')).Hash
    }

    It 'tells a missing Backup from a damaged one' {
        (Test-Backup -Path (Join-Path $TestDrive 'nowhere.hopover.7z') -SevenZip $SevenZip).Result | Should -Be 'missing'
        $junk = Join-Path (New-TestDestination) 'junk.hopover.7z'
        [IO.File]::WriteAllBytes($junk, [byte[]](1..200))
        (Test-Backup -Path $junk -Password (New-TestPassword 'correct horse battery') -SevenZip $SevenZip).Result | Should -Be 'damaged'
    }

    It 'refuses to overwrite a Backup that already has that name' {
        $out = New-TestDestination
        $pw = New-TestPassword 'correct horse battery'
        $first = New-Backup -Source (New-TestStaging) -Destination $out -Name 'same' -Password $pw -SevenZip $SevenZip
        $before = (Get-FileHash -LiteralPath $first.Path).Hash
        { New-Backup -Source (New-TestStaging) -Destination $out -Name 'same' -Password $pw -SevenZip $SevenZip } | Should -Throw '*already*'
        (Get-FileHash -LiteralPath $first.Path).Hash | Should -Be $before
    }
}

Describe 'hopover.json' {
    BeforeAll {
        $staging = New-TestStaging
        $winget = @{ Sources = @(@{ SourceDetails = @{ Name = 'winget' }; Packages = @(
            @{ PackageIdentifier = 'Git.Git' }, @{ PackageIdentifier = 'Microsoft.DotNet.SDK.8' },
            @{ PackageIdentifier = 'Microsoft.VCRedist.2015+.x64' }, @{ PackageIdentifier = 'Contoso.NotInCatalog' },
            # The catalog's JetBrains.* pattern matches ids that start with JetBrains., not ones that contain it.
            @{ PackageIdentifier = 'Contoso.JetBrains.Helper' }) }) }
        Set-Content -LiteralPath (Join-Path $staging 'data\winget-packages.json') -Value (ConvertTo-Json $winget -Depth 6) -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $staging 'data\settings\dev\packages.json') -Value '{ "Choco": ["7zip", "contoso-tool"], "Npm": [] }' -Encoding UTF8
        $made = New-Backup -Source $staging -Destination (New-TestDestination) -Name 'manifest' -Password (New-TestPassword 'correct horse battery') -Captured 'catalog', 'settings' -SevenZip $SevenZip
        $unpacked = New-TestDestination
        & $SevenZip e '-pcorrect horse battery' "-o$unpacked" $made.Path 'hopover.json' | Out-Null
        $m = Get-Content -LiteralPath (Join-Path $unpacked 'hopover.json') -Raw | ConvertFrom-Json
    }

    It 'sits at the root of the Backup with the format version, where it came from and when' {
        $m.formatVersion | Should -Be 1
        $m.hopoverVersion | Should -Not -BeNullOrEmpty
        $m.sourceOs | Should -Be 'windows'
        $m.computerName | Should -Be $env:COMPUTERNAME
        ([datetime]$m.created).ToUniversalTime() | Should -BeGreaterThan (Get-Date).ToUniversalTime().AddMinutes(-10)
        @($m.captured) | Should -Be @('catalog', 'settings')
    }

    It 'says whether the Backup is encrypted and whether it holds passwords and keys' {
        $m.encrypted | Should -BeTrue
        $m.includesPasswordsAndKeys | Should -BeFalse
    }

    It 'lists the apps by catalog key, with their winget or Chocolatey ids' {
        $apps = @($m.apps)
        $apps.Count | Should -Be 7
        ($apps | Where-Object winget -eq 'Git.Git').catalogKey | Should -Be 'Git.Git'
        ($apps | Where-Object winget -eq 'Microsoft.DotNet.SDK.8').catalogKey | Should -Be 'dotnet-sdk'
        ($apps | Where-Object choco -eq '7zip').catalogKey | Should -Be '7zip.7zip'
    }

    It 'lists apps the catalog does not know, and Windows-only ones, by their source id alone' {
        $unknown = @($m.apps) | Where-Object { $_.winget -in 'Contoso.NotInCatalog', 'Contoso.JetBrains.Helper' -or $_.choco -eq 'contoso-tool' }
        @($unknown).Count | Should -Be 3
        @($unknown | Where-Object { $_.PSObject.Properties.Name -contains 'catalogKey' }).Count | Should -Be 0
        $vc = @($m.apps) | Where-Object winget -eq 'Microsoft.VCRedist.2015+.x64'
        $vc.windowsOnly | Should -BeTrue
        $vc.PSObject.Properties.Name | Should -Not -Contain 'catalogKey'
    }

    It 'names the groups the Backup holds, and only those' {
        @($m.groups) | Should -Be @('apps', 'settings')
    }

    It 'names Developer tools when the Backup holds a repo list' {
        $dev = New-TestStaging
        Set-Content -LiteralPath (Join-Path $dev 'data\settings\dev\repos.json') -Value '[]' -Encoding UTF8
        $made = New-Backup -Source $dev -Destination (New-TestDestination) -Name 'dev' -NoEncryption -SevenZip $SevenZip
        $unpacked = New-TestDestination
        & $SevenZip e "-o$unpacked" $made.Path 'hopover.json' | Out-Null
        @((Get-Content -LiteralPath (Join-Path $unpacked 'hopover.json') -Raw | ConvertFrom-Json).groups) | Should -Contain 'developer-tools'
    }
}

Describe 'ConvertFrom-PipedPassword' {
    It 'drops the BOM Windows PowerShell 5.1 puts in front of piped text on a UTF-8 console' {
        $sec = ConvertFrom-PipedPassword ([string][char]0xFEFF + 'correct horse battery')
        # Compare ordinally: culture-aware comparison (Should -BeExactly included) ignores U+FEFF.
        $plain = (New-Object System.Net.NetworkCredential('', $sec)).Password
        $plain.Length | Should -Be 21
        [string]::Equals($plain, 'correct horse battery', [StringComparison]::Ordinal) | Should -BeTrue
    }

    It 'keeps every other character, and gives nothing for an empty line' {
        $sec = ConvertFrom-PipedPassword (' p' + [char]0x00E4 + 'ss ')
        (New-Object System.Net.NetworkCredential('', $sec)).Password | Should -BeExactly (' p' + [char]0x00E4 + 'ss ')
        ConvertFrom-PipedPassword '' | Should -BeNullOrEmpty
    }
}

Describe 'New-Backup.ps1 with the password piped in' {
    It 'uses the password piped in, without the BOM a UTF-8 console puts in front of it' {
        # Windows PowerShell 5.1 pipes into a PowerShell it starts with a UTF-8 BOM in front when the
        # console is UTF-8 (code page 65001, as on GitHub's Windows runners), and PowerShell 7 reads
        # it as the password's first character. The child's input here is those bytes, from a file,
        # on a UTF-8 console; it makes a Backup of no steps.
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($sub in 'appdata\Hopover\bin', 'data', 'out', 'temp') { New-Item -ItemType Directory -Path (Join-Path $d $sub) | Out-Null }
        Copy-Item -LiteralPath $SevenZip -Destination (Join-Path $d 'appdata\Hopover\bin')
        $stdin = Join-Path $d 'stdin.txt'
        [IO.File]::WriteAllBytes($stdin, [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::ASCII.GetBytes("correct horse battery`r`n")))
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', """$(Join-Path $root 'New-Backup.ps1')""",
            '-Destination', """$(Join-Path $d 'out')""", '-Name', 'piped', '-Steps', ',', '-DataDir', """$(Join-Path $d 'data')""")
        $saved = @{ LOCALAPPDATA = $env:LOCALAPPDATA; TEMP = $env:TEMP; TMP = $env:TMP }
        $savedEncoding = [Console]::InputEncoding
        try { [Console]::InputEncoding = [Text.Encoding]::UTF8 } catch { Set-ItResult -Skipped -Because 'this host has no console whose encoding can be set'; return }
        try {
            $env:LOCALAPPDATA = Join-Path $d 'appdata'; $env:TEMP = Join-Path $d 'temp'; $env:TMP = $env:TEMP
            $child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -RedirectStandardInput $stdin `
                -RedirectStandardOutput (Join-Path $d 'stdout.txt') -RedirectStandardError (Join-Path $d 'stderr.txt') -NoNewWindow -Wait -PassThru
        } finally {
            [Console]::InputEncoding = $savedEncoding
            foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] }
        }
        $child.ExitCode | Should -Be 0 -Because ((Get-Content -LiteralPath (Join-Path $d 'stdout.txt'), (Join-Path $d 'stderr.txt') -Raw) -join '')
        $made = Join-Path $d 'out\piped.hopover.7z'
        (Test-Backup -Path $made -Password (New-TestPassword 'correct horse battery') -SevenZip $SevenZip).Result | Should -Be 'ok'
    }
}

Describe 'Expand-Backup' {
    BeforeAll {
        $pw = New-TestPassword 'correct horse battery'
        $made = New-Backup -Source (New-TestStaging) -Destination (New-TestDestination) -Name 'Laptop 2026-11-27' -Password $pw -SevenZip $SevenZip
    }
    BeforeEach { $restoreRoot = New-TestDestination }

    It 'unpacks a Backup into a folder named after it' {
        $u = Expand-Backup -Path $made.Path -Password $pw -RestoreRoot $restoreRoot -SevenZip $SevenZip
        $u.Folder | Should -Be (Join-Path $restoreRoot 'Laptop 2026-11-27')
        $u.Reused | Should -BeFalse
        Join-Path $u.Folder 'data\settings\windows\hosts' | Should -Exist
        Join-Path $u.Folder 'extras\manifest.json' | Should -Exist
        $u.Manifest.formatVersion | Should -Be 1
    }

    It 'reuses the unpacked copy on a rerun instead of unpacking again' {
        $first = Expand-Backup -Path $made.Path -Password $pw -RestoreRoot $restoreRoot -SevenZip $SevenZip
        Remove-Item -LiteralPath (Join-Path $first.Folder 'data\settings\windows\hosts')
        $again = Expand-Backup -Path $made.Path -Password $pw -RestoreRoot $restoreRoot -SevenZip $SevenZip
        $again.Reused | Should -BeTrue
        $again.Folder | Should -Be $first.Folder
        Join-Path $again.Folder 'data\settings\windows\hosts' | Should -Not -Exist
    }

    It 'stops on a wrong password, in plain words, before unpacking anything' {
        { Expand-Backup -Path $made.Path -Password (New-TestPassword 'wrong horse battery') -RestoreRoot $restoreRoot -SevenZip $SevenZip } |
            Should -Throw "That password doesn't open the Backup ""Laptop 2026-11-27""."
        @(Get-ChildItem -LiteralPath $restoreRoot).Count | Should -Be 0
    }

    It 'says an encrypted Backup needs its password' {
        (Read-BackupManifest -Path $made.Path -SevenZip $SevenZip).Result | Should -Be 'password-needed'
    }

    It 'refuses a Backup made by a newer Hopover, before unpacking anything' {
        # A Backup from the future: formatVersion 2, packed the way any 7-Zip would.
        $future = New-TestStaging
        Set-Content -LiteralPath (Join-Path $future 'hopover.json') -Value '{ "formatVersion": 2, "computerName": "X", "created": "2030-01-01T00:00:00Z" }' -Encoding ASCII
        $file = Join-Path (New-TestDestination) 'Future.hopover.7z'
        Push-Location $future
        try { & $SevenZip a -t7z '-pcorrect horse battery' -mhe=on $file * | Out-Null } finally { Pop-Location }
        (Read-BackupManifest -Path $file -Password $pw -SevenZip $SevenZip).Result | Should -Be 'newer'
        { Expand-Backup -Path $file -Password $pw -RestoreRoot $restoreRoot -SevenZip $SevenZip } |
            Should -Throw 'This Backup was made by a newer Hopover; download the latest.'
        @(Get-ChildItem -LiteralPath $restoreRoot).Count | Should -Be 0
    }

    It 'tells two Backups apart even when they were made in the same second' {
        # Packed by hand: the same PC and name, created 0.6 s apart.
        $out = New-TestDestination
        foreach ($pair in @(@('a', '2026-11-27T10:00:00.1000000Z'), @('b', '2026-11-27T10:00:00.7000000Z'))) {
            $s = New-TestStaging
            Set-Content -LiteralPath (Join-Path $s 'hopover.json') -Value "{ ""formatVersion"": 1, ""computerName"": ""PC"", ""created"": ""$($pair[1])"" }" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $s "data\$($pair[0]).txt") -Value $pair[0] -Encoding ASCII
            New-Item -ItemType Directory -Path (Join-Path $out $pair[0]) | Out-Null
            Push-Location $s
            try { & $SevenZip a -t7z '-pcorrect horse battery' -mhe=on (Join-Path $out "$($pair[0])\Twin.hopover.7z") * | Out-Null } finally { Pop-Location }
        }
        $null = Expand-Backup -Path (Join-Path $out 'a\Twin.hopover.7z') -Password $pw -RestoreRoot $restoreRoot -SevenZip $SevenZip
        $u = Expand-Backup -Path (Join-Path $out 'b\Twin.hopover.7z') -Password $pw -RestoreRoot $restoreRoot -SevenZip $SevenZip
        $u.Reused | Should -BeFalse
        Join-Path $u.Folder 'data\b.txt' | Should -Exist
        Join-Path $u.Folder 'data\a.txt' | Should -Not -Exist
    }

    It 'never replaces a folder of that name that Hopover did not unpack, even one holding a hopover.json' {
        $mine = New-Item -ItemType Directory -Path (Join-Path $restoreRoot 'Laptop 2026-11-27') -Force
        Set-Content -LiteralPath (Join-Path $mine 'keep.txt') -Value 'mine' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $mine 'hopover.json') -Value '{}' -Encoding ASCII
        { Expand-Backup -Path $made.Path -Password $pw -RestoreRoot $restoreRoot -SevenZip $SevenZip } | Should -Throw '*in the way*'
        Join-Path $mine 'keep.txt' | Should -Exist
    }

    It 'unpacks again over its own copy that an earlier run left half-done' {
        $first = Expand-Backup -Path $made.Path -Password $pw -RestoreRoot $restoreRoot -SevenZip $SevenZip
        # As if that unpack had been stopped part-way: Hopover's marker, not yet marked complete.
        $marker = Join-Path $first.Folder '.hopover-unpacked.json'
        $m = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        $m.complete = $false
        Set-Content -LiteralPath $marker -Value (ConvertTo-Json $m) -Encoding UTF8
        Remove-Item -LiteralPath (Join-Path $first.Folder 'data\settings\windows\hosts')
        $again = Expand-Backup -Path $made.Path -Password $pw -RestoreRoot $restoreRoot -SevenZip $SevenZip
        $again.Reused | Should -BeFalse
        Join-Path $again.Folder 'data\settings\windows\hosts' | Should -Exist
    }

    It 'keeps the folder inside the restore root whatever the Backup file is called' {
        $odd = Join-Path (New-TestDestination) '..hopover.7z'
        Copy-Item -LiteralPath $made.Path -Destination $odd
        $u = Expand-Backup -Path $odd -Password $pw -RestoreRoot $restoreRoot -SevenZip $SevenZip
        (Split-Path -Parent $u.Folder) | Should -Be $restoreRoot
        (Split-Path -Leaf $u.Folder) | Should -Be 'Backup'
    }

    It 'calls a hopover.json whose formatVersion is not a number damaged' {
        $s = New-TestStaging
        Set-Content -LiteralPath (Join-Path $s 'hopover.json') -Value '{ "formatVersion": "two" }' -Encoding ASCII
        $file = Join-Path (New-TestDestination) 'Odd.hopover.7z'
        Push-Location $s
        try { & $SevenZip a -t7z $file * | Out-Null } finally { Pop-Location }
        (Read-BackupManifest -Path $file -SevenZip $SevenZip).Result | Should -Be 'damaged'
    }

    It 'removes what it unpacked when 7-Zip fails part-way' {
        # A stand-in 7-Zip that reads hopover.json like the real one, then fails to unpack.
        $failing = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $failing | Out-Null
        Set-Content -LiteralPath (Join-Path $failing 'hopover.json') -Value '{ "formatVersion": 1, "computerName": "PC", "created": "2026-11-27T10:00:00Z" }' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $failing '7z.cmd') -Encoding ASCII -Value @(
            '@echo off'
            'if "%1"=="e" ( type "%~dp0hopover.json" & exit /b 0 )'
            'exit /b 2'
        )
        { Expand-Backup -Path $made.Path -Password $pw -RestoreRoot $restoreRoot -SevenZip (Join-Path $failing '7z.cmd') } | Should -Throw "*couldn't unpack*"
        @(Get-ChildItem -LiteralPath $restoreRoot).Count | Should -Be 0
    }

    It 'unpacks afresh when a different Backup with the same name comes along' {
        $first = Expand-Backup -Path $made.Path -Password $pw -RestoreRoot $restoreRoot -SevenZip $SevenZip
        $other = New-TestStaging
        Set-Content -LiteralPath (Join-Path $other 'data\NOTES.md') -Value 'newer Backup' -Encoding UTF8
        $newer = New-Backup -Source $other -Destination (New-TestDestination) -Name 'Laptop 2026-11-27' -Password $pw -SevenZip $SevenZip
        $u = Expand-Backup -Path $newer.Path -Password $pw -RestoreRoot $restoreRoot -SevenZip $SevenZip
        $u.Reused | Should -BeFalse
        $u.Folder | Should -Be $first.Folder
        Join-Path $u.Folder 'data\NOTES.md' | Should -Exist
    }
}

Describe 'A Backup that 7-Zip fails to make' {
    It 'leaves none of its pieces behind' {
        # A stand-in 7-Zip that writes the first piece, then fails as 7-Zip does (exit 2).
        $failing = Join-Path $TestDrive 'failing'
        New-Item -ItemType Directory -Path $failing | Out-Null
        $cmd = @(
            '@echo off'
            'for %%a in (%*) do if /i "%%~xa"==".7z" type nul >"%%~a.001"'
            'exit /b 2'
        )
        Set-Content -LiteralPath (Join-Path $failing '7z.cmd') -Value $cmd -Encoding ASCII
        $out = New-TestDestination
        { New-Backup -Source (New-TestStaging) -Destination $out -Name 'broken' -Password (New-TestPassword 'correct horse battery') -SplitBytes 65536 -SevenZip (Join-Path $failing '7z.cmd') } |
            Should -Throw "*couldn't make the Backup*"
        @(Get-ChildItem -LiteralPath $out -File).Count | Should -Be 0
    }
}

Describe 'Passwords and keys in the extras' {
    # Backup-Extras archives gitignored .env files as dev-local-files, and .ssh as app-ssh when
    # asked: they hold secrets, which an unprotected Backup must never carry.
    BeforeAll {
        function New-SecretStaging {
            $s = New-TestStaging
            foreach ($n in 'dev-local-files', 'app-ssh', 'app-obs') { [IO.File]::WriteAllText((Join-Path $s "extras\$n.zip"), "contents of $n") }
            $items = @('dev-local-files', 'app-ssh', 'app-obs') | ForEach-Object { @{ Name = $_; File = "$_.zip"; Status = 'ok' } }
            Set-Content -LiteralPath (Join-Path $s 'extras\manifest.json') -Value (ConvertTo-Json @{ Items = $items } -Depth 4) -Encoding UTF8
            return $s
        }
        function Get-Unpacked($Made, [string]$Phrase) {
            $dir = New-TestDestination
            if ($Phrase) { & $SevenZip x "-p$Phrase" "-o$dir" $Made.Path | Out-Null } else { & $SevenZip x "-o$dir" $Made.Path | Out-Null }
            return $dir
        }
    }

    It 'leaves them out of an unprotected Backup, and its manifests say so' {
        $made = New-Backup -Source (New-SecretStaging) -Destination (New-TestDestination) -Name 'open' -NoEncryption -SevenZip $SevenZip
        $dir = Get-Unpacked $made
        Join-Path $dir 'extras\dev-local-files.zip' | Should -Not -Exist
        Join-Path $dir 'extras\app-ssh.zip' | Should -Not -Exist
        Join-Path $dir 'extras\app-obs.zip' | Should -Exist
        @((Get-Content -LiteralPath (Join-Path $dir 'extras\manifest.json') -Raw | ConvertFrom-Json).Items | ForEach-Object Name) | Should -Be @('app-obs')
        (Get-Content -LiteralPath (Join-Path $dir 'hopover.json') -Raw | ConvertFrom-Json).includesPasswordsAndKeys | Should -BeFalse
        @($made.LeftOut) | Should -Be @('dev-local-files', 'app-ssh')
    }

    It 'keeps them in an encrypted Backup, whose hopover.json says it holds passwords and keys' {
        $made = New-Backup -Source (New-SecretStaging) -Destination (New-TestDestination) -Name 'locked' -Password (New-TestPassword 'correct horse battery') -SevenZip $SevenZip
        $dir = Get-Unpacked $made 'correct horse battery'
        Join-Path $dir 'extras\dev-local-files.zip' | Should -Exist
        (Get-Content -LiteralPath (Join-Path $dir 'hopover.json') -Raw | ConvertFrom-Json).includesPasswordsAndKeys | Should -BeTrue
    }
}

Describe 'The password and 7-Zip''s command line' {
    # A stand-in 7-Zip that records its arguments and its standard input, and creates the .7z it
    # was asked for. Any program on the PC can read another's command line, but not its input.
    BeforeAll {
        $standIn = Join-Path $TestDrive 'standin'
        New-Item -ItemType Directory -Path $standIn | Out-Null
        $cmd = @(
            '@echo off'
            'echo %*>>"%~dp0args.txt"'
            'findstr "^" >>"%~dp0stdin.txt"'
            'for %%a in (%*) do if /i "%%~xa"==".7z" type nul >"%%~a"'
            'exit /b 0'
        )
        Set-Content -LiteralPath (Join-Path $standIn '7z.cmd') -Value $cmd -Encoding ASCII
        $secret = 'Tr0ub4dor-and-3'
        $made = New-Backup -Source (New-TestStaging) -Destination (New-TestDestination) -Name 'standin' -Password (New-TestPassword $secret) -SevenZip (Join-Path $standIn '7z.cmd')
        $null = Test-Backup -Path $made.Path -Password (New-TestPassword $secret) -SevenZip (Join-Path $standIn '7z.cmd')
    }

    It 'gives 7-Zip the password on standard input, when making and when testing a Backup' {
        @(Get-Content -LiteralPath (Join-Path $standIn 'stdin.txt') | Where-Object { $_ -eq $secret }).Count | Should -Be 2
    }

    It 'never puts the password on 7-Zip''s command line' {
        $args7z = Get-Content -LiteralPath (Join-Path $standIn 'args.txt') -Raw
        $args7z | Should -Match '\ba\b.*-mhe=on'
        $args7z | Should -Not -Match ([regex]::Escape($secret))
    }

    It 'passes no -p when testing a Backup, where a bare -p would mean an empty password' {
        $testLine = @(Get-Content -LiteralPath (Join-Path $standIn 'args.txt') | Where-Object { $_ -match '^t ' })
        $testLine.Count | Should -Be 1
        $testLine[0] | Should -Not -Match '(^| )-p'
    }
}

Describe 'Find-Backup' {
    BeforeAll {
        $tree = Join-Path $TestDrive 'find'
        foreach ($d in 'E\Hopover', 'E\deep\a\b\c', 'F') { New-Item -ItemType Directory -Path (Join-Path $tree $d) -Force | Out-Null }
        [IO.File]::WriteAllBytes((Join-Path $tree 'E\Hopover\Laptop 2026-11-20.hopover.7z'), (New-Object byte[] 1000))
        [IO.File]::WriteAllBytes((Join-Path $tree 'F\Desktop.hopover.7z.001'), (New-Object byte[] 4000))
        [IO.File]::WriteAllBytes((Join-Path $tree 'F\Desktop.hopover.7z.002'), (New-Object byte[] 1500))
        [IO.File]::WriteAllBytes((Join-Path $tree 'F\photos.7z'), (New-Object byte[] 10))
        # Beside the pieces, but not pieces of that Backup: a copy and another program's split archive.
        [IO.File]::WriteAllBytes((Join-Path $tree 'F\Desktop.hopover.7z.bak'), (New-Object byte[] 300))
        [IO.File]::WriteAllBytes((Join-Path $tree 'F\photos.7z.001'), (New-Object byte[] 10))
        # -Depth 2 reaches files two folders below a root, and no further.
        [IO.File]::WriteAllBytes((Join-Path $tree 'E\deep\a\At the edge.hopover.7z'), (New-Object byte[] 10))
        [IO.File]::WriteAllBytes((Join-Path $tree 'E\deep\a\b\Just too deep.hopover.7z'), (New-Object byte[] 10))
        $found = @(Find-Backup -Root (Join-Path $tree 'E'), (Join-Path $tree 'F') -Depth 2)
    }

    It 'lists each Backup once by name, a split one by its first piece with the size of all of them' {
        @($found | ForEach-Object Name | Sort-Object) | Should -Be @('At the edge', 'Desktop', 'Laptop 2026-11-20')
        $split = $found | Where-Object Name -eq 'Desktop'
        $split.Path | Should -Be (Join-Path $tree 'F\Desktop.hopover.7z.001')
        $split.Split | Should -BeTrue
        $split.Size | Should -Be 5500
        ($found | Where-Object Name -eq 'Laptop 2026-11-20').Size | Should -Be 1000
    }

    It 'skips other .7z files, later pieces, and anything deeper than -Depth' {
        @($found).Count | Should -Be 3
    }
}

Describe 'Get-HopoverVersion' {
    # The release zip is `git archive` of the tag, which fills lib\version.txt's $Format:...$
    # placeholder with the tag. A clone keeps the placeholder and asks git instead.
    BeforeEach {
        $tool = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $tool 'lib') | Out-Null
        Set-Content -LiteralPath (Join-Path $tool 'VERSION') -Value '0.2.0' -Encoding ASCII
    }

    It 'reads the version git archive wrote into lib\version.txt' {
        Set-Content -LiteralPath (Join-Path $tool 'lib\version.txt') -Value 'v0.2.6' -Encoding ASCII
        Get-HopoverVersion -Root $tool | Should -BeExactly 'v0.2.6'
    }

    It 'falls back to the VERSION line when the placeholder was never filled and there is no git' {
        Set-Content -LiteralPath (Join-Path $tool 'lib\version.txt') -Value '$Format:%(describe:tags=true)$' -Encoding ASCII
        Get-HopoverVersion -Root $tool | Should -BeExactly '0.2.0'
    }

    It 'falls back when git archive filled the placeholder with nothing (no tag to describe)' {
        Set-Content -LiteralPath (Join-Path $tool 'lib\version.txt') -Value '' -Encoding ASCII
        Get-HopoverVersion -Root $tool | Should -BeExactly '0.2.0'
    }

    It 'has git fill lib\version.txt when the release zip is made' {
        Push-Location $root
        try { (git check-attr export-subst -- lib/version.txt) | Should -BeExactly 'lib/version.txt: export-subst: set' } finally { Pop-Location }
        (Get-Content -LiteralPath (Join-Path $root 'lib\version.txt') -Raw).Trim() | Should -BeExactly '$Format:%(describe:tags=true)$'
    }
}

Describe 'Get-SevenZip' {
    BeforeEach {
        $cache = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'downloads the pinned 7zr.exe into the cache and returns it when its hash matches' {
        $exe = Get-SevenZip -CacheDir $cache
        $exe | Should -Exist
        (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash | Should -Be $Pin.sha256
        (cmd /c "`"$exe`" 2>&1" | Out-String) | Should -Match ([regex]::Escape("7-Zip (r) $($Pin.version)"))
    }

    It 'refuses a download whose hash differs from the pin, and keeps nothing' {
        $bad = [pscustomobject]@{ version = $Pin.version; url = $Pin.url; sha256 = ('0' * 64) }
        { Get-SevenZip -CacheDir $cache -Pin $bad } | Should -Throw '*SHA-256*'
        @(Get-ChildItem -LiteralPath $cache -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'replaces a cached copy that no longer matches the pin' {
        $exe = Get-SevenZip -CacheDir $cache
        [IO.File]::WriteAllText($exe, 'tampered')
        $again = Get-SevenZip -CacheDir $cache
        (Get-FileHash -LiteralPath $again -Algorithm SHA256).Hash | Should -Be $Pin.sha256
    }
}
