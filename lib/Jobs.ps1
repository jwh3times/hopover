# Jobs: a Back up (and later a Restore or a Ready check) runs as a job in a child process, never in
# the server's request handling. The job appends progress events, one JSON object per line, to its
# events.jsonl; the server reads that file, so a page opened again reconnects by reading it again.
#
#   %LOCALAPPDATA%\Hopover\jobs\<id>\job.json       what was asked: kind, name, destination, started
#                                    events.jsonl   the events, in order (an event's index is its line)
#                                    staging\       the job's working copy, removed when it ends
#
# An event is { type, time, step?, code?, details?, percent?, ok? }. Types: job-started,
# step-started, step-finished, item, percent, message, job-finished. Codes name a message in the
# page's string table; details fill it in.

function Get-HopoverHome { Split-Path -Parent (Get-OptionsPath) }
function Get-JobsRoot { Join-Path (Get-HopoverHome) 'jobs' }
$JobIdPattern = '^\d{8}-\d{6}-[0-9a-f]{6}$'

# Appends one event. The job and the server both write to the file, so each event is one append.
# A job killed part-way through writing leaves a line without its end: the next event starts on a
# line of its own, and readers skip the broken one.
function Add-JobEvent {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Type,
        [string]$Step,
        [string]$Code,
        $Details,
        [int]$Percent = -1,
        $Ok
    )
    $e = [ordered]@{ type = $Type; time = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
    if ($Step) { $e.step = $Step }
    if ($Code) { $e.code = $Code }
    if ($null -ne $Details) { $e.details = $Details }
    if ($Percent -ge 0) { $e.percent = $Percent }
    if ($null -ne $Ok) { $e.ok = [bool]$Ok }
    $line = (ConvertTo-Json -InputObject $e -Depth 6 -Compress) + "`n"
    for ($try = 0; ; $try++) {
        try {
            $fs = New-Object System.IO.FileStream($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
            try {
                $text = $line
                if ($fs.Length -gt 0) {
                    [void]$fs.Seek(-1, [IO.SeekOrigin]::End)
                    if ($fs.ReadByte() -ne 10) { $text = "`n" + $line }
                }
                [void]$fs.Seek(0, [IO.SeekOrigin]::End)
                $bytes = $Utf8.GetBytes($text)
                $fs.Write($bytes, 0, $bytes.Length)
            } finally { $fs.Close() }
            return
        } catch [System.IO.IOException] {
            if ($try -ge 40) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
}

# The events from line $Since on: Raw holds each one's JSON text as written, Events the same
# parsed, and Next the line to ask for next time. A last line without its newline is still being
# written, so it waits for the next read; a line that isn't an event (one a killed job left
# unfinished) is skipped.
function Read-JobEvents([string]$Path, [int]$Since = 0) {
    $raw = @(); $events = @()
    $next = $Since
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $fs = New-Object System.IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $text = (New-Object System.IO.StreamReader($fs, $Utf8)).ReadToEnd() } finally { $fs.Close() }
        $lines = $text.Split("`n")
        $complete = $lines.Count - 1
        for ($i = [math]::Max(0, $Since); $i -lt $complete; $i++) {
            $l = $lines[$i].TrimEnd("`r")
            try { $e = $l | ConvertFrom-Json } catch { continue }
            if ($e -isnot [System.Management.Automation.PSCustomObject] -or -not $e.type) { continue }
            $raw += $l; $events += $e
        }
        $next = [math]::Max($Since, $complete)
    }
    [pscustomobject]@{ Raw = $raw; Events = $events; Next = $next }
}

# What a job was asked to do (kind, name, destination, started), or $null when that record can't
# be read.
function Read-Job([string]$Dir) {
    try { $job = Get-Content -LiteralPath (Join-Path $Dir 'job.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return $null }
    if ($job -isnot [System.Management.Automation.PSCustomObject] -or $job.id -notmatch $JobIdPattern) { return $null }
    return $job
}
function Get-JobEventsPath([string]$Dir) { Join-Path $Dir 'events.jsonl' }

# A job's status from its events: running until a job-finished event says how it ended.
function Get-JobStatusFromEvents($Events) {
    $end = @($Events | Where-Object { $_.type -eq 'job-finished' }) | Select-Object -Last 1
    if (-not $end) { return 'running' }
    if ($end.ok) { return 'finished' }
    if ($end.code -eq 'job-stopped') { return 'stopped' }
    return 'failed'
}

function New-JobId { "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0, 6))" }

function Get-JobDir([string]$Id) {
    if ($Id -notmatch $JobIdPattern) { return $null }
    $dir = Join-Path (Get-JobsRoot) $Id
    if (Read-Job $dir) { return $dir }
    return $null
}

# Every job's folder whose record can be read, newest first.
function Get-JobDirs {
    $root = Get-JobsRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -match $JobIdPattern -and (Read-Job $_.FullName) } |
        Sort-Object Name -Descending | ForEach-Object FullName)
}

# Removes a job's staging folder: New-Backup.ps1 removes what it made inside it, and whatever a job
# that was ended left there is an unencrypted copy of everything.
function Remove-JobStaging([string]$Dir) {
    $staging = Join-Path $Dir 'staging'
    for ($try = 0; $try -lt 20 -and (Test-Path -LiteralPath $staging); $try++) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $staging) { Start-Sleep -Milliseconds 250 }
    }
}

# Records how a job that ended without saying so ended ($Code, a job-finished message), and clears
# what it left behind: its staging folder (an unencrypted copy of everything) and, for a Back up
# that hadn't finished packing, the pieces of the Backup it was writing. The Backup's name was
# checked to be free when the job started, so any file of that name is the job's own; once packing
# finished the Backup is whole, and is kept. Does nothing for a job that already said how it ended,
# and says whether it recorded the end.
function Close-EndedJob([string]$Dir, [string]$Code, $Details) {
    $job = Read-Job $Dir
    $events = Get-JobEventsPath $Dir
    $read = Read-JobEvents $events
    if (@($read.Events | Where-Object { $_.type -eq 'job-finished' }).Count) { return $false }
    Remove-JobStaging $Dir
    $packed = @($read.Events | Where-Object { $_.type -eq 'step-finished' -and $_.step -eq 'pack' -and $_.ok }).Count
    if ($job.kind -eq 'backup' -and -not $packed -and $job.destination -and $job.name -and (Test-Path -LiteralPath $job.destination)) {
        # FullName: in Windows PowerShell 5.1 a file from Get-ChildItem turns into its bare name.
        foreach ($f in @(Get-BackupFiles $job.destination $job.name)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    }
    Add-JobEvent -Path $events -Type 'job-finished' -Ok $false -Code $Code -Details $Details
    return $true
}

# A kill-on-close Windows job object. Every process in it, and every process those start, ends
# when the server holding the handle ends: closing Hopover's window stops the job, 7-Zip included,
# which runs in a console of its own.
function Initialize-JobObjectType {
    if ('Hopover.JobObject' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Hopover {
    public static class JobObject {
        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimits {
            public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
            public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters { public ulong R, W, O, RB, WB, OB; }
        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimits {
            public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        public static IntPtr Create() {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) throw new Win32Exception();
            ExtendedLimits limits = new ExtendedLimits();
            limits.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            int size = Marshal.SizeOf(typeof(ExtendedLimits));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(limits, buffer, false);
                if (!SetInformationJobObject(job, 9, buffer, (uint)size)) throw new Win32Exception();
            } finally { Marshal.FreeHGlobal(buffer); }
            return job;
        }
        public static void Assign(IntPtr job, IntPtr process) { if (!AssignProcessToJobObject(job, process)) throw new Win32Exception(); }
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);
        public static void Terminate(IntPtr job) { TerminateJobObject(job, 1); }
        // Closing the last handle ends whatever is still in the job: close it once they've exited.
        public static void Close(IntPtr job) { CloseHandle(job); }
    }
}
'@
}

# Starts a job's script in the same PowerShell, its password (if any) on standard input and never
# on the command line, in a kill-on-close job object. Its console output goes to Hopover's window.
# The script is in the job object before it reads its password, so before it starts anything.
# How to run one of Hopover's scripts in the same PowerShell as this one.
function New-ScriptStartInfo([string]$ScriptPath, [string[]]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.Arguments = Join-ProcessArguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($Arguments))
    $psi
}

function Start-JobProcess([string]$ScriptPath, [string[]]$Arguments, [securestring]$Password) {
    Initialize-JobObjectType
    $psi = New-ScriptStartInfo $ScriptPath $Arguments
    $psi.CreateNoWindow = $false
    $handle = [Hopover.JobObject]::Create()
    $p = Start-InputProcess $psi
    try { [Hopover.JobObject]::Assign($handle, $p.Handle) }
    catch { try { $p.Kill() } catch { }; [Hopover.JobObject]::Close($handle); throw }
    Send-ProcessPassword $p $Password
    [pscustomobject]@{ Process = $p; Handle = $handle }
}

# ---------------------------------------------------------------------------
# Administrator rights: a job runs as the user who started it, so what it writes belongs to them.
# The steps that need administrator rights run in one elevated helper, Invoke-AdminSteps.ps1,
# started through the administrator prompt (UAC) once per job. It writes to the job's event log.
# ---------------------------------------------------------------------------

# The steps of each kind of job that need administrator rights.
$JobAdminSteps = @{ backup = @('drivers') }

# Points this process, and every process it starts, at the user's options file. The helper runs as
# whoever approved the administrator prompt, possibly another account with Options of its own, so
# it is handed the user's file and reads only that.
function Use-UserOptions([string]$OptionsFile) { if ($OptionsFile) { $env:HOPOVER_OPTIONS = $OptionsFile } }

# Runs $Steps in the elevated helper, and waits for it. The helper puts each step's files in
# $StagingDir, reads the user's Options and the data folder $DataDir, and ends if this process
# does (a stopped job). Its window closes when it ends, so it writes what its steps printed to Log
# too: beside the job's event log, or in this user's TEMP. $AdminHelper, for tests, is a script
# run in its place without the prompt. Ran is false when the prompt was declined (or the helper
# couldn't start: Reason says why). Ran says the helper ran, not that its steps did: Done lists the
# steps whose folder it left in $StagingDir.
function Invoke-AdminHelper {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Mandatory)][string[]]$Steps,
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$StagingDir,
        [string]$EventLog,
        [string]$AdminHelper
    )
    $helperScript = if ($AdminHelper) { $AdminHelper } else { Join-Path $ToolRoot 'Invoke-AdminSteps.ps1' }
    $log = if ($EventLog) { Join-Path (Split-Path -Parent $EventLog) 'admin-steps.log' } else { Join-Path $env:TEMP "hopover-admin-steps-$(Get-Date -Format 'yyyyMMdd-HHmmss').log" }
    $arguments = @('-Steps', ($Steps -join ','), '-DataDir', $DataDir, '-StagingDir', $StagingDir,
        '-OptionsFile', (Get-OptionsPath), '-JobPid', $PID, '-LogFile', $log)
    if ($EventLog) { $arguments += @('-EventLog', $EventLog) }
    $psi = New-ScriptStartInfo $helperScript $arguments
    if ($AdminHelper) {
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
    } else {
        $psi.UseShellExecute = $true
        $psi.Verb = 'runas'
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
    }
    # 1223 (ERROR_CANCELLED) is what Windows gives when the prompt is declined.
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch {
        $e = $_.Exception.GetBaseException()
        $reason = if ($e -is [System.ComponentModel.Win32Exception] -and $e.NativeErrorCode -eq 1223) { '' } else { $e.Message }
        return [pscustomobject]@{ Ran = $false; ExitCode = $null; Reason = $reason; Log = $null; Done = @() }
    }
    try {
        $p.WaitForExit()
        $exit = $p.ExitCode
    } finally { $p.Dispose() }
    # The tests' stand-in declines the prompt by exiting with the same error.
    if ($exit -eq 1223) { return [pscustomobject]@{ Ran = $false; ExitCode = $exit; Reason = ''; Log = $null; Done = @() } }
    $done = @($Steps | Where-Object { Test-Path -LiteralPath (Join-Path $StagingDir $_) -PathType Container })
    [pscustomobject]@{ Ran = $true; ExitCode = $exit; Reason = ''; Log = $log; Done = $done }
}

# Runs a step's script in a process of its own, in a kill-on-close job object, with what it prints
# going to $LogFile as well as this window once it ends. Returns the running step: Wait-StepProcess
# waits for it.
function Start-StepProcess([string]$ScriptPath, [string[]]$Arguments, [string]$LogFile) {
    Initialize-JobObjectType
    $psi = New-ScriptStartInfo $ScriptPath $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $handle = [Hopover.JobObject]::Create()
    $p = [System.Diagnostics.Process]::Start($psi)
    try { [Hopover.JobObject]::Assign($handle, $p.Handle) }
    catch { try { $p.Kill() } catch { }; [Hopover.JobObject]::Close($handle); throw }
    [pscustomobject]@{ Process = $p; Handle = $handle; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync(); Log = $LogFile }
}

# Waits for a step started by Start-StepProcess, ending it early when & $Abandon says to. Returns
# its exit code, or $null when it was ended. Either way, what it printed is shown and logged.
function Wait-StepProcess($Step, [scriptblock]$Abandon) {
    while (-not $Step.Process.WaitForExit(500)) {
        if (& $Abandon) { Stop-JobProcess $Step; return $null }
    }
    if ($Step.Out.Wait(10000) -and $Step.Err.Wait(10000)) {
        $text = $Step.Out.Result + $Step.Err.Result
        if ($text) { Write-Host $text.TrimEnd() }
        if ($Step.Log) { [IO.File]::AppendAllText($Step.Log, $text, $Utf8) }
    }
    $exit = $Step.Process.ExitCode
    Close-JobProcess $Step
    return $exit
}

# Ends a job's processes, all of them, and waits for its own to exit.
function Stop-JobProcess($Running) {
    [Hopover.JobObject]::Terminate($Running.Handle)
    try { [void]$Running.Process.WaitForExit(10000) } catch { }
    [Hopover.JobObject]::Close($Running.Handle)
}

# Lets go of a job whose process has exited.
function Close-JobProcess($Running) { [Hopover.JobObject]::Close($Running.Handle) }
