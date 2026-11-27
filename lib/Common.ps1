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
        keepDrives        = @()
        wipedDrives       = @()
        excludedTypeRoots = @('%USERPROFILE%\Downloads')
        maxFileMB         = 1024
        portableRoots     = @('%USERPROFILE%\OneDrive\Documents', '%USERPROFILE%\Documents', '%USERPROFILE%\Desktop', '%USERPROFILE%\Downloads',
                              '%USERPROFILE%\Portable', '%USERPROFILE%\Apps', '%USERPROFILE%\Tools')
        appData           = [ordered]@{ include = @(); exclude = @(); custom = @() }
        backup            = [ordered]@{ provider = 'auto'; maxRemainingMB = 1024 }
        recoveryFiles     = @('*recovery*', '*backup*code*', '*2fa*')
        confirm           = @()
        linux             = [ordered]@{ devRoot = '~/dev'; prefer = @('vendor', 'distro', 'portable', 'flatpak'); aur = 'auto'; flatpak = $true; nodeMajor = 24 }
    }
}

# Where Hopover keeps its Options on this PC: %LOCALAPPDATA%\Hopover\options.json.
function Get-OptionsPath {
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
# wipedDrives Option. Letters come back upper-case and without a colon, each once.
function Get-WipedDrives($Options) {
    $letters = @($env:SystemDrive) + @($Options['wipedDrives']) |
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

# Git state of a folder: $null if it isn't a repo, else dirty/unpushed counts and whether it has a remote.
function Get-GitState([string]$Dir) {
    if (-not (Test-Path -LiteralPath (Join-Path $Dir '.git'))) { return $null }
    $dirty    = @(git -C $Dir status --porcelain 2>$null).Count
    $hasUp    = [bool](git -C $Dir rev-parse --abbrev-ref '@{u}' 2>$null)
    $unpushed = if ($hasUp) { @(git -C $Dir log '@{u}..' --oneline 2>$null).Count } else { @(git -C $Dir log --branches --not --remotes --oneline 2>$null).Count }
    $remote   = [bool](@(git -C $Dir remote 2>$null).Count)
    [pscustomobject]@{ Dirty = $dirty; Unpushed = $unpushed; HasUpstream = $hasUp; HasRemote = $remote }
}
