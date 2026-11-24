# Releases

## Scheme

stamp-on-tag — `.github/workflows/release.yml` tags every merge to `main`
`v<major>.<minor>.<build>` with a GitHub Release, and attaches `hopover-<version>.zip`, the tool
as `git archive` exports it. Each branch's entries live in its own `changelog.d/<branch-slug>.md`
fragment; the workflow stamps them into the merge's dated section and tags the merge commit
(`changelog.d/README.md`; [ADR 0001](../adr/0001-stamp-changelog-on-tag.md)). `Unreleased` stays
an empty placeholder.

## Version file

`VERSION` — the bare `<major>.<minor>.<build>` release line. It starts at `0.1.0`; `v0.0.0`, on the
last commit before the scheme, is the baseline the first stamp counts from and has no Release.

## Ask before bumping

when ambiguous
