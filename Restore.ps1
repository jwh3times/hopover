<#
    Restore.ps1
    Sets up the new PC from the data folder (settings\, winget export, plan)
    and the migration drive (<migrationRoot>: extras archives and drivers).
    Every step is safe to rerun.

    Steps that need admin run only from an elevated prompt; the rest run only
    from a normal prompt (so repos and config end up owned by you, not by
    Administrators). Run it both ways; the order between them doesn't matter
    except that app data under Program Files needs the app installed first.

        # 1. elevated: drivers, drive letters, machine prefs, Chocolatey, machine env, hosts
        powershell -ExecutionPolicy Bypass -File .\Restore.ps1
        # 2. normal: winget apps, env, git, repos, dev tools, VS Code, Terminal, Claude, Codex, app data
        powershell -ExecutionPolicy Bypass -File .\Restore.ps1
        # 3. elevated again once apps are installed: app data under Program Files
        powershell -ExecutionPolicy Bypass -File .\Restore.ps1 -Steps app-data

    Options:
        -Steps a,b      run only these steps (see -List); runs them even if the plan turns them off
        -DryRun         report what would change, change nothing
        -NoOverwrite    leave existing config files alone (default: back them up, then replace)
        -List           list the steps and exit (-AsJson for Show-RestorePlan.ps1)
        -IgnorePlan     restore everything, ignoring restore-plan.json

    <data>\restore-plan.json (written by Show-RestorePlan.ps1) lists steps and
    items to skip. Anything it doesn't list is restored.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [string[]]$Steps = @('all'),
    # Data folder (default: $env:HOPOVER_DATA, else .\data).
    [string]$DataDir,
    # Defaults: migrationRoot and devRoot from the Options.
    [string]$MigrationRoot,
    [string]$DevRoot,
    [switch]$DryRun,
    [switch]$NoOverwrite,
    [switch]$List,
    [switch]$AsJson,
    [string]$Plan,
    [switch]$IgnorePlan
)

$ErrorActionPreference = 'Continue'
$Steps = @($Steps | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptDir 'lib\Common.ps1')
$DataDir  = Resolve-DataDir $DataDir
$Config   = Get-Options $DataDir
if (-not $MigrationRoot) { $MigrationRoot = Expand-ConfigPath $Config.migrationRoot }
if (-not $MigrationRoot) { $MigrationRoot = '(migrationRoot not set in the Options)' }
if (-not $DevRoot) { $DevRoot = Expand-ConfigPath $Config.devRoot }
$S        = Join-Path $DataDir 'settings'
$Extras   = Join-Path $MigrationRoot 'extras'
$Tar      = Join-Path $env:windir 'System32\tar.exe'
$Stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$IsAdmin  = Test-IsAdmin
$Results  = New-Object System.Collections.Generic.List[object]
$Manual   = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# Restore plan: steps and items to skip, by group id and key (see Show-RestorePlan.ps1).
# ---------------------------------------------------------------------------
if (-not $Plan) { $Plan = Join-Path $DataDir 'restore-plan.json' }
$PlanData = $null
if (-not $IgnorePlan -and (Test-Path -LiteralPath $Plan)) { $PlanData = Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json }
$PlanSkip = @{}
$PlanSkipSteps = @()
if ($PlanData) {
    $PlanSkipSteps = @(@($PlanData.SkipSteps) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLower() })
    foreach ($g in @($PlanData.Skip.PSObject.Properties)) {
        $set = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
        foreach ($v in @($g.Value)) { if ($null -ne $v) { [void]$set.Add([string]$v) } }
        $PlanSkip[$g.Name] = $set
    }
}
$script:PlanHits = 0

# False when the plan skips this item (and counts it for the step's summary).
function Test-Planned([string]$Group, [string]$Key) {
    $set = $PlanSkip[$Group]
    if ($set -and $set.Contains($Key)) { $script:PlanHits++; return $false }
    return $true
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$Text) { Write-Host "  $Text" }

# Runs a change, or just reports it under -DryRun. Returns $true if it ran (or would run).
function Invoke-Change([string]$What, [scriptblock]$Do) {
    if ($DryRun) { Write-Host "  would: $What" -ForegroundColor DarkCyan; return $true }
    Write-Host "  $What" -ForegroundColor Gray
    # Out-Host shows the command's output live and keeps it out of the return value.
    try { & $Do | Out-Host; return $true } catch { Write-Host "    failed: $($_.Exception.Message)" -ForegroundColor Yellow; return $false }
}

function Test-Tool([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# Reload PATH so tools installed earlier in this run are found.
function Update-SessionPath {
    $env:Path = ([Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User'))
}

# PS 5.1 returns a top-level JSON array as one object; this always yields the elements.
function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return $parsed
}
function Read-JsonArray([string]$Path) { $p = Read-Json $Path; if ($null -eq $p) { return @() }; return @($p | ForEach-Object { $_ }) }

# Copies one config file: identical -> nothing; existing -> backed up then replaced (or kept with -NoOverwrite).
function Copy-Config([string]$Src, [string]$Dst) {
    if (-not (Test-Path -LiteralPath $Src -PathType Leaf)) { return 'missing' }
    # Plan keys for files are paths under settings\ with forward slashes.
    if ($Src.StartsWith($S + '\', [StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-Planned 'files' $Src.Substring($S.Length + 1).Replace('\', '/'))) { return 'skipped by plan' }
    }
    $note = ''
    if ((Get-Content -LiteralPath $Src -Raw -ErrorAction SilentlyContinue) -match '<redacted') { $note = ' (has <redacted> values to fill in)' }
    if (Test-Path -LiteralPath $Dst -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $Src).Hash -eq (Get-FileHash -LiteralPath $Dst).Hash) { return 'same' }
        if ($NoOverwrite) { return 'kept existing' }
        [void](Invoke-Change "back up $Dst" { Copy-Item -LiteralPath $Dst -Destination "$Dst.pre-restore-$Stamp" -Force })
    }
    [void](Invoke-Change "copy $(Split-Path -Leaf $Src) -> $Dst$note" {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Dst) -Force | Out-Null
        Copy-Item -LiteralPath $Src -Destination $Dst -Force
    })
    return "copied$note"
}

function Copy-ConfigDir([string]$SrcDir, [string]$DstDir) {
    if (-not (Test-Path -LiteralPath $SrcDir -PathType Container)) { return 0 }
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $SrcDir -Recurse -File)) {
        $r = Copy-Config $f.FullName (Join-Path $DstDir $f.FullName.Substring($SrcDir.TrimEnd('\').Length + 1))
        if ($r -like 'copied*') { $n++ }
    }
    return $n
}

function Get-ExtrasItems {
    $m = Read-Json (Join-Path $Extras 'manifest.json')
    if ($null -eq $m) { return @() }
    return @($m.Items | ForEach-Object { $_ })
}

# Extracts an extras archive without overwriting existing files (-k).
function Expand-Extra([string]$Zip, [string]$Into) {
    return (Invoke-Change "extract $(Split-Path -Leaf $Zip) -> $Into" {
        & $Tar -x -k -f $Zip -C $Into 2>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -and $_.ToString() -notmatch 'File exists|Already exists' } |
            Select-Object -First 3 | ForEach-Object { Write-Host "    tar: $_" -ForegroundColor Yellow }
    })
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
$StepList = @(
@{ Name = 'drivers'; Admin = $true; Text = 'Install exported drivers'; Run = {
    $dir = Join-Path $MigrationRoot 'drivers'
    if (-not @(Get-ChildItem -LiteralPath $dir -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count) { return "skipped: no drivers in $dir" }
    [void](Invoke-Change "pnputil /add-driver $dir\*.inf /subdirs /install" { pnputil /add-driver "$dir\*.inf" /subdirs /install | Select-Object -Last 4 | ForEach-Object { Write-Host "    $_" } })
    $Manual.Add('Drivers: install current GPU and chipset drivers from the vendors; the exported copies are a fallback.')
    'done' } }

@{ Name = 'drive-letters'; Admin = $true; Text = 'Reassign drive letters by label'; Run = {
    $saved = Read-JsonArray (Join-Path $S 'windows\drives.json')
    if (-not $saved.Count) { return 'skipped: no drives.json' }
    $msgs = @()
    foreach ($d in $saved) {
        if (-not $d.Label -or $d.Letter -eq 'C') { continue }
        if (-not (Test-Planned 'drive-letters' $d.Label)) { continue }
        $vol = @(Get-Volume | Where-Object { $_.FileSystemLabel -eq $d.Label })
        if ($vol.Count -ne 1) { $msgs += "$($d.Label): $($vol.Count) volumes with that label"; continue }
        $cur = [string]$vol[0].DriveLetter
        if ($cur -eq $d.Letter) { continue }
        if (Get-Volume -DriveLetter $d.Letter -ErrorAction SilentlyContinue) { $msgs += "$($d.Label): $($d.Letter): is taken"; continue }
        $part = if ($cur) { Get-Partition -DriveLetter $cur -ErrorAction SilentlyContinue } else { $null }
        if ($part) {
            [void](Invoke-Change "$($d.Label): ${cur}: -> $($d.Letter):" { $part | Set-Partition -NewDriveLetter $d.Letter })
        } else {
            # Dynamic (LDM) volumes have no basic partition; diskpart can still assign the letter.
            $dp = Join-Path $env:TEMP "letter-$($d.Letter).txt"
            $sel = if ($cur) { "select volume $cur" } else { "select volume `"$($d.Label)`"" }
            [void](Invoke-Change "$($d.Label): assign $($d.Letter): with diskpart" {
                [IO.File]::WriteAllText($dp, "$sel`r`nassign letter=$($d.Letter)`r`n")
                diskpart /s $dp | Select-Object -Last 2 | ForEach-Object { Write-Host "    $_" }
            })
        }
    }
    if ($msgs.Count) { 'partly: ' + ($msgs -join '; ') } else { 'done' } } }

@{ Name = 'prefs'; Admin = $null; Text = 'Windows preferences (user part normally, machine part elevated)'; Run = {
    if (-not (Test-Path -LiteralPath (Join-Path $S 'windows\preferences.json'))) { return 'skipped: no preferences.json' }
    # Registry keys are "Path|Name"; features are passed as "feature:Name".
    $skip = @()
    if ($PlanSkip['prefs'])    { $skip += @($PlanSkip['prefs']) }
    if ($PlanSkip['features']) { $skip += @($PlanSkip['features'] | ForEach-Object { "feature:$_" }) }
    $script:PlanHits += $skip.Count
    if ($DryRun) { Write-Host '  would: Set-WindowsPreferences.ps1 -Apply' -ForegroundColor DarkCyan; return 'dry run' }
    & (Join-Path $scriptDir 'Set-WindowsPreferences.ps1') -Apply -Dir (Join-Path $S 'windows') -Skip $skip
    'done' } }

@{ Name = 'winget'; Admin = $false; Text = 'Install apps with winget'; Run = {
    if (-not (Test-Tool winget)) { return 'FAILED: winget missing; install App Installer from the Microsoft Store' }
    $file = Join-Path $DataDir 'winget-packages.json'
    if (-not (Test-Path -LiteralPath $file)) { return "skipped: no $file (run Catalog-InstalledApps.ps1 on the old PC)" }
    if ($PlanSkip['winget'] -and $PlanSkip['winget'].Count) {
        # winget import takes a file, so write a copy without the skipped apps.
        $w = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        $kept = 0
        foreach ($src in @($w.Sources)) {
            $src.Packages = @(@($src.Packages) | Where-Object { Test-Planned 'winget' $_.PackageIdentifier })
            $kept += $src.Packages.Count
        }
        if (-not $kept) { return 'skipped: every app is unticked in the plan' }
        $w.Sources = @(@($w.Sources) | Where-Object { @($_.Packages).Count })
        $file = Join-Path $env:TEMP "winget-plan-$Stamp.json"
        [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $w -Depth 10), $Utf8)
    }
    [void](Invoke-Change "winget import $(Split-Path -Leaf $file) (already-installed apps are skipped)" {
        winget import -i $file --accept-package-agreements --accept-source-agreements --disable-interactivity
    })
    Update-SessionPath
    $Manual.Add('Apps: install the "Not Available via winget" list in Installed-Apps-Catalog.md by hand.')
    'done' } }

@{ Name = 'choco'; Admin = $true; Text = 'Install Chocolatey packages'; Run = {
    $cfg = Join-Path $S 'dev\choco-packages.config'
    if (-not (Test-Path -LiteralPath $cfg)) { return 'skipped: no choco-packages.config' }
    if (-not (Test-Tool choco)) {
        [void](Invoke-Change 'install Chocolatey with winget' { winget install --id Chocolatey.Chocolatey -e --accept-package-agreements --accept-source-agreements --disable-interactivity })
        Update-SessionPath
        if (-not (Test-Tool choco) -and -not $DryRun) { return 'FAILED: Chocolatey not installed; open a new elevated prompt and rerun -Steps choco' }
    }
    # Skip Windows hotfixes and Chocolatey's own plumbing; dependencies come back on their own.
    $ids = @(([xml](Get-Content -LiteralPath $cfg -Raw)).packages.package | ForEach-Object id |
        Where-Object { $_ -notmatch '^(KB\d+|chocolatey|chocolatey-.*\.extension|.+\.install)$' } | Where-Object { Test-Planned 'choco' $_ })
    $have = if (Test-Tool choco) { @(choco list --limit-output 2>$null | ForEach-Object { ($_ -split '\|')[0] }) } else { @() }
    $todo = @($ids | Where-Object { $have -notcontains $_ })
    if (-not $todo.Count) { return 'done: all installed' }
    [void](Invoke-Change "choco install $($todo -join ' ')" { choco install @todo -y --no-progress | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" } })
    Update-SessionPath
    'done' } }

@{ Name = 'env-machine'; Admin = $true; Text = 'Machine environment variables and PATH'; Run = { Restore-Env 'Machine' } }
@{ Name = 'env-user';    Admin = $false; Text = 'User environment variables and PATH'; Run = { Restore-Env 'User' } }

@{ Name = 'hosts'; Admin = $true; Text = 'Custom hosts file lines'; Run = {
    $saved = @(Get-Content -LiteralPath (Join-Path $S 'windows\hosts') -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^\s*(#|$)' } | ForEach-Object { $_.Trim() } |
        Where-Object { Test-Planned 'hosts' (($_ -replace '\s+', ' ').Trim()) })
    if (-not $saved.Count) { return 'skipped: no custom lines' }
    $hostsFile = Join-Path $env:windir 'System32\drivers\etc\hosts'
    $current = @(Get-Content -LiteralPath $hostsFile | ForEach-Object { ($_ -replace '\s+', ' ').Trim() })
    $add = @($saved | Where-Object { $current -notcontains (($_ -replace '\s+', ' ').Trim()) })
    if (-not $add.Count) { return 'done: already present' }
    [void](Invoke-Change "add $($add.Count) hosts line(s): $($add -join ' | ')" {
        Copy-Item -LiteralPath $hostsFile -Destination "$hostsFile.pre-restore-$Stamp"
        Add-Content -LiteralPath $hostsFile -Value $add
    })
    'done' } }

@{ Name = 'git-config'; Admin = $false; Text = 'Git and npm config'; Run = {
    $r1 = Copy-Config (Join-Path $S 'dev\gitconfig') (Join-Path $env:USERPROFILE '.gitconfig')
    $r2 = Copy-Config (Join-Path $S 'dev\gitignore_global') (Join-Path $env:USERPROFILE '.gitignore_global')
    $npm = Join-Path $S 'dev\npmrc'
    if (Test-Path -LiteralPath $npm) { $Manual.Add('npm: run "npm login" (the auth token was not exported).') }
    if (Test-Tool gh) {
        gh auth status 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $Manual.Add('GitHub: run "gh auth login" before the repos step if cloning prompts for credentials.') }
    }
    "gitconfig $r1; gitignore_global $r2" } }

@{ Name = 'repos'; Admin = $false; Text = "Clone repos into $DevRoot"; Run = {
    if (-not (Test-Tool git)) { return 'FAILED: git missing (winget step installs it)' }
    $repos = Read-JsonArray (Join-Path $S 'dev\repos.json')
    $cloned = 0; $skipped = 0; $notes = @()
    foreach ($r in $repos) {
        if (-not (Test-Planned 'repos' $r.Path)) { continue }
        if (-not $r.Url) { $notes += "$($r.Path): no remote"; continue }
        $target = Join-Path $DevRoot $r.Path
        if (Test-Path -LiteralPath (Join-Path $target '.git')) { $skipped++; continue }
        $ok = Invoke-Change "git clone $($r.Url) $target" {
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            git clone $r.Url $target 2>&1 | Select-Object -Last 1 | ForEach-Object { Write-Host "    $_" }
            if ($LASTEXITCODE -ne 0) { throw "clone failed" }
        }
        if ($ok) { $cloned++ }
        if ($ok -and -not $DryRun -and $r.Branch) {
            $cur = git -C $target branch --show-current 2>$null
            if ($cur -ne $r.Branch) {
                git -C $target checkout $r.Branch 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { $notes += "$($r.Path): was on $($r.Branch), not on origin; check it out from where you pushed it" }
            }
        }
    }
    $Manual.Add("Repos: put back gitignored local files with -Steps dev-extras (listed in settings\dev\repos.md).")
    "cloned $cloned, already there $skipped" + $(if ($notes.Count) { '; ' + ($notes -join '; ') } else { '' }) } }

@{ Name = 'dev-extras'; Admin = $false; Text = 'Untracked dev folders, local .env files, patches'; Run = {
    $items = @(Get-ExtrasItems | Where-Object { $_.Name -like 'dev-*' -and $_.File -and $_.Status -in 'ok', 'PARTIAL' } | Where-Object { Test-Planned 'extras' $_.Name })
    if (-not $items.Count) { return "skipped: no dev items in $Extras\manifest.json" }
    $n = 0
    foreach ($i in $items) {
        $zip = Join-Path $Extras $i.File
        if ($i.Name -eq 'dev-uncommitted') {
            $into = Join-Path $DevRoot '_restored-patches'
            if (-not $DryRun) { New-Item -ItemType Directory -Path $into -Force -ErrorAction SilentlyContinue | Out-Null }
            if (Expand-Extra $zip $into) { $n++ }
            $Manual.Add("Uncommitted changes from the old PC are in $into; apply with: git -C <repo> apply <file>.patch")
            continue
        }
        if (-not $DryRun) { New-Item -ItemType Directory -Path $DevRoot -Force -ErrorAction SilentlyContinue | Out-Null }
        if (Expand-Extra $zip $DevRoot) { $n++ }
    }
    "restored $n archive(s)" } }

@{ Name = 'dev-packages'; Admin = $false; Text = 'npm, .NET, Go, Cargo, uv, PowerShell packages'; Run = {
    $p = Read-Json (Join-Path $S 'dev\packages.json')
    if ($null -eq $p) { return 'skipped: no packages.json' }
    Update-SessionPath
    $npmList    = @(@($p.Npm)        | Where-Object { $_ -and (Test-Planned 'npm' $_) })
    $dotnetList = @(@($p.Dotnet)     | Where-Object { $_ -and (Test-Planned 'dotnet' $_) })
    $goList     = @(@($p.Go)         | Where-Object { $_ -and (Test-Planned 'go' $_) })
    $cargoList  = @(@($p.Cargo)      | Where-Object { $_ -and (Test-Planned 'cargo' $_) })
    $uvList     = @(@($p.Uv)         | Where-Object { $_ -and (Test-Planned 'uv' $_) })
    $psList     = @(@($p.PowerShell) | Where-Object { $_ -and (Test-Planned 'psmodules' $_) })
    $done = @(); $missing = @()
    if ($npmList.Count) {
        if (Test-Tool npm) {
            $have = @()
            try { $have = @((npm ls -g --depth=0 --json 2>$null | Out-String | ConvertFrom-Json).dependencies.PSObject.Properties.Name) } catch { }
            $todo = @($npmList | Where-Object { $have -notcontains $_ })
            if ($todo.Count) { [void](Invoke-Change "npm install -g $($todo -join ' ')" { npm install -g @todo 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Host "    $_" } }) }
            $done += "npm $($todo.Count) new"
        } else { $missing += 'npm (Node.js)' }
    }
    if ($dotnetList.Count) {
        if (Test-Tool dotnet) {
            $have = @(dotnet tool list -g 2>$null | Select-Object -Skip 2 | ForEach-Object { ($_ -split '\s+')[0] })
            $todo = @($dotnetList | Where-Object { $have -notcontains $_ })
            foreach ($t in $todo) { [void](Invoke-Change "dotnet tool install -g $t" { dotnet tool install -g $t | Out-Null }) }
            $done += "dotnet $($todo.Count) new"
        } else { $missing += '.NET SDK' }
    }
    if ($goList.Count) {
        if (Test-Tool go) {
            $gobin = Join-Path (go env GOPATH) 'bin'
            $todo = @($goList | Where-Object { -not (Test-Path -LiteralPath (Join-Path $gobin ((Split-Path -Leaf $_) + '.exe'))) })
            foreach ($m in $todo) { [void](Invoke-Change "go install $m@latest" { go install "$m@latest" }) }
            $done += "go $($todo.Count) new"
        } else { $missing += 'Go' }
    }
    if ($cargoList.Count) {
        if (Test-Tool cargo) {
            $have = @(cargo install --list 2>$null | Where-Object { $_ -match '^(\S+) v' } | ForEach-Object { ($_ -split ' ')[0] })
            $todo = @($cargoList | Where-Object { $have -notcontains $_ })
            if ($todo.Count) { [void](Invoke-Change "cargo install $($todo -join ' ')" { cargo install @todo }) }
            $done += "cargo $($todo.Count) new"
        } else { $missing += 'Rust (cargo)' }
    }
    if ($uvList.Count) {
        if (Test-Tool uv) { foreach ($t in $uvList) { [void](Invoke-Change "uv tool install $t" { uv tool install $t }) }; $done += 'uv' } else { $missing += 'uv' }
    }
    foreach ($m in $psList) {
        if (-not (Get-Module -ListAvailable -Name $m)) { [void](Invoke-Change "Install-Module $m -Scope CurrentUser" { Install-Module $m -Scope CurrentUser -Force }) }
    }
    if ($missing.Count) { $Manual.Add("Dev packages: install $($missing -join ', ') and rerun -Steps dev-packages.") }
    ($done -join ', ') + $(if ($missing.Count) { "; waiting on: $($missing -join ', ')" } else { '' }) } }

@{ Name = 'vscode'; Admin = $false; Text = 'VS Code extensions and settings'; Run = {
    Update-SessionPath
    $user = Join-Path $env:APPDATA 'Code\User'
    $res = @()
    foreach ($f in 'settings.json', 'keybindings.json', 'mcp.json', 'tasks.json') {
        $r = Copy-Config (Join-Path $S "vscode\$f") (Join-Path $user $f)
        if ($r -ne 'missing') { $res += "$f $r" }
    }
    $sn = Copy-ConfigDir (Join-Path $S 'vscode\snippets') (Join-Path $user 'snippets')
    $pr = Copy-ConfigDir (Join-Path $S 'vscode\prompts')  (Join-Path $user 'prompts')
    if (-not (Test-Tool code)) { return (($res -join '; ') + '; extensions waiting on VS Code (winget step)') }
    $want = @(Get-Content -LiteralPath (Join-Path $S 'vscode\extensions.txt') -ErrorAction SilentlyContinue | Where-Object { $_ -and (Test-Planned 'vscode-extensions' $_) })
    $have = @(code --list-extensions 2>$null)
    $todo = @($want | Where-Object { $have -notcontains $_ })
    foreach ($e in $todo) { [void](Invoke-Change "code --install-extension $e" { code --install-extension $e --force 2>&1 | Out-Null }) }
    ($res -join '; ') + "; $sn snippet(s), $pr prompt(s); $($todo.Count) extension(s) installed" } }

@{ Name = 'terminal'; Admin = $false; Text = 'Windows Terminal settings'; Run = {
    $dst = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
    if (-not (Test-Path -LiteralPath $dst)) { return 'skipped: open Windows Terminal once, then rerun -Steps terminal' }
    Copy-Config (Join-Path $S 'terminal\settings.json') (Join-Path $dst 'settings.json') } }

@{ Name = 'claude'; Admin = $false; Text = 'Claude Code config, memory, MCP servers'; Run = {
    $c = Join-Path $env:USERPROFILE '.claude'
    $res = @()
    foreach ($f in 'CLAUDE.md', 'settings.json', 'keybindings.json') {
        $r = Copy-Config (Join-Path $S "claude\$f") (Join-Path $c $f)
        if ($r -ne 'missing') { $res += "$f $r" }
    }
    $n = 0
    foreach ($d in 'hooks', 'themes', 'agents', 'commands') { $n += Copy-ConfigDir (Join-Path $S "claude\$d") (Join-Path $c $d) }
    $mem = 0
    foreach ($proj in @(Get-ChildItem -LiteralPath (Join-Path $S 'claude\memory') -Directory -ErrorAction SilentlyContinue)) {
        $mem += Copy-ConfigDir $proj.FullName (Join-Path $c "projects\$($proj.Name)\memory")
    }
    $r = Copy-Config (Join-Path $S 'claude\claude_desktop_config.json') (Join-Path $env:APPDATA 'Claude\claude_desktop_config.json')

    # User-scope MCP servers without secrets can be re-added directly.
    $mcp = Read-Json (Join-Path $S 'claude\mcp-servers.json')
    $added = 0
    if ($mcp -and (Test-Tool claude)) {
        $existing = (claude mcp list 2>$null) -join "`n"
        foreach ($prop in @($mcp.user.PSObject.Properties)) {
            $cfg = $prop.Value
            if ($existing -match [regex]::Escape($prop.Name) -or -not $cfg.url -or $cfg.headers -or $cfg.env) { continue }
            if (-not (Test-Planned 'mcp' $prop.Name)) { continue }
            if (Invoke-Change "claude mcp add --transport $($cfg.type) $($prop.Name) $($cfg.url) --scope user" { claude mcp add --transport $cfg.type $prop.Name $cfg.url --scope user | Out-Null }) { $added++ }
        }
    }
    $Manual.Add('Claude Code: sign in, reinstall skills (settings\claude\skills.md) and plugins (settings\claude\plugins), and re-add project MCP servers from settings\claude\mcp-servers.json.')
    ($res -join '; ') + "; $n hook/theme file(s); $mem memory file(s); desktop config $r; $added MCP server(s) added" } }

@{ Name = 'codex'; Admin = $false; Text = 'Codex config'; Run = {
    $c = Join-Path $env:USERPROFILE '.codex'
    $res = @()
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $S 'codex') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'skills.md' })) {
        $res += "$($f.Name) $(Copy-Config $f.FullName (Join-Path $c $f.Name))"
    }
    $n = Copy-ConfigDir (Join-Path $S 'codex\rules') (Join-Path $c 'rules')
    $Manual.Add('Codex: sign in (auth.json was not exported) and reinstall skills listed in settings\codex\skills.md.')
    ($res -join '; ') + "; $n rule file(s)" } }

@{ Name = 'app-data'; Admin = $null; Text = 'App data and excluded file types from the extras archive'; Run = {
    $items = @(Get-ExtrasItems | Where-Object { ($_.Name -like 'app-*' -or $_.Name -like 'excluded-types-*') -and $_.File -and $_.Status -in 'ok', 'PARTIAL' } | Where-Object { Test-Planned 'extras' $_.Name })
    if (-not $items.Count) { return "skipped: no app items in $Extras\manifest.json" }
    $done = @(); $waiting = @(); $other = 0
    foreach ($i in $items) {
        # Program Files items need admin; everything else is restored as you, not as Administrators.
        if ([bool]$i.Admin -ne $IsAdmin) { $other++; continue }
        $target = [Environment]::ExpandEnvironmentVariables($i.RestoreTo).TrimEnd('\')
        $into   = if ($i.Kind -eq 'folder') { Split-Path -Parent $target } else { $target }
        if ($into -match '^[A-Za-z]:$') { $into += '\' }
        if (-not (Test-Path -LiteralPath $into)) { $waiting += "$($i.Name) (needs $into)"; continue }
        if (Expand-Extra (Join-Path $Extras $i.File) $into) { $done += $i.Name }
    }
    if ($waiting.Count) { $Manual.Add("App data waiting on the app or drive: $($waiting -join ', '). Install/launch it, then rerun -Steps app-data$(if ($IsAdmin) { ' (elevated)' })") }
    $otherNote = if ($other) { "; $other item(s) for the $(if ($IsAdmin) { 'normal' } else { 'elevated' }) pass" } else { '' }
    "restored $($done.Count)$(if ($waiting.Count) { ", waiting on $($waiting.Count)" })$otherNote" } }

@{ Name = 'docker-volumes'; Admin = $false; Text = 'Docker named volumes'; Run = {
    $dir = Join-Path $Extras 'docker-volumes'
    $tgz = @(Get-ChildItem -LiteralPath $dir -Filter *.tgz -File -ErrorAction SilentlyContinue)
    if (-not $tgz.Count) { return 'skipped: no volume archives' }
    $up = $false
    if (Test-Tool docker) { docker info --format '{{.ServerVersion}}' 2>$null | Out-Null; $up = ($LASTEXITCODE -eq 0) }
    if (-not $up) { return 'skipped: start Docker Desktop, then rerun -Steps docker-volumes' }
    $have = @(docker volume ls --format '{{.Name}}' 2>$null)
    $n = 0
    foreach ($t in $tgz) {
        $v = $t.BaseName
        if (-not (Test-Planned 'docker-volumes' $v)) { continue }
        if ($have -contains $v) { continue }
        if (Invoke-Change "restore volume $v" {
            docker volume create $v | Out-Null
            docker run --rm -v "${v}:/data" -v "${dir}:/backup:ro" alpine tar xzf "/backup/$($t.Name)" -C /data
        }) { $n++ }
    }
    "restored $n of $($tgz.Count)" } }
)

# Environment restore, shared by env-user and env-machine.
function Restore-Env([string]$Scope) {
    $lower = $Scope.ToLower()
    $data = Read-Json (Join-Path $S "windows\env-$lower.json")
    if ($null -eq $data) { return "skipped: no env-$lower.json" }
    $set = 0
    foreach ($prop in @($data.Variables.PSObject.Properties)) {
        if (-not (Test-Planned "env-$lower" $prop.Name)) { continue }
        $cur = [Environment]::GetEnvironmentVariable($prop.Name, $Scope)
        if ($cur -eq $prop.Value) { continue }
        if (Invoke-Change "set $Scope env $($prop.Name)" { [Environment]::SetEnvironmentVariable($prop.Name, [string]$prop.Value, $Scope) }) { $set++ }
    }
    # PATH: keep the new PC's entries, append the old ones it lacks.
    $saved = @(Get-Content -LiteralPath (Join-Path $S "windows\path-$lower.txt") -ErrorAction SilentlyContinue | Where-Object { $_ -and (Test-Planned "path-$lower" $_) })
    $current = @(([Environment]::GetEnvironmentVariable('Path', $Scope)) -split ';' | Where-Object { $_ })
    $norm = @($current | ForEach-Object { $_.TrimEnd('\').ToLower() })
    $add = @($saved | Where-Object { $norm -notcontains $_.TrimEnd('\').ToLower() })
    if ($add.Count) {
        [void](Invoke-Change "append $($add.Count) $Scope PATH entr(ies): $($add -join '; ')" {
            [Environment]::SetEnvironmentVariable('Path', (@($current + $add) -join ';'), $Scope)
        })
        Update-SessionPath
    }
    $missingSecrets = @(@($data.SecretNames) | Where-Object { $_ -and -not [Environment]::GetEnvironmentVariable($_, $Scope) })
    if ($missingSecrets.Count) { $Manual.Add("Secrets: set $Scope env vars from your password manager: $($missingSecrets -join ', ')") }
    "$set var(s) set, $($add.Count) PATH entr(ies) added" + $(if ($missingSecrets.Count) { "; $($missingSecrets.Count) secret(s) to set" } else { '' })
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
# Note: loop variables must not be $s; PowerShell names are case-insensitive and $S is the settings path.
if ($List) {
    if ($AsJson) {
        return (ConvertTo-Json -Depth 3 -InputObject @($StepList | ForEach-Object { [ordered]@{ name = $_.Name; admin = $_.Admin; text = $_.Text } }))
    }
    foreach ($step in $StepList) {
        $who = if ($null -eq $step.Admin) { 'both' } elseif ($step.Admin) { 'elevated' } else { 'normal' }
        Write-Host ("{0,-15} {1,-9} {2}" -f $step.Name, $who, $step.Text)
    }
    return
}

$known = @($StepList | ForEach-Object { $_.Name })
$unknown = @($Steps | Where-Object { $_ -ne 'all' -and $known -notcontains $_ })
if ($unknown.Count) { throw "Unknown step(s): $($unknown -join ', '). Run with -List." }

if (-not (Test-Path -LiteralPath $S)) { throw "No settings folder at $S. Put your data folder there (or pass -DataDir / set HOPOVER_DATA)." }
if (-not (Test-Path -LiteralPath $MigrationRoot)) {
    $drive = if ($MigrationRoot -match '^([A-Za-z]:)') { $Matches[1] } else { '' }
    $why = if ($drive -and -not (Test-Path -LiteralPath "$drive\")) { "$drive isn't connected" } else { "$MigrationRoot doesn't exist" }
    Write-Host "${why}; steps that need the extras or drivers will be skipped." -ForegroundColor Yellow
}

$log = Join-Path $env:USERPROFILE "restore-$Stamp$(if ($IsAdmin) { '-admin' }).log"
if (-not $DryRun) { Start-Transcript -Path $log | Out-Null }

Write-Host "Restore from $DataDir  ($(if ($IsAdmin) { 'elevated' } else { 'normal' }) prompt$(if ($DryRun) { ', DRY RUN' }))" -ForegroundColor Cyan
if ($PlanData) {
    $nItems = 0; foreach ($set in $PlanSkip.Values) { $nItems += $set.Count }
    Write-Host "Plan: $Plan ($($PlanSkipSteps.Count) step(s) off, $nItems item(s) unticked; -IgnorePlan restores everything)" -ForegroundColor Cyan
} elseif ($IgnorePlan) {
    Write-Host 'Plan: ignored (-IgnorePlan); restoring everything' -ForegroundColor Cyan
} else {
    Write-Host 'Plan: none (no restore-plan.json); restoring everything' -ForegroundColor Cyan
}
$explicit = $Steps -notcontains 'all'
$deferred = @()
foreach ($step in $StepList) {
    if ($explicit -and $Steps -notcontains $step.Name) { continue }
    # Naming a step with -Steps runs it even when the plan turns it off.
    if (-not $explicit -and $PlanSkipSteps -contains $step.Name) { $Results.Add([pscustomobject]@{ Step = $step.Name; Status = 'skipped by plan' }); continue }
    if ($null -ne $step.Admin -and $step.Admin -ne $IsAdmin) { $deferred += $step.Name; continue }
    Write-Host ''
    Write-Host "== $($step.Name): $($step.Text)" -ForegroundColor Cyan
    $script:PlanHits = 0
    try { $status = [string](& $step.Run | Select-Object -Last 1) } catch { $status = "FAILED: $($_.Exception.Message)" }
    if (-not $status) { $status = 'done' }
    if ($script:PlanHits) { $status += "; $($script:PlanHits) item(s) skipped by plan" }
    $Results.Add([pscustomobject]@{ Step = $step.Name; Status = $status })
    Write-Host "  -> $status" -ForegroundColor $(if ($status -like 'FAILED*') { 'Red' } elseif ($status -like 'skipped*' -or $status -like 'partly*') { 'Yellow' } else { 'Green' })
}

Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
foreach ($r in $Results) { Write-Host ("  {0,-15} {1}" -f $r.Step, $r.Status) }
if ($deferred.Count) {
    $how = if ($IsAdmin) { 'a normal (non-elevated) prompt' } else { 'an elevated prompt' }
    Write-Host ''
    Write-Host "Run again from $how for: $($deferred -join ', ')" -ForegroundColor Yellow
}
if ($Manual.Count) {
    Write-Host ''
    Write-Host 'Still to do by hand:' -ForegroundColor Cyan
    $Manual | Sort-Object -Unique | ForEach-Object { Write-Host "  [ ] $_" }
}
if (-not $DryRun) { Stop-Transcript | Out-Null; Write-Host "Log: $log" }
