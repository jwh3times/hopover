# Pester 6 tests for lib\Ready.ps1, the Ready check (#18). Each test gives the check a system
# probe fixture in place of the machine, and real Backups packed with the pinned 7zr.exe, which
# these tests download like Backup.Tests.ps1, so every run needs the network.

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Backup.ps1')
    . (Join-Path $root 'lib\Ready.ps1')
    $SevenZip = Get-SevenZip -CacheDir (Join-Path $TestDrive 'bin')
    $Phrase = 'correct horse battery'
    $Password = (New-Object System.Net.NetworkCredential('', $Phrase)).SecurePassword
    # The drive this test drive is on: the fixtures say whether it is wiped.
    $Here = $TestDrive.Substring(0, 1).ToUpper()
    $Made = [datetime]'2026-11-27T09:00:00Z'
    $Now = $Made.AddHours(2)

    # A Backup packed by hand from a hopover.json made when and holding what the test says.
    function New-FixtureBackup {
        param([string]$Folder, [datetime]$Created = $Made, [string[]]$Groups = @('settings'), [string]$Name = 'Fixture PC', [string]$With = $Phrase)
        if (-not $Folder) { $Folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) }
        $staging = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Folder, (Join-Path $staging 'data') -Force | Out-Null
        $manifest = [ordered]@{
            formatVersion = 1; hopoverVersion = 'v0.6.1'; created = $Created.ToUniversalTime().ToString('o'); sourceOs = 'windows'
            computerName = 'FIXTURE-PC'; encrypted = $true; includesPasswordsAndKeys = $false; captured = @('settings'); groups = @($Groups); apps = @()
        }
        Set-Content -LiteralPath (Join-Path $staging 'hopover.json') -Value (ConvertTo-Json $manifest) -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $staging 'data\note.txt') -Value ([guid]::NewGuid().ToString()) -Encoding ASCII
        $file = Join-Path $Folder "$Name.hopover.7z"
        Push-Location $staging
        try { & $SevenZip a -t7z "-p$With" -mhe=on $file * | Out-Null } finally { Pop-Location }
        return $file
    }

    # A probe of a PC whose only drive is this test drive's, the Windows drive, unless the test
    # says otherwise; with an installer USB plugged in and a cloud backup service that has caught up.
    function New-Probe([hashtable]$With = @{}) {
        $p = [ordered]@{
            drives         = @([pscustomobject]@{ letter = $Here; label = 'Windows'; sizeBytes = 500GB; freeBytes = 100GB; fileSystem = 'NTFS'; system = $true; removable = $false })
            syncedFolders  = @()
            cloudBackup    = [pscustomobject]@{ service = 'backblaze'; supported = $true; readable = $true; remainingBytes = 0; remainingFiles = 0; reportTime = $Now.AddMinutes(-10); serviceStatus = 'Running'; volumes = @() }
            repos          = @()
            installerMedia = @([pscustomobject]@{ letter = 'F'; kind = 'windows' })
        }
        foreach ($k in $With.Keys) { $p[$k] = $With[$k] }
        return [pscustomobject]$p
    }
    # This test drive's drive, not wiped, and another one the Windows drive.
    function Get-DrivesWithDataDrive {
        @([pscustomobject]@{ letter = 'W'; label = 'Windows'; sizeBytes = 500GB; freeBytes = 100GB; fileSystem = 'NTFS'; system = $true; removable = $false },
          [pscustomobject]@{ letter = $Here; label = 'Data'; sizeBytes = 2TB; freeBytes = 1TB; fileSystem = 'NTFS'; system = $false; removable = $false })
    }

    function Invoke-Check {
        param([string[]]$Copies, $Probe = (New-Probe), [hashtable]$Options = @{}, [securestring]$With = $Password, [datetime]$At = $Now)
        $opt = Get-ConfigDefaults
        foreach ($k in $Options.Keys) { $opt[$k] = $Options[$k] }
        return Test-ReadyCheck -Copies $Copies -Password $With -Options $opt -Probe $Probe -Now $At -SevenZip $SevenZip
    }
    function Get-Rule($Check, [string]$Rule) { @($Check.results | Where-Object { $_.rule -eq $Rule }) }
}

Describe 'The Ready check: the Backup survives the wipe' {
    It 'fails when the only copy is on the Windows drive' {
        $check = Invoke-Check -Copies (New-FixtureBackup)
        $check.ready | Should -BeFalse
        $r = Get-Rule $check 'survives-wipe'
        $r.status | Should -Be 'fail'
        $r.code | Should -Be 'all-copies-wiped'
    }

    It 'passes when a copy is on a drive that is not wiped' {
        $file = New-FixtureBackup
        $check = Invoke-Check -Copies $file -Probe (New-Probe @{ drives = Get-DrivesWithDataDrive })
        $r = Get-Rule $check 'survives-wipe'
        $r.status | Should -Be 'pass'
        $r.code | Should -Be 'backup-survives'
        @($r.details.copies) | Should -Be @($file)
        $check.ready | Should -BeTrue
    }

    It 'still counts the Windows drive as wiped when the probe could not list the drives' {
        $copy = "$($env:SystemDrive)\Backups\Fixture PC.hopover.7z"
        $r = Get-Rule (Invoke-Check -Copies $copy -Probe (New-Probe @{ drives = @() })) 'survives-wipe'
        $r.status | Should -Be 'fail'
        $r.code | Should -Be 'all-copies-wiped'
    }

    It 'counts a drive the wipedDrives Option names as wiped' {
        $check = Invoke-Check -Copies (New-FixtureBackup) -Probe (New-Probe @{ drives = Get-DrivesWithDataDrive }) -Options @{ wipedDrives = @("${Here}:") }
        (Get-Rule $check 'survives-wipe').status | Should -Be 'fail'
        $check.ready | Should -BeFalse
    }

    It 'passes when one copy of several is on a drive that is not wiped' {
        $one = New-FixtureBackup
        $two = Join-Path $TestDrive 'second.hopover.7z'
        Copy-Item -LiteralPath $one -Destination $two
        $probe = New-Probe @{ drives = Get-DrivesWithDataDrive }
        # The first is on the Windows drive by its letter; the second is on the kept one.
        $check = Invoke-Check -Copies 'W:\Backups\Fixture PC.hopover.7z', $two -Probe $probe
        $r = Get-Rule $check 'survives-wipe'
        $r.status | Should -Be 'pass'
        @($r.details.copies) | Should -Be @($two)
    }

    It 'counts a copy in a synced folder as surviving, and asks the user to confirm it finished uploading' {
        $folder = Join-Path $TestDrive 'OneDrive'
        $file = New-FixtureBackup -Folder (Join-Path $folder 'Backups')
        $check = Invoke-Check -Copies $file -Probe (New-Probe @{ syncedFolders = @([pscustomobject]@{ service = 'onedrive'; path = $folder }) })
        (Get-Rule $check 'survives-wipe').status | Should -Be 'pass'
        $upload = @($check.confirm | Where-Object { $_.code -eq 'confirm-upload' })
        $upload.Count | Should -Be 1
        $upload[0].details.path | Should -Be $file
        $upload[0].details.service | Should -Be 'onedrive'
        $check.ready | Should -BeTrue
    }

    It 'does not take a folder whose name only starts like a synced folder''s for one' {
        $folder = Join-Path $TestDrive 'OneDrive'
        $file = New-FixtureBackup -Folder (Join-Path $TestDrive 'OneDrive old')
        $check = Invoke-Check -Copies $file -Probe (New-Probe @{ syncedFolders = @([pscustomobject]@{ service = 'onedrive'; path = $folder }) })
        (Get-Rule $check 'survives-wipe').status | Should -Be 'fail'
        @($check.confirm | Where-Object { $_.code -eq 'confirm-upload' }).Count | Should -Be 0
    }
}

Describe 'The Ready check: the Backup opens with the password typed again' {
    BeforeAll { $DataDriveProbe = New-Probe @{ drives = Get-DrivesWithDataDrive } }

    It 'passes when the copy where it is saved opens with the password' {
        $file = New-FixtureBackup
        $r = Get-Rule (Invoke-Check -Copies $file -Probe $DataDriveProbe) 'opens'
        $r.status | Should -Be 'pass'
        $r.code | Should -Be 'copy-opens'
        $r.details.path | Should -Be $file
    }

    It 'fails when the password typed again is not the Backup''s' {
        $check = Invoke-Check -Copies (New-FixtureBackup) -Probe $DataDriveProbe -With (New-Object System.Net.NetworkCredential('', 'correct horse battery staple')).SecurePassword
        $check.ready | Should -BeFalse
        $r = Get-Rule $check 'opens'
        $r.status | Should -Be 'fail'
        $r.code | Should -Be 'copy-wrong-password'
    }

    It 'fails when no password was typed for an encrypted Backup' {
        $r = Get-Rule (Invoke-Check -Copies (New-FixtureBackup) -Probe $DataDriveProbe -With $null) 'opens'
        $r.status | Should -Be 'fail'
        $r.code | Should -Be 'copy-password-needed'
    }

    It 'fails when there is no Backup where the user said it is saved' {
        $check = Invoke-Check -Copies (Join-Path $TestDrive 'nowhere\Fixture PC.hopover.7z') -Probe $DataDriveProbe
        $check.ready | Should -BeFalse
        (Get-Rule $check 'opens').code | Should -Be 'copy-missing'
    }

    It 'fails when the copy is damaged' {
        $file = New-FixtureBackup
        $bytes = [IO.File]::ReadAllBytes($file)
        [IO.File]::WriteAllBytes($file, $bytes[0..([int]($bytes.Length / 2))])
        $r = Get-Rule (Invoke-Check -Copies $file -Probe $DataDriveProbe) 'opens'
        $r.status | Should -Be 'fail'
        $r.code | Should -Be 'copy-damaged'
    }

    It 'tests only the copies that survive the wipe when one does' {
        $kept = New-FixtureBackup
        $check = Invoke-Check -Copies 'W:\Backups\Fixture PC.hopover.7z', $kept -Probe $DataDriveProbe
        @(Get-Rule $check 'opens' | ForEach-Object { $_.details.path }) | Should -Be @($kept)
        $check.ready | Should -BeTrue
    }

    It 'still tests the password when no copy survives the wipe' {
        $r = Get-Rule (Invoke-Check -Copies (New-FixtureBackup) -With $null) 'opens'
        $r.code | Should -Be 'copy-password-needed'
    }

    It 'fails when the copies are not the same Backup' {
        $one = New-FixtureBackup
        $two = New-FixtureBackup -Created $Made.AddMinutes(-30)
        $check = Invoke-Check -Copies $one, $two -Probe $DataDriveProbe
        $check.ready | Should -BeFalse
        $r = Get-Rule $check 'same-backup'
        $r.status | Should -Be 'fail'
        $r.code | Should -Be 'copies-differ'
        @($r.details.copies) | Should -Be @($one, $two)
    }
}

Describe 'The Ready check: the Backup is recent' {
    BeforeAll { $DataDriveProbe = New-Probe @{ drives = Get-DrivesWithDataDrive } }

    It 'passes a Backup made less than 24 hours ago' {
        $r = Get-Rule (Invoke-Check -Copies (New-FixtureBackup) -Probe $DataDriveProbe -At $Made.AddHours(23.5)) 'recent'
        $r.status | Should -Be 'pass'
        $r.code | Should -Be 'backup-recent'
        $r.details.hours | Should -Be 23.5
    }

    It 'fails a Backup made more than 24 hours ago, going by when it was made, not the file''s date' {
        $file = New-FixtureBackup
        (Get-Item -LiteralPath $file).LastWriteTime = $Made.AddHours(25).ToLocalTime()
        $check = Invoke-Check -Copies $file -Probe $DataDriveProbe -At $Made.AddHours(25)
        $check.ready | Should -BeFalse
        $r = Get-Rule $check 'recent'
        $r.status | Should -Be 'fail'
        $r.code | Should -Be 'backup-old'
        $r.details.hours | Should -Be 25
        $r.details.limit | Should -Be 24
    }

    It 'passes a Backup made exactly 24 hours ago' {
        $r = Get-Rule (Invoke-Check -Copies (New-FixtureBackup) -Probe $DataDriveProbe -At $Made.AddHours(24)) 'recent'
        $r.status | Should -Be 'pass'
        $r.details.hours | Should -Be 24
    }

    It 'says the age is unknown when no copy opens' {
        $r = Get-Rule (Invoke-Check -Copies (New-FixtureBackup) -Probe $DataDriveProbe -With $null) 'recent'
        $r.status | Should -Be 'info'
        $r.code | Should -Be 'backup-age-unknown'
    }
}

Describe 'The Ready check: Your files are kept somewhere' {
    BeforeAll {
        function New-Backblaze([hashtable]$With = @{}) {
            $b = [ordered]@{ service = 'backblaze'; supported = $true; readable = $true; remainingBytes = 10MB; remainingFiles = 3; reportTime = $Now.AddMinutes(-10); serviceStatus = 'Running'; volumes = @() }
            foreach ($k in $With.Keys) { $b[$k] = $With[$k] }
            return [pscustomobject]$b
        }
        function Invoke-YourFiles($Cloud, [string[]]$Groups = @('settings'), [hashtable]$Options = @{}) {
            $probe = New-Probe @{ drives = Get-DrivesWithDataDrive; cloudBackup = $Cloud }
            Get-Rule (Invoke-Check -Copies (New-FixtureBackup -Groups $Groups) -Probe $probe -Options $Options) 'your-files'
        }
    }

    It 'fails when the Backup leaves out Your files and no cloud backup service is found' {
        $probe = New-Probe @{ drives = Get-DrivesWithDataDrive; cloudBackup = $null }
        $check = Invoke-Check -Copies (New-FixtureBackup) -Probe $probe
        $check.ready | Should -BeFalse
        $r = Get-Rule $check 'your-files'
        $r.status | Should -Be 'fail'
        $r.code | Should -Be 'no-cloud-backup'
    }

    It 'passes with no cloud backup service when the Backup holds Your files' {
        $r = Invoke-YourFiles $null -Groups 'settings', 'your-files'
        $r.status | Should -Be 'pass'
        $r.code | Should -Be 'your-files-in-backup'
    }

    It 'passes when the cloud backup service has caught up' {
        $r = Invoke-YourFiles (New-Backblaze)
        $r.status | Should -Be 'pass'
        $r.code | Should -Be 'cloud-backup-caught-up'
    }

    It 'fails when the cloud backup service has more left to upload than backup.maxRemainingMB' {
        $r = @(Invoke-YourFiles (New-Backblaze @{ remainingBytes = 3GB; remainingFiles = 1200 }) -Options @{ backup = [ordered]@{ provider = 'auto'; maxRemainingMB = 2048 } })
        $r.status | Should -Be 'fail'
        $r.code | Should -Be 'cloud-backup-behind'
        $r.details.remainingBytes | Should -Be 3GB
        $r.details.remainingFiles | Should -Be 1200
    }

    It 'fails when the cloud backup service is not running' {
        $r = @(Invoke-YourFiles (New-Backblaze @{ serviceStatus = 'Stopped' }))
        @($r | Where-Object status -eq 'fail' | ForEach-Object code) | Should -Be @('cloud-backup-stopped')
    }

    It 'fails when the cloud backup service''s status cannot be read' {
        $r = Invoke-YourFiles (New-Backblaze @{ readable = $false })
        $r.status | Should -Be 'fail'
        $r.code | Should -Be 'cloud-backup-unreadable'
    }

    It 'warns when the cloud backup service last reported more than two hours ago' {
        $r = @(Invoke-YourFiles (New-Backblaze @{ reportTime = $Now.AddHours(-3) }))
        @($r | Where-Object status -eq 'warn' | ForEach-Object code) | Should -Be @('cloud-backup-stale')
        @($r | Where-Object status -eq 'fail').Count | Should -Be 0
    }

    It 'warns, rather than fails, about a cloud backup service it cannot read' {
        $r = Invoke-YourFiles ([pscustomobject]@{ service = 'carbonite'; supported = $false })
        $r.status | Should -Be 'warn'
        $r.code | Should -Be 'cloud-backup-unsupported'
    }
}

Describe 'The Ready check: repos are committed and pushed' {
    BeforeAll {
        $OneBackup = New-FixtureBackup
        function New-Repo([string]$Name, [hashtable]$With = @{}) {
            $r = [ordered]@{ path = "C:\dev\$Name"; name = $Name; readable = $true; remotes = 1; uncommitted = 0; unpushed = 0; stashes = 0 }
            foreach ($k in $With.Keys) { $r[$k] = $With[$k] }
            return [pscustomobject]$r
        }
        function Invoke-Repos([object[]]$Repos, [hashtable]$Options = @{}) {
            Invoke-Check -Copies $OneBackup -Probe (New-Probe @{ drives = Get-DrivesWithDataDrive; repos = $Repos }) -Options $Options
        }
    }

    It 'passes when every repo is committed and pushed' {
        $r = Get-Rule (Invoke-Repos (New-Repo 'a'), (New-Repo 'b')) 'repos'
        $r.status | Should -Be 'pass'
        $r.code | Should -Be 'repos-saved'
        $r.details.count | Should -Be 2
    }

    It 'fails for each repo with uncommitted changes, unpushed commits, stashes or no remote' {
        $check = Invoke-Repos (New-Repo 'clean'), (New-Repo 'dirty' @{ uncommitted = 2 }), (New-Repo 'ahead' @{ unpushed = 1 }),
            (New-Repo 'stashed' @{ stashes = 1 }), (New-Repo 'local' @{ remotes = 0 })
        $check.ready | Should -BeFalse
        $r = @(Get-Rule $check 'repos')
        @($r | ForEach-Object status | Select-Object -Unique) | Should -Be @('fail')
        @($r | ForEach-Object code | Select-Object -Unique) | Should -Be @('repo-unsaved')
        @($r | ForEach-Object { $_.details.name }) | Should -Be @('dirty', 'ahead', 'stashed', 'local')
        ($r | Where-Object { $_.details.name -eq 'dirty' }).details.uncommitted | Should -Be 2
    }

    It 'leaves out the repos useOnlyRepos names' {
        $check = Invoke-Repos (New-Repo 'tools\vendored' @{ uncommitted = 5 }), (New-Repo 'mine') -Options @{ useOnlyRepos = @('tools\vendored') }
        $r = Get-Rule $check 'repos'
        $r.code | Should -Be 'repos-saved'
        $r.details.count | Should -Be 1
        $check.ready | Should -BeTrue
    }

    It 'fails for a repo whose state git could not read, since it may hold unpushed work' {
        $check = Invoke-Repos (New-Repo 'odd' @{ readable = $false })
        $check.ready | Should -BeFalse
        $r = Get-Rule $check 'repos'
        $r.status | Should -Be 'fail'
        $r.code | Should -Be 'repo-unreadable'
    }

    It 'says nothing about repos when there are none' {
        @(Get-Rule (Invoke-Repos @()) 'repos').Count | Should -Be 0
    }
}

Describe 'The Ready check: getting through the reinstall' {
    BeforeAll { $OneBackup = New-FixtureBackup }

    It 'warns, without failing, when no installer media is plugged in' {
        $check = Invoke-Check -Copies $OneBackup -Probe (New-Probe @{ drives = Get-DrivesWithDataDrive; installerMedia = @() })
        $r = Get-Rule $check 'installer-media'
        $r.status | Should -Be 'warn'
        $r.code | Should -Be 'no-installer'
        $check.ready | Should -BeTrue
    }

    It 'passes when installer media is plugged in' {
        $r = Get-Rule (Invoke-Check -Copies $OneBackup -Probe (New-Probe @{ drives = Get-DrivesWithDataDrive })) 'installer-media'
        $r.status | Should -Be 'pass'
        $r.code | Should -Be 'installer-found'
        @($r.details.drives) | Should -Be @('F')
    }

    It 'says to unplug a removable drive that holds the Backup before reinstalling' {
        $drives = @(Get-DrivesWithDataDrive)
        $drives[1].removable = $true
        $drives[1].label = 'Backup USB'
        $r = Get-Rule (Invoke-Check -Copies $OneBackup -Probe (New-Probe @{ drives = $drives })) 'survives-wipe' | Where-Object code -eq 'unplug-drive'
        $r.status | Should -Be 'info'
        $r.details.drive | Should -Be $Here
        $r.details.label | Should -Be 'Backup USB'
    }

    It 'asks about the cloud backup service''s account only when there is one' {
        $with = @((Invoke-Check -Copies $OneBackup -Probe (New-Probe @{ drives = Get-DrivesWithDataDrive })).confirm | ForEach-Object code)
        $without = @((Invoke-Check -Copies $OneBackup -Probe (New-Probe @{ drives = Get-DrivesWithDataDrive; cloudBackup = $null })).confirm | ForEach-Object code)
        $with | Should -Contain 'confirm-cloud-backup-account'
        $without | Should -Not -Contain 'confirm-cloud-backup-account'
    }

    It 'lists what only the user can confirm, recovery codes and the confirm Option''s lines among them' {
        $check = Invoke-Check -Copies $OneBackup -Probe (New-Probe @{ drives = Get-DrivesWithDataDrive }) -Options @{ confirm = @('NAS snapshot taken') }
        $codes = @($check.confirm | ForEach-Object code)
        foreach ($c in 'confirm-password-manager', 'confirm-recovery-codes', 'confirm-bitlocker-key', 'confirm-microsoft-account', 'confirm-licences') { $codes | Should -Contain $c }
        @($check.confirm | Where-Object code -eq 'confirm-custom' | ForEach-Object { $_.details.text }) | Should -Be @('NAS snapshot taken')
        @($check.confirm | ForEach-Object status | Select-Object -Unique) | Should -Be @('confirm')
    }
}

Describe 'The Ready check: dynamic volumes' {
    It 'says how to keep a volume that spans dynamic disks' {
        $drives = @(Get-DrivesWithDataDrive) + [pscustomobject]@{ letter = 'R'; label = 'Raid'; sizeBytes = 4TB; freeBytes = 1TB; fileSystem = 'NTFS'; system = $false; removable = $false; dynamicDisks = @(1, 2) }
        $r = Get-Rule (Invoke-Check -Copies (New-FixtureBackup) -Probe (New-Probe @{ drives = $drives })) 'dynamic-volumes'
        $r.status | Should -Be 'info'
        $r.code | Should -Be 'dynamic-volume'
        $r.details.drive | Should -Be 'R'
        @($r.details.disks) | Should -Be @(1, 2)
    }
}

Describe 'The Windows system probe' {
    BeforeAll { . (Join-Path $root 'lib\Probe.ps1') }

    It 'reports the Windows drive' {
        $opt = Get-ConfigDefaults
        $opt['devRoot'] = Join-Path $TestDrive 'no-dev-root'
        $probe = Get-SystemProbe $opt
        $system = @($probe.drives | Where-Object system)
        $system.Count | Should -Be 1
        $system[0].letter | Should -Be $env:SystemDrive.Substring(0, 1).ToUpper()
        $system[0].sizeBytes | Should -BeGreaterThan 0
        $system[0].fileSystem | Should -Not -BeNullOrEmpty
    }

    It 'finds the repos under the dev root, with their uncommitted work and missing remote' {
        $dev = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $repo = Join-Path $dev 'work\app'
        New-Item -ItemType Directory -Path $repo, (Join-Path $dev 'node_modules\dep\.git') -Force | Out-Null
        git init -q $repo 2>$null
        Set-Content -LiteralPath (Join-Path $repo 'new.txt') -Value 'not committed' -Encoding ASCII
        $opt = Get-ConfigDefaults
        $opt['devRoot'] = $dev
        $repos = @((Get-SystemProbe $opt).repos)
        $repos.Count | Should -Be 1
        $repos[0].name | Should -Be 'work\app'
        $repos[0].readable | Should -BeTrue
        $repos[0].uncommitted | Should -Be 1
        $repos[0].remotes | Should -Be 0
    }

    It 'reads how much Backblaze has left to upload from its status files' {
        $bz = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $bz 'bzreports') | Out-Null
        Set-Content -LiteralPath (Join-Path $bz 'bzinfo.xml') -Encoding ASCII -Value '<contents><hard_drives_to_backup><drive bzVolumeGuid="g1" mountPointPath="C:\" /></hard_drives_to_backup></contents>'
        Set-Content -LiteralPath (Join-Path $bz 'bzreports\bzstat_remainingbackup.xml') -Encoding ASCII -Value (
            '<contents><remaining remainingnumfilesforbackup="12" remainingnumbytesforbackup="5368709120" />' +
            '<bzvolume bzVolumeGuid="g1" pervol_remaining_files_numbytes="5368709120" /></contents>')
        $cloud = Get-ProbeCloudBackup (Get-ConfigDefaults) -BackblazeData $bz
        $cloud.service | Should -Be 'backblaze'
        $cloud.readable | Should -BeTrue
        $cloud.remainingBytes | Should -Be 5GB
        $cloud.remainingFiles | Should -Be 12
        $cloud.volumes[0].path | Should -Be 'C:\'
    }

    It 'finds no cloud backup service when backup.provider is none, or auto finds none' {
        $opt = Get-ConfigDefaults
        Get-ProbeCloudBackup $opt -BackblazeData (Join-Path $TestDrive 'no-backblaze') | Should -BeNullOrEmpty
        $opt['backup']['provider'] = 'none'
        Get-ProbeCloudBackup $opt | Should -BeNullOrEmpty
    }

    It 'names a backup.provider it cannot read as unsupported' {
        $opt = Get-ConfigDefaults
        $opt['backup']['provider'] = 'carbonite'
        $cloud = Get-ProbeCloudBackup $opt
        $cloud.service | Should -Be 'carbonite'
        $cloud.supported | Should -BeFalse
    }
}
