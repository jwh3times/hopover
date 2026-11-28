### Added

- Restore a Windows Backup on Linux: `linux/restore-linux.sh --backup <file>.hopover.7z` (or a
  split one's `.001`). Each run asks once for the password of an encrypted Backup, or reads it
  from standard input when a program pipes it in, and the password reaches 7-Zip only on its
  standard input. A wrong password, or a Backup made by a newer Hopover, stops the restore before
  anything is unpacked. The Backup is unpacked to `~/.local/share/hopover/restore/<Backup name>`,
  readable only by you, and the restore runs from there with the plan and Options the Backup
  carries. A rerun reuses that copy, and the restore says how to delete it once you're done.
  `--dry-run` unpacks to a temporary folder and removes it at the end.
- `restore-linux.sh --backup` installs 7-Zip when it's missing: the distro's `7zip` package, or
  `p7zip` where there is none (Fedora 41 and 42). It uses whichever of `7z`, `7zz` (Ubuntu 22.04,
  Debian 12) and `7za` is installed, including when a password has accented or non-Latin letters.
- `linux/backup.py`, the Backup module on Linux, finds, tests and unpacks Backups, and runs on its
  own too (`python3 linux/backup.py find|test|unpack`).

### Changed

- For contributors, `linux/tests/Test-LinuxRestore.ps1` restores a fixture Backup it makes with
  the Backup module, on Ubuntu 22.04 and Debian 12 as well as the newest of each distro; `-Backup`
  restores one of yours, and `-DataDir` a data folder. A new test opens a Backup made by the
  PowerShell module with the Python one, so `tests/Invoke-PowerShellChecks.ps1` now needs `uv`, and
  CI's Linux runner installs `7zip` for the Python module's tests.
