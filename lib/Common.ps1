# lib\Common.ps1: helpers shared by the scripts in the tool root.
#
#     $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
#     . (Join-Path $scriptDir 'lib\Common.ps1')
#     $DataDir = Resolve-DataDir $DataDir
#     $Config  = Get-MigrationConfig $DataDir
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

# Defaults for everything config.json can set. See config.example.json for what each one means.
function Get-ConfigDefaults {
    [ordered]@{
        devRoot           = 'C:\dev'
        repoDepth         = 3
        useOnlyRepos      = @()
        migrationRoot     = ''
        keepDrives        = @()
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

# data\config.json merged over the defaults (one level deep for the nested sections).
function Get-MigrationConfig([string]$DataDir) {
    $cfg = Get-ConfigDefaults
    $file = Join-Path $DataDir 'config.json'
    if (Test-Path -LiteralPath $file) {
        $user = ConvertTo-PlainHashtable (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)
        foreach ($k in @($user.Keys)) {
            if ($k.StartsWith('$') -or $k.StartsWith('_')) { continue }   # $schema, _comment
            if ($cfg[$k] -is [System.Collections.IDictionary] -and $user[$k] -is [System.Collections.IDictionary]) {
                foreach ($k2 in @($user[$k].Keys)) { $cfg[$k][$k2] = $user[$k][$k2] }
            } else {
                $cfg[$k] = $user[$k]
            }
        }
    }
    $cfg['_file']   = $file
    $cfg['_exists'] = Test-Path -LiteralPath $file
    return $cfg
}

# A setting that must be set before a script can run.
function Assert-ConfigValue($Config, [string]$Name, [string]$Why) {
    if (-not $Config[$Name]) {
        throw "Set ""$Name"" in $($Config['_file']) ($Why). Copy config.example.json from the tool folder to start."
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
