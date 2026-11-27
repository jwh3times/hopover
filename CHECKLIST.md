# Reinstall checklist

The order to do things in when you're about to wipe a Windows PC and set it up again, as Windows or as Linux (or both, dual-booting). It assumes every drive you format is gone for good except the ones listed in `keepDrives`, and that a cloud backup holds a second copy of your files. Keep anything specific to your own PC in `NOTES.md` in your data folder.

## Scripts

| Script | Run | What it does |
| --- | --- | --- |
| `Hopover.cmd` | both | Double-click it: Hopover's page in your browser. **Back up** there runs `New-Backup.ps1` in the background; **Check I'm ready** and **Restore** come later. |
| `New-Backup.ps1` | old PC | Runs the four capture scripts below and packs everything into one encrypted file, `<name>.hopover.7z`. On the new Windows PC, `Restore.ps1 -Backup <file>` restores from it; the steps below still work without one. |
| `Catalog-InstalledApps.ps1` | old PC | Lists installed, Store and portable apps and runs `winget export`. |
| `Export-Settings.ps1` | old PC | Writes `settings\`: PATH, env vars (secrets withheld), Windows preferences, drive layout, hardware, dev config and package lists, VS Code, Terminal, Claude Code, Codex, startup apps, and `settings\dev\repos.md` (work not in git). |
| `Set-WindowsPreferences.ps1` | both | Captures and applies Explorer, taskbar, theme, input, Game Bar, power plan, time zone, long paths, Developer Mode and optional features. |
| `Backup-Extras.ps1` | old PC | Archives app data, files cloud backups skip, dev extras and Docker volumes to `<migrationRoot>\extras`. |
| `Save-Drivers.ps1` | old PC, elevated | Exports every third-party driver to `<migrationRoot>\drivers`, including network drivers. |
| `Show-RestorePlan.ps1` | both | A page in your browser to look through the exports and untick anything you don't want restored. Saves `restore-plan.json`. |
| `Test-WipeReady.ps1` | old PC | Go/no-go check. Exits 0 only when the backup has caught up, every export is fresh and clean, and all repos and the data folder are pushed. |
| `Restore.ps1` | new Windows | Does the scriptable setup. Run it once elevated and once normally; every step is safe to rerun. |
| `linux/restore-linux.sh` | Linux | Installs Linux equivalents of your apps and restores dev config, repos and extras. |

## Days before

- [ ] **Set up the data folder and config.** `config.json` needs at least `migrationRoot` (on a drive you'll keep) and `keepDrives`. See the README.
- [ ] **Let your cloud backup finish.** Exclude folders that simply redownload (game libraries) so it finishes sooner.
- [ ] **Check the backup's version history** is long enough that files deleted by the wipe aren't purged before you've restored them (Backblaze defaults to 30 days; 1 year is safer).
- [ ] **Make an installer USB** (Windows Media Creation Tool, or your Linux distro's ISO), on a stick that isn't a keep drive.
- [ ] **Check you can reach your password manager** from another device, and keep its recovery kit somewhere other than this PC. Everything else depends on it.
- [ ] **Copy 2FA recovery codes** to a keep drive (`Test-WipeReady.ps1` looks for `recoveryFiles`).
- [ ] **Decide about RAID or dynamic volumes.** `Test-WipeReady.ps1` lists them; to keep one, leave its disks alone in setup and import it afterwards.
- [ ] **Clear `settings\dev\repos.md`:** push or discard anything listed under "Repos needing attention".
- [ ] **Optional:** `Backup-Extras.ps1 -Include app-thunderbird-*` (or other optional items) for a fast local restore of big profiles.

## The day of the wipe

1. Start Docker Desktop, if you use it.
2. `Catalog-InstalledApps.ps1`
3. `Export-Settings.ps1`
4. `Backup-Extras.ps1`. It must end without "Needs attention".
5. From an elevated prompt, `Save-Drivers.ps1`.
6. Optional: `Show-RestorePlan.ps1` to untick apps, repos, settings or anything else you don't want back. Save the plan.
7. Commit and push the data folder (and the tool, if you changed it).
8. Wait for the cloud backup to upload the new archives on the migration drive.
9. `Test-WipeReady.ps1` must print **READY**. Then tick off its "confirm yourself" list.
10. Shut down. **Unplug the keep drives.**

## Installing

- **Identical disks look the same in setup.** Tell them apart by size, model and partitions (`settings\windows\drives.md` lists them). Unplugging disks you're keeping takes the guesswork out.
- **Dual boot:** install Windows first, then Linux into free space, so the Linux bootloader manages both. Leave a shared data partition (or the migration drive) readable from both.
- **Windows:** sign in with the same Microsoft account. Windows names the profile folder after the account; the exported PATH and some app paths assume the old one, so check `$env:USERPROFILE` before restoring. After the install, recreate other partitions with the same labels; `Restore.ps1` puts the drive letters back by label.

## On a new Windows PC

1. Run Windows Update. Plug the migration drive back in.
2. Get the tool and your data:
   ```powershell
   winget install Git.Git GitHub.cli
   gh auth login
   git clone https://github.com/jwh3times/hopover.git C:\dev\hopover
   gh repo clone <you>/hopover-private C:\dev\hopover\data
   ```
   Optional: `.\Show-RestorePlan.ps1` to check or change the plan. **Preview restore** shows what will happen.
   With a Backup, give every `.\Restore.ps1` below `-Backup "<path>\<name>.hopover.7z"`: each run asks for its password (if it has one), and they all share one unpacked copy, which you delete once the restore is finished (the run tells you where it is).
3. **Elevated** PowerShell in the tool folder: `.\Restore.ps1`. This runs drivers, drive letters, machine preferences and Windows features, Chocolatey, machine env vars and hosts. Reboot if it asks.
4. **Normal** PowerShell: `.\Restore.ps1`. This runs winget apps, preferences, env vars and PATH, git config, cloning repos, dev extras, dev packages, VS Code, Terminal, Claude Code, Codex, app data and Docker volumes.
5. Work through the "Still to do by hand" list it prints: secrets from your password manager, `npm login`, sign-ins, skills, and the apps winget can't install.
6. Launch apps whose data needs their folder to exist (Windows Terminal, Stream Deck, SimHub, games, Docker Desktop), then rerun:
   - normal: `.\Restore.ps1 -Steps terminal,app-data,docker-volumes,dev-packages,vscode`
   - elevated: `.\Restore.ps1 -Steps app-data` (app data under Program Files)
7. Sign in to your dev services (`az login`, `gh auth login`, cloud CLIs, Claude Code, Codex, Docker Hub).
8. Compare startup apps against `settings\windows\startup-apps.md`.

## On Linux

1. Install updates, then get the tool and your data:
   ```bash
   sudo apt install git     # or: sudo dnf install git / sudo pacman -S git
   git clone https://github.com/jwh3times/hopover.git ~/hopover
   git clone <you>/hopover-private ~/hopover/data   # only without a Backup
   cd ~/hopover
   ```
2. On Arch or CachyOS, install `paru` or `yay` first if you want AUR packages (CachyOS ships paru). On Arch, enable `[multilib]` in `/etc/pacman.conf` if you'll use Steam.
3. Mount the drive with your Backup, then `linux/restore-linux.sh --backup "<path>/<name>.hopover.7z" --dry-run` and read the plan. It asks for the Backup's password (if it has one). Without a Backup, clone your companion repo to `~/hopover/data`, mount the migration drive, and leave out `--backup`.
4. The same without `--dry-run` (as your user; it asks for sudo). Once the restore is finished, delete the unpacked copy it names: it holds your files unencrypted. Log out and back in afterwards so PATH and group changes (docker) apply.
5. Work through the report's "Still to do by hand" and "No Linux version" lists. Merge any `*.windows.*` config files it set aside.
6. Games: launch Steam once and enable Proton; install Battle.net, the EA app and others through Lutris, and Epic/GOG games through Heroic. Copy game settings and addons from the extras archive into the Wine prefix if you want them.

## Cloud backup on the new install

- [ ] **Restore first.** Restore what you need before reinstalling the backup client, by download or by ordering a restore drive for multi-TB amounts. Anything already on a keep drive can come from there instead.
- [ ] **Inherit, don't start over.** Most clients (Backblaze: **Inherit Backup State**) can take over the old backup instead of re-uploading everything.
- [ ] **Re-add your exclusions.**
- [ ] **Keep external drives connected regularly.** Backups of drives left disconnected past the retention period can be dropped.

## Not covered by the scripts

- **Mail stores** (Thunderbird, Outlook PST): from the backup, or `Backup-Extras.ps1 -Include app-thunderbird-*`.
- **Video and photo editor projects:** export project archives from the app before the wipe.
- **Cloud-synced apps** (Adobe, game launchers, peripherals software): sign in again.
- **Synced folders** (OneDrive, Dropbox): check they're fully uploaded.
- **Python packages:** reinstall per project.
- **Wi-Fi passwords:** `netsh wlan export profile key=clear folder=<usb>` if you want them; keep the files out of git.
