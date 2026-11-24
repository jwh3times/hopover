# Dependabot

What reviewing a Dependabot pull request takes here, read by the `dependabot` skill in a session
and in the scheduled review. These facts apply to this repository only.

## Stack

Hopover itself has no runtime dependencies: the Windows scripts are Windows PowerShell 5.1 and
PowerShell 7 with built-in modules only, and `linux/restore_linux.py` uses Python's standard library
on whatever `python3` the distro ships (3.10 and up). Dependabot updates only the development tools
and the workflows' actions.

- **uv, `/`:** `pyproject.toml` and `uv.lock` pin the dev group: `ruff` (lint and format) and
  `shellcheck-py` (the shellcheck binary). `python-minor-and-patch` groups minor and patch updates;
  each major is its own PR.
- **github-actions, `/`:** `actions-minor-and-patch`; each major is its own PR. Every action is
  pinned by commit SHA with its version in a comment.

PSScriptAnalyzer (1.25.0) and Pester (6.2.0) come from the PowerShell Gallery, which Dependabot
does not cover: their versions are pinned in `tests/Invoke-PowerShellChecks.ps1` and in `ci.yml`'s
install step, and move by hand, together.

`.github/workflows/ci.yml` runs four jobs, all required on `main`: `windows` (installs the two
modules, then `tests/Invoke-PowerShellChecks.ps1` in Windows PowerShell 5.1 and in PowerShell 7),
`linux` (`uv sync --frozen`, `ruff check`, `ruff format --check`, shellcheck, `bash -n` and
`python -m unittest discover -s linux/tests` on Python 3.15 from `.python-version` and again on
3.10, the floor), `changelog`
(`node scripts/check-changelog.mjs`) and `agents` (the repository scripts on the Node in `.nvmrc`).
`release.yml` runs on a push to `main` and stamps, tags and releases each merge.

## Review triggers

- **A ruff bump that moves its default rules or formatter style**: CI goes red on code the PR
  never touched. Read which rule or style changed before calling it a regression.

## Resolution

- **Toolchain.** Node from `.nvmrc` (22), Python from `.python-version` (3.15, the newest), and
  3.10 for the floor's unit-test run (ruff's `target-version = "py310"` covers its syntax). If
  `uv python find 3.15` or `3.10` fails, run `uv python install` with that version.
- **uv** (`pyproject.toml`, `uv.lock`), from the repository root: `uv lock --check`, then
  `uv sync --frozen`.

## Where to look

- The `[tool.ruff]` sections of `pyproject.toml` (`select = ["E", "F", "I", "B", "UP", "SIM"]`,
  `target-version = "py310"`, the ignores with their reasons).
- `linux/restore_linux.py`, `linux/tests/` and `linux/restore-linux.sh`.
- The `with:` inputs in `ci.yml` and `release.yml`.

## Grounding facts

- **Dependabot reads `.python-version` for the `uv` ecosystem and supports only recent Pythons**
  (3.10 to 3.15 on 2026-11-24). A pin below its range fails every `uv` update job before it reads a
  dependency, with `tool_version_not_supported`, and opens no PR: Hopover's first run did, on
  3.9. Check the `Dependabot Updates` runs when `uv` PRs stop arriving.

## Playbook

- **ruff bump:** run `uv run ruff check .` and `uv run ruff format --check .`; cite the rule or
  style change against `[tool.ruff]`. A formatter change is fixed in the same PR with
  `uv run ruff format .`, which must change no behaviour.
- **shellcheck-py bump:** run `uv run shellcheck linux/restore-linux.sh`; a new warning names its
  `SC` code, which the fix or a `# shellcheck disable=SCxxxx` comment with a reason addresses.
- **GitHub Actions major:** NEEDS EFFORT only when a removed or renamed input, or a changed default,
  reaches a `with:` input; name the step. The inputs in use: `actions/checkout` (`fetch-depth: 0`,
  `ref: main`, `token`), `actions/setup-node` (`node-version-file: .nvmrc`), `astral-sh/setup-uv`
  (none: uv reads `.python-version`) and `actions/create-github-app-token` (`client-id`,
  `private-key`, `permission-contents: write`).
