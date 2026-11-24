# Agent notes for Hopover

Hopover captures a Windows PC's apps, settings and data and restores them onto a fresh Windows or Linux install. Read `README.md` for what each script does.

## Layout

- Windows scripts (`*.ps1`) live in the repo root and share `lib\Common.ps1` (data folder, config, helpers).
- `ui\index.html` is the page `Show-RestorePlan.ps1` serves.
- `catalog\` holds data, not code: `app-data.json` (app-data folders to back up), `linux-packages.json` (Windows app to Linux install methods), `linux-repos.json` (vendor repos, installer scripts, prerequisites).
- `linux\` holds `restore-linux.sh` (bash bootstrap) and `restore_linux.py` (the restore; Python 3.8+, standard library only), plus `tests\`.

## The private companion at `data\`

A user's exports and `config.json` live in `data\`, which is usually a separate private git repository checked out there. This repo ignores the whole folder and must work when it's absent.

- Never commit anything from `data\` to this repo, and never copy personal values (names, paths, drive letters, repo lists, hostnames) into the tool's code, catalogs or docs. Use `config.json` settings or placeholders instead.
- When the companion is present, run its git commands from inside `data\`.
- Scripts find the data folder from `-DataDir`, then `$env:HOPOVER_DATA`, then `data\`.

## Rules for changes

- Windows scripts must run in Windows PowerShell 5.1 (a fresh install has nothing newer) and PowerShell 7. Watch for: `$PSScriptRoot` is empty in `param()` defaults; `ConvertFrom-Json` returns a top-level array as one object; variable names are case-insensitive (`$s` is `$S`); `powershell -File` passes `a,b` as one string (split list parameters with `Split-List`). Every script uses `[CmdletBinding(PositionalBinding = $false)]`.
- Keep `*.sh` and `*.py` LF-only (`.gitattributes` enforces it).
- Secrets: `Export-Settings.ps1` redacts and leak-scans everything it writes; keep that intact for any new export.
- Plan keys (`restore-plan.json`) are shared by `Show-RestorePlan.ps1`, `Restore.ps1` and `restore_linux.py`; change all three together.

## Checking a change

```powershell
# parse every script in both PowerShell versions
powershell -NoProfile -Command "Get-ChildItem *.ps1,lib\*.ps1 | % { $e=$null; [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$e); if ($e) { $_.Name; $e } }"
pwsh -NoProfile -Command "Get-ChildItem *.ps1,lib\*.ps1 | % { $e=$null; [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$e); if ($e) { $_.Name; $e } }"

# Windows restore without changing anything
.\Restore.ps1 -DryRun

# Linux catalog: structure, vendor URLs, GitHub asset patterns
powershell -File linux\tests\Test-LinuxCatalog.ps1

# Linux restore in Docker (dry run on six distros; -Install -Only <ids> really installs)
powershell -File linux\tests\Test-LinuxRestore.ps1
```

`Test-LinuxRestore.ps1` needs Docker Desktop and a data folder; its containers run as root, so AUR, Flatpak and systemd steps only print what they'd do there.
