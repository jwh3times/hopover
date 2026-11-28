# lib\Probe.ps1: the Windows system probe, the only way the Ready check reads the machine (spec
# #12). Dot-source it after lib\Common.ps1. Tests give the check a fixture of the same shape:
#
#     drives          letter, label, sizeBytes, freeBytes, fileSystem, system, removable, dynamicDisks
#     syncedFolders   service (onedrive, dropbox, google-drive), path
#     cloudBackup     $null, or service, supported, readable, remainingBytes, remainingFiles,
#                     reportTime, serviceStatus, volumes (path, remainingBytes)
#     repos           path, name (below the dev root), readable, remotes, uncommitted, unpushed, stashes
#     installerMedia  letter, kind (windows, linux)
#
# Works in Windows PowerShell 5.1 (what a fresh install has) and PowerShell 7.

# Every volume with a drive letter. The first storage query in a process can take many seconds
# (an empty card reader), so the probe asks once and hands the list on.
function Get-ProbeVolumes { @(try { Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter } } catch { @() }) }

function Get-ProbeDrives([object[]]$Volumes) {
    $system = ([string]$env:SystemDrive).TrimEnd(':').ToUpper()
    # Letters to disks through CIM, all at once: Get-Partition takes seconds per dynamic disk.
    $ldm = @{}
    foreach ($p in @(Get-CimInstance Win32_DiskPartition -ErrorAction SilentlyContinue)) { $ldm[[string]$p.DeviceID] = [string]$p.Type -like 'Logical Disk Manager*' }
    $disksOf = @{}
    $dynamicOf = @{}
    foreach ($m in @(Get-CimInstance Win32_LogicalDiskToPartition -ErrorAction SilentlyContinue)) {
        $l = ([string]$m.Dependent.DeviceID).TrimEnd(':').ToUpper()
        if ([string]$m.Antecedent.DeviceID -notmatch 'Disk #(\d+)') { continue }
        $disksOf[$l] = @($disksOf[$l]) + [int]$Matches[1] | Where-Object { $null -ne $_ }
        if ($ldm[[string]$m.Antecedent.DeviceID]) { $dynamicOf[$l] = $true }
    }
    $busOf = @{}
    foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue)) { $busOf[[int]$d.Number] = [string]$d.BusType }
    foreach ($v in (@($Volumes) | Sort-Object DriveLetter)) {
        $letter = ([string]$v.DriveLetter).ToUpper()
        $disks = @($disksOf[$letter] | Where-Object { $null -ne $_ } | Sort-Object -Unique)
        $bus = @($disks | ForEach-Object { $busOf[$_] })
        # A volume on dynamic (LDM) disks, as a software RAID is, survives only if setup leaves them alone.
        $dynamic = if ($dynamicOf[$letter]) { $disks } else { @() }
        [pscustomobject]@{
            letter = $letter; label = [string]$v.FileSystemLabel; sizeBytes = [long]$v.Size; freeBytes = [long]$v.SizeRemaining
            fileSystem = [string]$v.FileSystem; system = $letter -eq $system
            removable = $v.DriveType -eq 'Removable' -or $bus -contains 'USB'; dynamicDisks = @($dynamic)
        }
    }
}

# Folders a cloud service keeps online: OneDrive's accounts, Dropbox's, and Google Drive's drive.
function Get-ProbeSyncedFolders([object[]]$Volumes) {
    $found = @()
    foreach ($v in 'OneDrive', 'OneDriveConsumer', 'OneDriveCommercial') {
        $p = [Environment]::GetEnvironmentVariable($v)
        if ($p) { $found += [pscustomobject]@{ service = 'onedrive'; path = $p } }
    }
    foreach ($a in @(Get-ChildItem -Path 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue)) {
        $p = (Get-ItemProperty -LiteralPath $a.PSPath -Name UserFolder -ErrorAction SilentlyContinue).UserFolder
        if ($p) { $found += [pscustomobject]@{ service = 'onedrive'; path = $p } }
    }
    foreach ($base in @($env:LOCALAPPDATA, $env:APPDATA) | Where-Object { $_ }) {
        $info = Read-JsonFile (Join-Path $base 'Dropbox\info.json')
        foreach ($account in @($info.PSObject.Properties | Where-Object { $_.Value.path })) {
            $found += [pscustomobject]@{ service = 'dropbox'; path = [string]$account.Value.path }
        }
    }
    foreach ($v in @($Volumes)) {
        if ($v.FileSystemLabel -eq 'Google Drive') { $found += [pscustomobject]@{ service = 'google-drive'; path = "$($v.DriveLetter):\" } }
    }
    $seen = @{}
    return @($found | Where-Object { Test-Path -LiteralPath $_.path } |
        Where-Object { $k = $_.path.TrimEnd('\').ToLower(); -not $seen.ContainsKey($k) -and ($seen[$k] = $true) })
}

# The cloud backup service the Options name (backup.provider): auto finds Backblaze, the one with
# a status Hopover can read today. $null when there is none.
function Get-ProbeCloudBackup($Options, [string]$BackblazeData = (Join-Path $env:ProgramData 'Backblaze\bzdata')) {
    $provider = [string]$Options['backup']['provider']
    if ($provider -eq 'auto') { $provider = if (Test-Path -LiteralPath $BackblazeData) { 'backblaze' } else { 'none' } }
    if (-not $provider -or $provider -eq 'none') { return $null }
    if ($provider -ne 'backblaze') { return [pscustomobject]@{ service = $provider; supported = $false } }

    $out = [ordered]@{ service = 'backblaze'; supported = $true; readable = $false; remainingBytes = 0; remainingFiles = 0; reportTime = $null; serviceStatus = 'Missing'; volumes = @() }
    $svc = Get-Service -Name bzserv -ErrorAction SilentlyContinue
    if ($svc) { $out.serviceStatus = [string]$svc.Status }
    $report = Join-Path $BackblazeData 'bzreports\bzstat_remainingbackup.xml'
    try {
        $rep = [xml](Get-Content -LiteralPath $report -Raw -ErrorAction Stop)
        $map = @{}
        $infoFile = Join-Path $BackblazeData 'bzinfo.xml'
        if (Test-Path -LiteralPath $infoFile) {
            foreach ($d in ([xml](Get-Content -LiteralPath $infoFile -Raw)).SelectNodes('//hard_drives_to_backup/*')) { $map[$d.bzVolumeGuid] = $d.mountPointPath }
        }
        $out.remainingBytes = [long]$rep.contents.remaining.remainingnumbytesforbackup
        $out.remainingFiles = [long]$rep.contents.remaining.remainingnumfilesforbackup
        $out.volumes = @(@($rep.contents.bzvolume) | Where-Object { $_ } | ForEach-Object {
            [pscustomobject]@{ path = [string]$map[$_.bzVolumeGuid]; remainingBytes = [long]$_.pervol_remaining_files_numbytes } })
        $out.reportTime = (Get-Item -LiteralPath $report).LastWriteTime
        $out.readable = $true
    } catch { }
    return [pscustomobject]$out
}

# The repos under the dev root (devRoot, repoDepth), each with what its remotes don't hold.
function Get-ProbeRepos($Options) {
    $devRoot = Expand-ConfigPath $Options['devRoot']
    if (-not $devRoot -or -not (Test-Path -LiteralPath $devRoot -PathType Container)) { return @() }
    $root = (Resolve-Path -LiteralPath $devRoot).Path.TrimEnd('\')
    $git = [bool](Get-Command git -ErrorAction SilentlyContinue)
    foreach ($top in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $RepoSkipDirs } | Sort-Object Name)) {
        foreach ($r in @(Find-Repos $top.FullName ([int]$Options['repoDepth']))) {
            # Without git nothing can be read, which the Ready check treats as unsaved work.
            $s = if ($git) { Get-RepoState $r } else { [pscustomobject]@{ Readable = $false; Remotes = @(); Uncommitted = 0; Unpushed = 0; Stashes = 0 } }
            [pscustomobject]@{
                path = $r; name = $r.Substring($root.Length + 1); readable = [bool]$s.Readable; remotes = @($s.Remotes).Count
                uncommitted = $s.Uncommitted; unpushed = $s.Unpushed; stashes = $s.Stashes
            }
        }
    }
}

# Plugged-in removable drives an installer boots from: Windows setup's install image, or the
# folders a Linux live USB carries (Ubuntu and Debian's .disk, casper and live; Fedora's LiveOS;
# Arch's arch).
function Get-ProbeInstallerMedia([object[]]$Volumes) {
    foreach ($v in @(@($Volumes) | Where-Object { $_.DriveType -eq 'Removable' })) {
        $l = ([string]$v.DriveLetter).ToUpper()
        if (@('install.wim', 'install.esd', 'install.swm') | Where-Object { Test-Path -LiteralPath "${l}:\sources\$_" }) {
            [pscustomobject]@{ letter = $l; kind = 'windows' }
        } elseif (@('.disk\info', 'casper', 'live', 'LiveOS', 'arch\boot') | Where-Object { Test-Path -LiteralPath "${l}:\$_" }) {
            [pscustomobject]@{ letter = $l; kind = 'linux' }
        }
    }
}

# What the Ready check needs to know about this PC.
function Get-SystemProbe($Options) {
    $volumes = Get-ProbeVolumes
    return [pscustomobject]@{
        drives         = @(Get-ProbeDrives $volumes)
        syncedFolders  = @(Get-ProbeSyncedFolders $volumes)
        cloudBackup    = Get-ProbeCloudBackup $Options
        repos          = @(Get-ProbeRepos $Options)
        installerMedia = @(Get-ProbeInstallerMedia $volumes)
    }
}
