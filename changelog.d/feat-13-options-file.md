### Added

- Hopover reads its options from a per-user `options.json` as well:
  `%LOCALAPPDATA%\Hopover\options.json` on Windows, and `~/.config/hopover/options.json` (or under
  `$XDG_CONFIG_HOME`) on Linux. Each script starts from the defaults, applies the data folder's
  `config.json`, then `options.json` over it key by key, and its own parameters still win. Until a
  Backup carries your options, keep them in the data folder's `config.json`, which survives the
  reinstall with it.
- A `wipedDrives` option lists the drives the reinstall will erase; the Windows drive always
  counts. Nothing reads it yet: the coming Ready check will.
- `GLOSSARY.md` holds Hopover's terms, and ADRs 0002 and 0003 record the decisions behind the
  coming one-click Backup: a single encrypted `.7z` made with a bundled 7-Zip, and PowerShell with
  a browser page instead of a packaged app.

### Changed

- Messages that asked you to set an option in `config.json` now name the file to edit:
  `options.json` when it exists, else the data folder's `config.json`. `Test-WipeReady.ps1`'s
  check for a missing file is now called "Options".
- Keys starting with `$` or `_` are now skipped inside sections such as `linux` on Windows too, as
  the Linux restore already did.
