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
