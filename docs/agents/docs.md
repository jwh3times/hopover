# Docs

## Doc map

- `README.md`: what Hopover is, what each script does, how to capture a PC and restore it on
  Windows or Linux, and the configuration; for people running the tool. Update when a script, a
  parameter, an option or where options are read from (`config.example.json`,
  `Get-ConfigDefaults` and `Get-Options` in `lib/Common.ps1`), a restore step (`STEPS` in `linux/restore_linux.py`) or the catalog format
  changes.
- `CHECKLIST.md`: the step-by-step order for moving a PC, from capture to wipe to restore. Update
  when a script is added or removed, or when `Test-WipeReady.ps1` checks something new.
- `CHANGELOG.md`: one dated section per version a merge mints, stamped by the release workflow's
  `scripts/stamp-changelog.mjs` after the merge (`docs/agents/releases.md`). `frozen`: no branch
  writes its sections.
- `changelog.d/README.md`: the fragment format and how fragments are stamped, for whoever writes
  one. Update when the fragment rules in `scripts/check-changelog.mjs` or the stamping in
  `scripts/stamp-changelog.mjs` change.
- `changelog.d/*.md`: each branch's changelog fragment (every file there but the README), stamped
  into `CHANGELOG.md` after its merge and checked by the `changelog` CI job. `ship-owned`, like the
  `VERSION` file.
- `GLOSSARY.md`: the project's language, one tight definition per term with the words to avoid,
  and no implementation detail. Update when a term is settled or renamed while designing a change.
- `docs/adr/*.md`: architecture decision records, one decision each with the reason it was made.
  Add one when a decision is hard to reverse and would surprise a reader; supersede rather than
  rewrite.
- `AGENTS.md`: guidance for every coding agent: the layout, the private companion, the rules for
  changes, the commands, the development flow and the agent skills. Update when a command, a
  folder or a cross-file rule (plan keys, PowerShell 5.1 traps) changes, or when
  `.claude/settings.json` does. The `shared:` blocks are written by `scripts/sync-agents.mjs`;
  never edit them here.
- `CLAUDE.md`: imports `AGENTS.md` for Claude Code. `owner-only`.
- `docs/agents/*.md`: settings the shared skills read. Update when this repository's process
  changes, or the `main` ruleset's required checks do (`open-pr.md` lists them).
- `docs/agents/merging.md`: from open PR to tagged release. Update when a merge or release lesson
  is learned that no check enforces, or `release.yml` changes.
- `docs/agents/dependabot.md`: what reviewing a Dependabot pull request takes here, read by the
  `dependabot` skill. Update when `.github/dependabot.yml`, `pyproject.toml`'s dev group, a
  workflow's toolchain pins or install steps, or the pinned PowerShell modules change.
- `docs/agents/test-proof.md`: how the `test-prover` skill runs one test on its own here. Update
  when a test runner, a test folder or a test command changes.
- `.agents/skills/**`: installed skills, listed in `skills-lock.json`. `frozen`: a reinstall
  overwrites them, and `scripts/check-skills.mjs` fails on an edited copy.

## Drift probes

- Scripts and their parameters in `README.md`: the `param()` blocks of the root `*.ps1` files and
  `restore-linux.sh --help`.
- Restore steps in `README.md`: `STEPS` in `linux/restore_linux.py`.
- Configuration in `README.md`: `config.example.json` and `Get-ConfigDefaults` in
  `lib/Common.ps1`.
- CI jobs and their commands in `AGENTS.md` and `docs/agents/open-pr.md`:
  `.github/workflows/ci.yml`.
- Dev tools in `docs/agents/dependabot.md`: `pyproject.toml` and `tests/Invoke-PowerShellChecks.ps1`.
