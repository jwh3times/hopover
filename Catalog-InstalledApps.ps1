<#
    Catalog-InstalledApps.ps1
    Enumerates installed apps (registry + Store) and portable .exe apps,
    then writes a markdown catalog for reference during a fresh Windows install.
    Also runs `winget export` so most apps can be bulk-reinstalled.

    Usage (from PowerShell):
        powershell -ExecutionPolicy Bypass -File .\Catalog-InstalledApps.ps1

    Output (in the data folder by default):
        Installed-Apps-Catalog.md  catalog; override with -OutFile
        winget-packages.json       winget export; override with -WingetFile, skip with -SkipWinget

    Restore on the new PC with Restore.ps1 (or on Linux with linux/restore-linux.sh).
    Anything winget can't match is listed in the catalog's "Not Available via winget" section
    and has to be installed by hand.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    # Data folder (default: $env:HOPOVER_DATA, else .\data).
    [string]$DataDir,

    # Defaults to Installed-Apps-Catalog.md in the data folder.
    [string]$OutFile,

    # winget export output, for `winget import` on the new PC.
    # Defaults to winget-packages.json in the data folder.
    [string]$WingetFile,

    # Skip the winget export step.
    [switch]$SkipWinget,

    # Where to hunt for portable apps (default: config portableRoots).
    [string[]]$PortableRoots,

    # How deep to recurse when searching for portable apps.
    [int]$PortableDepth = 4
)

$ErrorActionPreference = 'SilentlyContinue'

# Windows PowerShell 5.1 leaves $PSScriptRoot empty inside param() defaults,
# so resolve the default output paths here.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptDir 'lib\Common.ps1')
$DataDir = Resolve-DataDir $DataDir
$Config  = Get-MigrationConfig $DataDir
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
if (-not $OutFile)    { $OutFile    = Join-Path $DataDir 'Installed-Apps-Catalog.md' }
if (-not $WingetFile) { $WingetFile = Join-Path $DataDir 'winget-packages.json' }
if (-not $PSBoundParameters.ContainsKey('PortableRoots')) { $PortableRoots = @($Config.portableRoots | ForEach-Object { Expand-ConfigPath $_ }) }
$PortableRoots = Split-List $PortableRoots

function Format-InstallDate {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    if ($Raw -match '^\d{8}$') {
        try { return ([datetime]::ParseExact($Raw,'yyyyMMdd',$null)).ToString('yyyy-MM-dd') } catch { return $Raw }
    }
    return $Raw
}

function Escape-Md {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '\|','\|' -replace '[\r\n]+',' ').Trim()
}

# ---------------------------------------------------------------------------
# 1. Registry-installed applications
# ---------------------------------------------------------------------------
Write-Host 'Scanning registry uninstall keys...' -ForegroundColor Cyan

$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

$registryApps = foreach ($path in $uninstallPaths) {
    Get-ItemProperty -Path $path | ForEach-Object {
        $name = $_.DisplayName
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        # Filter out system updates / hotfixes / patch entries.
        if ($_.SystemComponent -eq 1) { return }
        if ($_.ParentKeyName) { return }               # component of another app
        if ($name -match '^(Security Update|Update for|Hotfix|KB\d+)') { return }
        if ($_.ReleaseType -match 'Update|Hotfix') { return }

        [PSCustomObject]@{
            Name       = $name.Trim()
            Version    = ([string]$_.DisplayVersion).Trim()
            Publisher  = ([string]$_.Publisher).Trim()
            Location   = ([string]$_.InstallLocation).Trim()
            InstallDate= Format-InstallDate ([string]$_.InstallDate)
        }
    }
}

$registryApps = $registryApps |
    Sort-Object Name, Version -Unique |
    Sort-Object Name

# ---------------------------------------------------------------------------
# 2. Microsoft Store / UWP apps
# ---------------------------------------------------------------------------
Write-Host 'Scanning Microsoft Store / UWP apps...' -ForegroundColor Cyan

$storeApps = Get-AppxPackage |
    Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' } |
    ForEach-Object {
        [PSCustomObject]@{
            Name      = $_.Name
            Version   = [string]$_.Version
            Publisher = ($_.Publisher -replace '^CN=','' -replace ',.*$','')
            Location  = $_.InstallLocation
        }
    } |
    Sort-Object Name -Unique |
    Sort-Object Name

# ---------------------------------------------------------------------------
# 3. Portable applications (standalone .exe not under Program Files / Windows)
# ---------------------------------------------------------------------------
Write-Host 'Scanning for portable apps...' -ForegroundColor Cyan

# Also add non-system fixed drive roots if accessible.
$extraRoots = Get-PSDrive -PSProvider FileSystem |
    Where-Object { $_.Root -match '^[D-Z]:\\$' -and (Test-Path $_.Root) } |
    Select-Object -ExpandProperty Root

$searchRoots = @($PortableRoots + $extraRoots) |
    Where-Object { $_ -and (Test-Path $_) } |
    Select-Object -Unique

$excludePattern = '(?i)\\(Windows|Program Files|Program Files \(x86\)|\$Recycle\.Bin|AppData\\Local\\Microsoft|WinSxS)\\'
$installerPattern = '(?i)(setup|install|uninstall|update|redist|vc_redist|vcredist|dotnet|node_modules)'

function Get-DepthLimitedFiles {
    param([string]$Root,[int]$MaxDepth)
    $rootDepth = ($Root.TrimEnd('\') -split '\\').Count
    Get-ChildItem -Path $Root -Filter *.exe -File -Recurse -Force |
        Where-Object {
            $depth = ($_.FullName -split '\\').Count - $rootDepth
            $depth -le $MaxDepth
        }
}

$portableApps = foreach ($root in $searchRoots) {
    Get-DepthLimitedFiles -Root $root -MaxDepth $PortableDepth | ForEach-Object {
        $full = $_.FullName
        if ($full -match $excludePattern) { return }
        if ($_.BaseName -match $installerPattern) { return }
        [PSCustomObject]@{
            Name     = $_.BaseName
            Exe      = $_.Name
            Location = $_.DirectoryName
        }
    }
}

$portableApps = $portableApps |
    Sort-Object Name, Location -Unique |
    Sort-Object Name

# ---------------------------------------------------------------------------
# 4. winget export (for bulk reinstall via `winget import`)
# ---------------------------------------------------------------------------
$wingetStatus    = 'skipped (-SkipWinget)'
$wingetPackages  = @()
$wingetUnmatched = @()

if (-not $SkipWinget) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        $wingetStatus = 'skipped (winget not found; install "App Installer" from the Microsoft Store)'
        Write-Host "winget not found; skipping export." -ForegroundColor Yellow
    } else {
        Write-Host 'Running winget export (this can take a minute)...' -ForegroundColor Cyan
        $wingetOutput = winget export -o $WingetFile --accept-source-agreements --disable-interactivity 2>&1
        $wingetExit = $LASTEXITCODE

        # winget prints one line per installed package it can't map to a source.
        $wingetUnmatched = $wingetOutput |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -match 'not available from any source:\s*(.+)$' } |
            ForEach-Object { $Matches[1].Trim() } |
            Sort-Object -Unique

        if ($wingetExit -eq 0 -and (Test-Path $WingetFile)) {
            $wingetJson = Get-Content $WingetFile -Raw | ConvertFrom-Json
            $wingetPackages = foreach ($src in $wingetJson.Sources) {
                foreach ($pkg in $src.Packages) {
                    [PSCustomObject]@{
                        Id     = $pkg.PackageIdentifier
                        Source = $src.SourceDetails.Name
                    }
                }
            }
            $wingetPackages = $wingetPackages | Sort-Object Id -Unique
            $wingetStatus = "exported to $(Split-Path $WingetFile -Leaf)"
            Write-Host "winget export written to: $WingetFile" -ForegroundColor Green
        } else {
            $wingetStatus = "failed (winget exit code $wingetExit)"
            Write-Host "winget export failed (exit $wingetExit)." -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Build markdown
# ---------------------------------------------------------------------------
Write-Host 'Writing markdown...' -ForegroundColor Cyan

$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine('# Installed Applications Catalog')
$null = $sb.AppendLine()
$null = $sb.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $env:COMPUTERNAME")
$null = $sb.AppendLine('Purpose: reference for reinstalling apps after a fresh Windows install.')
$null = $sb.AppendLine()
$null = $sb.AppendLine("- Registry-installed apps: **$($registryApps.Count)**")
$null = $sb.AppendLine("- Microsoft Store / UWP apps: **$($storeApps.Count)**")
$null = $sb.AppendLine("- Portable apps found: **$($portableApps.Count)**")
$null = $sb.AppendLine("- winget export: $wingetStatus; **$(@($wingetPackages).Count)** packages exportable, **$(@($wingetUnmatched).Count)** not available via winget")
$null = $sb.AppendLine()

if (@($wingetPackages).Count -gt 0) {
    $null = $sb.AppendLine('## Restore with winget')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('On the new PC, from the folder holding the export:')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('```powershell')
    $null = $sb.AppendLine("winget import -i .\$(Split-Path $WingetFile -Leaf) --accept-package-agreements --accept-source-agreements")
    $null = $sb.AppendLine('```')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('| Package ID | Source |')
    $null = $sb.AppendLine('| --- | --- |')
    foreach ($p in $wingetPackages) {
        $null = $sb.AppendLine("| $(Escape-Md $p.Id) | $(Escape-Md $p.Source) |")
    }
    $null = $sb.AppendLine()
}

if (@($wingetUnmatched).Count -gt 0) {
    $null = $sb.AppendLine('## Not Available via winget (install manually)')
    $null = $sb.AppendLine()
    foreach ($u in $wingetUnmatched) {
        $null = $sb.AppendLine("- $(Escape-Md $u)")
    }
    $null = $sb.AppendLine()
}

# Registry section
$null = $sb.AppendLine('## Registry-Installed Applications')
$null = $sb.AppendLine()
$null = $sb.AppendLine('| Name | Version | Publisher | Install Directory |')
$null = $sb.AppendLine('| --- | --- | --- | --- |')
foreach ($a in $registryApps) {
    $null = $sb.AppendLine("| $(Escape-Md $a.Name) | $(Escape-Md $a.Version) | $(Escape-Md $a.Publisher) | $(Escape-Md $a.Location) |")
}
$null = $sb.AppendLine()

# Store section
$null = $sb.AppendLine('## Microsoft Store / UWP Apps')
$null = $sb.AppendLine()
$null = $sb.AppendLine('| Name | Version | Publisher | Install Directory |')
$null = $sb.AppendLine('| --- | --- | --- | --- |')
foreach ($a in $storeApps) {
    $null = $sb.AppendLine("| $(Escape-Md $a.Name) | $(Escape-Md $a.Version) | $(Escape-Md $a.Publisher) | $(Escape-Md $a.Location) |")
}
$null = $sb.AppendLine()

# Portable section
$null = $sb.AppendLine('## Portable Applications')
$null = $sb.AppendLine()
$null = $sb.AppendLine('| Name | Executable | Location |')
$null = $sb.AppendLine('| --- | --- | --- |')
foreach ($a in $portableApps) {
    $null = $sb.AppendLine("| $(Escape-Md $a.Name) | $(Escape-Md $a.Exe) | $(Escape-Md $a.Location) |")
}
$null = $sb.AppendLine()

$sb.ToString() | Out-File -FilePath $OutFile -Encoding UTF8

Write-Host "Done. Catalog written to: $OutFile" -ForegroundColor Green
