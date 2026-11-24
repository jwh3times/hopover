<#
    Test-LinuxCatalog.ps1
    Checks catalog/linux-packages.json and catalog/linux-repos.json without Docker:
      - every method has a known kind, and every repo, script, prereq and via target exists
      - vendor URLs (direct .deb/.rpm/AppImage files, repo keys, repo files) answer
      - GitHub release asset patterns match an asset of the latest release
    Run it before sending a catalog change.

        powershell -File linux\tests\Test-LinuxCatalog.ps1
        powershell -File linux\tests\Test-LinuxCatalog.ps1 -Offline     # structure only
#>
[CmdletBinding(PositionalBinding = $false)]
param([switch]$Offline)

$ErrorActionPreference = 'Continue'
$tool = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$pk = Get-Content (Join-Path $tool 'catalog\linux-packages.json') -Raw | ConvertFrom-Json
$rp = Get-Content (Join-Path $tool 'catalog\linux-repos.json') -Raw | ConvertFrom-Json
$problems = New-Object System.Collections.Generic.List[string]
$kinds = 'repo', 'script', 'aur', 'distro', 'flatpak', 'deb', 'rpm', 'appimage', 'tarball'
$keys = @($pk.packages.PSObject.Properties.Name)
$repoIds = @($rp.repos.PSObject.Properties.Name)
$scriptIds = @($rp.scripts.PSObject.Properties.Name)
$prereqIds = @($rp.prereqs.PSObject.Properties.Name)
$tiers = 'vendor', 'distro', 'portable', 'flatpak'

# Sample values for templates, enough to build real URLs.
$sample = @{ '1' = '21'; base = 'ubuntu'; codename = 'noble'; version = '24.04'; fedora = '43'; arch = 'amd64'; rpmarch = 'x86_64'; goarch = 'amd64'; node = '24' }
function Format-Sample([string]$s) { [regex]::Replace($s, '\{(\w+)\}', { param($m) if ($sample.ContainsKey($m.Groups[1].Value)) { $sample[$m.Groups[1].Value] } else { $m.Value } }) }

$urls = New-Object System.Collections.Generic.List[object]
$gh   = New-Object System.Collections.Generic.List[object]

foreach ($k in $keys) {
    $e = $pk.packages.$k
    if ($e.via -and $keys -notcontains $e.via) { $problems.Add("${k}: via target '$($e.via)' doesn't exist") }
    if (-not $e.via -and -not $e.none -and -not @($e.methods).Count) { $problems.Add("${k}: has no methods, via or none") }
    foreach ($m in @($e.methods | Where-Object { $_ })) {
        $kind = $kinds | Where-Object { $m.PSObject.Properties.Name -contains $_ } | Select-Object -First 1
        if (-not $kind) { $problems.Add("${k}: method with no known kind: $($m | ConvertTo-Json -Compress)"); continue }
        if ($m.tier -and $tiers -notcontains $m.tier) { $problems.Add("${k}: unknown tier '$($m.tier)'") }
        if ($kind -eq 'repo' -and $repoIds -notcontains $m.repo) { $problems.Add("${k}: unknown repo '$($m.repo)'") }
        if ($kind -eq 'repo' -and -not $m.package) { $problems.Add("${k}: repo method without package") }
        if ($kind -eq 'script' -and $scriptIds -notcontains $m.script) { $problems.Add("${k}: unknown script '$($m.script)'") }
        $pre = @(); if ($m.prereq -is [array]) { $pre = $m.prereq } elseif ($m.prereq) { $pre = @($m.prereq.PSObject.Properties | ForEach-Object { $_.Value } | ForEach-Object { $_ }) }
        foreach ($p in $pre) { if ($prereqIds -notcontains $p) { $problems.Add("${k}: unknown prereq '$p'") } }
        if ($kind -in 'deb', 'rpm', 'appimage', 'tarball') {
            $spec = $m.$kind
            $specs = if ($spec -is [string]) { @($spec) } else { @($spec.PSObject.Properties | ForEach-Object { $_.Value }) }
            foreach ($s in $specs) {
                if ($m.github) { $gh.Add([pscustomobject]@{ Key = $k; Repo = $m.github; Pattern = (Format-Sample $s) }) }
                else { $urls.Add([pscustomobject]@{ Key = $k; Url = (Format-Sample $s); MayFail = [bool]$m.mayFail }) }
            }
        }
    }
}
foreach ($p in @($pk.patterns)) { if ($keys -notcontains $p.use) { $problems.Add("pattern $($p.match): target '$($p.use)' doesn't exist") } }
foreach ($a in @($pk.aliases.PSObject.Properties)) {
    if ($keys -notcontains $a.Value -and -not @($pk.patterns | Where-Object { $a.Value -like $_.match }).Count) { $problems.Add("alias $($a.Name): target '$($a.Value)' doesn't exist") }
}
foreach ($r in $repoIds) {
    $d = $rp.repos.$r
    foreach ($key in @($d.apt.key | Where-Object { $_ })) { $urls.Add([pscustomobject]@{ Key = "repo $r (apt key)"; Url = (Format-Sample $key) }) }
    if ($d.dnf.repofile) { $urls.Add([pscustomobject]@{ Key = "repo $r (dnf repo file)"; Url = (Format-Sample $d.dnf.repofile) }) }
    if ($d.dnf.gpgkey) { $urls.Add([pscustomobject]@{ Key = "repo $r (dnf key)"; Url = (Format-Sample $d.dnf.gpgkey) }) }
}

Write-Host "Structure: $($keys.Count) entries, $($repoIds.Count) repos, $($scriptIds.Count) scripts; $($problems.Count) problem(s)" -ForegroundColor Cyan

if (-not $Offline) {
    $ua = @{ 'User-Agent' = 'hopover-catalog-check' }
    foreach ($u in $urls) {
        $ok = $false
        try { $r = Invoke-WebRequest -Uri $u.Url -Method Head -Headers $ua -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 30 -ErrorAction Stop; $ok = $r.StatusCode -lt 400 } catch {
            try { $r = Invoke-WebRequest -Uri $u.Url -Headers ($ua + @{ Range = 'bytes=0-0' }) -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 30 -ErrorAction Stop; $ok = $r.StatusCode -lt 400 } catch { }
        }
        if (-not $ok -and $u.MayFail) { Write-Host "  (allowed to fail) $($u.Key): no answer from $($u.Url)" -ForegroundColor DarkGray }
        elseif (-not $ok) { $problems.Add("$($u.Key): no answer from $($u.Url)") }
    }
    Write-Host "URLs: $($urls.Count) checked" -ForegroundColor Cyan
    $useGh = [bool](Get-Command gh -ErrorAction SilentlyContinue)
    $cache = @{}
    foreach ($g in $gh) {
        if (-not $cache.ContainsKey($g.Repo)) {
            $names = if ($useGh) { @(gh api "repos/$($g.Repo)/releases/latest" --jq '.assets[].name' 2>$null) }
                     else { try { @((Invoke-RestMethod "https://api.github.com/repos/$($g.Repo)/releases/latest" -Headers $ua).assets.name) } catch { @() } }
            $cache[$g.Repo] = $names
        }
        if (-not @($cache[$g.Repo] | Where-Object { $_ -match $g.Pattern }).Count) { $problems.Add("$($g.Key): no asset of $($g.Repo) matches $($g.Pattern)") }
    }
    Write-Host "GitHub patterns: $($gh.Count) checked" -ForegroundColor Cyan
}

if ($problems.Count) {
    Write-Host ''
    $problems | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    exit 1
}
Write-Host 'Catalog OK' -ForegroundColor Green
