---
status: accepted
---

# Stamp each merge's changelog section when it is tagged, not when it ships

Every merge to `main` is a release, `v<major>.<minor>.<build>`, and no branch names the version its
merge will mint. `/open-pr` writes the branch's entries to its own `changelog.d/<branch-slug>.md`
fragment and never edits `CHANGELOG.md`; after the merge, `.github/workflows/release.yml` runs
`scripts/stamp-changelog.mjs`, which turns each untagged merge's fragments (or, with none, its PR
title) into a dated section, commits the sections with `[skip ci]`, tags the merge commit, and
creates a GitHub Release with the tool attached as `hopover-<version>.zip`. The version is
`scripts/next-version.mjs`'s computation over `VERSION` and the tags, made once, at tag time, over
the merges in the order they landed.

Hopover adopts this from the start, as the other `jwh3times` repositories did after trying
`per-merge`: predicting the version on the branch meant every merge invalidated every open PR's
changelog section, so branches shipped one at a time and a Dependabot merge turned green PRs red.
Fragments cannot collide, and a merge that wrote none still gets a section. The scheme had no tag to
count from, so `v0.0.0` was placed on the last commit before it, and the first merge under it
releases `0.1.0` as `VERSION` declares.

The stamp commit goes straight to `main`, which the ruleset otherwise forbids, so the workflow
pushes it with a token from a release GitHub App listed as the ruleset's one bypass actor
(`GITHUB_TOKEN` cannot be one). Every first-parent commit on `main` is a release, so squash and
rebase merging stay off. The scheme and its operating rules are `stamp-on-tag` in
`jwh3times/skills`, which holds the canonical scripts.
