### Added

- Every merge to `main` is now a numbered release with a GitHub Release, release notes from this
  changelog, and `hopover-<version>.zip`: the scripts, catalogs and docs without the development
  files, for running Hopover without cloning the repository.
- CI checks every pull request: the Windows scripts parse, pass PSScriptAnalyzer and Pester in both
  Windows PowerShell 5.1 and PowerShell 7, and `restore_linux.py` and `restore-linux.sh` pass
  ruff, shellcheck and their unit tests.

### Changed

- `restore_linux.py` is formatted with ruff, with no change in what it does.
