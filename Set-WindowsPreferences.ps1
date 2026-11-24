<#
    Set-WindowsPreferences.ps1
    Captures Windows preferences on the old PC (-Export) and applies them on the
    new one (-Apply): Explorer and taskbar options, theme, mouse and keyboard,
    accessibility shortcuts, Game Bar/Game DVR, clipboard history, default
    terminal, power plan, time zone, optional Windows features, and the
    machine-wide switches (long paths, Developer Mode, GPU scheduling, fast startup).

    Usage:
        # old PC (Export-Settings.ps1 runs this for you)
        powershell -ExecutionPolicy Bypass -File .\Set-WindowsPreferences.ps1 -Export
        # new PC: once normally, then once from an elevated prompt for the machine-wide parts
        powershell -ExecutionPolicy Bypass -File .\Set-WindowsPreferences.ps1 -Apply -RestartExplorer

    Files (in settings\windows by default):
        preferences.json   what -Apply reads
        preferences.md     the same, readable
        power-plan.pow     exported active power plan
#>

[CmdletBinding(DefaultParameterSetName = 'Export', PositionalBinding = $false)]
param(
    [Parameter(ParameterSetName = 'Export', Mandatory)] [switch]$Export,
    [Parameter(ParameterSetName = 'Apply',  Mandatory)] [switch]$Apply,

    # Folder holding preferences.json. Defaults to <data>\settings\windows.
    [string]$Dir,

    # Data folder (default: $env:HOPOVER_DATA, else .\data). Only used when -Dir isn't given.
    [string]$DataDir,

    # Apply only: restart Explorer so taskbar and Explorer changes show at once.
    [Parameter(ParameterSetName = 'Apply')] [switch]$RestartExplorer,

    # Apply only: settings to leave alone. Registry settings are "Path|Name";
    # also TimeZone, PowerPlan, ClassicContextMenu and feature:<Name>.
    # Restore.ps1 passes the ones unticked in restore-plan.json.
    [Parameter(ParameterSetName = 'Apply')] [string[]]$Skip = @()
)

$ErrorActionPreference = 'Continue'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptDir 'lib\Common.ps1')
if (-not $Dir) { $Dir = Join-Path (Resolve-DataDir $DataDir) 'settings\windows' }
$IsAdmin = Test-IsAdmin

# ---------------------------------------------------------------------------
# The settings captured. Scope Machine needs an elevated prompt to apply.
# ---------------------------------------------------------------------------
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$Settings = @(
    # Explorer
    @{ Scope = 'User'; Path = $adv; Name = 'HideFileExt';                  Label = 'Hide file extensions' }
    @{ Scope = 'User'; Path = $adv; Name = 'Hidden';                       Label = 'Show hidden files (1 = show)' }
    @{ Scope = 'User'; Path = $adv; Name = 'ShowSuperHidden';              Label = 'Show protected OS files' }
    @{ Scope = 'User'; Path = $adv; Name = 'LaunchTo';                     Label = 'Explorer opens to (1 = This PC, 2 = Home)' }
    @{ Scope = 'User'; Path = $adv; Name = 'SeparateProcess';              Label = 'Folder windows in separate process' }
    @{ Scope = 'User'; Path = $adv; Name = 'NavPaneExpandToCurrentFolder'; Label = 'Nav pane expands to current folder' }
    @{ Scope = 'User'; Path = $adv; Name = 'NavPaneShowAllFolders';        Label = 'Nav pane shows all folders' }
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState'; Name = 'FullPath'; Label = 'Full path in title bar' }
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'ShowRecent';   Label = 'Quick access: recent files' }
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'ShowFrequent'; Label = 'Quick access: frequent folders' }
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'ShowCloudFilesInQuickAccess'; Label = 'Quick access: cloud files' }
    # Taskbar and Start
    @{ Scope = 'User'; Path = $adv; Name = 'TaskbarAl';                Label = 'Taskbar alignment (0 = left, 1 = center)' }
    @{ Scope = 'User'; Path = $adv; Name = 'TaskbarDa';                Label = 'Widgets button' }
    @{ Scope = 'User'; Path = $adv; Name = 'TaskbarMn';                Label = 'Chat button' }
    @{ Scope = 'User'; Path = $adv; Name = 'ShowTaskViewButton';       Label = 'Task View button' }
    @{ Scope = 'User'; Path = $adv; Name = 'ShowCopilotButton';        Label = 'Copilot button' }
    @{ Scope = 'User'; Path = $adv; Name = 'TaskbarGlomLevel';         Label = 'Combine taskbar buttons' }
    @{ Scope = 'User'; Path = $adv; Name = 'MMTaskbarEnabled';         Label = 'Taskbar on all displays' }
    @{ Scope = 'User'; Path = $adv; Name = 'MMTaskbarMode';            Label = 'Multi-display taskbar mode' }
    @{ Scope = 'User'; Path = $adv; Name = 'MMTaskbarGlomLevel';       Label = 'Combine buttons on other displays' }
    @{ Scope = 'User'; Path = $adv; Name = 'ShowSecondsInSystemClock'; Label = 'Seconds in clock' }
    @{ Scope = 'User'; Path = $adv; Name = 'Start_TrackDocs';          Label = 'Start: show recent items' }
    @{ Scope = 'User'; Path = $adv; Name = 'Start_TrackProgs';         Label = 'Start: show most used apps' }
    @{ Scope = 'User'; Path = $adv; Name = 'Start_Layout';             Label = 'Start layout (more pins / more recommendations)' }
    @{ Scope = 'User'; Path = $adv; Name = 'Start_IrisRecommendations'; Label = 'Start: tips and recommendations' }
    @{ Scope = 'User'; Path = "$adv\TaskbarDeveloperSettings"; Name = 'TaskbarEndTask'; Label = 'End task in taskbar right-click' }
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Label = 'Taskbar search (0 hidden, 1 icon, 2 box)' }
    # Theme
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme';   Label = 'Apps light theme' }
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme'; Label = 'System light theme' }
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency';  Label = 'Transparency effects' }
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'ColorPrevalence';     Label = 'Accent color on Start and taskbar' }
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'ColorPrevalence'; Label = 'Accent color on title bars' }
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'AccentColor';     Label = 'Accent color' }
    # Mouse and keyboard
    @{ Scope = 'User'; Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseSpeed';       Label = 'Enhance pointer precision (with thresholds)' }
    @{ Scope = 'User'; Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold1';  Label = 'Pointer threshold 1' }
    @{ Scope = 'User'; Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold2';  Label = 'Pointer threshold 2' }
    @{ Scope = 'User'; Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseSensitivity'; Label = 'Pointer speed' }
    @{ Scope = 'User'; Path = 'HKCU:\Control Panel\Keyboard'; Name = 'KeyboardDelay';  Label = 'Key repeat delay' }
    @{ Scope = 'User'; Path = 'HKCU:\Control Panel\Keyboard'; Name = 'KeyboardSpeed';  Label = 'Key repeat rate' }
    @{ Scope = 'User'; Path = 'HKCU:\Control Panel\Accessibility\StickyKeys';       Name = 'Flags'; Label = 'Sticky Keys shortcut flags' }
    @{ Scope = 'User'; Path = 'HKCU:\Control Panel\Accessibility\Keyboard Response'; Name = 'Flags'; Label = 'Filter Keys shortcut flags' }
    @{ Scope = 'User'; Path = 'HKCU:\Control Panel\Accessibility\ToggleKeys';       Name = 'Flags'; Label = 'Toggle Keys shortcut flags' }
    # Gaming
    @{ Scope = 'User'; Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Label = 'Game DVR' }
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Label = 'Game capture' }
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled';        Label = 'Game Mode' }
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'UseNexusForGameBarEnabled';  Label = 'Controller opens Game Bar' }
    # Misc
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Clipboard'; Name = 'EnableClipboardHistory'; Label = 'Clipboard history' }
    @{ Scope = 'User'; Path = 'HKCU:\Console\%%Startup'; Name = 'DelegationConsole';  Label = 'Default terminal (console host)' }
    @{ Scope = 'User'; Path = 'HKCU:\Console\%%Startup'; Name = 'DelegationTerminal'; Label = 'Default terminal (terminal)' }
    # Machine-wide
    @{ Scope = 'Machine'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; Name = 'LongPathsEnabled'; Label = 'Long paths' }
    @{ Scope = 'Machine'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'; Name = 'AllowDevelopmentWithoutDevLicense'; Label = 'Developer Mode' }
    @{ Scope = 'Machine'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode'; Label = 'Hardware-accelerated GPU scheduling (2 = on)' }
    @{ Scope = 'Machine'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; Name = 'HiberbootEnabled'; Label = 'Fast startup' }
)
$ClassicMenuKey = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
if ($Export) {
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $reg = foreach ($s in $Settings) {
        $key = Get-Item -LiteralPath $s.Path -ErrorAction SilentlyContinue
        if (-not $key -or $key.GetValueNames() -notcontains $s.Name) { continue }
        $kind = $key.GetValueKind($s.Name).ToString()
        $val  = $key.GetValue($s.Name, $null, 'DoNotExpandEnvironmentNames')
        if ($kind -eq 'Binary') { $val = @([byte[]]$val | ForEach-Object { [int]$_ }) }
        [ordered]@{ Scope = $s.Scope; Path = $s.Path; Name = $s.Name; Kind = $kind; Value = $val; Label = $s.Label }
    }

    $scheme = (powercfg /getactivescheme 2>$null) -join ' '
    $power  = $null
    if ($scheme -match '([0-9a-fA-F\-]{36})\s+\((.+)\)') {
        $guid = $Matches[1]; $pname = $Matches[2]
        $pow  = Join-Path $Dir 'power-plan.pow'
        if (Test-Path -LiteralPath $pow) { Remove-Item -LiteralPath $pow -Force }
        # Export needs admin and writes an empty file without it. Built-in plans
        # (Balanced etc.) exist on every install and are matched by name instead.
        powercfg /export $pow $guid 2>$null | Out-Null
        $ok = (Test-Path -LiteralPath $pow) -and ((Get-Item -LiteralPath $pow).Length -gt 0)
        if (-not $ok -and (Test-Path -LiteralPath $pow)) { Remove-Item -LiteralPath $pow -Force }
        $power = [ordered]@{ Name = $pname; Guid = $guid; File = $(if ($ok) { 'power-plan.pow' } else { $null }) }
    }

    $features = @(Get-CimInstance Win32_OptionalFeature -ErrorAction SilentlyContinue | Where-Object { $_.InstallState -eq 1 } | ForEach-Object Name | Sort-Object)
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

    $data = [ordered]@{
        Exported           = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        ComputerName       = $env:COMPUTERNAME
        Windows            = "$($os.Caption) $($os.Version)"
        TimeZone           = (Get-TimeZone).Id
        ClassicContextMenu = [bool](Test-Path -LiteralPath $ClassicMenuKey)
        PowerPlan          = $power
        OptionalFeatures   = $features
        Registry           = @($reg)
    }
    [IO.File]::WriteAllText((Join-Path $Dir 'preferences.json'), ($data | ConvertTo-Json -Depth 6), $Utf8)

    $NL = "`r`n"
    $md  = "# Windows preferences$NL$NL"
    $md += "Exported $($data.Exported) from $($data.ComputerName) ($($data.Windows)). Apply with ``Set-WindowsPreferences.ps1 -Apply``.$NL$NL"
    $md += "- Computer name: **$($data.ComputerName)** (not applied; rename in Settings > System > About)$NL"
    $md += "- Time zone: $($data.TimeZone)$NL"
    $md += "- Classic right-click menu: $($data.ClassicContextMenu)$NL"
    $md += "- Power plan: $(if ($power) { "$($power.Name) ($($power.Guid))" } else { 'unknown' })$NL"
    $md += "- Optional features enabled: $($features.Count) (applied from an elevated prompt): $($features -join ', ')$NL$NL"
    $md += "| Setting | Value | Scope |$NL| --- | --- | --- |$NL"
    foreach ($r in $reg) { $md += "| $($r.Label) | ``$(@($r.Value) -join ',')`` | $($r.Scope) |$NL" }
    [IO.File]::WriteAllText((Join-Path $Dir 'preferences.md'), $md, $Utf8)

    Write-Host "Exported $(@($reg).Count) settings, power plan and $($features.Count) features to $Dir" -ForegroundColor Green
    return
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
$jsonPath = Join-Path $Dir 'preferences.json'
if (-not (Test-Path -LiteralPath $jsonPath)) { throw "No preferences.json in $Dir. Run -Export on the old PC first." }
$data = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json

$applied = 0; $same = 0; $planned = 0; $skipped = New-Object System.Collections.Generic.List[string]; $failed = New-Object System.Collections.Generic.List[string]

foreach ($r in $data.Registry) {
    if ($Skip -contains "$($r.Path)|$($r.Name)") { $planned++; continue }
    if ($r.Scope -eq 'Machine' -and -not $IsAdmin) { $skipped.Add($r.Label); continue }
    try {
        $value = switch ($r.Kind) {
            'Binary'      { [byte[]]@($r.Value | ForEach-Object { [byte]$_ }) }
            'MultiString' { [string[]]@($r.Value) }
            'DWord'       { [int]$r.Value }
            'QWord'       { [long]$r.Value }
            default       { [string]$r.Value }
        }
        $key = Get-Item -LiteralPath $r.Path -ErrorAction SilentlyContinue
        if ($key -and $key.GetValueNames() -contains $r.Name) {
            $cur = $key.GetValue($r.Name, $null, 'DoNotExpandEnvironmentNames')
            if ((@($cur) -join ',') -eq (@($value) -join ',')) { $same++; continue }
        }
        if (-not (Test-Path -LiteralPath $r.Path)) { New-Item -Path $r.Path -Force | Out-Null }
        New-ItemProperty -LiteralPath $r.Path -Name $r.Name -Value $value -PropertyType $r.Kind -Force -ErrorAction Stop | Out-Null
        $applied++
    } catch {
        $failed.Add("$($r.Label): $($_.Exception.Message)")
    }
}

if ($data.ClassicContextMenu -and $Skip -contains 'ClassicContextMenu') { $planned++ }
elseif ($data.ClassicContextMenu -and -not (Test-Path -LiteralPath $ClassicMenuKey)) {
    New-Item -Path $ClassicMenuKey -Force | Out-Null
    Set-ItemProperty -LiteralPath $ClassicMenuKey -Name '(default)' -Value ''
    $applied++
}

if ($Skip -contains 'TimeZone') { $planned++ }
else {
    try {
        if ((Get-TimeZone).Id -ne $data.TimeZone) { Set-TimeZone -Id $data.TimeZone -ErrorAction Stop; $applied++ }
    } catch { $failed.Add("Time zone: $($_.Exception.Message)") }
}

if ($data.PowerPlan -and $Skip -contains 'PowerPlan') { $planned++ }
elseif ($data.PowerPlan) {
    $plans = (powercfg /list 2>$null) -join "`n"
    $m = [regex]::Match($plans, '([0-9a-fA-F\-]{36})\s+\(' + [regex]::Escape($data.PowerPlan.Name) + '\)')
    $target = if ($m.Success) { $m.Groups[1].Value } else { $null }
    if (-not $target -and $data.PowerPlan.File) {
        $pow = Join-Path $Dir $data.PowerPlan.File
        $out = (powercfg /import $pow 2>&1) -join ' '
        if ($out -match '([0-9a-fA-F\-]{36})') { $target = $Matches[1] } else { $failed.Add("Power plan import: $out") }
    }
    if ($target) {
        $active = (powercfg /getactivescheme 2>$null) -join ' '
        if ($active -notmatch [regex]::Escape($target)) { powercfg /setactive $target 2>$null | Out-Null; $applied++ }
    }
}

$features = @(@($data.OptionalFeatures) | Where-Object { $_ })
$planned += @($features | Where-Object { $Skip -contains "feature:$_" }).Count
$features = @($features | Where-Object { $Skip -notcontains "feature:$_" })
if ($IsAdmin) {
    $enabled = @(Get-CimInstance Win32_OptionalFeature -ErrorAction SilentlyContinue | Where-Object { $_.InstallState -eq 1 } | ForEach-Object Name)
    foreach ($f in @($features | Where-Object { $_ -notin $enabled })) {
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction Stop | Out-Null
            Write-Host "  enabled feature $f"
            $applied++
        } catch { $failed.Add("Feature ${f}: $($_.Exception.Message)") }
    }
} else {
    if ($features.Count) { $skipped.Add("$($features.Count) optional Windows features") }
}

if ($RestartExplorer) { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue }

Write-Host "Applied $applied change(s); $same already matched$(if ($planned) { "; $planned left alone by the restore plan" })." -ForegroundColor Green
if ($skipped.Count) {
    Write-Host "Needs an elevated prompt (rerun with -Apply as admin): $($skipped -join '; ')" -ForegroundColor Yellow
}
if ($failed.Count) {
    Write-Host 'Could not apply:' -ForegroundColor Yellow
    $failed | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}
Write-Host "Computer name on the old PC was $($data.ComputerName); rename in Settings > System > About if you want it back."
if (-not $RestartExplorer) { Write-Host 'Sign out and back in (or pass -RestartExplorer) for taskbar and Explorer changes.' }
