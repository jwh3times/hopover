### Changed

- CI runs the `restore_linux.py` unit tests on Python 3.15, the newest release, instead of 3.9,
  which Dependabot no longer supports: its `uv` updates for ruff and shellcheck failed on 3.9. The
  script itself still runs on Python 3.8 and up, which ruff's `py38` target checks.
