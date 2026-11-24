# Workspace

## Private companion

`data/` — the independent `jwh3times/hopover-private` repository, ignored by this one. It holds one
person's exports and `config.json` (`AGENTS.md`). Optional: its absence is a valid
public-contributor state, and the scripts take `-DataDir` or `$env:HOPOVER_DATA` instead.

## Sync with main

`node scripts/sync-main.mjs --target data`

## Companion restore command

`git clone https://github.com/jwh3times/hopover-private.git data`

## Safe-to-remove paths

- `.venv/` (the dev tools `uv sync` installs from `uv.lock`)
- `.ruff_cache/` and `__pycache__/` (lint and bytecode caches)

## Never-remove paths

- `data/`: the private companion, a user's exports and settings captured from a PC that may since
  have been wiped. Not regenerable.

## Dev stack

none: Hopover runs no local services. `linux/tests/Test-LinuxRestore.ps1` starts throwaway Docker
containers and removes them itself.
