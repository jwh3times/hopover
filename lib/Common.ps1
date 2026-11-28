# lib\Common.ps1: helpers shared by the scripts in the tool root.
#
#     $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
#     . (Join-Path $scriptDir 'lib\Common.ps1')
#     $DataDir = Resolve-DataDir $DataDir
#     $Config  = Get-Options $DataDir
#
# Works in Windows PowerShell 5.1 (what a fresh install has) and PowerShell 7.

$ToolRoot = Split-Path -Parent $PSScriptRoot
$Utf8     = New-Object System.Text.UTF8Encoding($false)

# powershell -File passes "a,b" as one string; split list parameters ourselves.
function Split-List([string[]]$Values) {
    @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# The data folder holds one person's exports and config, apart from the tool:
# -DataDir, else $env:HOPOVER_DATA, else .\data next to the scripts.
function Resolve-DataDir([string]$DataDir) {
    if (-not $DataDir) { $DataDir = $env:HOPOVER_DATA }
    if (-not $DataDir) { $DataDir = Join-Path $ToolRoot 'data' }
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($DataDir)).TrimEnd('\')
}

# %VARS% and a leading ~ expanded.
function Expand-ConfigPath([string]$Path) {
    if (-not $Path) { return $Path }
    $p = [Environment]::ExpandEnvironmentVariables($Path)
    if ($p -eq '~' -or $p.StartsWith('~\') -or $p.StartsWith('~/')) { $p = $env:USERPROFILE + $p.Substring(1) }
    return $p
}

# The reverse, so archived paths still work for a different user name or drive layout.
function Compress-EnvPath([string]$Path) {
    foreach ($v in 'LOCALAPPDATA', 'APPDATA', 'ProgramFiles(x86)', 'ProgramFiles', 'ProgramData', 'USERPROFILE') {
        $val = [Environment]::GetEnvironmentVariable($v)
        if ($val -and $Path.StartsWith($val.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return "%$v%" + $Path.Substring($val.TrimEnd('\').Length) }
        if ($val -and $Path -eq $val.TrimEnd('\')) { return "%$v%" }
    }
    return $Path
}

# ConvertFrom-Json gives PSCustomObjects (and 5.1 has no -AsHashtable); configs are easier as hashtables.
function ConvertTo-PlainHashtable($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-PlainHashtable $p.Value }
        return $h
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return , @($Value | ForEach-Object { ConvertTo-PlainHashtable $_ })
    }
    return $Value
}

# Defaults for every Option. See config.example.json for what each one means.
function Get-ConfigDefaults {
    [ordered]@{
        devRoot           = 'C:\dev'
        repoDepth         = 3
        useOnlyRepos      = @()
        migrationRoot     = ''
        wipedDrives       = @()
        excludedTypeRoots = @('%USERPROFILE%\Downloads')
        maxFileMB         = 1024
        portableRoots     = @('%USERPROFILE%\OneDrive\Documents', '%USERPROFILE%\Documents', '%USERPROFILE%\Desktop', '%USERPROFILE%\Downloads',
                              '%USERPROFILE%\Portable', '%USERPROFILE%\Apps', '%USERPROFILE%\Tools')
        appData           = [ordered]@{ include = @(); exclude = @(); custom = @() }
        backup            = [ordered]@{ provider = 'auto'; maxRemainingMB = 1024 }
        confirm           = @()
        linux             = [ordered]@{ devRoot = '~/dev'; prefer = @('vendor', 'distro', 'portable', 'flatpak'); aur = 'auto'; flatpak = $true; nodeMajor = 24 }
    }
}

# Where Hopover keeps its Options on this PC: %LOCALAPPDATA%\Hopover\options.json, or the file
# HOPOVER_OPTIONS names. The elevated helper (Invoke-AdminSteps.ps1) sets that to the user's file:
# it runs as whoever approved the administrator prompt, whose own LOCALAPPDATA may be another
# account's. restore_linux.py's options_path follows the same rule.
function Get-OptionsPath {
    if ($env:HOPOVER_OPTIONS) { return $env:HOPOVER_OPTIONS }
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $env:USERPROFILE 'AppData\Local' }
    return Join-Path $base 'Hopover\options.json'
}

# One options file's keys over $Options, one level deep for the nested sections. $schema and
# _comment keys are skipped at both levels. restore_linux.py's load_options follows the same rule.
function Merge-OptionsFile($Options, [string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    $user = ConvertTo-PlainHashtable (Get-Content -LiteralPath $File -Raw | ConvertFrom-Json)
    foreach ($k in @($user.Keys)) {
        if ($k.StartsWith('$') -or $k.StartsWith('_')) { continue }
        if ($Options[$k] -is [System.Collections.IDictionary] -and $user[$k] -is [System.Collections.IDictionary]) {
            foreach ($k2 in @($user[$k].Keys)) {
                if ($k2.StartsWith('$') -or $k2.StartsWith('_')) { continue }
                $Options[$k][$k2] = $user[$k][$k2]
            }
        } else {
            $Options[$k] = $user[$k]
        }
    }
    return $true
}

# Hopover's Options, in layers: the defaults, then the data folder's config.json (the layout
# from before Options), then options.json in the per-user Hopover folder. A later layer wins key
# by key, so a config.json key that options.json doesn't set still applies.
# _file is the file to edit: options.json when it exists, else the data folder's config.json,
# which survives the wipe with the data folder (options.json sits on the Windows drive).
function Get-Options([string]$DataDir) {
    $opt = Get-ConfigDefaults
    $configFile  = if ($DataDir) { Join-Path $DataDir 'config.json' } else { '' }
    $optionsFile = Get-OptionsPath
    $hasConfig  = $configFile -and (Merge-OptionsFile $opt $configFile)
    $hasOptions = Merge-OptionsFile $opt $optionsFile
    $opt['_file']   = if ($configFile -and -not $hasOptions) { $configFile } else { $optionsFile }
    $opt['_exists'] = [bool]($hasConfig -or $hasOptions)
    return $opt
}

# Drive letters that will be erased by the reinstall: the Windows drive always, plus the
# wipedDrives Option. Letters come back upper-case and without a colon, each once. $SystemDrive
# names the Windows drive (the Ready check passes the system probe's).
function Get-WipedDrives($Options, [string[]]$SystemDrive = @($env:SystemDrive)) {
    $letters = @($SystemDrive) + @($Options['wipedDrives']) |
        Where-Object { $_ } | ForEach-Object { ([string]$_).Trim().TrimEnd('\', '/', ':').ToUpper() } | Where-Object { $_ -match '^[A-Z]$' }
    $seen = @{}
    return @($letters | Where-Object { -not $seen.ContainsKey($_) -and ($seen[$_] = $true) })
}

# A setting that must be set before a script can run.
function Assert-ConfigValue($Config, [string]$Name, [string]$Why) {
    if (-not $Config[$Name]) {
        throw "Set ""$Name"" in $($Config['_file']) ($Why). config.example.json in the tool folder lists every option."
    }
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}
# PS 5.1 returns a top-level JSON array as one object; this always yields the elements.
function Read-JsonList([string]$Path) { $p = Read-JsonFile $Path; if ($null -eq $p) { return @() }; return @($p | ForEach-Object { $_ }) }

# Folders never searched for repos: build output and package caches.
$RepoSkipDirs = @('node_modules', '.git', 'bin', 'obj', '.venv', 'venv', 'target', 'dist', 'build', '.next', '.turbo', '.cache')

# The repos at or below $Dir, at most $Depth folders down; a repo's own subfolders aren't searched.
function Find-Repos([string]$Dir, [int]$Depth) {
    if (Test-Path -LiteralPath (Join-Path $Dir '.git')) { return $Dir }
    if ($Depth -le 0) { return }
    Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $RepoSkipDirs } |
        ForEach-Object { Find-Repos $_.FullName ($Depth - 1) }
}

# What a repo holds that its remotes don't: uncommitted changes, unpushed commits and stashes.
# Changes under $IgnorePath (a folder inside the repo) aren't counted. Readable is false when git
# couldn't read it (a repo it doesn't trust, say), and the counts are then 0.
function Get-RepoState([string]$Repo, [string]$IgnorePath) {
    # Windows PowerShell 5.1 makes a native command's stderr an error under ErrorAction Stop.
    $ErrorActionPreference = 'Continue'
    $remotes = @(git -C $Repo remote 2>$null)
    $url     = if ($remotes.Count) { [string](git -C $Repo remote get-url $remotes[0] 2>$null) } else { '' }
    $branch  = [string](git -C $Repo branch --show-current 2>$null)
    $status  = @(git -C $Repo status --porcelain 2>$null)
    $readable = $LASTEXITCODE -eq 0
    if ($IgnorePath -and $IgnorePath.StartsWith($Repo.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $ignoreRel = $IgnorePath.Substring($Repo.TrimEnd('\').Length + 1).Replace('\', '/').TrimEnd('/') + '/'
        $status = @($status | Where-Object { -not ($_.Substring(3).Trim('"')).StartsWith($ignoreRel, [StringComparison]::OrdinalIgnoreCase) })
    }
    # A branch whose remote/pushRemote is a URL (e.g. a fork) has no remote-tracking ref, so
    # --remotes can't see it. Ask the URL for the branch tip and count it as pushed if we have that
    # commit.
    $pushedTips = @()
    foreach ($b in @(git -C $Repo for-each-ref --format='%(refname:short)' refs/heads 2>$null)) {
        $bRemote = git -C $Repo config --get "branch.$b.pushremote" 2>$null
        if (-not $bRemote) { $bRemote = git -C $Repo config --get "branch.$b.remote" 2>$null }
        if ($bRemote -notmatch '://|^git@') { continue }
        $refs = @("refs/heads/$b")
        $bMerge = git -C $Repo config --get "branch.$b.merge" 2>$null
        if ($bMerge -and $bMerge -ne $refs[0]) { $refs += $bMerge }
        foreach ($line in @(git -C $Repo ls-remote $bRemote @refs 2>$null)) {
            $sha = ($line -split '\s+')[0]
            git -C $Repo cat-file -e "$sha^{commit}" 2>$null
            if ($LASTEXITCODE -eq 0) { $pushedTips += $sha }
        }
    }
    # After --not, plain SHAs are excluded too.
    $unpushed = @(git -C $Repo log --branches --not --remotes @pushedTips --oneline 2>$null).Count
    $stashes  = @(git -C $Repo stash list 2>$null).Count
    if (-not $readable) { $status = @(); $unpushed = 0; $stashes = 0 }
    [pscustomobject]@{
        Readable = $readable; Remotes = $remotes; Url = $url; Branch = $branch
        Uncommitted = $status.Count; Unpushed = $unpushed; Stashes = $stashes
    }
}
