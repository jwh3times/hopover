<#
    Test-WipeReady.ps1
    Go/no-go check before formatting the drives. Every FAIL is something that
    would be lost or would make the restore harder. Exit code 0 means go.

    Usage:
        powershell -ExecutionPolicy Bypass -File .\Test-WipeReady.ps1

    Checks:
      - the cloud backup (Backblaze, when installed or set in the Options) has
        almost nothing left to upload, has scanned since the extras archive
        was written, and its service is running
      - Backup-Extras.ps1, Save-Drivers.ps1, Export-Settings.ps1 and
        Catalog-InstalledApps.ps1 have all run recently and cleanly
      - no repo under the dev root has unpushed or uncommitted work
      - the data folder (and this tool, if you changed it) is committed and pushed
      - recovery files exist on a drive that isn't being wiped
      - a Windows installer USB is plugged in
    and lists the things only you can confirm. Defaults come from the Options.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    # Data folder (default: $env:HOPOVER_DATA, else .\data).
    [string]$DataDir,

    # Where Backup-Extras.ps1 and Save-Drivers.ps1 wrote (default: config migrationRoot).
    [string]$MigrationRoot,

    # Drives that will NOT be wiped (default: config keepDrives).
    [string[]]$KeepDrives,

    # How old the exports may be.
    [int]$MaxAgeHours = 24,

    # A backup client always has a little churn on an active drive; this much left is fine (default: config backup.maxRemainingMB).
    [int]$MaxRemainingMB,

    # Don't fail on Docker volumes not being archived.
    [switch]$SkipDocker
)

$ErrorActionPreference = 'Continue'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptDir 'lib\Common.ps1')
$DataDir = Resolve-DataDir $DataDir
$Config  = Get-Options $DataDir
if (-not $MigrationRoot) { $MigrationRoot = Expand-ConfigPath $Config.migrationRoot }
if (-not $PSBoundParameters.ContainsKey('KeepDrives')) { $KeepDrives = @($Config.keepDrives) }
if (-not $PSBoundParameters.ContainsKey('MaxRemainingMB')) { $MaxRemainingMB = [int]$Config.backup.maxRemainingMB }
$KeepDrives = @(Split-List $KeepDrives | ForEach-Object { $_.TrimEnd(':', '\') })
$DevRoot = Expand-ConfigPath $Config.devRoot
$now = Get-Date
$results = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$Status, [string]$Check, [string]$Detail) {
    $results.Add([pscustomobject]@{ Status = $Status; Check = $Check; Detail = $Detail })
}
function Get-Age([datetime]$When) { [math]::Round(($now - $When).TotalHours, 1) }

if (-not $Config['_exists']) { Add-Result 'WARN' 'Options' "No $($Config['_file']); using defaults. config.example.json in the tool folder lists every option." }
if (-not $MigrationRoot) {
    Add-Result 'FAIL' 'Migration folder' "Set migrationRoot in $($Config['_file']): a folder on a drive that will not be wiped."
    $MigrationRoot = '(migrationRoot not set)'   # the checks below then report the archives as missing
}

# ---------------------------------------------------------------------------
# Cloud backup (Backblaze is the one with a readable status today)
# ---------------------------------------------------------------------------
$bz = Join-Path $env:ProgramData 'Backblaze\bzdata'
$remainingFile = Join-Path $bz 'bzreports\bzstat_remainingbackup.xml'
$provider = [string]$Config.backup.provider
if ($provider -eq 'auto') { $provider = if (Test-Path -LiteralPath $bz) { 'backblaze' } else { 'none' } }
if ($provider -eq 'none') {
    Add-Result 'INFO' 'Cloud backup' 'No backup client checked (none installed, or backup.provider is "none"). Make sure your backup has finished.'
} elseif ($provider -ne 'backblaze') {
    Add-Result 'WARN' 'Cloud backup' "backup.provider ""$provider"" isn't supported; check it by hand."
} elseif (-not (Test-Path -LiteralPath $remainingFile)) {
    Add-Result 'FAIL' 'Backblaze status' "No $remainingFile; is Backblaze installed?"
} else {
    $rep  = [xml](Get-Content -LiteralPath $remainingFile -Raw)
    $info = [xml](Get-Content -LiteralPath (Join-Path $bz 'bzinfo.xml') -Raw)
    $map  = @{}
    foreach ($d in $info.SelectNodes('//hard_drives_to_backup/*')) { $map[$d.bzVolumeGuid] = $d.mountPointPath }
    $remMB  = [math]::Round([long]$rep.contents.remaining.remainingnumbytesforbackup / 1MB)
    $remN   = [long]$rep.contents.remaining.remainingnumfilesforbackup
    $per    = @($rep.contents.bzvolume | ForEach-Object {
        $gb = [math]::Round([long]$_.pervol_remaining_files_numbytes / 1GB, 1)
        if ($gb -gt 0) { "$($map[$_.bzVolumeGuid]) $gb GB" } })
    $repTime = (Get-Item -LiteralPath $remainingFile).LastWriteTime
    if ($remMB -le $MaxRemainingMB) {
        Add-Result 'PASS' 'Backblaze upload' "$remN files / $remMB MB left (report from $($repTime.ToString('MM-dd HH:mm')))"
    } else {
        Add-Result 'FAIL' 'Backblaze upload' ("{0:N0} files / {1:N0} GB still to upload: {2}" -f $remN, ($remMB / 1024), ($per -join ', '))
    }
    if ((Get-Age $repTime) -gt 2) { Add-Result 'WARN' 'Backblaze status age' "Status file is $(Get-Age $repTime) h old; open Backblaze and click Backup Now." }

    $svc = Get-Service -Name bzserv -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { Add-Result 'PASS' 'Backblaze service' 'running' }
    else { Add-Result 'FAIL' 'Backblaze service' "bzserv is $(if ($svc) { $svc.Status } else { 'missing' })" }

    $manifest = Join-Path $MigrationRoot 'extras\manifest.json'
    if (Test-Path -LiteralPath $manifest) {
        $mTime = (Get-Item -LiteralPath $manifest).LastWriteTime
        if ($repTime -gt $mTime.AddMinutes(30)) { Add-Result 'PASS' 'Backblaze saw the extras' "status ($($repTime.ToString('MM-dd HH:mm'))) is newer than the extras ($($mTime.ToString('MM-dd HH:mm')))" }
        else { Add-Result 'FAIL' 'Backblaze saw the extras' "Backblaze hasn't reported since the extras were written ($($mTime.ToString('MM-dd HH:mm'))); wait for its next pass." }
    }
}

# ---------------------------------------------------------------------------
# Exports and archives
# ---------------------------------------------------------------------------
function Test-Fresh([string]$Check, [string]$Path, [string]$Fix) {
    if (-not (Test-Path -LiteralPath $Path)) { Add-Result 'FAIL' $Check "missing: $Path. $Fix"; return $false }
    $age = Get-Age (Get-Item -LiteralPath $Path).LastWriteTime
    if ($age -gt $MaxAgeHours) { Add-Result 'FAIL' $Check "$age h old (limit $MaxAgeHours h). $Fix"; return $false }
    Add-Result 'PASS' $Check "$age h old"
    return $true
}

[void](Test-Fresh 'App catalog'     (Join-Path $DataDir 'Installed-Apps-Catalog.md') 'Run Catalog-InstalledApps.ps1.')
[void](Test-Fresh 'winget export'   (Join-Path $DataDir 'winget-packages.json')      'Run Catalog-InstalledApps.ps1.')
if (Test-Fresh 'Settings export' (Join-Path $DataDir 'settings\README.md') 'Run Export-Settings.ps1.') {
    $readme = Get-Content -LiteralPath (Join-Path $DataDir 'settings\README.md') -Raw
    if ($readme -match 'Leak scan: clean') { Add-Result 'PASS' 'Settings leak scan' 'clean' }
    else { Add-Result 'FAIL' 'Settings leak scan' 'settings\README.md lists files the leak scan removed; check them.' }
}

$manifest = Join-Path $MigrationRoot 'extras\manifest.json'
if (Test-Fresh 'Extras archive' $manifest 'Run Backup-Extras.ps1.') {
    $items = @((Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).Items)
    $bad = @($items | Where-Object { $_.Status -in 'FAILED', 'PARTIAL', 'NOT RUN' -and -not ($SkipDocker -and $_.Name -eq 'docker-volumes') })
    if ($bad.Count) { Add-Result 'FAIL' 'Extras contents' (($bad | ForEach-Object { "$($_.Name): $($_.Status) $($_.Note)" }) -join '; ') }
    else { Add-Result 'PASS' 'Extras contents' "$($items.Count) items, $([math]::Round((($items | Measure-Object SizeMB -Sum).Sum) / 1024, 1)) GB" }
}

$drvDir = Join-Path $MigrationRoot 'drivers'
$infs = @(Get-ChildItem -LiteralPath $drvDir -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue)
if (-not $infs.Count) { Add-Result 'FAIL' 'Driver export' "No drivers in $drvDir. Run Save-Drivers.ps1 elevated." }
else {
    $netInfs = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceClass -eq 'NET' -and $_.InfName -like 'oem*.inf' } | ForEach-Object InfName | Sort-Object -Unique)
    Add-Result 'PASS' 'Driver export' "$($infs.Count) packages in $drvDir (network adapters on this PC use $($netInfs -join ', '))"
}

# ---------------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------------
$reposMd = Join-Path $DataDir 'settings\dev\repos.md'
if (Test-Path -LiteralPath $reposMd) {
    $m = [regex]::Match((Get-Content -LiteralPath $reposMd -Raw), 'needing attention: \*\*(\d+)\*\*')
    if ($m.Success -and $m.Groups[1].Value -eq '0') { Add-Result 'PASS' "Repos under $DevRoot" 'all committed and pushed (as of the last settings export)' }
    elseif ($m.Success) { Add-Result 'FAIL' "Repos under $DevRoot" "$($m.Groups[1].Value) repo(s) need attention; see settings\dev\repos.md" }
}

# The data folder is how you get everything back, so it must be safe somewhere else.
$dataGit = Get-GitState $DataDir
if ($null -eq $dataGit) {
    Add-Result 'WARN' 'Data folder' "$DataDir isn't a git repo. Push it to a private repo, or copy it to a keep drive."
} elseif (-not $dataGit.HasRemote) {
    Add-Result 'FAIL' 'Data folder' "$DataDir has no remote; push it to a private repo (or copy it to a keep drive)."
} elseif ($dataGit.Dirty -or $dataGit.Unpushed) {
    Add-Result 'FAIL' 'Data folder' "$($dataGit.Dirty) uncommitted, $($dataGit.Unpushed) unpushed; commit and push it (it's how you get everything back)."
} else { Add-Result 'PASS' 'Data folder' 'committed and pushed' }

# The tool itself can be cloned again; only your own changes to it are at risk.
$toolGit = Get-GitState $ToolRoot
if ($toolGit -and ($toolGit.Dirty -or $toolGit.Unpushed)) {
    Add-Result 'WARN' 'Tool folder' "$($toolGit.Dirty) uncommitted, $($toolGit.Unpushed) unpushed change(s) in $ToolRoot; push them if you made them."
}

# ---------------------------------------------------------------------------
# Drives and recovery material
# ---------------------------------------------------------------------------
if (-not $KeepDrives.Count) { Add-Result 'WARN' 'Keep drives' "Set keepDrives in $($Config['_file']) (drive letters that survive the reinstall)." }
foreach ($k in $KeepDrives) {
    $vol = Get-Volume -DriveLetter $k -ErrorAction SilentlyContinue
    if (-not $vol) { Add-Result 'WARN' "Keep drive ${k}:" 'not connected'; continue }
    $part = Get-Partition -DriveLetter $k -ErrorAction SilentlyContinue
    $bus  = if ($part) { [string](Get-Disk -Number $part.DiskNumber).BusType } else { '?' }
    Add-Result 'INFO' "Keep drive ${k}:" "$($vol.FileSystemLabel) ($bus). Unplug it before booting the installer."
}

$patterns = @($Config.recoveryFiles | Where-Object { $_ })
$codes = @(foreach ($k in $KeepDrives) {
    Get-ChildItem -LiteralPath "${k}:\" -File -ErrorAction SilentlyContinue | Where-Object { $n = $_.Name; @($patterns | Where-Object { $n -like $_ }).Count }
})
if ($codes.Count) { Add-Result 'PASS' 'Recovery files off the wiped drives' (($codes | ForEach-Object FullName) -join ', ') }
elseif ($KeepDrives.Count) { Add-Result 'WARN' 'Recovery files off the wiped drives' "Nothing matching $($patterns -join ', ') in the root of $(($KeepDrives | ForEach-Object { "${_}:" }) -join ', '). Copy your 2FA recovery codes somewhere that survives (or set recoveryFiles in $($Config['_file']))." }

$installer = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter } |
    Where-Object { (Test-Path "$($_.DriveLetter):\sources\install.wim") -or (Test-Path "$($_.DriveLetter):\sources\install.esd") -or (Test-Path "$($_.DriveLetter):\sources\install.swm") })
if ($installer.Count) { Add-Result 'PASS' 'Windows installer USB' "found on $(($installer | ForEach-Object { "$($_.DriveLetter):" }) -join ', ')" }
else { Add-Result 'WARN' 'Windows installer USB' 'none plugged in; make one with the Media Creation Tool.' }

foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' })) {
    if (Get-Partition -DriveLetter $v.DriveLetter -ErrorAction SilentlyContinue) { continue }
    $disks = @(Get-CimInstance Win32_LogicalDiskToPartition -ErrorAction SilentlyContinue |
        Where-Object { $_.Dependent.DeviceID -eq "$($v.DriveLetter):" } |
        ForEach-Object { if ($_.Antecedent.DeviceID -match 'Disk #(\d+)') { $Matches[1] } } | Sort-Object -Unique)
    if ($disks.Count) {
        Add-Result 'INFO' "$($v.DriveLetter): is a dynamic (LDM) volume" ("on disks $($disks -join ', '). Keep it: don't touch those disks in setup, then Disk Management > Import Foreign Disks. " +
            'Reuse them: delete the volume and convert both disks to basic.')
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host ''
foreach ($r in $results) {
    $color = switch ($r.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
    Write-Host ("[{0}] {1,-36} {2}" -f $r.Status, $r.Check, $r.Detail) -ForegroundColor $color
}
Write-Host ''
Write-Host 'Confirm yourself (no script can check these):' -ForegroundColor Cyan
$confirm = @(
    'Password manager: you can sign in from another device, and its recovery kit or secret key is somewhere other than this PC.',
    'Cloud backup: you know the account password and 2FA, and its version history keeps deleted files long enough to restore them.',
    'BitLocker recovery key is at https://account.microsoft.com/devices/recoverykey (if BitLocker is on).',
    'Microsoft account password and 2FA work, for Windows activation and OneDrive.',
    'OneDrive (or any other sync client) shows "up to date", with no pending uploads.',
    'Licenses for anything not tied to an account sign-in are saved.'
) + @($Config.confirm | Where-Object { $_ })
$confirm | Select-Object -Unique | ForEach-Object { Write-Host "  [ ] $_" }

$fails = @($results | Where-Object Status -eq 'FAIL').Count
Write-Host ''
if ($fails) { Write-Host "NOT READY: $fails check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'READY to wipe, once you have confirmed the list above.' -ForegroundColor Green
