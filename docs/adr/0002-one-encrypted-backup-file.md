---
status: accepted
---

# One encrypted Backup file, made with a bundled 7-Zip

Hopover's output is one file, the Backup: a `.7z` archive, AES-256 with encrypted headers, that the
user names and keeps anywhere, on a drive or in the cloud. It holds everything a restore needs (the
exports, the app data and other extras, the drivers, the user's own files and a `hopover.json`
manifest), so nothing else has to survive the wipe. It replaces the earlier pair of a data folder in
a private git repo and a `migrationRoot` folder on a drive the user had to name. Hopover is meant for
anyone, and a non-technical user can't be asked to run git and GitHub, edit a drive letter into
JSON, or keep two things safe instead of one.

## Considered options

- **Data folder in git plus a migration drive** (the old design): it needs git, a GitHub account and
  `gh auth` on both machines; the data folder's default place was on the drive being wiped; and on
  the new PC the drive often gets another letter.
- **AES `.zip` from Windows' own `tar.exe`**: it leaves every file name readable; Windows 10's `tar`
  may not write it; and Python's standard library can't open AES zips, so Linux needs a package
  anyway.
- **`.7z` with 7-Zip** (chosen): encrypted file names, and anyone can still open a Backup with 7-Zip
  if Hopover is gone. Windows' `tar` can't read an encrypted `.7z` on any build, so Hopover ships
  7-Zip's public-domain `7zr.exe`, pinned by SHA-256. The release workflow adds it to the release
  zip and a git clone downloads it on first use, so the binary is never committed. On Linux the
  bootstrap installs the distro's `7zip` or `p7zip` package and finds whichever command it provides.

## Consequences

- Encryption is on by default; turning it off takes a deliberate choice. A forgotten password can't
  be recovered, so the user types it twice and the Ready check has them type it again and tests the
  Backup where it was saved. The password reaches 7-Zip on standard input, never on a command line.
- An encrypted Backup carries the user's passwords and keys (secret environment variables, tokens in
  settings files, SSH keys, Wi-Fi passwords) unless the user unticks them. Sign-in sessions and
  browser cookies never go in. An unencrypted Backup and the companion repo keep the redaction and
  leak scan.
- Nothing inside an encrypted Backup can be read without the password, so Hopover recognizes Backups
  by name: the user names the file and Hopover appends `.hopover.7z` (split Backups end
  `.hopover.7z.001`).
- `hopover.json` records the format version and the source OS, and lists apps by catalog key, so a
  Backup made on one OS restores on another. A newer Hopover restores every older Backup; an older
  one refuses a newer Backup rather than restore part of it.
- The private git repo becomes the optional companion repo: redacted settings for developers who
  want to compare Backups, never needed to restore.
