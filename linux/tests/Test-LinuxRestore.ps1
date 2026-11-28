<#
    Test-LinuxRestore.ps1
    Runs linux/restore-linux.sh inside throwaway Docker containers, one per distro, restoring a
    Backup (seam 3 of spec #12). Needs Docker Desktop. By default the Backup is a small fixture,
    made here with the Backup module (lib\Backup.ps1) and its password piped in, so each run also
    shows the bootstrap installing a 7-Zip that opens a Backup made on Windows.

        # resolve the fixture's apps against real package metadata, install nothing
        powershell -File linux\tests\Test-LinuxRestore.ps1

        # really install a few apps in each container (vendor repos, .deb/.rpm, scripts)
        powershell -File linux\tests\Test-LinuxRestore.ps1 -Install -Only Git.GitHub.cli,Microsoft.VisualStudioCode

        # a subset of distros
        powershell -File linux\tests\Test-LinuxRestore.ps1 -Images ubuntu:latest,fedora:latest

        # your own Backup (asks for its password once), or a data folder's exports
        powershell -File linux\tests\Test-LinuxRestore.ps1 -Backup 'E:\Laptop 2026-11-27.hopover.7z'
        powershell -File linux\tests\Test-LinuxRestore.ps1 -DataDir C:\dev\hopover\data

    Logs and reports go to -OutDir (default: %TEMP%\linux-restore-tests). Containers
    run as root, so AUR packages are skipped there (AUR helpers refuse root) and
    Flatpak and systemd steps only print what they would do.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    # Ubuntu 22.04 and Debian 12 too: their 7zip package's command is 7zz, not 7z.
    [string[]]$Images = @('ubuntu:22.04', 'ubuntu:latest', 'debian:12', 'debian:latest', 'fedora:latest', 'archlinux:latest', 'linuxmintd/mint22-amd64', 'cachyos/cachyos:latest'),
    # A Backup to restore instead of the fixture.
    [string]$Backup,
    # A data folder (the layout from before Backups) to restore instead of a Backup.
    [string]$DataDir,
    [string]$OutDir = (Join-Path $env:TEMP 'linux-restore-tests'),
    [string]$Steps = 'packages',
    [string]$Only,
    [switch]$Install
)

$ErrorActionPreference = 'Continue'
$tool = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $tool 'lib\Common.ps1')
. (Join-Path $tool 'lib\Backup.ps1')
$Images = Split-List $Images
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
if ($Backup -and $DataDir) { throw 'Pass -Backup or -DataDir, not both.' }

docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker is not running. Start Docker Desktop first.' }

# The fixture Backup: a few apps (one with a vendor repo, one Windows-only), a git config and no
# extras, made fresh each run so it is always the format this Hopover writes.
function New-FixtureBackup([string]$Folder, [securestring]$Password) {
    $staging = Join-Path $Folder 'staging'
    $out = Join-Path $Folder 'backup'
    Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path (Join-Path $staging 'data\settings\dev'), (Join-Path $staging 'extras'), $out -Force | Out-Null
    $apps = 'Git.Git', 'GitHub.cli', 'Microsoft.VisualStudioCode', 'Mozilla.Firefox', '7zip.7zip', 'Microsoft.VCRedist.2015+.x64'
    $winget = @{ Sources = @(@{ Packages = @($apps | ForEach-Object { @{ PackageIdentifier = $_ } }) }) }
    [IO.File]::WriteAllText((Join-Path $staging 'data\winget-packages.json'), (ConvertTo-Json $winget -Depth 5), $Utf8)
    [IO.File]::WriteAllText((Join-Path $staging 'data\settings\dev\gitconfig'), "[user]`n`tname = Fixture User`n", $Utf8)
    [IO.File]::WriteAllText((Join-Path $staging 'extras\manifest.json'), '{ "Items": [] }', $Utf8)
    return (New-Backup -Source $staging -Destination $out -Name 'Fixture PC' -Password $Password -Captured @('catalog', 'settings')).Path
}

$password = $null
if ($DataDir) {
    $DataDir = Resolve-DataDir $DataDir
} elseif ($Backup) {
    $Backup = (Resolve-Path -LiteralPath $Backup).Path
    $checked = Read-BackupManifest -Path $Backup
    if ($checked.Result -eq 'password-needed') { $password = Read-BackupPassword "Password for $(Get-BackupName $Backup)" }
} else {
    # Accented letters, so the containers' 7-Zip is shown reading a non-ASCII password as typed.
    $password = (New-Object System.Net.NetworkCredential('', "fixture p$([char]0x00E4)ssw$([char]0x00F6)rd")).SecurePassword
    $Backup = New-FixtureBackup (Join-Path $OutDir 'fixture') $password
    Write-Host "Fixture Backup: $Backup" -ForegroundColor Cyan
}
# The password goes to the container on standard input, as UTF-8 with no BOM.
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
$plain = ConvertFrom-BackupPassword $password

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
    $cmd = @('bash', '/tool/linux/restore-linux.sh', '--steps', $Steps, '--report', "/out/$report")
    if ($DataDir) {
        $mounts = @('-v', "${DataDir}:/data:ro")
        $cmd += @('--data', '/data')
    } else {
        $mounts = @('-v', "$(Split-Path -Parent $Backup):/backup:ro")
        $cmd += @('--backup', "/backup/$(Split-Path -Leaf $Backup)")
    }
    if (-not $Install) { $cmd += @('--dry-run', '--refresh') }
    if ($Only) { $cmd += @('--only', $Only) }
    Write-Host "== $img" -ForegroundColor Cyan
    $t0 = Get-Date
    if ($plain) {
        $plain | & docker run --rm -i @envArgs -e TERM=dumb -v "${tool}:/tool:ro" @mounts -v "${OutDir}:/out" $img @cmd *> $log
    } else {
        & docker run --rm @envArgs -e TERM=dumb -v "${tool}:/tool:ro" @mounts -v "${OutDir}:/out" $img @cmd *> $log
    }
    $code = $LASTEXITCODE
    $secs = [math]::Round(((Get-Date) - $t0).TotalSeconds)
    $summary = (Select-String -LiteralPath $log -Pattern '^\s+packages\s+' | Select-Object -Last 1).Line
    $system = (Select-String -LiteralPath $log -Pattern 'system:' | Select-Object -First 1).Line
    $sevenZip = (Select-String -LiteralPath $log -Pattern '7-Zip:' | Select-Object -First 1).Line
    Write-Host "  exit $code in $secs s; $("$system".Trim())"
    if ($sevenZip) { Write-Host "  $("$sevenZip".Trim())" }
    Write-Host "  $("$summary".Trim())"
    $results += [pscustomobject]@{ Image = $img; Exit = $code; Seconds = $secs; SevenZip = "$sevenZip".Trim(); Summary = $summary; Log = $log; Report = (Join-Path $OutDir $report) }
}
$results | Format-Table Image, Exit, Seconds, SevenZip -AutoSize | Out-String | Write-Host
Write-Host "Logs and reports: $OutDir"
