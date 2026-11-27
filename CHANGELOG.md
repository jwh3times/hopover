# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) via the
`v<major>.<minor>.<build>` tags minted by `.github/workflows/release.yml`. Branches never edit this
file: each writes its entries to `changelog.d/`, and the workflow stamps them into the section for
the version its merge mints.

_`v0.0.0` marks the last commit before this changelog and has no section._

## [Unreleased]

No unreleased changes.

## [0.5.0] - 2026-11-27

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

## [0.4.1] - 2026-11-27

### Changed

- The README now says `Restore.ps1 -Backup` restores with the Options the Backup carries. Keeping
  them in the data folder's `config.json` is needed only to restore without a Backup.

## [0.4.0] - 2026-11-27

### Added

- `Restore.ps1 -Backup "<file>.hopover.7z"` restores straight from a Backup on Windows. It checks
  the Backup before unpacking anything, and asks for the password only when the Backup is
  encrypted (or reads it from a pipe). A wrong password, or a Backup made by a newer Hopover, stops
  it in plain words before any step runs and with nothing unpacked.
- The Backup is unpacked to `%LOCALAPPDATA%\Hopover\restore\<name>`, and the restore runs from
  that copy. Later runs of the same account reuse it, the elevated and normal passes included. A
  different Backup with the same name, or a copy an earlier run left half-done, is unpacked
  afresh. Hopover only ever replaces a folder there that it unpacked itself.
- The unpacked copy holds the Backup's files unencrypted, passwords and keys included, so a real
  run ends by saying where it is and to delete it once the restore is finished. `-DryRun` with no
  copy to reuse unpacks to a temporary folder and removes it at the end, so a dry run leaves
  nothing behind.
- `-Backup` can't be combined with `-DataDir` or `-MigrationRoot`, since the Backup holds the data
  folder.

### Fixed

- A password piped into `New-Backup.ps1` running in PowerShell 7 no longer starts with the
  invisible byte-order mark Windows PowerShell 5.1 puts in front of text it pipes on a UTF-8
  console, so the Backup opens with the password you piped rather than one with a hidden character
  in front.

## [0.3.0] - 2026-11-27

### Added

- `New-Backup.ps1` makes a Backup: one file, `<name>.hopover.7z`, that holds what the capture
  scripts collect (the app catalog and winget export, the settings export, the extras, and the
  drivers when run elevated), the options it was made with, and your `restore-plan.json` and
  `NOTES.md`. It's encrypted by default (AES-256, with the file names hidden too), with a password
  you type twice or pipe in; a forgotten password can't be recovered. `-NoEncryption` makes one
  anyone can open, which leaves out the extras that hold passwords and keys (`.env` files and
  `.ssh`). Your data folder is only read, and the staging copy is removed afterwards. Restoring
  straight from a Backup comes in a later release.
- Each Backup carries a `hopover.json` recording its format version, the Hopover version that made
  it, when and on which PC, whether it's encrypted and holds passwords and keys, and every app by
  its catalog key with its winget or Chocolatey id.
- Backups are made with 7-Zip's `7zr.exe`, pinned by version and SHA-256 in `lib\7zip.json`. It's
  downloaded to `%LOCALAPPDATA%\Hopover\bin` on first use, and a file whose hash differs is
  refused. The password reaches 7-Zip only on its standard input, never a command line, and any
  7-Zip opens a Backup given its password.
- The release zip records its own version (`lib\version.txt`), so a Backup made from it says which
  Hopover made it.

## [0.2.6] - 2026-11-26

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

## [0.2.5] - 2026-11-26

### Changed

- The Dependabot review notes in `docs/agents/dependabot.md` record that `uv` updates run on
  Python 3.15: the first run after the pin moved from 3.9 succeeded on 2026-11-25. They also say
  that a successful run that opens no PR means no update was due.

## [0.2.4] - 2026-11-25

### Changed

- Take the latest shared skills and scripts from `jwh3times/skills` (#8)

## [0.2.3] - 2026-11-25

### Changed

- CI and the release workflow run on Node 26, the newest release, instead of 22. The agent and
  release scripts in `scripts/` still run on Node 22 and later.

## [0.2.2] - 2026-11-25

### Changed

- Take the latest shared skills and scripts from `jwh3times/skills` (#6)

## [0.2.1] - 2026-11-24

### Changed

- Take the latest shared skills and scripts from `jwh3times/skills` (#5)

## [0.2.0] - 2026-11-24

### Changed

- The Linux restore needs Python 3.10 or newer, up from 3.8. Ubuntu 22.04, Debian 12, Fedora 35 and
  later releases ship it; on an older `python3`, `restore-linux.sh` now stops with a message naming
  the version it found, before anything runs.
- CI runs the `restore_linux.py` unit tests on Python 3.10 as well as 3.15, so the floor is tested,
  not only checked for syntax.

## [0.1.1] - 2026-11-24

### Changed

- CI runs the `restore_linux.py` unit tests on Python 3.15, the newest release, instead of 3.9,
  which Dependabot no longer supports: its `uv` updates for ruff and shellcheck failed on 3.9. The
  script itself still runs on Python 3.8 and up, which ruff's `py38` target checks.

## [0.1.0] - 2026-11-24

### Added

- Every merge to `main` is now a numbered release with a GitHub Release, release notes from this
  changelog, and `hopover-<version>.zip`: the scripts, catalogs and docs without the development
  files, for running Hopover without cloning the repository.
- CI checks every pull request: the Windows scripts parse, pass PSScriptAnalyzer and Pester in both
  Windows PowerShell 5.1 and PowerShell 7, and `restore_linux.py` and `restore-linux.sh` pass
  ruff, shellcheck and their unit tests.

### Changed

- `restore_linux.py` is formatted with ruff, with no change in what it does.
