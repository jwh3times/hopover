<#
    Invoke-AdminSteps.ps1
    The elevated helper: runs the steps of a job that need administrator rights, so the job asks
    for them once (lib\Jobs.ps1's Invoke-AdminHelper starts it through the administrator prompt).
    The job itself, and every other step, runs as the user who started it, so what they write
    belongs to that user. You don't run this yourself: New-Backup.ps1 does.

    Each step runs in a process of its own, in a kill-on-close job object, and writes its progress
    events to the job's event log like the job's own steps. What a step prints goes to -LogFile as
    well as this window, which closes when the helper ends. The helper ends, and its steps with
    it, when the job's process (-JobPid) ends: a stopped job, or Hopover's window closed.

    Options:
        -Steps a,b       the steps to run: drivers
        -DataDir         the job's data folder
        -StagingDir      the job's staging folder; each step's files go in a folder of its name,
                         which tells the job the step ran
        -OptionsFile     the user's options file, read instead of this account's own
        -EventLog        the job's event log (lib\Jobs.ps1)
        -LogFile         where to keep what the steps print
        -JobPid          the job's process

    It exits 0 when every step went well, and 1 when one reported a problem.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string[]]$Steps,
    [Parameter(Mandatory)][string]$DataDir,
    [Parameter(Mandatory)][string]$StagingDir,
    [string]$OptionsFile,
    [string]$EventLog,
    [string]$LogFile,
    [int]$JobPid
)

$ErrorActionPreference = 'Stop'
# Its window closes as it ends, so why it failed goes to the log. The job finds the steps it didn't
# get to by their missing folders, and says so.
trap {
    if ($LogFile) { [IO.File]::AppendAllText($LogFile, "The administrator helper failed: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)`r`n") }
    exit 1
}
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptDir 'lib\Common.ps1')
. (Join-Path $scriptDir 'lib\Backup.ps1')
. (Join-Path $scriptDir 'lib\Jobs.ps1')

function Send-Event { if ($EventLog) { Add-JobEvent -Path $EventLog @args } }
# The job may have ended while the administrator prompt was open, and with it the job's records.
function Test-JobEnded { $JobPid -and -not (Get-Process -Id $JobPid -ErrorAction SilentlyContinue) }
Use-UserOptions $OptionsFile

# Each step: its script and that script's parameters.
$runs = @{
    drivers = @{ Script = 'Save-Drivers.ps1'; Arguments = @('-DataDir', $DataDir, '-Destination', (Join-Path $StagingDir 'drivers')) }
}
$list = @(Split-List $Steps | ForEach-Object { $_.ToLower() })
$unknown = @($list | Where-Object { -not $runs.ContainsKey($_) })
if ($unknown.Count) { throw "Unknown administrator step(s): $($unknown -join ', ')." }

$failed = 0
foreach ($step in $list) {
    if (Test-JobEnded) { exit 1 }
    Write-Host ''
    Write-Host "== $step (with administrator rights)" -ForegroundColor Cyan
    Send-Event -Type 'step-started' -Step $step
    $run = Start-StepProcess (Join-Path $scriptDir $runs[$step].Script) $runs[$step].Arguments $LogFile
    # Nothing waits for the step once the job has ended.
    $exit = Wait-StepProcess $run { Test-JobEnded }
    if ($null -eq $exit) { exit 1 }
    if ($exit) {
        $failed++
        $details = @{ exitCode = $exit }
        if ($LogFile) { $details.log = $LogFile }
        Send-Event -Type 'message' -Step $step -Code 'step-problem' -Details $details
    }
    Send-Event -Type 'step-finished' -Step $step -Ok (-not $exit)
}
exit [int]($failed -gt 0)
