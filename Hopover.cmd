@echo off
rem Hopover: double-click to open its page in your browser.
rem Starts Windows PowerShell 5.1, which every Windows has, with this run's script execution
rem policy set to Bypass (so a downloaded copy runs whatever the PC's policy is), in a minimized
rem window titled "Hopover is running - close this to stop". Arguments are passed on to
rem Hopover.ps1 (for example -NoBrowser).
start "Hopover" /min "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Hopover.ps1" %*
