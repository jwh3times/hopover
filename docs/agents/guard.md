# Guard

The commands and paths `scripts/guard.mjs` stops here, on top of the rules it applies everywhere.
Each `##` heading is one setting, defined in `.agents/skills/open-pr/settings/guard.md`.

## Deny commands

- `^npx (-y |--yes )?skills update\b` — it leaves `.claude/skills/` linked to its source instead of
  copied. Re-run the install commands in the `shared-skills` block of `AGENTS.md` instead.

## Protected paths

- `^data/` — the private companion: one person's exports and settings, often from a PC that has
  since been wiped, so nothing there is regenerable. Replace or remove its files only on the
  user's word.
