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

    It 'returns an empty array for nothing' {
        @(Split-List @()).Count | Should -Be 0
    }
}

Describe 'Get-MigrationConfig' {
    It 'returns the defaults when config.json is absent' {
        $cfg = Get-MigrationConfig $TestDrive
        $cfg['_exists'] | Should -BeFalse
        $cfg['repoDepth'] | Should -Be 3
    }

    It 'merges nested sections one level deep and skips $schema and _comment keys' {
        $json = '{ "$schema": "x", "_comment": "y", "repoDepth": 5, "linux": { "aur": "never" } }'
        Set-Content -LiteralPath (Join-Path $TestDrive 'config.json') -Value $json -Encoding UTF8
        $cfg = Get-MigrationConfig $TestDrive
        $cfg['_exists'] | Should -BeTrue
        $cfg['repoDepth'] | Should -Be 5
        $cfg['linux']['aur'] | Should -Be 'never'
        $cfg['linux']['nodeMajor'] | Should -Be 24
        $cfg.Contains('$schema') | Should -BeFalse
        $cfg.Contains('_comment') | Should -BeFalse
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
