# Open PR

## Fast checks

- Repo root: `uv sync --frozen`, only when `pyproject.toml` or `uv.lock` changed (it installs the
  pinned ruff and shellcheck the next entries run).
- Repo root: `uv run ruff format --check .`, only when a `*.py` file or `pyproject.toml` changed,
  fixed by `uv run ruff format .`.
- Repo root: `uv run ruff check .`, only when a `*.py` file or `pyproject.toml` changed.
- Repo root: `uv run shellcheck linux/restore-linux.sh && bash -n linux/restore-linux.sh`, only
  when a `*.sh` file changed.
- Repo root: `uv run python -m unittest discover -s linux/tests`, only when `linux/` changed.
- Repo root: `powershell -NoProfile -File tests/Invoke-PowerShellChecks.ps1`, only when a `*.ps1`
  or `*.psd1` file changed (parse, PSScriptAnalyzer and Pester in Windows PowerShell 5.1).
- Repo root: `pwsh -NoProfile -File tests/Invoke-PowerShellChecks.ps1`, with the same condition, in
  PowerShell 7.
- Repo root: `node scripts/sync-agents.mjs --check`, fixed by `node scripts/sync-agents.mjs`,
  committing both sides.
- Repo root: `node scripts/check-skills.mjs`, fixed by re-running the install commands in the
  `shared-skills` block of `AGENTS.md`.
- Repo root: `node scripts/lint-agent-neutrality.mjs`.
- Repo root: `node scripts/check-docs.mjs`.
- Repo root: `node --test "scripts/*.test.mjs"`, only when `scripts/` changed.

The PowerShell entries need Windows for 5.1, and PSScriptAnalyzer 1.25.0 and Pester 6.2.0
installed in each edition (`tests/Invoke-PowerShellChecks.ps1`). CI runs every entry: the `windows`
job the two PowerShell ones, the `linux` job the uv, ruff, shellcheck and unittest ones, and the
`agents` job the repo-root scripts on every run, the script tests included. The `changelog` job runs
the `Changelog check` on every pull request, Dependabot's included. Nothing is CI-only.

The `Main branch rules` ruleset on `main` requires a PR (merge commits only, review threads
resolved), the `windows`, `linux`, `agents` and `changelog` checks passing on a branch up to date
with `main`, and CodeQL code scanning (`gh api repos/jwh3times/hopover/rules/branches/main`).
