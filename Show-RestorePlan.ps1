<#
    Show-RestorePlan.ps1
    Opens a page in your browser for looking through what was exported and
    choosing what Restore.ps1 puts back. Your choices are saved to
    restore-plan.json in the data folder; commit it so the new PC uses them.

        powershell -ExecutionPolicy Bypass -File .\Show-RestorePlan.ps1
        powershell -ExecutionPolicy Bypass -File .\Show-RestorePlan.ps1 -Port 8800 -NoBrowser

    The page is served on http://localhost only, and every request has to carry
    a token that changes each run, so other sites in the browser can't use it.
    Stop it with the Quit button on the page or Ctrl+C here.

    Works in Windows PowerShell 5.1 (a fresh install) and PowerShell 7.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 8765,
    # Data folder (default: $env:HOPOVER_DATA, else .\data).
    [string]$DataDir,
    # Defaults: migrationRoot and devRoot from the Options.
    [string]$MigrationRoot,
    [string]$DevRoot,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$scriptDir = $scriptDir.TrimEnd('\')
. (Join-Path $scriptDir 'lib\Common.ps1')
$DataDir  = Resolve-DataDir $DataDir
$Config   = Get-Options $DataDir
if (-not $MigrationRoot) { $MigrationRoot = Expand-ConfigPath $Config.migrationRoot }
if (-not $MigrationRoot) { $MigrationRoot = '(migrationRoot not set in the Options)' }
if (-not $DevRoot) { $DevRoot = Expand-ConfigPath $Config.devRoot }
$S        = Join-Path $DataDir 'settings'
$Extras   = Join-Path $MigrationRoot 'extras'
$PlanPath = Join-Path $DataDir 'restore-plan.json'
$PagePath = Join-Path $scriptDir 'ui\index.html'
$Tar      = Join-Path $env:windir 'System32\tar.exe'
$Token    = [guid]::NewGuid().ToString('N')
$UserHome = $env:USERPROFILE
$IsAdmin  = Test-IsAdmin

# File views are relative to the data folder, or to the tool folder with a "tool:" prefix.
function Resolve-ViewPath([string]$Path) {
    if ($Path.StartsWith('tool:')) { return @{ Root = $scriptDir; Rel = $Path.Substring(5) } }
    return @{ Root = $DataDir; Rel = $Path }
}

if (-not (Test-Path -LiteralPath $PagePath)) { throw "Missing $PagePath." }

# ---------------------------------------------------------------------------
# Catalog: everything Restore.ps1 would put back, grouped the way the plan
# file skips it. Group ids and keys must match Test-Planned calls in Restore.ps1.
# ---------------------------------------------------------------------------
function Test-Tool([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function New-PlanItem([string]$Key, [string]$Label, [string]$Detail = '', [string]$Status = '', [string]$View = '', [string]$ViewKind = '') {
    [ordered]@{ key = $Key; label = $Label; detail = $Detail; status = $Status; view = $View; viewKind = $ViewKind }
}
function New-Group([string]$Id, [string]$Title, $Items, [string]$Note = '') {
    [ordered]@{ id = $Id; title = $Title; note = $Note; items = @($Items | Where-Object { $_ }) }
}
function New-View([string]$Title, [string]$Path) {
    $v = Resolve-ViewPath $Path
    if (-not (Test-Path -LiteralPath (Join-Path $v.Root $v.Rel) -PathType Leaf)) { return $null }
    [ordered]@{ title = $Title; path = $Path.Replace('\', '/') }
}
# -Whole marks a step that is only ever on or off (no item list by design).
function New-StepInfo($Groups = @(), $Views = @(), [string]$Note = '', [switch]$Whole) {
    [ordered]@{ note = $Note; whole = [bool]$Whole; views = @($Views | Where-Object { $_ }); groups = @($Groups | Where-Object { $_ -and $_.items.Count }) }
}
function Format-Home([string]$Path) { if ($Path.StartsWith($UserHome, [StringComparison]::OrdinalIgnoreCase)) { '~' + $Path.Substring($UserHome.Length) } else { $Path } }

function Get-FileStatus([string]$Src, [string]$Dst) {
    if (-not (Test-Path -LiteralPath $Dst -PathType Leaf)) { return 'new' }
    if ((Get-FileHash -LiteralPath $Src).Hash -eq (Get-FileHash -LiteralPath $Dst).Hash) { return 'same' }
    return 'differs'
}

# One config file. The key is its path under settings\ with forward slashes.
function Get-FileItem([string]$Src, [string]$Dst) {
    $rel = $Src.Substring($S.Length + 1).Replace('\', '/')
    $detail = '-> ' + (Format-Home $Dst)
    try { if ((Get-Content -LiteralPath $Src -Raw -ErrorAction Stop) -match '<redacted') { $detail += '  (has <redacted> values to fill in)' } } catch { }
    New-PlanItem -Key $rel -Label $rel -Detail $detail -Status (Get-FileStatus $Src $Dst) -View "settings/$rel" -ViewKind 'file'
}
# Named files in a settings folder, or (no names) every file under it.
function Get-FileItems([string]$SrcRel, [string]$DstDir, [string[]]$Names) {
    $src = Join-Path $S $SrcRel
    if ($Names) {
        foreach ($n in $Names) { $f = Join-Path $src $n; if (Test-Path -LiteralPath $f -PathType Leaf) { Get-FileItem $f (Join-Path $DstDir $n) } }
    } elseif (Test-Path -LiteralPath $src -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File)) { Get-FileItem $f.FullName (Join-Path $DstDir $f.FullName.Substring($src.TrimEnd('\').Length + 1)) }
    }
}

function Get-ExtrasManifest { Read-JsonFile (Join-Path $Extras 'manifest.json') }
function Get-ExtrasItems([scriptblock]$Filter) {
    $m = Get-ExtrasManifest
    if ($null -eq $m) { return @() }
    foreach ($i in @($m.Items | ForEach-Object { $_ } | Where-Object $Filter)) {
        if (-not $i.File -or $i.Status -notin 'ok', 'PARTIAL') { continue }
        $to = if ($i.RestoreTo) { Format-Home ([Environment]::ExpandEnvironmentVariables($i.RestoreTo)) } else { '' }
        $detail = "$($i.Files) file(s), $($i.SizeMB) MB$(if ($to) { " -> $to" })$(if ($i.Admin) { ' (elevated pass)' })$(if ($i.Note) { "; $($i.Note)" })"
        $status = if ($i.Status -eq 'PARTIAL') { 'differs' } else { '' }
        New-PlanItem -Key $i.Name -Label $i.Name -Detail $detail -Status $status -View $i.Name -ViewKind 'archive'
    }
}
function Get-ExtrasNote {
    $drive = if ($MigrationRoot -match '^([A-Za-z]:)') { $Matches[1] } else { '' }
    if (-not $drive) { return "Set migrationRoot in $($Config['_file']) to list the archived items." }
    if (-not (Test-Path -LiteralPath "$drive\")) { return "$drive isn't connected, so the archived items can't be listed." }
    if (-not (Test-Path -LiteralPath $MigrationRoot)) { return "Nothing archived in $Extras yet (run Backup-Extras.ps1 on the old PC)." }
    if ($null -eq (Get-ExtrasManifest)) { return "Nothing archived in $Extras yet (run Backup-Extras.ps1 on the old PC)." }
    return ''
}

$script:FeatureCache = $null
function Get-EnabledFeatures {
    if ($null -eq $script:FeatureCache) {
        $script:FeatureCache = @(Get-CimInstance Win32_OptionalFeature -ErrorAction SilentlyContinue | Where-Object { $_.InstallState -eq 1 } | ForEach-Object Name)
    }
    return $script:FeatureCache
}

function Get-EnvGroups([string]$Scope) {
    $lower = $Scope.ToLower()
    $data = Read-JsonFile (Join-Path $S "windows\env-$lower.json")
    $vars = foreach ($p in @($data.Variables.PSObject.Properties)) {
        $cur = [Environment]::GetEnvironmentVariable($p.Name, $Scope)
        $st = if ($null -eq $cur) { 'new' } elseif ($cur -eq $p.Value) { 'same' } else { 'differs' }
        New-PlanItem -Key $p.Name -Label $p.Name -Detail ([string]$p.Value) -Status $st
    }
    $current = @(([Environment]::GetEnvironmentVariable('Path', $Scope)) -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() })
    $paths = foreach ($e in @(Get-Content -LiteralPath (Join-Path $S "windows\path-$lower.txt") -ErrorAction SilentlyContinue | Where-Object { $_ })) {
        $st = if ($current -contains $e.TrimEnd('\').ToLower()) { 'same' } else { 'new' }
        New-PlanItem -Key $e -Label $e -Detail '' -Status $st
    }
    $secrets = @(@($data.SecretNames) | Where-Object { $_ })
    $note = if ($secrets.Count) { "Not exported (set these by hand from your password manager): $($secrets -join ', ')." } else { '' }
    New-StepInfo -Groups @(
        (New-Group "env-$lower" 'Variables' $vars)
        (New-Group "path-$lower" 'PATH entries (added to the end of the new PC''s PATH)' $paths)
    ) -Views @((New-View "$Scope environment" "settings\windows\env-$lower.md")) -Note $note
}

$Builders = @{
    'drivers' = {
        $dir = Join-Path $MigrationRoot 'drivers'
        $n = @(Get-ChildItem -LiteralPath $dir -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count
        $note = if ($n) { "$n driver file(s) in $dir; all of them are installed." } else { "No drivers exported to $dir yet (run Save-Drivers.ps1 elevated on the old PC)." }
        New-StepInfo -Whole -Views @((New-View 'Drivers' 'settings\windows\drivers.md'), (New-View 'Hardware' 'settings\windows\hardware.md')) -Note $note
    }
    'drive-letters' = {
        $items = foreach ($d in (Read-JsonList (Join-Path $S 'windows\drives.json'))) {
            if (-not $d.Label -or $d.Letter -eq 'C') { continue }
            $vol = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq $d.Label })
            $st = if ($vol.Count -ne 1) { 'waiting' } elseif ([string]$vol[0].DriveLetter -eq $d.Letter) { 'same' } else { 'differs' }
            $detail = "$($d.SizeGB) GB, $($d.Model)" + $(if ($vol.Count -eq 0) { '; no volume with this label here' } elseif ($vol.Count -gt 1) { '; several volumes have this label' } elseif ($st -eq 'differs') { "; now $([string]$vol[0].DriveLetter):" } else { '' })
            New-PlanItem -Key $d.Label -Label "$($d.Letter): $($d.Label)" -Detail $detail -Status $st
        }
        New-StepInfo -Groups @((New-Group 'drive-letters' 'Drives (matched by volume label)' $items)) -Views @((New-View 'Drive layout' 'settings\windows\drives.md'))
    }
    'prefs' = {
        $data = Read-JsonFile (Join-Path $S 'windows\preferences.json')
        if ($null -eq $data) { return (New-StepInfo -Note 'No preferences.json exported.') }
        $reg = foreach ($r in @($data.Registry)) {
            $val = if ($r.Kind -eq 'Binary') { "binary, $(@($r.Value).Count) bytes" } else { @($r.Value) -join ',' }
            $key = Get-Item -LiteralPath $r.Path -ErrorAction SilentlyContinue
            $st = 'new'
            if ($key -and $key.GetValueNames() -contains $r.Name) {
                $cur = $key.GetValue($r.Name, $null, 'DoNotExpandEnvironmentNames')
                $st = if ((@($cur) -join ',') -eq (@($r.Value) -join ',')) { 'same' } else { 'differs' }
            }
            New-PlanItem -Key "$($r.Path)|$($r.Name)" -Label $r.Label -Detail "$val  ($($r.Scope.ToLower())$(if ($r.Scope -eq 'Machine') { ', elevated pass' }))" -Status $st
        }
        $other = @()
        $tz = (Get-TimeZone).Id
        $other += New-PlanItem -Key 'TimeZone' -Label 'Time zone' -Detail $data.TimeZone -Status $(if ($tz -eq $data.TimeZone) { 'same' } else { 'differs' })
        if ($data.PowerPlan) {
            $active = (powercfg /getactivescheme 2>$null) -join ' '
            $other += New-PlanItem -Key 'PowerPlan' -Label 'Power plan' -Detail $data.PowerPlan.Name -Status $(if ($active -match [regex]::Escape("($($data.PowerPlan.Name))")) { 'same' } else { 'differs' })
        }
        if ($data.ClassicContextMenu) {
            $on = Test-Path -LiteralPath 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
            $other += New-PlanItem -Key 'ClassicContextMenu' -Label 'Classic right-click menu' -Detail 'on' -Status $(if ($on) { 'same' } else { 'new' })
        }
        $enabled = Get-EnabledFeatures
        $feat = foreach ($f in @($data.OptionalFeatures)) { New-PlanItem -Key $f -Label $f -Detail 'elevated pass' -Status $(if ($enabled -contains $f) { 'same' } else { 'new' }) }
        New-StepInfo -Groups @(
            (New-Group 'prefs' 'Registry settings' $reg)
            (New-Group 'prefs' 'Time zone, power plan, context menu' $other)
            (New-Group 'features' 'Optional Windows features' $feat)
        ) -Views @((New-View 'Preferences' 'settings\windows\preferences.md')) -Note "Exported $($data.Exported) from $($data.ComputerName). The computer name isn't applied."
    }
    'winget' = {
        $w = Read-JsonFile (Join-Path $DataDir 'winget-packages.json')
        # winget export lists apps in no useful order; sort them by id.
        $items = foreach ($src in @($w.Sources)) {
            foreach ($p in @($src.Packages | Sort-Object PackageIdentifier)) { New-PlanItem -Key $p.PackageIdentifier -Label $p.PackageIdentifier -Detail $src.SourceDetails.Name }
        }
        $items = @($items | Sort-Object { $_.label })
        New-StepInfo -Groups @((New-Group 'winget' 'Apps' $items)) -Views @((New-View 'Installed apps catalog' 'Installed-Apps-Catalog.md')) `
            -Note 'Apps winget can''t install are listed under "Not Available via winget" in the catalog.'
    }
    'choco' = {
        $cfg = Join-Path $S 'dev\choco-packages.config'
        if (-not (Test-Path -LiteralPath $cfg)) { return (New-StepInfo -Note 'No Chocolatey export.') }
        $ids = @(([xml](Get-Content -LiteralPath $cfg -Raw)).packages.package | ForEach-Object id |
            Where-Object { $_ -notmatch '^(KB\d+|chocolatey|chocolatey-.*\.extension|.+\.install)$' })
        $have = if (Test-Tool choco) { @(choco list --limit-output 2>$null | ForEach-Object { ($_ -split '\|')[0] }) } else { $null }
        $items = foreach ($id in $ids) { New-PlanItem -Key $id -Label $id -Status $(if ($null -eq $have) { '' } elseif ($have -contains $id) { 'same' } else { 'new' }) }
        New-StepInfo -Groups @((New-Group 'choco' 'Packages' $items)) -Views @((New-View 'Package lists' 'settings\dev\packages.md')) `
            -Note 'Windows hotfixes and Chocolatey''s own extensions are left out; dependencies come back on their own.'
    }
    'env-machine' = { Get-EnvGroups 'Machine' }
    'env-user'    = { Get-EnvGroups 'User' }
    'hosts' = {
        $hostsFile = Join-Path $env:windir 'System32\drivers\etc\hosts'
        $current = @(Get-Content -LiteralPath $hostsFile -ErrorAction SilentlyContinue | ForEach-Object { ($_ -replace '\s+', ' ').Trim() })
        $items = foreach ($l in @(Get-Content -LiteralPath (Join-Path $S 'windows\hosts') -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^\s*(#|$)' })) {
            $k = ($l -replace '\s+', ' ').Trim()
            New-PlanItem -Key $k -Label $k -Status $(if ($current -contains $k) { 'same' } else { 'new' })
        }
        New-StepInfo -Groups @((New-Group 'hosts' 'Lines added to the hosts file' $items)) -Views @((New-View 'Exported hosts file' 'settings\windows\hosts'))
    }
    'git-config' = {
        # Saved without the leading dot; restored as ~\.gitconfig and ~\.gitignore_global.
        $files = foreach ($n in 'gitconfig', 'gitignore_global') {
            $f = Join-Path $S "dev\$n"
            if (Test-Path -LiteralPath $f -PathType Leaf) { Get-FileItem $f (Join-Path $UserHome ".$n") }
        }
        New-StepInfo -Groups @((New-Group 'files' 'Config files' $files)) -Note '.npmrc isn''t copied (its token was withheld); run "npm login" instead.'
    }
    'repos' = {
        $items = foreach ($r in (Read-JsonList (Join-Path $S 'dev\repos.json'))) {
            $target = Join-Path $DevRoot $r.Path
            $st = if (-not $r.Url) { 'waiting' } elseif (Test-Path -LiteralPath (Join-Path $target '.git')) { 'same' } else { 'new' }
            $detail = if ($r.Url) { "$($r.Url)$(if ($r.Branch) { " ($($r.Branch))" })" } else { 'no remote; not cloned' }
            if (@($r.LocalFiles).Count) { $detail += "; local files from extras: $(@($r.LocalFiles) -join ', ')" }
            New-PlanItem -Key $r.Path -Label $r.Path -Detail $detail -Status $st
        }
        New-StepInfo -Groups @((New-Group 'repos' "Repos cloned into $DevRoot" $items)) -Views @((New-View 'Repo report' 'settings\dev\repos.md'))
    }
    'dev-extras' = {
        $items = Get-ExtrasItems { $_.Name -like 'dev-*' }
        New-StepInfo -Groups @((New-Group 'extras' 'Archives' $items)) -Note (Get-ExtrasNote)
    }
    'dev-packages' = {
        $p = Read-JsonFile (Join-Path $S 'dev\packages.json')
        if ($null -eq $p) { return (New-StepInfo -Note 'No packages.json exported.') }
        $groups = foreach ($pair in @(@('npm', 'Npm', 'npm global packages'), @('dotnet', 'Dotnet', '.NET global tools'), @('go', 'Go', 'Go tools'),
                                     @('cargo', 'Cargo', 'Cargo crates'), @('uv', 'Uv', 'uv tools'), @('psmodules', 'PowerShell', 'PowerShell modules'))) {
            $items = foreach ($n in @($p.($pair[1]) | Where-Object { $_ })) { New-PlanItem -Key $n -Label $n }
            New-Group $pair[0] $pair[2] $items
        }
        New-StepInfo -Groups $groups -Views @((New-View 'Package lists' 'settings\dev\packages.md'))
    }
    'vscode' = {
        $user = Join-Path $env:APPDATA 'Code\User'
        $files = @(Get-FileItems 'vscode' $user @('settings.json', 'keybindings.json', 'mcp.json', 'tasks.json')) +
                 @(Get-FileItems 'vscode\snippets' (Join-Path $user 'snippets')) + @(Get-FileItems 'vscode\prompts' (Join-Path $user 'prompts'))
        $have = $null
        if (Test-Tool code) { $have = @(code --list-extensions 2>$null) }
        $ext = foreach ($e in @(Get-Content -LiteralPath (Join-Path $S 'vscode\extensions.txt') -ErrorAction SilentlyContinue | Where-Object { $_ })) {
            New-PlanItem -Key $e -Label $e -Status $(if ($null -eq $have) { '' } elseif ($have -contains $e) { 'same' } else { 'new' })
        }
        New-StepInfo -Groups @((New-Group 'files' 'Config files' $files), (New-Group 'vscode-extensions' 'Extensions' $ext)) -Views @((New-View 'Extensions' 'settings\vscode\extensions.md'))
    }
    'terminal' = {
        $dst = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
        New-StepInfo -Groups @((New-Group 'files' 'Config files' (Get-FileItems 'terminal' $dst @('settings.json'))))
    }
    'claude' = {
        $c = Join-Path $UserHome '.claude'
        $files = @(Get-FileItems 'claude' $c @('CLAUDE.md', 'settings.json', 'keybindings.json'))
        foreach ($d in 'hooks', 'themes', 'agents', 'commands') { $files += @(Get-FileItems "claude\$d" (Join-Path $c $d)) }
        $files += @(Get-FileItems 'claude' (Join-Path $env:APPDATA 'Claude') @('claude_desktop_config.json'))
        $mem = foreach ($proj in @(Get-ChildItem -LiteralPath (Join-Path $S 'claude\memory') -Directory -ErrorAction SilentlyContinue)) {
            Get-FileItems "claude\memory\$($proj.Name)" (Join-Path $c "projects\$($proj.Name)\memory")
        }
        $mcp = Read-JsonFile (Join-Path $S 'claude\mcp-servers.json')
        $servers = @(); $manual = @()
        foreach ($prop in @($mcp.user.PSObject.Properties)) {
            $cfg = $prop.Value
            if (-not $cfg.url -or $cfg.headers -or $cfg.env) { $manual += $prop.Name; continue }
            $servers += New-PlanItem -Key $prop.Name -Label $prop.Name -Detail "$($cfg.type) $($cfg.url)"
        }
        $note = 'Skills, plugins and sign-in are done by hand (see the list Restore.ps1 prints).'
        if ($manual.Count) { $note += " MCP servers with secrets to add by hand: $($manual -join ', ')." }
        New-StepInfo -Groups @((New-Group 'files' 'Config files' $files), (New-Group 'files' 'Memory' $mem), (New-Group 'mcp' 'User MCP servers' $servers)) `
            -Views @((New-View 'Skills' 'settings\claude\skills.md'), (New-View 'Plugins' 'settings\claude\plugins\installed_plugins.json'), (New-View 'All MCP servers' 'settings\claude\mcp-servers.json')) -Note $note
    }
    'codex' = {
        $c = Join-Path $UserHome '.codex'
        $names = @(Get-ChildItem -LiteralPath (Join-Path $S 'codex') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'skills.md' } | ForEach-Object Name)
        $files = @(Get-FileItems 'codex' $c $names) + @(Get-FileItems 'codex\rules' (Join-Path $c 'rules'))
        New-StepInfo -Groups @((New-Group 'files' 'Config files' $files)) -Views @((New-View 'Skills' 'settings\codex\skills.md'))
    }
    'app-data' = {
        $items = Get-ExtrasItems { $_.Name -like 'app-*' -or $_.Name -like 'excluded-types-*' }
        New-StepInfo -Groups @((New-Group 'extras' 'Archives' $items)) -Note (Get-ExtrasNote)
    }
    'docker-volumes' = {
        $dir = Join-Path $Extras 'docker-volumes'
        $items = foreach ($t in @(Get-ChildItem -LiteralPath $dir -Filter *.tgz -File -ErrorAction SilentlyContinue)) {
            New-PlanItem -Key $t.BaseName -Label $t.BaseName -Detail ('{0:N1} MB' -f ($t.Length / 1MB))
        }
        $note = if (@($items).Count) { 'Needs Docker Desktop running on the new PC.' } else { (Get-ExtrasNote) + ' No volume archives found.' }
        New-StepInfo -Groups @((New-Group 'docker-volumes' 'Volumes' $items)) -Views @((New-View 'WSL and Docker' 'settings\dev\wsl-docker.md')) -Note $note.Trim()
    }
}

function Get-Catalog {
    $script:FeatureCache = $null
    $stepList = (& (Join-Path $scriptDir 'Restore.ps1') -List -AsJson -DataDir $DataDir) | ConvertFrom-Json
    $steps = foreach ($st in @($stepList | ForEach-Object { $_ })) {
        $info = $null
        try {
            $b = $Builders[$st.name]
            $info = if ($b) { & $b } else { New-StepInfo -Note 'This step has no item list.' }
        } catch {
            $info = New-StepInfo -Note "Couldn't list this step: $($_.Exception.Message)"
        }
        [ordered]@{ name = $st.name; admin = $st.admin; text = $st.text; note = $info.note; whole = $info.whole; views = $info.views; groups = $info.groups }
    }

    $reports = @(
        (New-View 'README' 'tool:README.md'), (New-View 'Checklist' 'tool:CHECKLIST.md'), (New-View 'Your notes' 'NOTES.md'),
        (New-View 'Installed apps catalog' 'Installed-Apps-Catalog.md'), (New-View 'Settings export' 'settings\README.md')
    )
    foreach ($f in @(Get-ChildItem -LiteralPath $S -Recurse -File -Filter *.md -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike "$S\claude\memory\*" -and $_.FullName -ne "$S\README.md" } | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($DataDir.Length + 1)
        $reports += New-View ($rel.Substring(9).Replace('\', '/') -replace '\.md$', '') $rel
    }

    $prefs = Read-JsonFile (Join-Path $S 'windows\preferences.json')
    $man = Get-ExtrasManifest
    [ordered]@{
        meta = [ordered]@{
            computer       = $env:COMPUTERNAME
            exportedFrom   = $prefs.ComputerName
            exported       = $prefs.Exported
            isAdmin        = $IsAdmin
            shell          = "PowerShell $($PSVersionTable.PSVersion)"
            repo           = $DataDir
            migrationRoot  = $MigrationRoot
            migrationUp    = [bool]($MigrationRoot -match '^[A-Za-z]:' -and (Test-Path -LiteralPath ($MigrationRoot.Substring(0, 2) + '\')))
            extrasUpdated  = $(if ($man) { $man.Updated } else { $null })
            extrasCount    = $(if ($man) { @($man.Items).Count } else { 0 })
            planFile       = 'restore-plan.json'
        }
        planText = $(if (Test-Path -LiteralPath $PlanPath) { [IO.File]::ReadAllText($PlanPath) } else { $null })
        steps    = @($steps)
        reports  = @($reports | Where-Object { $_ })
    }
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
function Send-Text($Ctx, [int]$Code, [string]$Type, [string]$Body) {
    $bytes = $Utf8.GetBytes($Body)
    $res = $Ctx.Response
    $res.StatusCode = $Code
    $res.ContentType = $Type
    $res.AddHeader('Cache-Control', 'no-store')
    $res.AddHeader('X-Content-Type-Options', 'nosniff')
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}
function Send-Json($Ctx, $Obj, [int]$Code = 200) { Send-Text $Ctx $Code 'application/json; charset=utf-8' (ConvertTo-Json -InputObject $Obj -Depth 12 -Compress) }

function Read-Body($Ctx) {
    $reader = New-Object System.IO.StreamReader($Ctx.Request.InputStream, $Utf8)
    try { return $reader.ReadToEnd() } finally { $reader.Close() }
}

$script:Catalog = $null
$script:Running = $true

function Invoke-Request($Ctx) {
    $req = $Ctx.Request
    $path = $req.Url.AbsolutePath

    if ($path -eq '/' -and $req.HttpMethod -eq 'GET') {
        $html = [IO.File]::ReadAllText($PagePath).Replace('__TOKEN__', $Token)
        $Ctx.Response.AddHeader('Content-Security-Policy', "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; base-uri 'none'; form-action 'none'")
        Send-Text $Ctx 200 'text/html; charset=utf-8' $html
        return
    }
    if (-not $path.StartsWith('/api/')) { Send-Text $Ctx 404 'text/plain' 'Not found'; return }
    if ($req.Headers['X-Token'] -ne $Token) { Send-Text $Ctx 403 'text/plain' 'Forbidden'; return }

    switch ($path) {
        '/api/data' {
            if ($null -eq $script:Catalog -or $req.QueryString['refresh']) { $script:Catalog = Get-Catalog }
            Send-Json $Ctx $script:Catalog
        }
        '/api/file' {
            $rel = [string]$req.QueryString['path']
            $full = ''; $root = ''
            if ($rel) {
                $v = Resolve-ViewPath $rel
                $root = $v.Root.TrimEnd('\')
                try { $full = [IO.Path]::GetFullPath((Join-Path $root $v.Rel)) } catch { }
            }
            # Only files inside the data folder (or the tool folder for tool:), never anything under .git.
            $ok = $rel -and $full -and $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -and $full -notmatch '\\\.git(\\|$)' -and (Test-Path -LiteralPath $full -PathType Leaf)
            if (-not $ok) { Send-Text $Ctx 404 'text/plain' 'Not found'; return }
            if ((Get-Item -LiteralPath $full).Length -gt 4MB) { Send-Text $Ctx 413 'text/plain' 'File too large to show'; return }
            Send-Text $Ctx 200 'text/plain; charset=utf-8' ([IO.File]::ReadAllText($full))
        }
        '/api/archive' {
            $name = [string]$req.QueryString['name']
            $m = Get-ExtrasManifest
            $item = @($m.Items | ForEach-Object { $_ } | Where-Object { $_.Name -eq $name -and $_.File }) | Select-Object -First 1
            if (-not $item) { Send-Text $Ctx 404 'text/plain' 'Not in the extras manifest'; return }
            $zip = Join-Path $Extras $item.File
            if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { Send-Text $Ctx 404 'text/plain' "Archive missing: $zip"; return }
            $lines = @(& $Tar -tf $zip 2>$null | Select-Object -First 5001)
            $text = ($lines | Select-Object -First 5000) -join "`n"
            if ($lines.Count -gt 5000) { $text += "`n... (first 5000 entries shown)" }
            Send-Text $Ctx 200 'text/plain; charset=utf-8' "$zip`n$($item.Files) file(s), $($item.SizeMB) MB, archived $($item.Created)`n`n$text"
        }
        '/api/plan' {
            if ($req.HttpMethod -ne 'POST') { Send-Text $Ctx 405 'text/plain' 'POST only'; return }
            $body = Read-Body $Ctx
            try { $p = $body | ConvertFrom-Json } catch { Send-Json $Ctx @{ error = 'Not valid JSON' } 400; return }
            $names = @($p.PSObject.Properties.Name)
            if ($names -notcontains 'SkipSteps' -or $names -notcontains 'Skip') { Send-Json $Ctx @{ error = 'Plan needs SkipSteps and Skip' } 400; return }
            [IO.File]::WriteAllText($PlanPath, $body.TrimEnd() + "`n", $Utf8)
            # Read it back: a write that "succeeded" but can't be parsed is worse than an error.
            $null = [IO.File]::ReadAllText($PlanPath) | ConvertFrom-Json
            $script:Catalog = $null
            Write-Host "Saved $PlanPath" -ForegroundColor Green
            Send-Json $Ctx @{ ok = $true; path = $PlanPath }
        }
        '/api/dryrun' {
            if ($req.HttpMethod -ne 'POST') { Send-Text $Ctx 405 'text/plain' 'POST only'; return }
            $exe = (Get-Process -Id $PID).Path
            Write-Host 'Running Restore.ps1 -DryRun...' -ForegroundColor Cyan
            $out = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'Restore.ps1') -DryRun -DataDir $DataDir -MigrationRoot $MigrationRoot -DevRoot $DevRoot 2>&1 | Out-String
            Send-Text $Ctx 200 'text/plain; charset=utf-8' ($out -replace "\x1b\[[0-9;?]*[A-Za-z]", '')
        }
        '/api/quit' {
            if ($req.HttpMethod -ne 'POST') { Send-Text $Ctx 405 'text/plain' 'POST only'; return }
            Send-Json $Ctx @{ ok = $true }
            $script:Running = $false
        }
        default { Send-Text $Ctx 404 'text/plain' 'Not found' }
    }
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
$listener = $null
foreach ($p in $Port..($Port + 10)) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://localhost:$p/")
    try { $l.Start(); $listener = $l; $Port = $p; break } catch { $l.Close() }
}
if (-not $listener) { throw "Couldn't listen on ports $Port-$($Port + 10). Pass -Port with a free port." }

$url = "http://localhost:$Port/"
Write-Host "Restore plan: $url" -ForegroundColor Cyan
Write-Host 'Stop with the Quit button on the page, or Ctrl+C here.'
if (-not $NoBrowser) { Start-Process $url }

try {
    while ($script:Running -and $listener.IsListening) {
        $task = $listener.GetContextAsync()
        # Short waits keep Ctrl+C working; a blocking GetContext() ignores it.
        while (-not $task.AsyncWaitHandle.WaitOne(300)) { }
        $ctx = $task.GetAwaiter().GetResult()
        try { Invoke-Request $ctx | Out-Null }
        catch {
            # The browser dropped the connection (tab reloaded or closed mid-request): nothing to report.
            $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
            if ($inner -is [System.Net.HttpListenerException] -or $inner -is [System.IO.IOException]) { continue }
            Write-Host "Request failed: $($_.Exception.Message)" -ForegroundColor Yellow
            try { Send-Json $ctx @{ error = $_.Exception.Message } 500 } catch { }
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
    Write-Host 'Stopped.'
}
