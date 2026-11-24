<#
    Test-LinuxRestore.ps1
    Runs linux/restore-linux.sh inside throwaway Docker containers, one per distro,
    with the tool and a data folder mounted read-only. Needs Docker Desktop.

        # resolve every app against real package metadata, install nothing
        powershell -File linux\tests\Test-LinuxRestore.ps1

        # really install a few apps in each container (vendor repos, .deb/.rpm, scripts)
        powershell -File linux\tests\Test-LinuxRestore.ps1 -Install -Only Git.GitHub.cli,Microsoft.VisualStudioCode

        # a subset of distros
        powershell -File linux\tests\Test-LinuxRestore.ps1 -Images ubuntu:latest,fedora:latest

    Logs and reports go to -OutDir (default: %TEMP%\linux-restore-tests). Containers
    run as root, so AUR packages are skipped there (AUR helpers refuse root) and
    Flatpak and systemd steps only print what they would do.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string[]]$Images = @('ubuntu:latest', 'debian:latest', 'fedora:latest', 'archlinux:latest', 'linuxmintd/mint22-amd64', 'cachyos/cachyos:latest'),
    [string]$DataDir,
    [string]$OutDir = (Join-Path $env:TEMP 'linux-restore-tests'),
    [string]$Steps = 'packages',
    [string]$Only,
    [switch]$Install
)

$ErrorActionPreference = 'Continue'
$tool = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $tool 'lib\Common.ps1')
$DataDir = Resolve-DataDir $DataDir
$Images = Split-List $Images
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker is not running. Start Docker Desktop first.' }

# GitHub's API allows 60 unauthenticated requests an hour; use the gh login if there is one.
# The token goes straight into the environment and is never printed.
$envArgs = @()
if (-not $env:GITHUB_TOKEN -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    $t = gh auth token 2>$null
    if ($LASTEXITCODE -eq 0 -and $t) { $env:GITHUB_TOKEN = $t; $envArgs = @('-e', 'GITHUB_TOKEN') }
} elseif ($env:GITHUB_TOKEN) { $envArgs = @('-e', 'GITHUB_TOKEN') }

$results = @()
foreach ($img in $Images) {
    $tag = ($img -replace '[^A-Za-z0-9]+', '-').Trim('-')
    $log = Join-Path $OutDir "$tag.log"
    $report = "$tag.md"
    # (PowerShell names ignore case, so these must not be called $only / $steps.)
    $cmd = @('bash', '/tool/linux/restore-linux.sh', '--data', '/data', '--steps', $Steps, '--report', "/out/$report")
    if (-not $Install) { $cmd += @('--dry-run', '--refresh') }
    if ($Only) { $cmd += @('--only', $Only) }
    Write-Host "== $img" -ForegroundColor Cyan
    $t0 = Get-Date
    & docker run --rm @envArgs -e TERM=dumb -v "${tool}:/tool:ro" -v "${DataDir}:/data:ro" -v "${OutDir}:/out" $img @cmd *> $log
    $code = $LASTEXITCODE
    $secs = [math]::Round(((Get-Date) - $t0).TotalSeconds)
    $summary = (Select-String -LiteralPath $log -Pattern '^\s+packages\s+' | Select-Object -Last 1).Line
    $system = (Select-String -LiteralPath $log -Pattern 'system:' | Select-Object -First 1).Line
    Write-Host "  exit $code in $secs s; $("$system".Trim())"
    Write-Host "  $("$summary".Trim())"
    $results += [pscustomobject]@{ Image = $img; Exit = $code; Seconds = $secs; Summary = $summary; Log = $log; Report = (Join-Path $OutDir $report) }
}
$results | Format-Table Image, Exit, Seconds -AutoSize | Out-String | Write-Host
Write-Host "Logs and reports: $OutDir"
