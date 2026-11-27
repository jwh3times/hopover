# lib\Backup.ps1: the Backup module (docs/adr/0002-one-encrypted-backup-file.md). Dot-source it
# after lib\Common.ps1.
#
# Works in Windows PowerShell 5.1 (what a fresh install has) and PowerShell 7.

# The pinned 7-Zip: lib\7zip.json (version, url, sha256).
function Get-SevenZipPin {
    return Get-Content -LiteralPath (Join-Path $PSScriptRoot '7zip.json') -Raw | ConvertFrom-Json
}

# The path of a 7zr.exe whose SHA-256 matches the pin, downloading it into the cache
# (%LOCALAPPDATA%\Hopover\bin by default) when it isn't there or no longer matches.
# A download whose hash differs is deleted and refused: nothing that fails the check is ever run.
function Get-SevenZip([string]$CacheDir, $Pin) {
    if (-not $Pin) { $Pin = Get-SevenZipPin }
    if (-not $CacheDir) { $CacheDir = Join-Path (Split-Path -Parent (Get-OptionsPath)) 'bin' }
    $exe = Join-Path $CacheDir "7zr-$($Pin.version).exe"
    if ((Test-Path -LiteralPath $exe) -and (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -eq $Pin.sha256) { return $exe }

    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    $part = Join-Path $CacheDir "7zr-$([guid]::NewGuid().ToString('N')).download"
    try {
        # Windows PowerShell 5.1 on an older .NET may not offer TLS 1.2 unless asked.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Pin.url -OutFile $part -UseBasicParsing
        $hash = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash
        if ($hash -ne $Pin.sha256) {
            throw "Refused $($Pin.url): its SHA-256 is $hash, not the pinned $($Pin.sha256)."
        }
        Move-Item -LiteralPath $part -Destination $exe -Force
    } finally {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    }
    return $exe
}

# The suffix every Backup's file name ends with (split Backups add .001, .002, ...).
$BackupSuffix = '.hopover.7z'

# Plain text from a SecureString, for 7-Zip's standard input only.
function ConvertFrom-BackupPassword([securestring]$Password) {
    if (-not $Password) { return $null }
    return (New-Object System.Net.NetworkCredential('', $Password)).Password
}

# Runs 7-Zip with the password, if any, on standard input: never on its command line, where other
# programs could read it. 7-Zip reads it as UTF-8 because of -sccUTF-8. With no password, standard
# input is closed at once, so a prompt for one ends the run instead of waiting.
function Invoke-SevenZip([string]$SevenZip, [string[]]$Arguments, [securestring]$Password, [string]$WorkingDirectory) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SevenZip
    # Windows PowerShell 5.1's .NET has no ArgumentList: quote each argument for CreateProcess.
    $psi.Arguments = (@($Arguments) | ForEach-Object { if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    # Nothing but the password may reach 7-Zip's input. PowerShell 7's .NET takes the encoding to
    # write it in. Windows PowerShell 5.1's .NET writes the console input encoding's preamble the
    # moment the process starts: under code page 65001 a UTF-8 BOM, which 7-Zip would take as the
    # start of the password. So for the start only, make that encoding the same code page without
    # a preamble.
    $consoleEncoding = $null
    if ($psi.PSObject.Properties.Name -contains 'StandardInputEncoding') {
        $psi.StandardInputEncoding = $Utf8
    } elseif ([Console]::InputEncoding.GetPreamble().Length) {
        $consoleEncoding = [Console]::InputEncoding
        [Console]::InputEncoding = $Utf8
    }
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    finally { if ($consoleEncoding) { [Console]::InputEncoding = $consoleEncoding } }
    try {
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        try {
            if ($Password) {
                # Write the bytes ourselves: 5.1's ProcessStartInfo has no StandardInputEncoding.
                $bytes = $Utf8.GetBytes((ConvertFrom-BackupPassword $Password) + "`n")
                $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
                $p.StandardInput.BaseStream.Flush()
            }
            $p.StandardInput.Close()
        } catch [System.IO.IOException] {
            # 7-Zip exited before reading its input (an unencrypted archive needs none).
        }
        $p.WaitForExit()
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $stdout.Result + $stderr.Result }
    } finally {
        # Stopped part-way (Ctrl+C, an error): don't leave 7-Zip writing on its own.
        if (-not $p.HasExited) { try { $p.Kill() } catch { } }
    }
}

# Extras items that hold secrets (Backup-Extras.ps1 names them; catalog\app-data.json marks app-ssh
# optional): gitignored .env files and the like, and ~\.ssh. Only an encrypted Backup carries them.
$SecretExtras = @('dev-local-files', 'app-ssh')

# The files of the Backup called $Name in $Folder: <Name>.hopover.7z, or its pieces .001, .002, ...
function Get-BackupFiles([string]$Folder, [string]$Name) {
    return @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq ($Name + $BackupSuffix) -or ($_.Name.StartsWith($Name + $BackupSuffix + '.') -and $_.Name -match '\.\d{3}$')
    } | Sort-Object Name)
}

# Keeps an unencrypted Backup free of secrets: deletes the secret extras items' archives from the
# staging tree and drops them from its manifest. Returns the names left out.
function Remove-SecretExtras([string]$Source) {
    $file = Join-Path $Source 'extras\manifest.json'
    $m = Read-JsonFile $file
    if ($null -eq $m) { return @() }
    $out = @(@($m.Items) | Where-Object { $SecretExtras -contains $_.Name })
    if (-not $out.Count) { return @() }
    foreach ($i in $out) { if ($i.File) { Remove-Item -LiteralPath (Join-Path $Source "extras\$($i.File)") -Force -ErrorAction SilentlyContinue } }
    $m.Items = @(@($m.Items) | Where-Object { $SecretExtras -notcontains $_.Name })
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $m -Depth 8), $Utf8)
    return @($out | ForEach-Object Name)
}

# True when the staging tree's extras hold any secret item.
function Test-SecretExtras([string]$Source) {
    $m = Read-JsonFile (Join-Path $Source 'extras\manifest.json')
    return [bool](@(@($m.Items) | Where-Object { $SecretExtras -contains $_.Name -and $_.File }).Count)
}

# The version of Hopover running, in the form a tag has (v0.2.6). The release zip is `git archive`
# of the tag, which fills lib\version.txt's $Format:...$ placeholder with the tag (export-subst in
# .gitattributes). A clone keeps the placeholder, so git describe answers (v0.2.6-3-g1a2b3c4 past
# the tag). With neither, the VERSION file's release line is the best there is.
function Get-HopoverVersion([string]$Root = $ToolRoot) {
    $stamped = Join-Path $Root 'lib\version.txt'
    if (Test-Path -LiteralPath $stamped) {
        $v = [string](Get-Content -LiteralPath $stamped -Raw)
        $v = $v.Trim()
        if ($v -and -not $v.StartsWith('$Format:')) { return $v }
    }
    if (Test-Path -LiteralPath (Join-Path $Root '.git')) {
        # In Windows PowerShell 5.1 a native command's stderr is an error under ErrorAction Stop,
        # even when redirected: a git that complains must not stop a Backup.
        try { $v = git -C $Root describe --tags --always 2>$null } catch { $v = $null }
        if ($LASTEXITCODE -eq 0 -and $v) { return [string]$v }
    }
    $file = Join-Path $Root 'VERSION'
    if (Test-Path -LiteralPath $file) { return (Get-Content -LiteralPath $file -Raw).Trim() }
    return 'unknown'
}

# A Windows app's catalog key, the same on every OS (GLOSSARY.md), the way restore_linux.py's
# Catalog.lookup finds it: a package key, then an alias, then a pattern; a Windows-only app has
# none. $Id is a winget id or choco:<id>. Returns @{ Key; WindowsOnly }.
function Resolve-CatalogKey([string]$Id, $Catalog, [int]$Hops = 0) {
    $lower = $Id.ToLower()
    foreach ($k in $Catalog.packages.PSObject.Properties.Name) { if ($k.ToLower() -eq $lower) { return @{ Key = $k; WindowsOnly = $false } } }
    # An alias names another id; a chain of more than a few is a loop in the catalog, not an app.
    if ($Hops -lt 5) {
        foreach ($a in $Catalog.aliases.PSObject.Properties) {
            if ($a.Name.ToLower() -eq $lower) { $found = Resolve-CatalogKey $a.Value $Catalog ($Hops + 1); if ($found.Key) { return $found } }
        }
    }
    foreach ($p in @($Catalog.patterns)) {
        $rx = '^' + [regex]::Escape($p.match.ToLower()).Replace('\*', '(.*?)') + '$'
        if ($lower -match $rx -and $Catalog.packages.PSObject.Properties.Name -contains $p.use) { return @{ Key = $p.use; WindowsOnly = $false } }
    }
    foreach ($w in @($Catalog.windowsOnly)) { if ($lower -like $w.ToLower()) { return @{ Key = $null; WindowsOnly = $true } } }
    return @{ Key = $null; WindowsOnly = $false }
}

# The apps in a staging data folder (its winget export and Chocolatey list), each with its
# catalog key when the catalog knows it.
function Get-BackupApps([string]$DataDir) {
    $catalog = Get-Content -LiteralPath (Join-Path $ToolRoot 'catalog\linux-packages.json') -Raw | ConvertFrom-Json
    $ids = @()
    $w = Read-JsonFile (Join-Path $DataDir 'winget-packages.json')
    foreach ($src in @($w.Sources)) { foreach ($p in @($src.Packages)) { if ($p.PackageIdentifier) { $ids += , @('winget', $p.PackageIdentifier) } } }
    $pk = Read-JsonFile (Join-Path $DataDir 'settings\dev\packages.json')
    foreach ($c in @($pk.Choco)) { if ($c) { $ids += , @('choco', $c) } }
    foreach ($pair in $ids) {
        $found = Resolve-CatalogKey $(if ($pair[0] -eq 'choco') { "choco:$($pair[1])" } else { $pair[1] }) $catalog
        $app = [ordered]@{}
        if ($found.Key) { $app['catalogKey'] = $found.Key }
        $app[$pair[0]] = $pair[1]
        if ($found.WindowsOnly) { $app['windowsOnly'] = $true }
        $app
    }
}

# The groups (GLOSSARY.md) a staging tree holds, as far as its contents show them.
function Get-BackupGroups([string]$Source, $Apps) {
    $data = Join-Path $Source 'data'
    $groups = @()
    if (@($Apps).Count) { $groups += 'apps' }
    if (@('windows', 'vscode', 'terminal') | Where-Object { Test-Path -LiteralPath (Join-Path $data "settings\$_") }) { $groups += 'settings' }
    $dev = @('dev\repos.json', 'claude', 'codex') | Where-Object { Test-Path -LiteralPath (Join-Path $data "settings\$_") }
    $devExtras = @((Read-JsonFile (Join-Path $Source 'extras\manifest.json')).Items | Where-Object { $_.Name -like 'dev-*' -or $_.Name -eq 'docker-volumes' })
    if (@($dev).Count -or $devExtras.Count) { $groups += 'developer-tools' }
    return $groups
}

# hopover.json, at the root of every Backup: what it is and what it holds.
function Write-BackupManifest([string]$Source, [bool]$Encrypted, [bool]$PasswordsAndKeys, [string[]]$Captured) {
    $apps = @(Get-BackupApps (Join-Path $Source 'data'))
    $m = [ordered]@{
        formatVersion            = 1
        hopoverVersion           = Get-HopoverVersion
        created                  = (Get-Date).ToUniversalTime().ToString('o')
        sourceOs                 = 'windows'
        computerName             = $env:COMPUTERNAME
        encrypted                = $Encrypted
        includesPasswordsAndKeys = $PasswordsAndKeys
        captured                 = @($Captured)
        groups                   = @(Get-BackupGroups $Source $apps)
        apps                     = $apps
    }
    [IO.File]::WriteAllText((Join-Path $Source 'hopover.json'), (ConvertTo-Json -InputObject $m -Depth 6), $Utf8)
}

# Makes <Destination>\<Name>.hopover.7z from everything in the staging folder $Source. With a
# password the archive is AES-256 and its file names are encrypted too (-mhe=on); -NoEncryption
# makes an unprotected one, and leaves the secret extras items out of it (LeftOut names them).
# -SplitBytes > 0 writes pieces of that size (.001, .002, ...). Refuses to touch a Backup of that
# name that already exists, and removes its own pieces when it fails.
function New-Backup {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Name,
        [securestring]$Password,
        [switch]$NoEncryption,
        [long]$SplitBytes = 0,
        # What the staging tree holds, recorded in hopover.json (catalog, settings, extras, drivers).
        [string[]]$Captured = @(),
        [string]$SevenZip
    )
    $plain = ConvertFrom-BackupPassword $Password
    if (-not $NoEncryption -and -not $plain) { throw 'A Backup needs a password, or -NoEncryption to make an unprotected one.' }
    if ($plain -match "[`r`n]") { throw 'A password cannot contain a line break.' }
    if (-not $SevenZip) { $SevenZip = Get-SevenZip }
    $archive = Join-Path $Destination ($Name + $BackupSuffix)
    if ((Get-BackupFiles $Destination $Name).Count) { throw "There is already a Backup called ""$Name"" in $Destination. Choose another name." }

    $leftOut = if ($NoEncryption) { @(Remove-SecretExtras $Source) } else { @() }
    Write-BackupManifest -Source $Source -Encrypted (-not $NoEncryption) -PasswordsAndKeys ((-not $NoEncryption) -and (Test-SecretExtras $Source)) -Captured $Captured
    $arguments = @('a', '-t7z', '-sccUTF-8', '-bd', '-y')
    if (-not $NoEncryption) { $arguments += @('-p', '-mhe=on') }
    if ($SplitBytes -gt 0) { $arguments += "-v$($SplitBytes)b" }
    $arguments += @($archive, '*')
    $done = $false
    try {
        $r = Invoke-SevenZip -SevenZip $SevenZip -Arguments $arguments -Password $(if ($NoEncryption) { $null } else { $Password }) -WorkingDirectory $Source
        if ($r.ExitCode -ne 0) {
            # Exit 1 is 7-Zip's "some files couldn't be read": a Backup missing files isn't one to trust.
            throw "7-Zip couldn't make the Backup (exit $($r.ExitCode)): $(($r.Output -split "`n" | Where-Object { $_ -match 'error' } | Select-Object -First 3) -join ' ')"
        }
        $done = $true
    } finally {
        if (-not $done) { Get-BackupFiles $Destination $Name | Remove-Item -Force -ErrorAction SilentlyContinue }
    }
    $first = if ($SplitBytes -gt 0) { "$archive.001" } else { $archive }
    return [pscustomobject]@{ Path = $first; Files = @(Get-BackupFiles $Destination $Name | ForEach-Object FullName); Encrypted = -not $NoEncryption; LeftOut = $leftOut }
}

# Every Backup under the given folders, at most -Depth folders down: files named *.hopover.7z, or
# a split Backup's first piece (*.hopover.7z.001), whose Size is all its pieces together. Nothing
# inside a Backup can be read without its password, so Backups are recognized by name.
function Find-Backup {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Mandatory)][string[]]$Root,
        [int]$Depth = 2
    )
    foreach ($r in $Root) {
        if (-not (Test-Path -LiteralPath $r -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $r -Recurse -Depth $Depth -File -Filter ('*' + $BackupSuffix + '*') -ErrorAction SilentlyContinue)) {
            $split = $f.Name.EndsWith($BackupSuffix + '.001', [StringComparison]::OrdinalIgnoreCase)
            if (-not $split -and -not $f.Name.EndsWith($BackupSuffix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $name = $f.Name.Substring(0, $f.Name.Length - $BackupSuffix.Length - $(if ($split) { 4 } else { 0 }))
            $size = $f.Length
            if ($split) { $size = ((Get-BackupFiles $f.DirectoryName $name) | Measure-Object Length -Sum).Sum }
            [pscustomobject]@{ Name = $name; Path = $f.FullName; Size = [long]$size; Split = $split; Modified = $f.LastWriteTime }
        }
    }
}

# Opens a Backup and checks every file in it. Result: ok, wrong-password, password-needed,
# missing, or damaged (with 7-Zip's words in Message).
function Test-Backup {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [securestring]$Password,
        [string]$SevenZip
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Result = 'missing'; Message = "No file at $Path" } }
    if (-not $SevenZip) { $SevenZip = Get-SevenZip }
    $r = Invoke-SevenZip -SevenZip $SevenZip -Arguments @('t', '-sccUTF-8', '-bd', $Path) -Password $Password
    $result = if ($r.ExitCode -eq 0) { 'ok' }
        elseif ($r.Output -match 'Wrong password') { if ($Password) { 'wrong-password' } else { 'password-needed' } }
        elseif ($r.Output -match 'Break signaled|Enter password') { 'password-needed' }
        else { 'damaged' }
    return [pscustomobject]@{ Result = $result; Message = ($r.Output.Trim() -split "`r?`n" | Select-Object -Last 3) -join ' ' }
}
