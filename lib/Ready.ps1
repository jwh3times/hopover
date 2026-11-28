# lib\Ready.ps1: the Ready check, the go/no-go test before wiping (GLOSSARY.md). Dot-source it
# after lib\Common.ps1 and lib\Backup.ps1.
#
# The check reads the machine only through a system probe (lib\Probe.ps1's Get-SystemProbe, or a
# test's fixture). Each result is { status, rule, code, details }: status is pass, fail, warn or
# info (confirm for what only the user can confirm), rule names the rule, and code is the message
# code a front end words, filled in by details. Any fail means no-go.
#
# Works in Windows PowerShell 5.1 (what a fresh install has) and PowerShell 7.

function New-ReadyResult([string]$Status, [string]$Rule, [string]$Code, $Details = @{}) {
    return [pscustomobject]@{ status = $Status; rule = $Rule; code = $Code; details = [pscustomobject]$Details }
}

# The drive letter a path is on, upper-case; $null for a network path.
function Get-PathDrive([string]$Path) {
    if ($Path -match '^([A-Za-z]):') { return $Matches[1].ToUpper() }
    return $null
}

# hopover.json's created time in UTC, or $null. PowerShell 7's ConvertFrom-Json has already made
# it a date; Windows PowerShell 5.1's leaves the ISO 8601 text.
function ConvertTo-UtcTime($Value) {
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $t = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal', [ref]$t)) { return $t }
    return $null
}

# The probe's synced folder that holds $Path, or $null.
function Get-SyncedFolder([string]$Path, $Probe) {
    foreach ($s in @($Probe.syncedFolders)) {
        $folder = ([string]$s.path).TrimEnd('\', '/')
        if (-not $folder) { continue }
        if ($Path.StartsWith($folder + '\', [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($folder + '/', [StringComparison]::OrdinalIgnoreCase)) { return $s }
    }
    return $null
}

# Runs every rule of the Ready check on the copies of one Backup. $Copies are the paths of its
# copies (a split Backup's first piece), $Password the password the user typed again, $Probe the
# system probe, $Now the time to judge its age by. Returns { ready, wiped (the drive letters judged
# wiped), results, confirm }.
function Test-ReadyCheck {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Mandatory)][string[]]$Copies,
        [securestring]$Password,
        [Parameter(Mandatory)]$Options,
        [Parameter(Mandatory)]$Probe,
        [datetime]$Now = (Get-Date),
        # How old the Backup may be.
        [int]$MaxAgeHours = 24,
        [string]$SevenZip
    )
    $results = New-Object System.Collections.Generic.List[object]
    $confirm = New-Object System.Collections.Generic.List[object]

    # The Backup survives the wipe: a copy on a drive that isn't wiped, on a network share, or in a
    # synced folder, which the user confirms has finished uploading.
    # A probe that couldn't list the drives still leaves the Windows drive wiped.
    $system = @(@($Probe.drives) | Where-Object { $_.system } | ForEach-Object { $_.letter })
    if (-not $system.Count) { $system = @($env:SystemDrive) }
    $wiped = @(Get-WipedDrives $Options $system)
    $surviving = @(foreach ($c in $Copies) {
        $synced = Get-SyncedFolder $c $Probe
        if ($synced) { $confirm.Add((New-ReadyResult 'confirm' 'survives-wipe' 'confirm-upload' @{ path = $c; service = $synced.service })) }
        # A network path has no drive letter, so it is never on a wiped drive.
        if ($synced -or $wiped -notcontains (Get-PathDrive $c)) { $c }
    })
    if ($surviving.Count) {
        $results.Add((New-ReadyResult 'pass' 'survives-wipe' 'backup-survives' @{ copies = $surviving }))
    } else {
        $results.Add((New-ReadyResult 'fail' 'survives-wipe' 'all-copies-wiped' @{ copies = @($Copies); wiped = $wiped }))
    }

    # The Backup opens with the password typed again, where it is saved: every copy that survives,
    # or every copy when none does, since the password is worth knowing either way.
    if (-not $SevenZip) { $SevenZip = Get-SevenZip }
    $opened = @()
    foreach ($c in @(if ($surviving.Count) { $surviving } else { $Copies })) {
        $t = Test-Backup -Path $c -Password $Password -SevenZip $SevenZip
        if ($t.Result -eq 'ok') {
            $results.Add((New-ReadyResult 'pass' 'opens' 'copy-opens' @{ path = $c }))
            $m = Read-BackupManifest -Path $c -Password $Password -SevenZip $SevenZip
            if ($m.Result -eq 'ok') { $opened += [pscustomobject]@{ path = $c; manifest = $m.Manifest; identity = (Get-BackupIdentity $m.Raw) } }
        } else {
            $results.Add((New-ReadyResult 'fail' 'opens' "copy-$($t.Result)" @{ path = $c; message = $t.Message }))
        }
    }
    # Copies of one Backup: a copy of an older one would pass for the Backup just made.
    if (@($opened | ForEach-Object identity | Select-Object -Unique).Count -gt 1) {
        $results.Add((New-ReadyResult 'fail' 'same-backup' 'copies-differ' @{ copies = @($opened | ForEach-Object path) }))
    }
    $manifest = if ($opened.Count) { $opened[0].manifest } else { $null }

    # The Backup is recent, going by when it was made (a copied file can carry any date).
    $created = if ($manifest) { ConvertTo-UtcTime $manifest.created } else { $null }
    if ($null -eq $created) {
        $results.Add((New-ReadyResult 'info' 'recent' 'backup-age-unknown'))
    } else {
        $hours = [math]::Round(($Now.ToUniversalTime() - $created).TotalHours, 1)
        $age = @{ hours = $hours; limit = $MaxAgeHours; created = $created.ToString('o') }
        if ($hours -gt $MaxAgeHours) { $results.Add((New-ReadyResult 'fail' 'recent' 'backup-old' $age)) }
        else { $results.Add((New-ReadyResult 'pass' 'recent' 'backup-recent' $age)) }
    }

    # Your files are kept: in the Backup, or by a cloud backup service that has caught up. A
    # Backup that can't be read counts as leaving them out.
    $cloud = $Probe.cloudBackup
    if ($manifest -and @($manifest.groups) -contains 'your-files') {
        $results.Add((New-ReadyResult 'pass' 'your-files' 'your-files-in-backup'))
    } elseif (-not $cloud) {
        $results.Add((New-ReadyResult 'fail' 'your-files' 'no-cloud-backup'))
    } elseif (-not $cloud.supported) {
        $results.Add((New-ReadyResult 'warn' 'your-files' 'cloud-backup-unsupported' @{ service = $cloud.service }))
    } elseif (-not $cloud.readable) {
        $results.Add((New-ReadyResult 'fail' 'your-files' 'cloud-backup-unreadable' @{ service = $cloud.service }))
    } else {
        $limit = [long]$Options['backup']['maxRemainingMB'] * 1MB
        $upload = @{ service = $cloud.service; remainingBytes = [long]$cloud.remainingBytes; remainingFiles = [long]$cloud.remainingFiles; limitBytes = $limit; volumes = @($cloud.volumes) }
        if ($cloud.remainingBytes -gt $limit) { $results.Add((New-ReadyResult 'fail' 'your-files' 'cloud-backup-behind' $upload)) }
        else { $results.Add((New-ReadyResult 'pass' 'your-files' 'cloud-backup-caught-up' $upload)) }
        if ($cloud.serviceStatus -ne 'Running') {
            $results.Add((New-ReadyResult 'fail' 'your-files' 'cloud-backup-stopped' @{ service = $cloud.service; serviceStatus = [string]$cloud.serviceStatus }))
        }
        $reported = [math]::Round(($Now.ToUniversalTime() - ([datetime]$cloud.reportTime).ToUniversalTime()).TotalHours, 1)
        if ($reported -gt 2) { $results.Add((New-ReadyResult 'warn' 'your-files' 'cloud-backup-stale' @{ service = $cloud.service; hours = $reported })) }
    }

    # Repos under the dev root are committed and pushed, apart from the use-only ones. One git can't
    # read may hold anything, so it fails too.
    $useOnly = @(Split-List $Options['useOnlyRepos'])
    $repos = @(@($Probe.repos) | Where-Object { $_ -and $useOnly -notcontains $_.name })
    foreach ($r in $repos) {
        $state = @{ path = $r.path; name = $r.name }
        if (-not $r.readable) { $results.Add((New-ReadyResult 'fail' 'repos' 'repo-unreadable' $state)); continue }
        if ($r.uncommitted -or $r.unpushed -or $r.stashes -or -not $r.remotes) {
            foreach ($k in 'uncommitted', 'unpushed', 'stashes', 'remotes') { $state[$k] = [int]$r.$k }
            $results.Add((New-ReadyResult 'fail' 'repos' 'repo-unsaved' $state))
        }
    }
    if ($repos.Count -and -not @($results | Where-Object { $_.rule -eq 'repos' }).Count) {
        $results.Add((New-ReadyResult 'pass' 'repos' 'repos-saved' @{ count = $repos.Count }))
    }

    # Installer media to reinstall from: only a warning, since it can be made on another PC.
    $media = @(@($Probe.installerMedia) | Where-Object { $_ })
    if ($media.Count) { $results.Add((New-ReadyResult 'pass' 'installer-media' 'installer-found' @{ drives = @($media | ForEach-Object letter) })) }
    else { $results.Add((New-ReadyResult 'warn' 'installer-media' 'no-installer')) }

    # A removable drive holding the Backup is safest unplugged while the installer runs.
    $backupDrives = @($surviving | ForEach-Object { Get-PathDrive $_ } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($d in @(@($Probe.drives) | Where-Object { $_.removable -and $backupDrives -contains $_.letter })) {
        $results.Add((New-ReadyResult 'info' 'survives-wipe' 'unplug-drive' @{ drive = $d.letter; label = [string]$d.label }))
    }

    # A volume spanning dynamic disks (a software RAID) survives only if setup leaves its disks alone.
    foreach ($d in @($Probe.drives)) {
        $disks = @($d.dynamicDisks | Where-Object { $null -ne $_ })
        if ($disks.Count) { $results.Add((New-ReadyResult 'info' 'dynamic-volumes' 'dynamic-volume' @{ drive = $d.letter; disks = $disks })) }
    }

    # What no probe can see, for the user to confirm.
    $builtIn = @('confirm-password-manager', 'confirm-recovery-codes')
    if ($cloud) { $builtIn += 'confirm-cloud-backup-account' }
    $builtIn += 'confirm-bitlocker-key', 'confirm-microsoft-account', 'confirm-sync-clients', 'confirm-licences'
    foreach ($c in $builtIn) { $confirm.Add((New-ReadyResult 'confirm' 'confirm-yourself' $c)) }
    foreach ($text in @(@($Options['confirm']) | Where-Object { $_ } | Select-Object -Unique)) {
        $confirm.Add((New-ReadyResult 'confirm' 'confirm-yourself' 'confirm-custom' @{ text = [string]$text }))
    }

    return [pscustomobject]@{
        ready   = -not @($results | Where-Object { $_.status -eq 'fail' }).Count
        wiped   = $wiped
        results = $results.ToArray()
        confirm = $confirm.ToArray()
    }
}
