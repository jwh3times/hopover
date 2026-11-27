# Hopover

**Hop your setup over to a fresh install.** Capture a Windows PC's apps, settings and data before a reinstall, then rebuild it with as little hand work as possible:

- **onto a fresh Windows install** with `Restore.ps1`, or
- **onto Linux** (Ubuntu, Debian, Linux Mint, Pop!_OS, Fedora, Arch, CachyOS and other apt, dnf or pacman distros) with `linux/restore-linux.sh`, which translates your Windows apps into the closest Linux packages.

Nothing here is specific to one person. Everything about *you* lives in a separate **data folder**, usually your own private companion repo checked out at `data\`.

macOS and Windows on ARM aren't supported yet; the layout (`linux\` beside the Windows scripts, per-platform catalogs) leaves room for them.

## How it's organized

| | What | Where |
| --- | --- | --- |
| **The tool** | Scripts, the restore page, catalogs of apps and their Linux equivalents | this repo (safe to share) |
| **Your data** | `config.json`, the settings snapshot, app list, restore plan, your notes | `data\` inside the tool: a standalone **private** companion repo (this repo ignores the whole folder), or any folder you point to |
| **Your extras** | App data, `.exe`/`.iso` files, `.env` files, uncommitted work, Docker volumes, drivers | `<migrationRoot>` on a drive you won't wipe (an external drive is best) |
| **Everything else** | Documents, photos, mail... | your cloud backup |

Secrets are never written to the data folder: they're redacted, and a leak scan checks the output. The extras do hold secrets (`.env` files), which is why they go on a drive you keep private, not into git.

For the full sequence (days before, wipe day, install, new PC) follow [CHECKLIST.md](CHECKLIST.md). This README explains the pieces.

## Getting started

1. Clone this repo, e.g. to `C:\dev\hopover`, or download `hopover-<version>.zip` from the latest [release](https://github.com/jwh3times/hopover/releases/latest) and unzip it there (the zip leaves out the development files).
2. Create your data folder and config:

   ```powershell
   mkdir data
   copy config.example.json data\config.json
   notepad data\config.json      # at least: migrationRoot and keepDrives
   ```

3. Optional but recommended: make the data folder its own private repo, so your exports survive the wipe without depending on a drive. Run its git commands from inside `data\`; the outer repo never sees it.

   ```powershell
   cd data; git init -b main; git add -A; git commit -m "Hopover data"
   gh repo create hopover-private --private --source . --push
   ```

   On a new machine, clone it back into place: `gh repo clone hopover-private C:\dev\hopover\data`.

To keep the data somewhere else, pass `-DataDir <folder>` to any script, or set the `HOPOVER_DATA` environment variable.

## Requirements

- **Windows:** Windows PowerShell 5.1 (built in) or PowerShell 7. Run scripts from the tool folder:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\<Script>.ps1 [options]
  ```

  From a PowerShell window, `.\<Script>.ps1` works too. **From bash** (Git Bash, or `!` in Claude Code), `./<Script>.ps1` fails with a syntax error because bash can't run PowerShell; use `powershell -ExecutionPolicy Bypass -File ./<Script>.ps1`. List options take comma-separated values, e.g. `-Steps winget,vscode`.
- **Linux:** bash and an apt, dnf or pacman distro with Python 3.10 or newer (Ubuntu 22.04, Debian 12, Fedora 35 and later all ship it). `restore-linux.sh` installs `python3` and `curl` itself if they're missing, and stops if `python3` is older than 3.10.

## Quick start

### On the old PC (before wiping)

```powershell
.\Catalog-InstalledApps.ps1         # apps -> data\Installed-Apps-Catalog.md, data\winget-packages.json
.\Export-Settings.ps1               # settings -> data\settings\
.\Backup-Extras.ps1                 # extras -> <migrationRoot>\extras (start Docker Desktop first)
.\Save-Drivers.ps1                  # elevated prompt; drivers -> <migrationRoot>\drivers
.\Show-RestorePlan.ps1              # optional: untick what you don't want -> data\restore-plan.json
cd data; git add -A; git commit -m "Refresh exports"; git push; cd ..
.\Test-WipeReady.ps1                # must print READY
```

Don't wipe until `Test-WipeReady.ps1` prints **READY** and you've worked through its "confirm yourself" list.

### On a new Windows PC

```powershell
winget install Git.Git GitHub.cli
gh auth login
git clone https://github.com/jwh3times/hopover.git C:\dev\hopover
gh repo clone <you>/hopover-private C:\dev\hopover\data
cd C:\dev\hopover
```

Then, with the migration drive plugged in:

1. Optional: `.\Show-RestorePlan.ps1` to check the plan, change it, and **Preview restore**.
2. Elevated PowerShell: `.\Restore.ps1`
3. Normal PowerShell: `.\Restore.ps1`
4. Work through the "Still to do by hand" list it prints.

Each run does only the steps that suit that kind of prompt and skips anything already in place, so you can rerun it whenever you like. Run with `-DryRun` first to see what it would change.

### On Linux

```bash
git clone https://github.com/jwh3times/hopover.git ~/hopover
git clone <you>/hopover-private ~/hopover/data       # or use --data with the folder on your Windows partition
cd ~/hopover
linux/restore-linux.sh --dry-run      # see what it would do
linux/restore-linux.sh                # do it; asks for sudo when needed
```

Run it as your normal user, not with sudo. With the migration drive mounted, it finds the extras archive by itself (or pass `--extras <folder>`). It ends with a report of what was installed, what has no Linux version (with alternatives), and what's left to do by hand. See [Linux restore](#linux-restore) below.

### Choosing what to restore (either PC)

```powershell
.\Show-RestorePlan.ps1
```

This opens a page in your browser that shows every exported item, step by step:

- **What's there:** apps, repos, extensions, settings, config files and archives, each with a "View" button for the exported file or the archive's contents.
- **How it compares with this PC:** "already here", "differs here" or "not here yet".

Untick anything you don't want, or turn a whole step off, then click **Save plan**. That writes `restore-plan.json` in the data folder; commit and push it. **Preview restore** saves the plan and runs `Restore.ps1 -DryRun`. Without a plan file, everything is restored. The Linux restore follows the same item choices (an app you untick isn't installed on Linux either).

## Options

Hopover's options live in `%LOCALAPPDATA%\Hopover\options.json` (on Linux, `~/.config/hopover/options.json`, or under `$XDG_CONFIG_HOME`). A `config.json` in the data folder is read as well, so a data folder set up before Options keeps working: each script starts from the defaults, applies `config.json`, then `options.json` over it key by key (one level deep for the sections), and its own parameters win over all of them. [config.example.json](config.example.json) lists every option. Every key is optional except `migrationRoot`.

`options.json` sits on the Windows drive, which the reinstall erases. A Backup carries the Options it was made with (as its `data\config.json`), but until a restore reads them from there, keep them in the data folder's `config.json` (as in [Getting started](#getting-started)), which survives with the rest of your data folder.

| Key | Used by | Meaning |
| --- | --- | --- |
| `devRoot`, `repoDepth` | Export-Settings, Backup-Extras, Restore | Folder holding your git checkouts, and how deep to look for repos in it |
| `useOnlyRepos` | Export-Settings, Backup-Extras | Repos you only use and never push; their local changes aren't reported or archived |
| `migrationRoot` | New-Backup, Backup-Extras, Save-Drivers, Restore, Test-WipeReady | Folder on a drive that won't be wiped; gets `extras\` and `drivers\`, and is where `New-Backup.ps1` saves a Backup unless told `-Destination` |
| `keepDrives` | Test-WipeReady | Drive letters that survive the reinstall |
| `wipedDrives` | none yet | Drive letters the reinstall will erase; the Windows drive always counts, listed or not |
| `excludedTypeRoots`, `maxFileMB` | Backup-Extras | Folders to search for `.exe`/`.msi`/`.dll`/`.iso` and similar files that cloud backups usually skip; per-file size limit |
| `portableRoots` | Catalog-InstalledApps | Where to look for portable apps |
| `appData.include` / `exclude` / `custom` | Backup-Extras | Optional app-data items to add, items to drop, and your own folders (see [catalog/app-data.json](catalog/app-data.json)) |
| `backup.provider`, `backup.maxRemainingMB` | Test-WipeReady | `auto` (Backblaze if installed), `backblaze` or `none`; how much may still be uploading |
| `recoveryFiles` | Test-WipeReady | File name patterns (2FA recovery codes and the like) expected in the root of a keep drive |
| `confirm` | Test-WipeReady | Extra lines for its "confirm yourself" list |
| `linux.devRoot` | restore-linux.sh | Where repos are cloned on Linux (default `~/dev`) |
| `linux.prefer` | restore-linux.sh | Order of install sources (default `vendor`, `distro`, `portable`, `flatpak`) |
| `linux.aur` | restore-linux.sh | `auto` (use yay/paru if installed) or `never` |
| `linux.flatpak` | restore-linux.sh | `false` to never use Flathub |
| `linux.nodeMajor` | restore-linux.sh | Node.js major version for the NodeSource repo |
| `linux.extra`, `linux.skip` | restore-linux.sh | Catalog keys or winget ids to add, or to leave out, on Linux only |

## Windows scripts

All of them take `-DataDir`; settings come from the [Options](#options) and parameters override them.

### New-Backup.ps1 (old PC)

Makes a **Backup**: one file, `<name>.hopover.7z`, holding what the scripts below capture. It runs `Catalog-InstalledApps.ps1`, `Export-Settings.ps1`, `Backup-Extras.ps1` and, from an elevated prompt, `Save-Drivers.ps1` into a staging folder, then packs it with 7-Zip ([ADR 0002](docs/adr/0002-one-encrypted-backup-file.md)).

```powershell
.\New-Backup.ps1 -Destination E:\                                  # asks for the password twice
.\New-Backup.ps1 -Destination E:\ -Name "Laptop before reinstall"
```

- **Encrypted by default:** AES-256 with the file names hidden too. It asks for a password (at least 8 characters) twice; a forgotten password can't be recovered. A program can pipe the password in instead: `... | powershell -File .\New-Backup.ps1 ...`. The password reaches 7-Zip only on its standard input, never a command line. `-NoEncryption` makes a Backup anyone can open, so it leaves out the extras that hold passwords and keys (`dev-local-files`, your local `.env` and secret files, and `app-ssh`, your `.ssh` folder) and says so.
- **Inside it:** the exports as a data folder (`data\`, with the Options it was made with as `data\config.json`, and your `restore-plan.json` and `NOTES.md` if you have them), the extras (`extras\`), the drivers (`drivers\`) and `hopover.json`, which records the format version, when and where the Backup was made, whether it's encrypted, and every app by its catalog key with its winget or Chocolatey id. Any 7-Zip opens it with the password.
- **7-Zip:** 7-Zip's `7zr.exe`, pinned by version and SHA-256 in `lib\7zip.json`. It's downloaded to `%LOCALAPPDATA%\Hopover\bin` on first use, and a file whose hash differs is refused.
- **Your data folder is only read.** The staging folder (under `%TEMP%`, or `-StagingDir`) is removed afterwards, and an existing Backup with the same name is never overwritten.
- **Options:** `-Destination` (default: the `migrationRoot` option), `-Name` (default `<PC name> <yyyy-mm-dd>`), `-NoEncryption`, `-Steps catalog,settings,extras,drivers` (default: all), `-SplitMB` (write pieces of that size, `.001`, `.002`, ...), `-StagingDir`, `-DataDir`.

To restore on a new Windows PC: `.\Restore.ps1 -Backup "E:\<name>.hopover.7z"` (see [Restore.ps1](#restoreps1-new-windows-pc)).

### Catalog-InstalledApps.ps1 (old PC)

Lists installed programs from the registry, Store apps and portable apps, and runs `winget export`.

- **Writes:** `Installed-Apps-Catalog.md` (including what winget can't reinstall) and `winget-packages.json` in the data folder.
- **Options:** `-SkipWinget`; `-OutFile`, `-WingetFile` to write elsewhere; `-PortableRoots`, `-PortableDepth`.

### Export-Settings.ps1 (old PC)

Writes a snapshot to `<data>\settings\`. It rebuilds the folder each run, but only if the folder is its own earlier output.

| Folder | Contents |
| --- | --- |
| `settings\windows\` | PATH and environment variables, hosts file, startup apps, scheduled tasks, system info, Windows preferences, drive layout (`drives.md`/`.json`) and hardware inventory |
| `settings\dev\` | `.gitconfig`, `.npmrc`, Chocolatey and global package lists, WSL/Docker listing, and `repos.md` (every repo under the dev root, plus any work that isn't pushed) |
| `settings\vscode\`, `settings\terminal\` | VS Code settings, keybindings, snippets, extension list; Windows Terminal settings |
| `settings\claude\`, `settings\codex\` | Claude Code and Codex config, memory and MCP server definitions |

**Secrets:** values that look like secrets (by name or token shape) are replaced with `<redacted>`; secret environment variables are listed by name only; a final leak scan checks every output file against the real secret values and must report clean.

**Options:** `-OutDir`, `-DevRoot`, `-RepoDepth`, `-UseOnlyRepos`.

### Set-WindowsPreferences.ps1 (both)

Captures or applies Windows settings: Explorer and taskbar, theme, mouse and keyboard, Game Bar, power plan and time zone, long paths and Developer Mode, optional Windows features.

- `-Export` writes `settings\windows\preferences.json`. `Export-Settings.ps1` calls it for you.
- `-Apply` applies them; `Restore.ps1` calls it for you. User settings apply from a normal prompt, machine settings from an elevated one. Add `-RestartExplorer` so taskbar and Explorer changes show without signing out.
- `-Skip` (with `-Apply`) leaves the listed settings alone: registry settings are `Path|Name`, plus `TimeZone`, `PowerPlan`, `ClassicContextMenu` and `feature:<Name>`. `Restore.ps1` passes the ones unticked in the plan.
- `-Dir` / `-DataDir` choose where `preferences.json` lives.

### Backup-Extras.ps1 (old PC)

Archives what neither git nor a cloud backup usually keeps to `<migrationRoot>\extras`, with a `manifest.json`:

- **App data** of every app in [catalog/app-data.json](catalog/app-data.json) that's installed here (SimHub, MSI Afterburner, Stream Deck, Bambu Studio, OrcaSlicer, World of Warcraft settings and addons, OBS, FileZilla, ...), plus your `appData.custom` entries. Optional items (Thunderbird profiles, `.ssh`, Steam userdata) are only included when listed in `appData.include` or `-Include`.
- **Files cloud backups skip:** `.exe`, `.msi`, `.dll`, `.iso` and similar from `excludedTypeRoots`; files over `maxFileMB` are skipped.
- **Dev extras:** folders under the dev root that aren't git repos, local `.env` and secret files, uncommitted changes as patch files.
- **Docker named volumes** (Docker Desktop must be running).

**Options:** `-Only` (wildcards, e.g. `-Only docker-volumes,dev-*`), `-Include` (optional items), `-Destination`, `-ExcludedTypeRoots`, `-MaxFileMB`. The summary must list nothing under "Needs attention".

### Save-Drivers.ps1 (old PC, elevated)

Exports every third-party driver with `pnputil` to `<migrationRoot>\drivers`, including the network drivers so the new install can get online. It renames any earlier export instead of overwriting it, and writes `settings\windows\drivers.md`.

### Test-WipeReady.ps1 (old PC)

Go/no-go check before wiping:

- the cloud backup (Backblaze, when installed or configured) has finished uploading and its status is current
- the catalog, settings export, extras archive and driver export are fresh and complete
- every repo is committed and pushed, and **the data folder is committed and pushed** (the tool folder only warns)
- the keep drives are connected and hold files matching `recoveryFiles`
- an installer USB is plugged in

It ends with a list of things only you can confirm, and exits 1 if anything fails. **Options:** `-MaxAgeHours` (default 24), `-MaxRemainingMB`, `-SkipDocker`, `-KeepDrives`, `-MigrationRoot`.

### Show-RestorePlan.ps1 (both)

The browser page for choosing what to restore.

- Runs a small web server on `http://localhost:8765` (or the next free port) that only this PC can reach. Every request needs a token that changes each run, so other sites in your browser can't use it. It needs nothing installed, so it works on a fresh Windows install. The page itself is `ui\index.html`.
- It only shows files inside the data folder, the tool's own docs, and the contents of archives on the migration drive; never anything under `.git`.
- Leave the PowerShell window open while you use the page; stop it with **Quit** or Ctrl+C. The first load takes about 10 seconds while it compares everything with this PC.

**The page:**

- **Header:** **Save plan**; **Preview restore** (saves, then runs `Restore.ps1 -DryRun` from the prompt the page was started from); **Refresh**; **Quit** (warns about unsaved changes).
- **Left side:** every restore step with a tick box for the whole step and a count of ticked items, then the Markdown reports, which open in a viewer.
- **Overview:** where the exports came from, the data folder, whether a plan is saved, and every step with what it will restore; **Tick everything** and **Undo unsaved changes**.
- **A step's page:** its items in groups, with a filter, **All**/**None** per group, and "Hide items already on this PC". Click a row to tick or untick it; **View** opens the exported file or lists an archive. The address changes to `#step=<name>`, so a reload keeps your place.

| Label | Meaning |
| --- | --- |
| already here | This PC already matches the export |
| differs here | This PC has it, but different from the export (or the archive was only partly made) |
| not here yet | This PC doesn't have it |
| can't yet | Restore can't do it yet, e.g. no drive with that label, or a repo with no remote |

**Options:** `-Port`, `-NoBrowser`, `-DataDir`, `-MigrationRoot`, `-DevRoot`.

**`restore-plan.json`** lists only what to skip, so anything added by a later export is restored by default:

```json
{
  "SkipSteps": ["docker-volumes"],
  "LinuxSkipSteps": ["codex"],
  "Skip": {
    "winget": ["EpicGames.EpicGamesLauncher"],
    "repos": ["some-old-repo"],
    "files": ["vscode/settings.json"]
  }
}
```

`SkipSteps` are Windows restore steps and `LinuxSkipSteps` Linux ones; `Skip` maps a group (`winget`, `choco`, `repos`, `files`, `vscode-extensions`, `npm`, `extras`, ...) to its unticked keys. Keys for items no longer exported stay in the file and do no harm. Delete the file, or pass `-IgnorePlan` / `--ignore-plan`, to restore everything.

### Restore.ps1 (new Windows PC)

Rebuilds the PC from a Backup, or from the data folder and `<migrationRoot>`.

```powershell
.\Restore.ps1 -Backup "E:\Laptop 2026-11-27.hopover.7z"     # asks for the Backup's password
.\Restore.ps1 -Backup "E:\Laptop 2026-11-27.hopover.7z" -DryRun
```

With `-Backup` each run asks for the password once (or reads it from a pipe) and stops before unpacking anything if the password is wrong or a newer Hopover made the Backup ("This Backup was made by a newer Hopover; download the latest"). Then it unpacks the Backup to `%LOCALAPPDATA%\Hopover\restore\<Backup name>` and restores from there, with the plan the Backup carries and its Options (under this PC's own `options.json`, if it has one).

- **The unpacked copy** is reused by every later run of the same account, the elevated and normal passes included, instead of being unpacked again; a different Backup with the same name, or a copy an earlier run left half-done, is unpacked afresh. It holds the Backup's files unencrypted, passwords and keys included, so each run ends by saying where it is: delete it once the restore is finished. Hopover never replaces a folder there that it didn't unpack.
- **`-DryRun`** changes nothing: with no copy to reuse it unpacks into a temporary folder and removes it at the end.
- **A split Backup** is given by its first piece (`.hopover.7z.001`).

List the steps with `-List`:

| Step | Prompt | Does |
| --- | --- | --- |
| `drivers` | elevated | Install exported drivers |
| `drive-letters` | elevated | Reassign drive letters by volume label |
| `prefs` | both | Windows preferences |
| `winget` | normal | Install apps from `winget-packages.json` |
| `choco` | elevated | Install Chocolatey packages |
| `env-machine` / `env-user` | elevated / normal | Environment variables and PATH |
| `hosts` | elevated | Custom hosts file lines |
| `git-config` | normal | Git and npm config |
| `repos` | normal | Clone repos into the dev root |
| `dev-extras` | normal | Untracked dev folders, `.env` files, uncommitted patches |
| `dev-packages` | normal | npm, .NET, Go, Cargo, uv and PowerShell packages |
| `vscode` | normal | VS Code extensions and settings |
| `terminal` | normal | Windows Terminal settings |
| `claude` / `codex` | normal | Claude Code and Codex config, memory, MCP servers |
| `app-data` | both | App data and the files from the extras archive |
| `docker-volumes` | normal | Docker named volumes |

**Options:** `-Backup <file>` (instead of `-DataDir` and `-MigrationRoot`), `-Steps a,b` (runs them even if the plan turns them off; unticked items stay skipped), `-DryRun`, `-IgnorePlan`, `-Plan <file>`, `-NoOverwrite`, `-DataDir`, `-MigrationRoot`, `-DevRoot`.

**Plan and safety:** it prints which plan it's using and how many items each step skipped. Before replacing a file it saves `<name>.pre-restore-<timestamp>`; extracting archives never overwrites files; each real run writes `%USERPROFILE%\restore-<timestamp>.log`. Some steps need the app launched once first (Windows Terminal, Stream Deck, SimHub, WoW, Docker Desktop); rerun those steps afterwards, as in the checklist.

## Linux restore

`linux/restore-linux.sh` (a small bash bootstrap) runs `linux/restore_linux.py` (Python 3.10+, standard library only).

| Step | Does |
| --- | --- |
| `packages` | Translates every winget and Chocolatey app with [catalog/linux-packages.json](catalog/linux-packages.json): adds vendor repos, installs packages, vendor `.deb`/`.rpm` files, installer scripts, AppImages, tarballs and Flatpaks; installs Claude Code if its config was exported |
| `dev-packages` | npm, .NET, Go, Cargo, uv and PowerShell packages from the Windows lists |
| `git-config` | `~/.gitconfig`, with Windows-only settings dropped (credential manager, `.exe` editors, Windows paths, `autocrlf` set to `input`) |
| `repos` | Clones every repo into `linux.devRoot` |
| `dev-extras` | Untracked dev folders, `.env` files and patches from the extras archive |
| `vscode` | VS Code settings and extensions |
| `claude` | Claude Code config and memory (memory folders are renamed from the Windows dev root to the Linux one) and MCP servers |
| `codex` | Codex config |
| `docker-volumes` | Docker named volumes from the extras archive |

**How apps are chosen.** Each catalog entry lists install methods. The first one that works on the running distro wins, after ranking them by `linux.prefer`:

1. **vendor**: the vendor's own apt/dnf repo (VS Code, Docker, GitHub CLI, 1Password, Edge, Chrome, NodeSource, Microsoft .NET/PowerShell, ...), the vendor's `.deb`/`.rpm` download (Steam, Zoom, minikube, Proton, ...), the vendor's installer script (uv, rustup, Go, Deno, Claude Code, ...), or on Arch/CachyOS the AUR package of the vendor's build (with yay or paru)
2. **distro**: apt, dnf or pacman packages, with the right name for each distro
3. **portable**: AppImages and tarballs from the vendor (Bambu Studio, OrcaSlicer, WowUp, ...)
4. **flatpak**: Flathub, as a last resort

Package names are checked against the distro's repos before they're chosen, so a package your release doesn't have falls through to the next method. Vendor repos that don't publish for a brand-new release yet fall back to the newest one they do. Apps with no Linux version are listed with alternatives; launchers that run through something else are mapped to it (Battle.net and the EA app to Lutris, Epic and GOG to Heroic). Windows-only runtimes (Visual C++, .NET Desktop, DirectX, ...) are skipped.

**Options:** `--dry-run`, `--refresh` (with `--dry-run`: refresh package metadata so names are checked; needs sudo), `--steps`, `--only <ids>`, `--data`, `--extras`, `--dev-root`, `--prefer`, `--no-flatpak`, `--aur auto|never`, `--no-overwrite`, `--ignore-plan`, `--report <file>`, `--list`. Every run writes a Markdown report (default `~/hopover-linux-<timestamp>.md`).

**Config files written for Windows.** Copied settings that refer to Windows paths or programs (`.ps1` hooks, `C:\` paths) are saved beside the target as `*.windows.*` for you to merge, rather than copied over a working Linux config. Instruction files (`CLAUDE.md`, `AGENTS.md`) are copied, with a note to review them.

## Catalogs (contributions welcome)

| File | Holds |
| --- | --- |
| [catalog/app-data.json](catalog/app-data.json) | App-data folders Backup-Extras looks for |
| [catalog/linux-packages.json](catalog/linux-packages.json) | Windows app (winget id, or `choco:<id>`) to Linux install methods; Windows-only patterns; aliases |
| [catalog/linux-repos.json](catalog/linux-repos.json) | Vendor apt/dnf repos, installer scripts and prerequisites (i386, RPM Fusion, multilib) |

The Linux report lists apps that aren't in the catalog yet. To add one, give it an entry in `linux-packages.json` (the comment at the top describes every field), then check it:

```powershell
powershell -File linux\tests\Test-LinuxCatalog.ps1                 # structure, vendor URLs, GitHub asset patterns
powershell -File linux\tests\Test-LinuxRestore.ps1                 # dry run in Docker on six distros
powershell -File linux\tests\Test-LinuxRestore.ps1 -Install -Only <id>   # really install it in each container
```

`Test-LinuxRestore.ps1` needs Docker Desktop. Its containers run as root, so AUR installs are skipped there (AUR helpers refuse root), and Flatpak and systemd steps only print what they'd do.

## What isn't covered

Secrets (from your password manager), sign-ins, mail stores, video editor projects, cloud-synced apps, and apps winget can't install. These are listed under "Not covered by the scripts" in [CHECKLIST.md](CHECKLIST.md) and in the "Still to do by hand" lists both restores print. Keep notes specific to your own PC in `NOTES.md` in your data folder; the restore page shows it.

## Keeping it current

Rerun `Catalog-InstalledApps.ps1` and `Export-Settings.ps1` after installing apps or changing settings, then commit the data folder. `git diff` there shows what changed since the last snapshot. New apps and settings are restored by default; open `Show-RestorePlan.ps1` to untick any.

## License

Copyright (C) 2026 Jerry Holland

Hopover is free software under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0-only). You may use, change and share it, including commercially, as long as you keep this copyright notice and the license, and release anything you build from it, with its source, under the same license. That includes a modified version you let others use over a network.

## What's in the repo

| Path | What |
| --- | --- |
| `*.ps1` | The Windows scripts above |
| `lib\Common.ps1` | Shared helpers (data folder, Options) |
| `lib\Backup.ps1`, `lib\7zip.json` | The Backup module (make, test and find Backups) and the pinned 7-Zip it uses |
| `lib\version.txt` | A placeholder that `git archive` fills with the tag, so a release zip records its version in each Backup's `hopover.json` (a clone asks `git describe` instead) |
| `ui\index.html` | The page `Show-RestorePlan.ps1` serves |
| `catalog\` | App-data locations and the Linux translation tables |
| `linux\` | `restore-linux.sh`, `restore_linux.py`, and `tests\` |
| `config.example.json` | Every option with its default; the starting point for `data\config.json` |
| `CHECKLIST.md` | The step-by-step wipe and reinstall checklist |
| `tests\` | Pester tests for the Windows scripts, and `Invoke-PowerShellChecks.ps1` (parse, lint, test) |
| `pyproject.toml`, `uv.lock`, `PSScriptAnalyzerSettings.psd1` | Pinned lint and format tools for development (the tool itself needs none) |
| `CHANGELOG.md`, `changelog.d\`, `VERSION` | Release notes, stamped when each change merges, and the release line |
| `AGENTS.md`, `CLAUDE.md`, `docs\`, `scripts\`, `.agents\`, `.claude\` | Guidance, settings, decisions and scripts for coding agents working on this repo |
| `LICENSE` | AGPL-3.0 |
| `data\` | Your data folder, usually its own private repo (not part of this repo) |
