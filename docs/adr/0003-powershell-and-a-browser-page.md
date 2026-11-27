---
status: accepted
---

# PowerShell and a browser page, not a packaged app

Hopover's interface is the browser page in `ui/index.html`. On Windows a small server in Windows
PowerShell 5.1 serves it; on Linux a server in Python's standard library serves the same page, and
both implement one API. The user starts Hopover by double-clicking `Hopover.cmd` on Windows, or by
pasting one `bash` line on Linux, since a file manager can't be counted on to run a script from a
USB drive. A fresh Windows install has PowerShell 5.1 and a browser and nothing else, and
`Show-RestorePlan.ps1` already proved the pattern.

## Considered options

- **A packaged app** (.NET, Tauri or Electron): it needs code signing to get past SmartScreen, a
  runtime or a build per OS, and a second interface to keep in step with the scripts.
- **The scripts in a console** (the old design): about twenty typed commands, two kinds of prompt,
  and results that only exist in console output.

## Consequences

- The page runs as the normal user, so restored files belong to the user rather than
  Administrators. Work that needs administrator rights runs in one elevated helper per Back up or
  Restore, behind a single UAC prompt.
- Work runs in the background. Closing the tab doesn't stop it, opening Hopover again reconnects to
  it, and only Hopover's own window or a confirmed Stop ends it.
- The page and both servers share one API contract, and changing it means changing all of them, as
  plan keys already have to change together in `Show-RestorePlan.ps1`, `Restore.ps1` and
  `restore_linux.py`.
