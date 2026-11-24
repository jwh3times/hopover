<#
.SYNOPSIS
    Parse, analyze and test every tracked PowerShell file in the edition running this script.

.DESCRIPTION
    Run it once in each edition; CI's windows job does the same:

        powershell -NoProfile -File tests\Invoke-PowerShellChecks.ps1
        pwsh -NoProfile -File tests\Invoke-PowerShellChecks.ps1

    It reads the file list from git, so the private companion in data\ is never touched. Needs
    PSScriptAnalyzer 1.25.0 and Pester 6.2.0 (Install-Module <name> -RequiredVersion <v>
    -Scope CurrentUser, in each edition). Exits 1 when anything fails.
#>
[CmdletBinding(PositionalBinding = $false)]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $edition = "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    $files = @(git ls-files -- '*.ps1' '*.psm1' '*.psd1')
    if (-not $files.Count) { throw 'git ls-files found no PowerShell files.' }
    $failed = $false

    Write-Host "== Parse ($edition): $($files.Count) files"
    foreach ($f in $files) {
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $f), [ref]$null, [ref]$errors)
        foreach ($e in @($errors)) {
            Write-Host "${f}:$($e.Extent.StartLineNumber) $($e.Message)" -ForegroundColor Red
            $failed = $true
        }
    }

    Write-Host "== PSScriptAnalyzer ($edition)"
    Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    foreach ($f in $files) {
        foreach ($r in @(Invoke-ScriptAnalyzer -Path (Join-Path $root $f) -Settings $settings)) {
            Write-Host "${f}:$($r.Line) $($r.RuleName): $($r.Message)" -ForegroundColor Red
            $failed = $true
        }
    }

    Write-Host "== Pester ($edition)"
    Import-Module Pester -RequiredVersion 6.2.0
    $result = Invoke-Pester -Path (Join-Path $root 'tests') -PassThru -Output Normal
    if ($result.FailedCount -or $result.Result -ne 'Passed') { $failed = $true }

    if ($failed) { Write-Host "Checks failed in $edition." -ForegroundColor Red; exit 1 }
    Write-Host "All PowerShell checks passed in $edition." -ForegroundColor Green
} finally {
    Pop-Location
}
