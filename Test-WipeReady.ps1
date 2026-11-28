<#
    Test-WipeReady.ps1
    The Ready check from the command line: go or no-go before wiping, for one Backup. Every FAIL
    is something that would be lost. Exit code 0 means go.

        powershell -ExecutionPolicy Bypass -File .\Test-WipeReady.ps1 -Backup "E:\Laptop 2026-11-27.hopover.7z"
        powershell -ExecutionPolicy Bypass -File .\Test-WipeReady.ps1 -Backup "E:\Laptop.hopover.7z","\\nas\backups\Laptop.hopover.7z"

    It asks for the Backup's password again (Enter for an unprotected Backup). To pass it from
    another program, pipe it in.

    Fails when:
      - every copy of the Backup is on a drive that will be wiped (the Windows drive always is;
        the wipedDrives Option names the others). A copy on another drive, a network share or in a
        synced folder (OneDrive, Dropbox, Google Drive) survives.
      - a copy that survives doesn't open with the password where it is saved, or the copies aren't
        of one Backup
      - the Backup was made more than -MaxAgeHours ago
      - the Backup leaves out Your files and no cloud backup service (Backblaze) has them, or it
        hasn't caught up
      - a repo under the dev root has uncommitted changes, unpushed commits, stashes or no remote
    Warns when no installer USB is plugged in, and lists what only you can confirm: a copy in a
    synced folder adds "it finished uploading". Defaults come from the Options.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    # Where the Backup is saved: each copy's .hopover.7z (a split Backup's .001).
    [string[]]$Backup,

    # Data folder (default: $env:HOPOVER_DATA, else .\data); only its config.json is read.
    [string]$DataDir,

    # How old the Backup may be.
    [int]$MaxAgeHours = 24,

    # A cloud backup service always has a little churn on an active drive; this much left is fine (default: the backup.maxRemainingMB Option).
    [int]$MaxRemainingMB
)

$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptDir 'lib\Common.ps1')
. (Join-Path $scriptDir 'lib\Backup.ps1')
. (Join-Path $scriptDir 'lib\Probe.ps1')
. (Join-Path $scriptDir 'lib\Ready.ps1')

$Backup = @(Split-List $Backup | ForEach-Object { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_) })
if (-not $Backup.Count) { throw 'Say where the Backup is saved: -Backup <file> (several copies: -Backup <file>,<file>).' }
$DataDir = Resolve-DataDir $DataDir
$Options = Get-Options $DataDir
if ($PSBoundParameters.ContainsKey('MaxRemainingMB')) { $Options['backup']['maxRemainingMB'] = $MaxRemainingMB }

$password = Read-BackupPassword "Type the Backup's password again (Enter if it has none)"
Write-Host 'Checking this PC and testing the Backup; a big Backup takes a while...' -ForegroundColor Cyan
$probe = Get-SystemProbe $Options
$check = Test-ReadyCheck -Copies $Backup -Password $password -Options $Options -Probe $probe -MaxAgeHours $MaxAgeHours

# The check's results in words, for the command line. The page will word the same codes in its
# own table (MSG in ui\index.html) when it shows the Ready check (#23).
function Get-ServiceName([string]$Service) {
    switch ($Service) { 'onedrive' { 'OneDrive' } 'dropbox' { 'Dropbox' } 'google-drive' { 'Google Drive' } 'backblaze' { 'Backblaze' } default { $Service } }
}
function Format-Size([long]$Bytes) { if ($Bytes -ge 1GB) { '{0:N1} GB' -f ($Bytes / 1GB) } else { '{0:N0} MB' -f ($Bytes / 1MB) } }
function Get-ReadyText($Result) {
    $d = $Result.details
    $svc = Get-ServiceName $d.service
    switch ($Result.code) {
        'backup-survives'          { "a copy survives: $(@($d.copies) -join ', ')" }
        'all-copies-wiped'         { "every copy is on a drive that will be wiped ($((@($d.wiped) | ForEach-Object { "${_}:" }) -join ', ')). Copy the Backup to an external drive, a network share, a synced folder or a drive you'll keep." }
        'unplug-drive'             { "$($d.drive): ($($d.label)) holds the Backup: unplug it before starting the installer, so setup can't erase it." }
        'copy-opens'               { "$($d.path) opens" }
        'copy-wrong-password'      { "that password doesn't open $($d.path). Type the one you chose when you made it." }
        'copy-password-needed'     { "$($d.path) is encrypted: type its password." }
        'copy-missing'             { "there is no Backup at $($d.path)." }
        'copy-damaged'             { "$($d.path) is damaged ($($d.message)). Copy it again, or make a new Backup." }
        'copies-differ'            { "these aren't copies of one Backup: $(@($d.copies) -join ', '). Give only the copies of the Backup you'll restore." }
        'backup-recent'            { "made $($d.hours) h ago" }
        'backup-old'               { "made $($d.hours) h ago (limit $($d.limit) h). Make a new Backup." }
        'backup-age-unknown'       { "its age is known once a copy opens." }
        'your-files-in-backup'     { 'in the Backup' }
        'no-cloud-backup'          { "the Backup doesn't hold Your files (Desktop, Documents, Pictures...) and no cloud backup service was found. Copy them somewhere that survives the wipe, or set backup.provider in $($Options['_file'])." }
        'cloud-backup-caught-up'   { "${svc}: $($d.remainingFiles) files / $(Format-Size $d.remainingBytes) left to upload" }
        'cloud-backup-behind'      { "${svc} still has $($d.remainingFiles) files / $(Format-Size $d.remainingBytes) to upload$(if (@($d.volumes).Count) { ' (' + ((@($d.volumes) | Where-Object { $_.remainingBytes } | ForEach-Object { "$($_.path) $(Format-Size $_.remainingBytes)" }) -join ', ') + ')' }). Wait for it to finish." }
        'cloud-backup-stopped'     { "${svc}'s service is $($d.serviceStatus): start it." }
        'cloud-backup-unreadable'  { "${svc}'s status can't be read: is it installed?" }
        'cloud-backup-stale'       { "${svc} last reported $($d.hours) h ago: open it and click Backup Now." }
        'cloud-backup-unsupported' { "Hopover can't read ${svc}'s status: check that it has finished uploading." }
        'repos-saved'              { "$($d.count) repo(s), all committed and pushed" }
        'repo-unsaved'             { "$($d.name): " + ((@(if ($d.uncommitted) { "$($d.uncommitted) uncommitted" }; if ($d.unpushed) { "$($d.unpushed) unpushed" }; if ($d.stashes) { "$($d.stashes) stashed" }; if (-not $d.remotes) { 'no remote' })) -join ', ') + '. Commit and push it.' }
        'repo-unreadable'          { "git couldn't read $($d.path) (is git installed, and does it trust the folder?): make sure it's pushed, or add it to useOnlyRepos." }
        'installer-found'          { "on $((@($d.drives) | ForEach-Object { "${_}:" }) -join ', ')" }
        'no-installer'             { 'none plugged in: make one with the Media Creation Tool (or your Linux distribution''s USB writer).' }
        'dynamic-volume'           { "$($d.drive): is on dynamic disks $(@($d.disks) -join ', '). To keep it, leave those disks alone in setup, then Disk Management > Import Foreign Disks. To reuse them, delete the volume and convert the disks to basic." }
        'confirm-upload'           { "$($d.path) is in a folder $svc syncs: $svc shows it finished uploading." }
        'confirm-password-manager' { 'Password manager: you can sign in from another device, and its recovery kit or secret key is somewhere other than this PC.' }
        'confirm-recovery-codes'   { '2FA recovery codes are saved somewhere other than this PC.' }
        'confirm-cloud-backup-account' { 'Cloud backup service: you know the account password and 2FA, and its version history keeps deleted files long enough to restore them.' }
        'confirm-bitlocker-key'    { 'BitLocker recovery key is at https://account.microsoft.com/devices/recoverykey (if BitLocker is on).' }
        'confirm-microsoft-account' { 'Microsoft account password and 2FA work, for Windows activation and OneDrive.' }
        'confirm-sync-clients'     { 'OneDrive (or any other sync client) shows "up to date", with no pending uploads.' }
        'confirm-licences'         { 'Licences for anything not tied to an account sign-in are saved.' }
        'confirm-custom'           { $d.text }
        default                    { "$($Result.code) $(ConvertTo-Json -InputObject $d -Compress)" }
    }
}
$ruleNames = @{
    'survives-wipe' = 'Survives the wipe'; 'opens' = 'Opens with its password'; 'same-backup' = 'One Backup'
    'recent' = 'Recent'; 'your-files' = 'Your files'; 'repos' = 'Repos'; 'installer-media' = 'Installer USB'
    'dynamic-volumes' = 'Dynamic volume'
}

Write-Host ''
Write-Host "Wiped drives: $((@($check.wiped) | ForEach-Object { "${_}:" }) -join ', ') (the Windows drive, and the wipedDrives Option in $($Options['_file']))"
foreach ($r in $check.results) {
    $color = switch ($r.status) { 'pass' { 'Green' } 'fail' { 'Red' } 'warn' { 'Yellow' } default { 'Gray' } }
    Write-Host ("[{0}] {1,-24} {2}" -f $r.status.ToUpper(), $ruleNames[$r.rule], (Get-ReadyText $r)) -ForegroundColor $color
}
Write-Host ''
Write-Host 'Confirm yourself (no script can check these):' -ForegroundColor Cyan
foreach ($c in $check.confirm) { Write-Host "  [ ] $(Get-ReadyText $c)" }

Write-Host ''
if (-not $check.ready) {
    Write-Host "NOT READY: $(@($check.results | Where-Object status -eq 'fail').Count) check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'READY to wipe, once you have confirmed the list above.' -ForegroundColor Green
