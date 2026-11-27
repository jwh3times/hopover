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
