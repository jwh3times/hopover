# A stand-in for New-Backup.ps1 in the page API tests: the same parameters and the password on
# standard input, with events written the way New-Backup.ps1 writes them. HOPOVER_STUB says what
# it does: "finishes" makes a pretend Backup file and ends; "waits" leaves a staging file and a
# part-written Backup behind, then waits to be stopped; "packed" finishes the Backup but waits
# before saying so; "torn" leaves an event line half written; "slow" writes one in two halves,
# seconds apart. Each records what it was given in
# received.json beside its event log, so tests can see the password came on standard input only.

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Destination,
    [string]$Name,
    [switch]$NoEncryption,
    [string[]]$Steps = @('all'),
    [int]$SplitMB = 0,
    [string]$StagingDir,
    [string]$DataDir,
    [string]$EventLog
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'lib\Common.ps1')
. (Join-Path $root 'lib\Jobs.ps1')

$line = [Console]::In.ReadLine()
$received = [ordered]@{ commandLine = [Environment]::CommandLine; stdin = $line; steps = @($Steps) }
[IO.File]::WriteAllText((Join-Path (Split-Path -Parent $EventLog) 'received.json'), (ConvertTo-Json -InputObject $received), $Utf8)

if ($env:HOPOVER_STUB -eq 'waits') {
    # Left behind before the step says it started: tests wait for that event, then look for these.
    New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $StagingDir 'unencrypted.txt') -Value 'a copy of everything' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Destination "$Name.hopover.7z") -Value 'half written' -Encoding ASCII
}
Add-JobEvent -Path $EventLog -Type 'step-started' -Step 'catalog'
if ($env:HOPOVER_STUB -eq 'packed') {
    # The Backup is complete, but the job hasn't said it finished yet.
    Set-Content -LiteralPath (Join-Path $Destination "$Name.hopover.7z") -Value 'a whole Backup' -Encoding ASCII
    Add-JobEvent -Path $EventLog -Type 'step-finished' -Step 'pack' -Ok $true
    while ($true) { Start-Sleep -Milliseconds 200 }
}
if ($env:HOPOVER_STUB -eq 'slow') {
    # Writes an event in two halves, seconds apart, as a busy disk might.
    [IO.File]::AppendAllText($EventLog, '{"type":"message","code":"only-', $Utf8)
    Start-Sleep -Seconds 3
    [IO.File]::AppendAllText($EventLog, "some-steps`"}`n", $Utf8)
    while ($true) { Start-Sleep -Milliseconds 200 }
}
if ($env:HOPOVER_STUB -eq 'torn') {
    # Ended part-way through writing an event: the line has no end.
    [IO.File]::AppendAllText($EventLog, '{"type":"message","code":"half', $Utf8)
    while ($true) { Start-Sleep -Milliseconds 200 }
}
if ($env:HOPOVER_STUB -eq 'waits') {
    while ($true) { Start-Sleep -Milliseconds 200 }
}
Add-JobEvent -Path $EventLog -Type 'step-finished' -Step 'catalog' -Ok $true
Add-JobEvent -Path $EventLog -Type 'percent' -Percent 50
$file = Join-Path $Destination "$Name.hopover.7z"
Set-Content -LiteralPath $file -Value 'a pretend Backup' -Encoding ASCII
Add-JobEvent -Path $EventLog -Type 'item' -Code 'backup-file' -Details @{ path = $file; bytes = (Get-Item -LiteralPath $file).Length }
Add-JobEvent -Path $EventLog -Type 'percent' -Percent 100
Add-JobEvent -Path $EventLog -Type 'job-finished' -Ok $true -Code 'backup-made' -Details @{ path = $file; bytes = (Get-Item -LiteralPath $file).Length; pieces = 1; encrypted = $true }
