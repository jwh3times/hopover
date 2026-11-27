# Pester 6 tests for lib\Common.ps1. CI runs them in Windows PowerShell 5.1 and PowerShell 7:
#
#     Invoke-Pester -Path tests -CI

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Common.ps1')
}

Describe 'Split-List' {
    It 'splits the single "a,b" string powershell -File passes' {
        Split-List @('winget, choco,,npm ') | Should -Be @('winget', 'choco', 'npm')
    }

    It 'drops the empty string an unset list parameter passes' {
        @(Split-List @('')).Count | Should -Be 0
    }
}

Describe 'Get-Options' {
    # Each test gets its own data folder and its own per-user app-data folder.
    BeforeEach {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $appData = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir, (Join-Path $appData 'Hopover') | Out-Null
        $savedLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $appData
        $optionsFile = Join-Path $appData 'Hopover\options.json'
    }
    AfterEach { $env:LOCALAPPDATA = $savedLocalAppData }

    It 'returns the defaults when neither options.json nor config.json exists' {
        $opt = Get-Options $dir
        $opt['_exists'] | Should -BeFalse
        $opt['repoDepth'] | Should -Be 3
        $opt['devRoot'] | Should -Be 'C:\dev'
        @($opt['wipedDrives']).Count | Should -Be 0
        $opt['_file'] | Should -Be $optionsFile
    }

    It 'skips $schema and _comment keys, inside sections too' {
        Set-Content -LiteralPath $optionsFile -Value '{ "$schema": "x", "_comment": "y", "repoDepth": 5, "linux": { "aur": "never", "_aur": "z", "$id": "w" } }' -Encoding UTF8
        $opt = Get-Options $dir
        $opt['repoDepth'] | Should -Be 5
        $opt.Contains('$schema') | Should -BeFalse
        $opt.Contains('_comment') | Should -BeFalse
        $opt['linux']['aur'] | Should -Be 'never'
        $opt['linux'].Contains('_aur') | Should -BeFalse
        $opt['linux'].Contains('$id') | Should -BeFalse
    }

    It 'reads options.json from the per-user Hopover folder over the defaults' {
        Set-Content -LiteralPath $optionsFile -Value '{ "repoDepth": 7, "linux": { "aur": "never" } }' -Encoding UTF8
        $opt = Get-Options $dir
        $opt['repoDepth'] | Should -Be 7
        $opt['linux']['aur'] | Should -Be 'never'
        $opt['linux']['nodeMajor'] | Should -Be 24
        $opt['_exists'] | Should -BeTrue
        $opt['_file'] | Should -Be $optionsFile
    }

    It 'falls back to USERPROFILE\AppData\Local when LOCALAPPDATA is unset' {
        $env:LOCALAPPDATA = ''
        Get-OptionsPath | Should -Be (Join-Path $env:USERPROFILE 'AppData\Local\Hopover\options.json')
    }

    It 'reads a data folder''s config.json when there is no options.json' {
        Set-Content -LiteralPath (Join-Path $dir 'config.json') -Value '{ "devRoot": "D:\\code", "repoDepth": 5 }' -Encoding UTF8
        $opt = Get-Options $dir
        $opt['devRoot'] | Should -Be 'D:\code'
        $opt['repoDepth'] | Should -Be 5
        $opt['_exists'] | Should -BeTrue
        $opt['_file'] | Should -Be (Join-Path $dir 'config.json')
    }

    It 'layers options.json over config.json, so config.json keys options.json lacks still apply' {
        Set-Content -LiteralPath (Join-Path $dir 'config.json') -Value '{ "devRoot": "D:\\code", "repoDepth": 5, "linux": { "aur": "never", "nodeMajor": 22 } }' -Encoding UTF8
        Set-Content -LiteralPath $optionsFile -Value '{ "repoDepth": 2, "linux": { "aur": "auto" } }' -Encoding UTF8
        $opt = Get-Options $dir
        $opt['repoDepth'] | Should -Be 2
        $opt['devRoot'] | Should -Be 'D:\code'
        $opt['linux']['aur'] | Should -Be 'auto'
        $opt['linux']['nodeMajor'] | Should -Be 22
        $opt['_file'] | Should -Be $optionsFile
    }
}

Describe 'Script parameters over Options' {
    # Restore.ps1 -List names the dev root it settled on in the repos step's text.
    BeforeEach {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $appData = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir, (Join-Path $appData 'Hopover') | Out-Null
        $savedLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $appData
        Set-Content -LiteralPath (Join-Path $appData 'Hopover\options.json') -Value '{ "devRoot": "D:\\from-options" }' -Encoding UTF8
        $restore = Join-Path (Split-Path -Parent $PSScriptRoot) 'Restore.ps1'
    }
    AfterEach { $env:LOCALAPPDATA = $savedLocalAppData }

    It 'uses the Options when no parameter is given' {
        $steps = & $restore -List -AsJson -DataDir $dir | ConvertFrom-Json
        @($steps | Where-Object { $_.name -eq 'repos' })[0].text | Should -Be 'Clone repos into D:\from-options'
    }

    It 'lets a parameter win over the Options' {
        $steps = & $restore -List -AsJson -DataDir $dir -DevRoot 'E:\from-parameter' | ConvertFrom-Json
        @($steps | Where-Object { $_.name -eq 'repos' })[0].text | Should -Be 'Clone repos into E:\from-parameter'
    }
}

Describe 'Get-WipedDrives' {
    It 'always counts the Windows drive, even when the list is empty' {
        $system = $env:SystemDrive.Substring(0, 1).ToUpper()
        @(Get-WipedDrives @{ wipedDrives = @() }) | Should -BeExactly @($system)
    }

    It 'adds the listed drives once each, upper-case, whatever way they are written' {
        $system = $env:SystemDrive.Substring(0, 1).ToUpper()
        $drives = @(Get-WipedDrives @{ wipedDrives = @('d', 'D:', 'e:\', "$($system.ToLower()):") })
        $drives | Should -BeExactly @($system, 'D', 'E')
    }

    It 'drops entries that are not a single drive letter' {
        $system = $env:SystemDrive.Substring(0, 1).ToUpper()
        $drives = @(Get-WipedDrives @{ wipedDrives = @('D:\Games', 'DE', '', '  ', '1', 'f') })
        $drives | Should -BeExactly @($system, 'F')
    }
}

Describe 'Read-JsonList' {
    It 'yields each element of a top-level JSON array' {
        $file = Join-Path $TestDrive 'list.json'
        Set-Content -LiteralPath $file -Value '[{"Id":"a"},{"Id":"b"}]' -Encoding UTF8
        @(Read-JsonList $file).Count | Should -Be 2
    }

    It 'returns an empty array for a missing file' {
        @(Read-JsonList (Join-Path $TestDrive 'missing.json')).Count | Should -Be 0
    }
}
