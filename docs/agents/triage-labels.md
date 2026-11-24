# Triage labels

The labels and what they mean are in `.agents/skills/open-pr/settings/triage-labels.md`. A skill's
role name is the GitHub label to apply.

## Extra labels

- `blocked` — the issue waits on another issue or an external event and nobody should pick it up
  now. It sits beside the five rather than replacing one: the triage label still says what the issue
  will need once unblocked. It goes with the board's `Gate` values `Depends on another issue`,
  `External wait` and `Upstream`, and comes off in the same change that clears the blocker.
