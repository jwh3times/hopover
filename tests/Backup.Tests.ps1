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
