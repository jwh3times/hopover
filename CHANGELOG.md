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
