# AGENTS.md

Guidance for every coding agent in this repository (Claude Code reads it through `CLAUDE.md`).

Hopover captures a Windows PC's apps, settings and data and restores them onto a fresh Windows or Linux install. Read `README.md` for what each script does.

## Layout

- Windows scripts (`*.ps1`) live in the repo root and share `lib\Common.ps1` (data folder, Options, helpers). `lib\Backup.ps1` is the Backup module (make, test, find, unpack), with the 7-Zip it uses pinned by SHA-256 in `lib\7zip.json`; its tests, `tests\Restore.Tests.ps1` and `tests\Api.Tests.ps1` download that `7zr.exe` into Pester's `TestDrive` on every run, so they need the network.
- `ui\index.html` is the one page: `Hopover.ps1` (started by `Hopover.cmd`) serves it on its home view, `Show-RestorePlan.ps1` on its restore plan view. Both use `lib\Server.ps1` (localhost listener, per-run token, Content-Security-Policy). `lib\Jobs.ps1` runs a Back up as a job in a child process, in a kill-on-close job object, with its progress as JSON events in `%LOCALAPPDATA%\Hopover\jobs\<id>\events.jsonl`.
- `catalog\` holds data, not code: `app-data.json` (app-data folders to back up), `linux-packages.json` (Windows app to Linux install methods), `linux-repos.json` (vendor repos, installer scripts, prerequisites).
- `linux\` holds `restore-linux.sh` (bash bootstrap, which installs `python3` and `curl`, and the distro's 7-Zip for `--backup`), `restore_linux.py` (the restore; Python 3.10+, standard library only) and `backup.py` (the Backup module on Linux: find, test and unpack, with the distro's `7z`, `7zz` or `7za`), plus `tests\`. `tests\test_backup.py` opens real Backups: it needs a 7-Zip on `PATH` (or `HOPOVER_TEST_7Z`, such as the cached `7zr.exe` on Windows), skips without one, and fails without one in CI.
- `tests\` holds the Pester tests for the Windows scripts and `Invoke-PowerShellChecks.ps1`.
- `scripts\` holds the agent and release scripts from `jwh3times/skills` (see [Agent skills](#agent-skills)); they need Node and nothing else.

## The private companion at `data\`

A user's exports and `config.json` live in `data\`, which is usually a separate private git repository checked out there. This repo ignores the whole folder and must work when it's absent.

- Never commit anything from `data\` to this repo, and never copy personal values (names, paths, drive letters, repo lists, hostnames) into the tool's code, catalogs or docs. Use options or placeholders instead.
- When the companion is present, run its git commands from inside `data\`.
- Scripts find the data folder from `-DataDir`, then `$env:HOPOVER_DATA`, then `data\`.
- Linters and tests read only tracked files (`git ls-files`, ruff's `extend-exclude`), so they never open `data\`.

## Rules for changes

- Windows scripts must run in Windows PowerShell 5.1 (a fresh install has nothing newer) and PowerShell 7. Watch for: `$PSScriptRoot` is empty in `param()` defaults; `ConvertFrom-Json` returns a top-level array as one object; variable names are case-insensitive (`$s` is `$S`); `powershell -File` passes `a,b` as one string (split list parameters with `Split-List`); a `FileInfo` from `Get-ChildItem` turns into a string as its bare name, not its full path (pass `.FullName`); a process started with redirected input on a UTF-8 console gets a BOM before what's written to it (start it with `Start-InputProcess` in `lib/Backup.ps1`). Every script uses `[CmdletBinding(PositionalBinding = $false)]`.
- `restore_linux.py` runs on the distro's own `python3`, as old as 3.10, and `restore-linux.sh` refuses an older one. Ruff targets `py310` and rejects newer syntax, and CI's unit tests run on both the floor (3.10) and the newest Python (`.python-version`'s 3.15). Moving the floor changes all four together: the guard in `restore-linux.sh`, ruff's `target-version`, the 3.10 step in `ci.yml`, and the docs that state it.
- Keep `*.sh` and `*.py` LF-only, and `*.cmd` CRLF, which `cmd.exe` needs (`.gitattributes` enforces both).
- Secrets: `Export-Settings.ps1` redacts and leak-scans everything it writes; keep that intact for any new export.
- Plan keys (`restore-plan.json`) are shared by `Show-RestorePlan.ps1`, `Restore.ps1` and `restore_linux.py`; change all three together.
- The page API is a contract: `tests/api-cases.json` holds its request and response cases, which every Hopover server runs (`tests/Api.Tests.ps1` for `Hopover.ps1`). An API change changes that file, the page and every server together. Job events and API errors carry a message code; the page's one English string table (`MSG` in `ui/index.html`) words each code, so a new code needs an entry there.
- `Restore.ps1` runs only the steps of its prompt's pass, and GitHub's Windows runners are elevated, so a test that runs it must pass from either prompt (`tests/Restore.Tests.ps1` restores `app-data`, which runs in both, from an extras item of the current pass).
- Options (`options.json`, layered over a data folder's `config.json`) are read by `Get-Options` in `lib/Common.ps1` and `load_options` in `restore_linux.py`, with the same keys and the same merge rule; change both together, and their tests.
- A Backup is read the same way by `lib/Backup.ps1` and `linux/backup.py`: the `.hopover.7z` suffix, the newest `formatVersion` it restores (`$BackupFormatVersion`, `FORMAT_VERSION`), the unpacked copy's `.hopover-unpacked.json` marker, the result names (`ok`, `wrong-password`, `password-needed`, `missing`, `damaged`, `newer`) and the password on 7-Zip's standard input only; change both together, with their tests. `tests/Backup.Tests.ps1` opens a Backup made by the PowerShell module with the Python one, through `uv`.
- An app's catalog key is found the same way by `Resolve-CatalogKey` in `lib/Backup.ps1` and `Catalog.lookup` in `restore_linux.py` (package key, then alias, then pattern, then `windowsOnly`); change both together. The extras items that hold secrets (`$SecretExtras` in `lib/Backup.ps1`) are named by `Backup-Extras.ps1` and `catalog/app-data.json`: a new secret-holding item goes in that list, or an unencrypted Backup carries it.
- A PSScriptAnalyzer rule is excluded in `PSScriptAnalyzerSettings.psd1` only with the reason beside it; a ruff rule likewise in `pyproject.toml`.

## Commands

The fast checks, which CI runs on every pull request:

```bash
powershell -NoProfile -File tests/Invoke-PowerShellChecks.ps1   # parse, PSScriptAnalyzer, Pester in 5.1 (Backup.Tests.ps1 needs uv)
pwsh -NoProfile -File tests/Invoke-PowerShellChecks.ps1         # the same in PowerShell 7
uv sync --frozen                                                # ruff and shellcheck, pinned in uv.lock
uv run ruff check . && uv run ruff format --check .             # Python lint and format
uv run shellcheck linux/restore-linux.sh && bash -n linux/restore-linux.sh
uv run python -m unittest discover -s linux/tests               # restore_linux.py unit tests
uv run --isolated --no-project --python 3.10 python -m unittest discover -s linux/tests   # the same on the 3.10 floor
node scripts/sync-agents.mjs --check     # agent config is in sync
node scripts/check-skills.mjs            # installed skills match skills-lock.json
node scripts/lint-agent-neutrality.mjs   # skill and agent sources read correctly from both trees
node scripts/check-docs.mjs              # doc links resolve and docs/agents/docs.md maps every doc
node scripts/check-changelog.mjs         # the branch's changelog.d/ fragment is valid
node --test "scripts/*.test.mjs"         # tests for the scripts above
```

Release helpers:

```bash
node scripts/next-version.mjs                # the version the next merge to main will mint
node scripts/stamp-changelog.mjs --dry-run   # the sections the release workflow would stamp
```

Slower checks, run by hand when a change touches what they cover:

```powershell
# Windows restore without changing anything
.\Restore.ps1 -DryRun

# Linux catalog: structure, vendor URLs, GitHub asset patterns (reaches the network)
powershell -File linux\tests\Test-LinuxCatalog.ps1

# Linux restore in Docker (dry run on six distros; -Install -Only <ids> really installs)
powershell -File linux\tests\Test-LinuxRestore.ps1
```

`Test-LinuxRestore.ps1` needs Docker Desktop and the network; it restores a fixture Backup it makes with `lib/Backup.ps1` (or `-Backup <file>`, or `-DataDir <folder>`), and its logs are UTF-16 (Windows PowerShell 5.1's `*>`), so read them with `Select-String`, not `grep`. Its containers run as root, so AUR, Flatpak and systemd steps only print what they'd do there.

Once a PR is open, read [docs/agents/merging.md](docs/agents/merging.md).

## Development flow

<!-- shared:development-flow -->

The flow skills are this repository's binding process for changing code. Read
`.agents/skills/open-pr/settings/dev-flow.md` (the routing, exemptions and issue linking) and
`docs/agents/dev-flow.md` (what this repository adds) before the first edit of a change, and whenever
no ready issue exists. `/ask-matt` maps the flow itself.

- **The gate.** Every code edit starts from a ready issue: an open `ready-for-agent` issue whose body
  is a `/to-spec` spec or a `/to-tickets` ticket or that carries a `/triage` brief, or a `bug` issue
  worked through `/diagnosing-bugs`, which needs the number and no spec. With none, stop before the
  first edit and route the user. Reading code, running tests and answering questions need no issue.
- **Private work.** A ready issue in the private tracker counts. Its number stays out of the branch,
  the PR, commits and public issues, and it is closed by hand after the merge.
- **The human starts every phase.** `/wayfinder`, `/grill-with-docs`, `/to-spec`, `/to-tickets`,
  `/implement` and `/triage` stay user-invoked. At a phase boundary, name the next command, say in
  one line why, and wait. Inside a phase, use `/tdd`, `/code-review`, `/diagnosing-bugs`,
  `/domain-modeling`, `/codebase-design`, `/prototype` and `/research` whenever they fit.
- **Exempt from the gate:** dependency bumps, changes touching only docs and agent config, release
  prep, and an explicit user waiver recorded in the PR body as `Flow waived by the user: <reason>`.
- **Linking.** Branches are `<type>/<issue#>-<slug>`; the PR body opens with `Closes #N` or
  `Part of #N`.
- **The flow ends at `/open-pr`.** `/implement` stops at a commit; `/open-pr` refreshes the docs,
  writes the changelog and the PR body, and opens the PR (Claude Code's built-in `/ship` is a
  different command, outside this flow). When the user says to merge it, `/land` merges it
  and confirms its release. `/dependabot` reviews the open Dependabot PRs and hands the ones the
  user names to `/land`; nothing merges a Dependabot PR on its own. `/ask-matt` also routes to
  `/pr`, `/retro` and `/implement-spec`, which are not installed here.
- **Tests are proven, reds are read.** Before `/implement` commits a change that adds or changes
  tests, and in `/code-review`, run `/test-prover`: in a scratch worktree it reverts the fix and
  breaks its guards, and every new test must go red. `/open-pr` runs it too. `/land` and
  `/dependabot` read a red check with `/ci-triage`, which never re-runs anything.
  `/records-audit` checks the board, the trackers, the follow-up wiki and the changelog against
  each other; run it weekly, and `/what-next` says when it is due.
- **`/handoff` is the shared skill.** It parks the session for the next one, on either machine or
  harness, closes it out with `/end-session`, and `/lets-go` resumes it. It does not write the
  portable file `/ask-matt` describes, so a `/prototype` detour stays in the session or uses a
  branch.
- **A wizard is not the record.** A step only a human can take follows the `## Procedure` in
  `.agents/skills/open-pr/settings/human-follow-up.md`, whose instructions stand without the script.
- **Research goes where it is safe to keep.** `/research` findings that would expose private material
  go to the private companion, where there is one, never to an ignored folder with no repository
  behind it. Details of an unpublished vulnerability are a draft advisory, never a research file.

<!-- /shared:development-flow -->

## Agent skills

Skills are authored in `.agents/skills/` (Codex reads it directly); `.claude/skills/` is a
generated mirror for Claude Code. Never edit the mirror: run `node scripts/sync-agents.mjs`.

### Shared skills

<!-- shared:shared-skills -->

`end-session`, `handoff`, `lets-go`, `open-pr`, `land`, `dependabot`, `docs-updater`, `what-next`,
`test-prover`, `ci-triage`, `records-audit` and `tldr` install from `jwh3times/skills`, and are
never edited here: reinstalling overwrites a local edit.
A fix goes upstream, and what they need to know about this repository goes in the settings files
under `docs/agents/`, which each skill proposes on first run.

The other shared skills come from one `mattpocock/skills` snapshot (v1.3.2, pinned by commit), the
same in every repository, and are never edited here either: what they need to know goes in this
file or `docs/agents/`. Moving to a newer snapshot is a change in `jwh3times/skills`. Keep
`.agents/skills/` out of every formatter: `scripts/check-skills.mjs` fails when an installed copy
differs from `skills-lock.json`, or the lock from these commands.

Re-running the install is the update; never run `npx skills update`, which leaves `.claude/skills/`
linked to its source instead of copied:

```bash
npx skills add jwh3times/skills -s end-session -s handoff -s lets-go -s open-pr -s land -s dependabot -s docs-updater -s what-next -s test-prover -s ci-triage -s records-audit -s tldr -a codex --copy -y
npx skills add mattpocock/skills#d1478fcb140db0b93c0c8df17bcfd311844749d0 \
  -s ask-matt -s code-review -s codebase-design -s diagnosing-bugs -s domain-modeling -s grill-me \
  -s grill-with-docs -s grilling -s implement -s improve-codebase-architecture -s prototype \
  -s research -s setup-matt-pocock-skills -s tdd -s teach -s to-questionnaire -s to-spec \
  -s to-tickets -s triage -s wait-what -s wayfinder -s wizard -s writing-for-agents \
  -a codex --copy -y
node scripts/sync-agents.mjs
```

`scripts/sync-agents.mjs`, `lint-agent-neutrality.mjs`, `check-docs.mjs`, `check-skills.mjs`,
`guard.mjs`, and `sync-main.mjs`, `next-version.mjs`, `check-changelog.mjs` and
`stamp-changelog.mjs` where this repository carries them, are canonical in `jwh3times/skills` with
their tests: fix them there, then copy them here.
`sync-agents.mjs` also writes the marked blocks in this file: change them in `jwh3times/skills`, not
here. It registers `guard.mjs` in `.claude/settings.json`, which stops the commands and edits these
rules forbid; this repository's own additions go in `docs/agents/guard.md`.

<!-- /shared:shared-skills -->
