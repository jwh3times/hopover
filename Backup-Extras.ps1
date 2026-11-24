<#
    Backup-Extras.ps1
    Archives what cloud backups usually skip, plus things worth restoring in one
    step, to a drive that survives the reinstall (<migrationRoot>\extras):

      - app data of the apps in catalog\app-data.json that are installed here
        (some live under Program Files, which most cloud backups exclude),
        plus your own entries from config.json appData.custom
      - files with commonly excluded extensions (.exe, .msi, .dll, .iso, ...)
        under the folders in config.json excludedTypeRoots: portable apps, installers
      - the dev root: folders not in git, loose root files, gitignored local
        files (.env and friends) and uncommitted changes as patches
      - Docker named volumes (Docker must be running)

    Restore.ps1 -Steps app-data,dev-extras,docker-volumes reads manifest.json
    and puts each archive back where it came from.

    Usage:
        powershell -ExecutionPolicy Bypass -File .\Backup-Extras.ps1
        powershell -ExecutionPolicy Bypass -File .\Backup-Extras.ps1 -Only docker-*          # rerun one group
        powershell -ExecutionPolicy Bypass -File .\Backup-Extras.ps1 -Include app-thunderbird-*  # add optional items

    Settings come from <data>\config.json; parameters override them.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    # Data folder (default: $env:HOPOVER_DATA, else .\data).
    [string]$DataDir,

    # Default: <migrationRoot>\extras from config.json.
    [string]$Destination,
    [string]$DevRoot,

    # Folders scanned for commonly excluded file types (default: config excludedTypeRoots).
    [string[]]$ExcludedTypeRoots,

    # Skip individual excluded-type files larger than this (they're listed in the manifest).
    [int]$MaxFileMB,

    # Optional app-data items to include as well (wildcards), on top of config appData.include.
    [string[]]$Include = @(),

    # Only run items whose name matches one of these wildcards.
    [string[]]$Only = @('*'),

    # Repos (relative to DevRoot) whose uncommitted changes you don't care about.
    [string[]]$UseOnlyRepos
)

$ErrorActionPreference = 'Continue'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptDir 'lib\Common.ps1')
$DataDir = Resolve-DataDir $DataDir
$Config  = Get-MigrationConfig $DataDir

if (-not $Destination) {
    Assert-ConfigValue $Config 'migrationRoot' 'a folder on a drive that will not be wiped'
    $Destination = Join-Path (Expand-ConfigPath $Config.migrationRoot) 'extras'
}
if (-not $DevRoot) { $DevRoot = Expand-ConfigPath $Config.devRoot }
if (-not $PSBoundParameters.ContainsKey('ExcludedTypeRoots')) { $ExcludedTypeRoots = @($Config.excludedTypeRoots | ForEach-Object { Expand-ConfigPath $_ }) }
if (-not $PSBoundParameters.ContainsKey('MaxFileMB')) { $MaxFileMB = [int]$Config.maxFileMB }
if (-not $PSBoundParameters.ContainsKey('UseOnlyRepos')) { $UseOnlyRepos = @($Config.useOnlyRepos) }
$Only              = Split-List $Only
$Include           = @(Split-List $Include) + @($Config.appData.include | Where-Object { $_ })
$ExcludedTypeRoots = Split-List $ExcludedTypeRoots
$UseOnlyRepos      = Split-List $UseOnlyRepos
$Tar  = Join-Path $env:windir 'System32\tar.exe'
if (-not (Test-Path -LiteralPath $Tar)) { throw 'tar.exe not found (needs Windows 10 1803 or later).' }

$destDrive = [IO.Path]::GetPathRoot($Destination)
if (-not (Test-Path -LiteralPath $destDrive)) { throw "Destination drive $destDrive isn't connected." }
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$Work = Join-Path $env:TEMP "backup-extras-$PID"
New-Item -ItemType Directory -Path $Work -Force | Out-Null

$ExcludedExt = @('.exe', '.msi', '.dll', '.iso', '.cab', '.sys', '.vhd', '.vhdx', '.vmdk', '.wim', '.dmg', '.dl_', '.drk', '.mem', '.ost', '.vdi')
$SkipDirs    = @('node_modules', '.git', 'bin', 'obj', '.venv', 'venv', 'target', 'dist', 'build', '.next', '.turbo', '.cache')
$SkipPattern = '\\(\$RECYCLE\.BIN|System Volume Information|node_modules|\.git)\\'

# Load the previous manifest so -Only reruns keep the other entries.
$manifestPath = Join-Path $Destination 'manifest.json'
$entries = [ordered]@{}
if (Test-Path -LiteralPath $manifestPath) {
    foreach ($e in @((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).Items)) { $entries[$e.Name] = $e }
}

function Test-Wanted([string]$Name) { foreach ($p in $Only) { if ($Name -like $p) { return $true } }; return $false }

function Save-Entry($Name, $Kind, $File, $RestoreTo, [bool]$Admin, $Count, $Status, $Note) {
    $path = if ($File) { Join-Path $Destination $File } else { $null }
    $mb   = if ($path -and (Test-Path -LiteralPath $path)) { [math]::Round((Get-Item -LiteralPath $path).Length / 1MB, 1) } else { 0 }
    $entries[$Name] = [pscustomobject]@{
        Name = $Name; Kind = $Kind; File = $File; RestoreTo = $RestoreTo; Admin = $Admin
        Files = $Count; SizeMB = $mb; Status = $Status; Note = $Note; Created = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    }
    $color = if ($Status -eq 'ok') { 'Green' } elseif ($Status -like 'skipped*') { 'DarkGray' } else { 'Yellow' }
    Write-Host ("  {0,-34} {1,-10} {2,8} MB  {3}" -f $Name, $Status, $mb, $Note) -ForegroundColor $color
}

# Runs tar; returns $true when the archive exists and lists at least one entry.
function Invoke-Tar([string]$Zip, [string[]]$TarArgs) {
    if (Test-Path -LiteralPath $Zip) { Remove-Item -LiteralPath $Zip -Force }
    $err = & $Tar @TarArgs 2>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }
    $script:TarErrors = @($err)
    if (-not (Test-Path -LiteralPath $Zip)) { return $false }
    $listed = @(& $Tar -tf $Zip 2>$null).Count
    return ($listed -gt 0)
}

# Zips a folder so it extracts as <leaf>\... under its parent.
function Backup-Folder([string]$Name, [string]$Source, [bool]$Admin, [string[]]$Exclude = @()) {
    if (-not (Test-Wanted $Name)) { return }
    $src = [Environment]::ExpandEnvironmentVariables($Source)
    if (-not (Test-Path -LiteralPath $src -PathType Container)) { Save-Entry $Name 'folder' $null $Source $Admin 0 'skipped' 'not found'; return }
    $count = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    if ($count -eq 0) { Save-Entry $Name 'folder' $null $Source $Admin 0 'skipped' 'empty'; return }
    $file = "$Name.zip"
    $zip  = Join-Path $Destination $file
    $tarArgs = @('-a', '-c', '-f', $zip)
    foreach ($x in $Exclude) { $tarArgs += @('--exclude', $x) }
    $tarArgs += @('-C', (Split-Path -Parent $src), (Split-Path -Leaf $src))
    $ok = Invoke-Tar $zip $tarArgs
    $note = if ($script:TarErrors.Count) { "$($script:TarErrors.Count) tar warning(s): $($script:TarErrors[0])" } else { '' }
    Save-Entry $Name 'folder' $file $Source $Admin $count $(if ($ok) { 'ok' } else { 'FAILED' }) $note
}

# Zips a list of files, stored relative to $Root.
function Backup-FileList([string]$Name, [string]$Kind, [string]$Root, [string[]]$RelPaths, [string]$RestoreTo, [string]$Note) {
    if (-not (Test-Wanted $Name)) { return }
    if (-not $RelPaths.Count) { Save-Entry $Name $Kind $null $RestoreTo $false 0 'skipped' 'nothing to archive'; return }
    $list = Join-Path $Work "$Name.txt"
    [IO.File]::WriteAllText($list, (($RelPaths | ForEach-Object { $_.Replace('\', '/') }) -join "`n") + "`n", $Utf8)
    $file = "$Name.zip"
    $zip  = Join-Path $Destination $file
    # "D:" alone means the current folder on D:, so drive roots need the backslash.
    $tarRoot = if ($Root -match ':$') { "$Root\" } else { $Root }
    $ok   = Invoke-Tar $zip @('-a', '-c', '-f', $zip, '-C', $tarRoot, '-T', $list)
    $listed = if ($ok) { @(& $Tar -tf $zip 2>$null | Where-Object { $_ -notmatch '/$' }).Count } else { 0 }
    $status = if (-not $ok) { 'FAILED' } elseif ($listed -lt $RelPaths.Count) { 'PARTIAL' } else { 'ok' }
    if ($status -eq 'PARTIAL') { $Note = "$listed of $($RelPaths.Count) files archived; $Note" }
    if ($script:TarErrors.Count) { $Note = "$Note $($script:TarErrors.Count) tar warning(s): $($script:TarErrors[0])".Trim() }
    Save-Entry $Name $Kind $file $RestoreTo $false $RelPaths.Count $status $Note
}

Write-Host "Backing up to $Destination" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. App data
# ---------------------------------------------------------------------------
Write-Host 'App data:' -ForegroundColor Cyan

function Test-Like([string]$Name, [string[]]$Patterns) { foreach ($p in $Patterns) { if ($p -and $Name -like $p) { return $true } }; return $false }

# Folders matching one app-data pattern. "?:" stands for any drive letter; "*" is a
# wildcard whose first match fills {1} in the item name.
function Find-AppDataFolders([string]$Pattern) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Pattern)
    $roots = if ($expanded.StartsWith('?:')) {
        @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name.Length -eq 1 } | ForEach-Object { "$($_.Name):" + $expanded.Substring(2) })
    } else { @($expanded) }
    $rx = '^' + ([regex]::Escape($expanded) -replace '^\\\?:', '[A-Za-z]:' -replace '\\\*', '([^\\]*)') + '$'
    foreach ($r in $roots) {
        foreach ($m in @(Resolve-Path -Path $r -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path -LiteralPath $m.ProviderPath -PathType Container)) { continue }
            $mm = [regex]::Match($m.ProviderPath, $rx, 'IgnoreCase')
            [pscustomobject]@{ Path = $m.ProviderPath; Tag = $(if ($mm.Success -and $mm.Groups.Count -gt 1) { $mm.Groups[1].Value } else { '' }) }
        }
    }
}

$library = @((Read-JsonFile (Join-Path $ToolRoot 'catalog\app-data.json')).items) + @($Config.appData.custom | Where-Object { $_ -and $_.name -ne 'app-example' })
$seen = @{}
foreach ($item in $library) {
    $iname = [string]$item.name
    if (Test-Like $iname @($Config.appData.exclude)) { continue }
    if ($item.optional -and -not (Test-Like $iname $Include)) { continue }
    $found = @()
    foreach ($pat in @($item.paths)) { $found = @(Find-AppDataFolders $pat); if ($found.Count) { break } }
    foreach ($f in $found) {
        $tag = ($f.Tag.Trim('_').ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
        $name = if ($iname -match '\{1\}') { $iname.Replace('{1}', $tag) -replace '--+', '-' } else { $iname }
        if ($seen[$name]) { continue }
        $seen[$name] = $true
        # Stored with %VARS% so the restore works for another user name.
        Backup-Folder $name (Compress-EnvPath $f.Path) ([bool]$item.admin)
    }
}

# ---------------------------------------------------------------------------
# 2. Commonly excluded file types on the drives being wiped
# ---------------------------------------------------------------------------
Write-Host 'Excluded file types (.exe, .msi, .dll, .iso, ...):' -ForegroundColor Cyan
foreach ($root in $ExcludedTypeRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $rootFull = (Resolve-Path -LiteralPath $root).Path.TrimEnd('\')
    $tag  = ($rootFull -replace '^([A-Za-z]):$', '$1-drive' -replace '^([A-Za-z]):\\', '$1-' -replace '[\\ ]', '-').ToLower()
    $name = "excluded-types-$tag"
    if (-not (Test-Wanted $name)) { continue }
    $files = @(Get-ChildItem -LiteralPath ($rootFull + '\') -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $ExcludedExt -contains $_.Extension.ToLower() -and $_.FullName -notmatch $SkipPattern })
    $big   = @($files | Where-Object { $_.Length -gt $MaxFileMB * 1MB })
    $keep  = @($files | Where-Object { $_.Length -le $MaxFileMB * 1MB })
    $rel   = @($keep | ForEach-Object { $_.FullName.Substring($rootFull.Length + 1) })
    $note  = if ($big.Count) { "skipped $($big.Count) file(s) over $MaxFileMB MB: " + (($big | ForEach-Object { "$($_.Name) ($([math]::Round($_.Length / 1GB, 1)) GB)" }) -join ', ') } else { '' }
    Backup-FileList $name 'files' $rootFull $rel ($rootFull + '\') $note
}

# ---------------------------------------------------------------------------
# 3. C:\dev extras
# ---------------------------------------------------------------------------
Write-Host 'Dev extras:' -ForegroundColor Cyan
if (Test-Path -LiteralPath $DevRoot) {
    $devFull = (Resolve-Path -LiteralPath $DevRoot).Path.TrimEnd('\')

    # Folders with no repo at their top: archive everything outside nested repos.
    foreach ($top in @(Get-ChildItem -LiteralPath $devFull -Directory -Force | Sort-Object Name)) {
        if (Test-Path -LiteralPath (Join-Path $top.FullName '.git')) { continue }
        $name = "dev-folder-$($top.Name.ToLower() -replace '[^a-z0-9._-]', '-')"
        if (-not (Test-Wanted $name)) { continue }
        $files = New-Object System.Collections.Generic.List[string]
        $stack = New-Object System.Collections.Stack
        $stack.Push($top.FullName)
        while ($stack.Count) {
            $dir = $stack.Pop()
            foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
                if ($item.PSIsContainer) {
                    if ($SkipDirs -contains $item.Name) { continue }
                    if (Test-Path -LiteralPath (Join-Path $item.FullName '.git')) { continue }   # nested repo: re-cloned instead
                    $stack.Push($item.FullName)
                } else { $files.Add($item.FullName.Substring($devFull.Length + 1)) }
            }
        }
        Backup-FileList $name 'files' $devFull @($files) ($devFull + '\') 'folder not in git'
    }

    # Loose files in the dev root itself.
    $rootFiles = @(Get-ChildItem -LiteralPath $devFull -File -Force | ForEach-Object Name)
    Backup-FileList 'dev-root-files' 'files' $devFull $rootFiles ($devFull + '\') 'files directly in the dev root'

    # Gitignored local files (.env etc.) from every repo, and uncommitted changes as patches.
    $reposJson = Join-Path $DataDir 'settings\dev\repos.json'
    if (-not (Test-Path -LiteralPath $reposJson)) { Write-Host "  $reposJson missing; run Export-Settings.ps1 first." -ForegroundColor Yellow }
    else {
        # PS 5.1 returns a top-level JSON array as one object; unroll it.
        $parsed = Get-Content -LiteralPath $reposJson -Raw | ConvertFrom-Json
        $repos  = @($parsed | ForEach-Object { $_ })
        $local = @(foreach ($r in $repos) {
            foreach ($f in @($r.LocalFiles)) {
                $rel = (Join-Path $r.Path $f.TrimEnd('/'))
                if (Test-Path -LiteralPath (Join-Path $devFull $rel) -PathType Leaf) { $rel }
            }
        })
        Backup-FileList 'dev-local-files' 'files' $devFull $local ($devFull + '\') 'gitignored .env/.dev.vars/settings.local.json etc. (contains secrets)'

        if (Test-Wanted 'dev-uncommitted') {
            $patchDir = Join-Path $Work 'patches'
            New-Item -ItemType Directory -Path $patchDir -Force | Out-Null
            $n = 0
            foreach ($r in $repos) {
                if ($UseOnlyRepos -contains $r.Path) { continue }
                $repo = Join-Path $devFull $r.Path
                if (-not @(git -C $repo status --porcelain 2>$null).Count) { continue }
                $safe = $r.Path -replace '[\\/]', '__'
                # git writes the file itself, so line endings and binary hunks survive.
                $patchFile = Join-Path $patchDir "$safe.patch"
                git -C $repo diff HEAD --binary "--output=$patchFile" 2>$null
                if ((Test-Path -LiteralPath $patchFile) -and (Get-Item -LiteralPath $patchFile).Length -eq 0) { Remove-Item -LiteralPath $patchFile }
                $untracked = @(git -C $repo ls-files --others --exclude-standard 2>$null)
                if ($untracked.Count) {
                    $ulist = Join-Path $Work "$safe-untracked.txt"
                    [IO.File]::WriteAllText($ulist, ($untracked -join "`n") + "`n", $Utf8)
                    & $Tar -a -c -f (Join-Path $patchDir "$safe-untracked.zip") -C $repo -T $ulist 2>$null
                }
                $n++
            }
            if ($n) {
                $file = 'dev-uncommitted.zip'
                $ok = Invoke-Tar (Join-Path $Destination $file) @('-a', '-c', '-f', (Join-Path $Destination $file), '-C', $patchDir, '.')
                Save-Entry 'dev-uncommitted' 'patches' $file ($devFull + '\') $false $n $(if ($ok) { 'ok' } else { 'FAILED' }) "uncommitted changes in $n repo(s); apply with git apply"
            } else {
                Save-Entry 'dev-uncommitted' 'patches' $null ($devFull + '\') $false 0 'skipped' 'no uncommitted changes'
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Docker named volumes
# ---------------------------------------------------------------------------
if (Test-Wanted 'docker-volumes') {
    Write-Host 'Docker volumes:' -ForegroundColor Cyan
    $dockerUp = $false
    if (Get-Command docker -ErrorAction SilentlyContinue) { docker info --format '{{.ServerVersion}}' 2>$null | Out-Null; $dockerUp = ($LASTEXITCODE -eq 0) }
    if (-not $dockerUp) {
        Save-Entry 'docker-volumes' 'docker' $null '' $false 0 'NOT RUN' 'Docker is not running: start Docker Desktop, then rerun with -Only docker-volumes'
    } else {
        $volDir = Join-Path $Destination 'docker-volumes'
        New-Item -ItemType Directory -Path $volDir -Force | Out-Null
        # Anonymous volumes have 64-hex names and belong to throwaway containers.
        $vols = @(docker volume ls --format '{{.Name}}' 2>$null | Where-Object { $_ -and $_ -notmatch '^[0-9a-f]{64}$' })
        $done = 0; $fail = @()
        foreach ($v in $vols) {
            docker run --rm -v "${v}:/data:ro" -v "${volDir}:/backup" alpine tar czf "/backup/$v.tgz" -C /data . 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $volDir "$v.tgz"))) { $done++ } else { $fail += $v }
        }
        $note = "$done of $($vols.Count) named volumes" + $(if ($fail.Count) { "; failed: $($fail -join ', ')" } else { '' })
        $entries['docker-volumes'] = [pscustomobject]@{
            Name = 'docker-volumes'; Kind = 'docker'; File = 'docker-volumes'; RestoreTo = ''; Admin = $false
            Files = $done; SizeMB = [math]::Round(((Get-ChildItem -LiteralPath $volDir -File | Measure-Object Length -Sum).Sum) / 1MB, 1)
            Status = $(if ($fail.Count) { 'PARTIAL' } else { 'ok' }); Note = $note; Created = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        }
        Write-Host "  docker-volumes                     $($entries['docker-volumes'].Status)  $note"
    }
}

# ---------------------------------------------------------------------------
# Manifest and README
# ---------------------------------------------------------------------------
$items = @($entries.Values | Sort-Object Name)
$manifest = [ordered]@{ Computer = $env:COMPUTERNAME; Updated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); Items = $items }
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), $Utf8)

$NL = "`r`n"
$md  = "# Hopover extras$NL$NL"
$md += "Made by Backup-Extras.ps1 on $env:COMPUTERNAME, last updated $($manifest.Updated). Restore with ``Restore.ps1`` (reads manifest.json).$NL$NL"
$md += "**dev-local-files.zip holds secrets (.env files).** Keep this drive private.$NL$NL"
$md += "Archives are zip files (made with Windows tar). On Linux, linux/restore-linux.sh reads them too.$NL$NL"
$md += "| Item | Status | Files | MB | Restores to | Note |$NL| --- | --- | --- | --- | --- | --- |$NL"
foreach ($i in $items) { $md += "| $($i.Name) | $($i.Status) | $($i.Files) | $($i.SizeMB) | $($i.RestoreTo)$(if ($i.Admin) { ' (admin)' }) | $(($i.Note -replace '\|', '/')) |$NL" }
[IO.File]::WriteAllText((Join-Path $Destination 'README.md'), $md, $Utf8)

Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue

$bad = @($items | Where-Object { $_.Status -in 'FAILED', 'PARTIAL', 'NOT RUN' })
$total = [math]::Round((($items | Measure-Object SizeMB -Sum).Sum) / 1024, 1)
Write-Host ''
Write-Host "Manifest: $manifestPath  ($($items.Count) items, $total GB)" -ForegroundColor Green
if ($bad.Count) {
    Write-Host "Needs attention: $(($bad | ForEach-Object { "$($_.Name) ($($_.Status))" }) -join ', ')" -ForegroundColor Yellow
    exit 1
}
