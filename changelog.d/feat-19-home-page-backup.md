### Added

- Double-click `Hopover.cmd` to open Hopover's page in your browser, with **Back up**, **Check
  I'm ready** and **Restore**. It starts Windows PowerShell 5.1 with the script execution policy
  bypassed for that run, so a downloaded copy works on a fresh install, in a minimized window
  titled "Hopover is running — close this to stop". **Check I'm ready** and **Restore** say which
  script to run until they arrive on the page.
- **Back up** on the page makes a Backup: give it a name, a password typed twice (**Show** shows
  it, **Suggest one** makes one of four random words) and where to save it, typed or chosen in
  Windows' folder dialog. It runs the same `New-Backup.ps1` as the command line, so it makes the
  same Backup, and the page shows each step as it goes. A password under 8 characters, two that
  differ, a name Windows keeps for a device (such as `CON`), a folder that isn't a whole path or
  isn't there, and a name already used there are refused in plain words. Drivers, which need
  administrator rights, are left out with a note for now.
- A Back up runs in the background. Closing the browser tab doesn't stop it, and opening Hopover
  again shows how it's going. Only closing Hopover's window, or **Stop…** confirmed on the page,
  ends it; either way its unencrypted working copy is removed, and so is the half-made Backup
  unless it had finished packing.
- Only one Hopover runs at a time: starting it again opens the page of the one already running,
  even while that one is busy.
- `New-Backup.ps1 -EventLog <file>` also writes its progress as JSON events, one per line, which is
  how the page follows it.

### Changed

- The page is served the way the restore plan page was (on `http://localhost` only, with a
  per-run token and a policy that lets the page reach nothing but Hopover), and Hopover's page
  takes the token from the address Hopover opens rather than carrying it, so another user signed
  in to the same PC can't use it. `Show-RestorePlan.ps1` now shares that server code.
