### Added

- The Ready check judges a Backup: `Test-WipeReady.ps1 -Backup <file>[,<copy>]` asks for its
  password again and says go or no-go for wiping. It fails when every copy is on a drive that will
  be wiped (the Windows drive always is, and the `wipedDrives` Option names the others), when a
  copy that survives doesn't open with the password where it is saved (7-Zip tests every file),
  when the copies aren't of one Backup, when the Backup was made more than 24 hours ago (by the
  time in its `hopover.json`, not the file's date), when it leaves out Your files and no cloud
  backup service (Backblaze) has caught up, and when a repo under the dev root has uncommitted
  changes, unpushed commits, stashes or no remote, or git can't read it.
- A copy on a network share, or in a folder OneDrive, Dropbox or Google Drive syncs, survives the
  wipe; one in a synced folder adds "it finished uploading" to the list you confirm.
- The check warns when no installer USB is plugged in, and now recognises a Linux live USB
  (Ubuntu, Debian, Fedora, Arch) as well as Windows setup. It notes a removable drive holding the
  Backup to unplug before setup, and a volume on dynamic disks.

### Changed

- `Test-WipeReady.ps1` needs `-Backup`, and no longer takes `-KeepDrives`, `-MigrationRoot` or
  `-SkipDocker`. It no longer checks the data folder's exports, their leak scan, the extras and
  driver exports, or the data folder and tool folder being pushed: the Backup carries all of it.
- 2FA recovery codes are something you confirm on the list, instead of files the check looks for
  on a drive you keep.
- `Export-Settings.ps1` judges a repo's unsaved work with the same code as the Ready check.

### Removed

- The `keepDrives` and `recoveryFiles` Options. Hopover ignores them where a `config.json` or
  `options.json` still has them.
