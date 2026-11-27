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
