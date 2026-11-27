<#
    New-Backup.ps1
    Makes a Backup of this PC: one file, <name>.hopover.7z, that holds everything a restore needs
    (docs/adr/0002-one-encrypted-backup-file.md). It runs the capture scripts (app catalog,
    settings export, extras, and drivers from an elevated prompt) into a staging folder, writes
    hopover.json, and packs the lot, AES-256 encrypted with its file names hidden, using the
    pinned 7-Zip (lib\7zip.json, downloaded and hash-checked on first use).

        powershell -ExecutionPolicy Bypass -File .\New-Backup.ps1 -Destination E:\
        powershell -ExecutionPolicy Bypass -File .\New-Backup.ps1 -Destination E:\ -Name "Laptop before reinstall"

    It asks for the password twice. To pass it from another program, pipe it in:
        <program that prints the password> | powershell -File .\New-Backup.ps1 -Destination E:\

    A forgotten password can't be recovered. -NoEncryption makes an unprotected Backup instead.

    Options:
        -Destination    folder to save the Backup in (default: the migrationRoot option)
        -Name           the Backup's name (default: "<PC name> <yyyy-mm-dd>"); .hopover.7z is added
        -NoEncryption   make a Backup anyone can open
        -Steps a,b      capture only these: catalog, settings, extras, drivers (default: all)
        -SplitMB n      write the Backup in pieces of n MB (.001, .002, ...)
        -StagingDir     where to build it first (default: %TEMP%); a folder is made inside and removed after

    Defaults come from the Options; parameters override them. Your data folder is only read.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Destination,
    [string]$Name,
    [switch]$NoEncryption,
    [string[]]$Steps = @('all'),
    [int]$SplitMB = 0,
    [string]$StagingDir,
    # Data folder (default: $env:HOPOVER_DATA, else .\data).
    [string]$DataDir
)

$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptDir 'lib\Common.ps1')
. (Join-Path $scriptDir 'lib\Backup.ps1')
$DataDir = Resolve-DataDir $DataDir
$Config  = Get-Options $DataDir

$known = @('catalog', 'settings', 'extras', 'drivers')
$Steps = @(Split-List $Steps | ForEach-Object { $_.ToLower() })
if ($Steps -contains 'all') { $Steps = $known }
$unknown = @($Steps | Where-Object { $known -notcontains $_ })
if ($unknown.Count) { throw "Unknown step(s): $($unknown -join ', '). Choose from: $($known -join ', ')." }

if (-not $Destination) { $Destination = Expand-ConfigPath $Config.migrationRoot }
if (-not $Destination) { throw "Say where to save the Backup: -Destination <folder> (or set migrationRoot in $($Config['_file']))." }
$Destination = [IO.Path]::GetFullPath($Destination)
$drive = [IO.Path]::GetPathRoot($Destination)
if (-not (Test-Path -LiteralPath $drive)) { throw "$drive isn't connected." }
if (-not $Name) { $Name = "$env:COMPUTERNAME $(Get-Date -Format 'yyyy-MM-dd')" }
if ($Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "A Backup's name can't contain any of: \ / : * ? "" < > |" }
if ((Get-BackupFiles $Destination $Name).Count) { throw "There is already a Backup called ""$Name"" in $Destination. Choose another -Name." }

# The password: from standard input when something pipes it in, else typed twice.
$password = $null
if ($NoEncryption) {
    Write-Host 'This Backup will not be protected: anyone who gets the file can read everything in it.' -ForegroundColor Yellow
} else {
    if ([Console]::IsInputRedirected) {
        $text = [Console]::In.ReadLine()
        $password = if ($text) { (New-Object System.Net.NetworkCredential('', $text)).SecurePassword } else { $null }
    } else {
        Write-Host 'Choose a password for the Backup. It cannot be recovered if you forget it, so keep it in your password manager.' -ForegroundColor Cyan
        $password = Read-Host 'Password' -AsSecureString
        $again = Read-Host 'Type it again' -AsSecureString
        if ((ConvertFrom-BackupPassword $password) -cne (ConvertFrom-BackupPassword $again)) { throw 'The two passwords are different. Nothing was backed up.' }
    }
    $plain = ConvertFrom-BackupPassword $password
    if (-not $plain -or $plain.Length -lt 8) { throw 'The password needs at least 8 characters. Nothing was backed up.' }
}

$sevenZip = Get-SevenZip
$base = if ($StagingDir) { $StagingDir } else { $env:TEMP }
$staging = Join-Path $base "hopover-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$PID"
$stagingData = Join-Path $staging 'data'
New-Item -ItemType Directory -Path $stagingData -Force | Out-Null
$problems = New-Object System.Collections.Generic.List[string]
$captured = @()
try {
    # The staging data folder carries the Options it was made with: the scripts below read them
    # from here, and so does a restore from this Backup.
    $opts = [ordered]@{}
    foreach ($k in @($Config.Keys)) { if (-not $k.StartsWith('_')) { $opts[$k] = $Config[$k] } }
    [IO.File]::WriteAllText((Join-Path $stagingData 'config.json'), (ConvertTo-Json -InputObject $opts -Depth 6), $Utf8)
    foreach ($f in 'restore-plan.json', 'NOTES.md') {
        $src = Join-Path $DataDir $f
        if (Test-Path -LiteralPath $src -PathType Leaf) { Copy-Item -LiteralPath $src -Destination $stagingData }
    }

    $runs = [ordered]@{
        catalog  = { & (Join-Path $scriptDir 'Catalog-InstalledApps.ps1') -DataDir $stagingData }
        settings = { & (Join-Path $scriptDir 'Export-Settings.ps1') -DataDir $stagingData }
        extras   = { & (Join-Path $scriptDir 'Backup-Extras.ps1') -DataDir $stagingData -Destination (Join-Path $staging 'extras') }
        drivers  = { & (Join-Path $scriptDir 'Save-Drivers.ps1') -DataDir $stagingData -Destination (Join-Path $staging 'drivers') }
    }
    foreach ($step in $known) {
        if ($Steps -notcontains $step) { continue }
        if ($step -eq 'drivers' -and -not (Test-IsAdmin)) {
            $problems.Add('Drivers were left out: exporting them needs an elevated PowerShell (Run as administrator).')
            continue
        }
        Write-Host ''
        Write-Host "== Backup: $step" -ForegroundColor Cyan
        $global:LASTEXITCODE = 0
        try { & $runs[$step] | Out-Host } catch { throw "The $step step failed, so no Backup was made: $($_.Exception.Message)" }
        if ($LASTEXITCODE) { $problems.Add("The $step step reported a problem (exit $LASTEXITCODE); see its output above.") }
        $captured += $step
    }

    Write-Host ''
    Write-Host "== Backup: packing $Name$BackupSuffix" -ForegroundColor Cyan
    $made = New-Backup -Source $staging -Destination $Destination -Name $Name -Password $password -NoEncryption:$NoEncryption `
        -SplitBytes ([long]$SplitMB * 1MB) -Captured $captured -SevenZip $sevenZip
} finally {
    # The staging folder is an unencrypted copy of everything: it must not stay behind unnoticed.
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $staging) {
        Write-Host "Couldn't remove the staging folder $staging. It holds an unencrypted copy of the Backup: delete it yourself." -ForegroundColor Red
    }
}

$size = (@($made.Files) | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum
Write-Host ''
Write-Host "Backup made: $($made.Path) ($([math]::Round($size / 1MB, 1)) MB$(if (@($made.Files).Count -gt 1) { " in $(@($made.Files).Count) pieces" }))" -ForegroundColor Green
if ($made.Encrypted) { Write-Host 'It is encrypted. Without its password nobody can open it, including you.' }
if (@($made.LeftOut).Count) { Write-Host "  [!] Left out because the Backup isn't encrypted (they hold passwords and keys): $(@($made.LeftOut) -join ', ')." -ForegroundColor Yellow }
foreach ($p in $problems) { Write-Host "  [!] $p" -ForegroundColor Yellow }
if ($Steps.Count -lt $known.Count) { Write-Host "  [!] This Backup holds only: $($captured -join ', ')." -ForegroundColor Yellow }
