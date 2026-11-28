### Added

- A Back up from the page now includes the drivers: Windows asks once, as the Back up starts, for
  administrator rights, and only the drivers export runs with them, in a separate helper
  (`Invoke-AdminSteps.ps1`). Every other step still runs as you, so the files it writes belong to
  you. The helper's steps show on the page like the others, and it stops when the job does. The
  restore plan's Drivers view lists the devices of a Backup's drivers however they were saved.
- Choosing No at that prompt still makes the Backup, without the drivers, and the page says what
  was left out and how to include it. When the helper stops before it saves the drivers, the page
  says so and names the log, `admin-steps.log` in the job's folder, that holds what it printed.
- The `HOPOVER_OPTIONS` environment variable names the options file to read instead of the
  account's own, on Windows and on Linux. The helper uses it to read your Options rather than
  those of the account that approved the prompt.

### Changed

- `New-Backup.ps1` run from a prompt without administrator rights now asks for them for the
  drivers, instead of leaving the drivers out. From an elevated prompt it asks nothing.
