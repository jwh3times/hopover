### Changed

- The Linux restore needs Python 3.10 or newer, up from 3.8. Ubuntu 22.04, Debian 12, Fedora 35 and
  later releases ship it; on an older `python3`, `restore-linux.sh` now stops with a message naming
  the version it found, before anything runs.
- CI runs the `restore_linux.py` unit tests on Python 3.10 as well as 3.15, so the floor is tested,
  not only checked for syntax.
