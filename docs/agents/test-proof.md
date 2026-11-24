# Test proof

How `test-prover` runs one test on its own here. The suites and their CI jobs are in
`docs/agents/open-pr.md`.

## Test commands

- Repo root: `linux/tests/test_*.py`, Python's `unittest`. One file:
  `uv run --no-sync python -m unittest discover -s linux/tests -p "$(basename <file>)" -v`; one test,
  by method name: `uv run --no-sync python -m unittest discover -s linux/tests -k <name> -v`.
  Worktree: link `.venv` (or run `uv sync --frozen`).
- Repo root: `tests/*.Tests.ps1`, Pester 6. One test, by its full name (the `Describe` and `It`
  names joined by a dot, `Split-List.returns an empty array for nothing`):
  `pwsh -NoProfile -Command 'Import-Module Pester -RequiredVersion 6.2.0; $r = Invoke-Pester -Configuration @{Run=@{Path="<file>"; PassThru=$true}; Filter=@{FullName="<name>"}; Output=@{Verbosity="Detailed"}}; "Pester ran {0} tests" -f ($r.PassedCount + $r.FailedCount); exit $r.FailedCount'`;
  one file: the same with `FullName="*"`. The single quotes keep bash from expanding `$r`.
  Count: `--count "Pester ran ([0-9]+) tests"`, the line the command prints, since Pester's own
  summary puts the passed and failed counts in separate numbers. Worktree: none.
- Repo root: `scripts/*.test.mjs`, node's runner. One file: `node --test <file>`; one test:
  `node --test --test-name-pattern="<name>" <file>`. Worktree: none (the scripts need no
  dependencies).
- `linux/tests/Test-LinuxCatalog.ps1` and `Test-LinuxRestore.ps1` are not unit suites: one reaches
  vendor URLs over the network, the other needs Docker Desktop and a data folder, so `test-prover`
  reports them as not proven.
