# A stand-in for Invoke-AdminSteps.ps1, the elevated helper, in the page API tests: the same
# parameters, started without the administrator prompt. It acts as though another administrator
# approved the prompt: its LOCALAPPDATA is that account's, which holds Options of its own. It takes
# the user's Options the way the helper does, then reports what it was given as one event,
# { type: 'message', code: 'helper-given', details: { steps, devRoot } }, devRoot being the Option
# it read. For each step it sends step-started and step-finished and leaves a README.md in that
# step's folder of the staging copy, where the real helper's step puts its files.
# HOPOVER_STUB_HELPER=declines stands for a declined prompt: it does nothing and exits with 1223
# (ERROR_CANCELLED), the error Windows gives for one. HOPOVER_STUB_HELPER=fails stands for a
# helper that failed before its first step: it does nothing and exits with 1.

[CmdletBinding(PositionalBinding = $false)]
param(
    [string[]]$Steps,
    [string]$DataDir,
    [string]$StagingDir,
    [string]$OptionsFile,
    [string]$EventLog,
    [string]$LogFile,
    [int]$JobPid
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'lib\Common.ps1')
. (Join-Path $root 'lib\Backup.ps1')
. (Join-Path $root 'lib\Jobs.ps1')

if ($env:HOPOVER_STUB_HELPER -eq 'declines') { exit 1223 }
if ($env:HOPOVER_STUB_HELPER -eq 'fails') { exit 1 }

# Beside the job's event log, so it isn't packed into the Backup.
$env:LOCALAPPDATA = Join-Path (Split-Path -Parent $EventLog) 'another-administrator'
New-Item -ItemType Directory -Path (Join-Path $env:LOCALAPPDATA 'Hopover') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $env:LOCALAPPDATA 'Hopover\options.json'), '{ "devRoot": "C:\\another-administrator" }', $Utf8)
Use-UserOptions $OptionsFile

$list = @(Split-List $Steps)
foreach ($step in $list) {
    Add-JobEvent -Path $EventLog -Type 'step-started' -Step $step
    if ($step -eq $list[0]) {
        Add-JobEvent -Path $EventLog -Type 'message' -Code 'helper-given' -Details @{ steps = $list; devRoot = (Get-Options $DataDir)['devRoot'] }
    }
    New-Item -ItemType Directory -Path (Join-Path $StagingDir $step) -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $StagingDir "$step\README.md"), "What the $step step saved.", $Utf8)
    Add-JobEvent -Path $EventLog -Type 'step-finished' -Step $step -Ok $true
}
