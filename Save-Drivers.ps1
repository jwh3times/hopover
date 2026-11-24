<#
    Save-Drivers.ps1
    Exports every third-party driver installed on this PC (network, chipset,
    GPU, audio, USB devices...) so a fresh install has networking and devices
    working before Windows Update or any download. Run from an elevated prompt.

    Usage (elevated):
        powershell -ExecutionPolicy Bypass -File .\Save-Drivers.ps1                          # to <migrationRoot>\drivers
        powershell -ExecutionPolicy Bypass -File .\Save-Drivers.ps1 -Destination E:\drivers   # a USB stick

    On the new PC (elevated), plug in the drive and run Restore.ps1 -Steps drivers, or:
        pnputil /add-driver "<migrationRoot>\drivers\*.inf" /subdirs /install
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    # Data folder (default: $env:HOPOVER_DATA, else .\data).
    [string]$DataDir,

    # Default: <migrationRoot>\drivers from config.json.
    [string]$Destination
)

$ErrorActionPreference = 'Continue'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptDir 'lib\Common.ps1')
$DataDir = Resolve-DataDir $DataDir
$Config  = Get-MigrationConfig $DataDir
if (-not $Destination) {
    Assert-ConfigValue $Config 'migrationRoot' 'a folder on a drive that will not be wiped'
    $Destination = Join-Path (Expand-ConfigPath $Config.migrationRoot) 'drivers'
}

if (-not (Test-IsAdmin)) {
    Write-Host 'Run this from an elevated PowerShell (right-click > Run as administrator).' -ForegroundColor Yellow
    exit 1
}
$root = [IO.Path]::GetPathRoot($Destination)
if (-not (Test-Path -LiteralPath $root)) { Write-Host "Drive $root isn't connected." -ForegroundColor Yellow; exit 1 }

if (Test-Path -LiteralPath $Destination) {
    $old = "$Destination.old-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Rename-Item -LiteralPath $Destination -NewName (Split-Path -Leaf $old)
    Write-Host "Previous export moved to $old"
}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null

Write-Host "Exporting third-party drivers to $Destination ..." -ForegroundColor Cyan
$out = pnputil /export-driver * $Destination 2>&1
$exit = $LASTEXITCODE

# What's installed, for the README (works from the same elevated prompt).
$drivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.InfName -like 'oem*.inf' } |
    Sort-Object DeviceClass, DeviceName |
    Select-Object DeviceClass, DeviceName, DriverProviderName, DriverVersion, InfName -Unique)

$infs  = @(Get-ChildItem -LiteralPath $Destination -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue)
$sizeM = [math]::Round(((Get-ChildItem -LiteralPath $Destination -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB)

$NL = "`r`n"
$md  = "# Exported drivers$NL$NL"
$md += "From $env:COMPUTERNAME on $(Get-Date -Format 'yyyy-MM-dd HH:mm'): $($infs.Count) driver packages, $sizeM MB.$NL$NL"
$md += "Install on the new PC from an elevated prompt:$NL$NL"
$md += '```powershell' + $NL + "pnputil /add-driver `"$Destination\*.inf`" /subdirs /install" + $NL + '```' + $NL + $NL
$md += "Network drivers are the ones that matter first; after that, prefer current downloads from the GPU and chipset vendors over these copies.$NL$NL"
$md += "| Class | Device | Provider | Version | INF |$NL| --- | --- | --- | --- | --- |$NL"
foreach ($d in $drivers) { $md += "| $($d.DeviceClass) | $($d.DeviceName) | $($d.DriverProviderName) | $($d.DriverVersion) | $($d.InfName) |$NL" }
[IO.File]::WriteAllText((Join-Path $Destination 'README.md'), $md, $Utf8)

# Keep the device list in the data folder too, for reference when the drive isn't handy.
$repoCopy = Join-Path $DataDir 'settings\windows\drivers.md'
if (Test-Path -LiteralPath (Split-Path -Parent $repoCopy)) { [IO.File]::WriteAllText($repoCopy, $md, $Utf8) }

if ($exit -ne 0 -or $infs.Count -eq 0) {
    Write-Host "pnputil reported a problem (exit $exit):" -ForegroundColor Yellow
    $out | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" }
    exit 1
}
$net = @($drivers | Where-Object { $_.DeviceClass -eq 'NET' })
Write-Host "Exported $($infs.Count) driver packages ($sizeM MB)." -ForegroundColor Green
Write-Host "Network drivers included: $(($net | ForEach-Object DeviceName | Sort-Object -Unique) -join '; ')" -ForegroundColor Green
Write-Host "Device list: $(Join-Path $Destination 'README.md')"
