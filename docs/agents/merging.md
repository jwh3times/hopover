# Merging

From an open pull request to a merged release. What CI runs is in `open-pr.md`; this file holds
the steps around a merge.

## Before merging

- **Bound every wait on checks.** A check can stay `pending` in `gh pr checks` after its job
  finished, so `gh pr checks --watch` can hang. When the run reads `completed` and one check is
  still pending, read the job directly (`gh api repos/jwh3times/hopover/actions/jobs/<id>`): merge
  when it has a `conclusion` of success and the PR's `mergeStateStatus` is `CLEAN`.
- **`BLOCKED` with every check green is usually a new CodeQL alert.** The `main` ruleset blocks a
  merge on any new alert (errors and warnings, or medium security severity and up), and neither
  `gh pr view` nor GraphQL says why. Query the PR's head ref:
  `gh api "repos/jwh3times/hopover/code-scanning/alerts?ref=refs/pull/<N>/head&state=open"`. A job
  with no `permissions:` of its own, in a workflow with no top-level block, raises
  `actions/missing-workflow-permissions`; both workflows set one, so a new workflow needs it too.

## Merging several PRs

`main` requires branches up to date, and auto-merge is disabled for the repository (`--auto` is
refused). Once one PR merges, the next shows `BEHIND`: `gh pr update-branch <n>`, poll
`mergeStateStatus` until `CLEAN`, then `gh pr merge <n> --merge`.

- **PRs merge in any order.** No branch names a version or edits `CHANGELOG.md`: each writes its
  own `changelog.d/<branch-slug>.md` fragment
  ([ADR 0001](../adr/0001-stamp-changelog-on-tag.md)), so open PRs don't collide over the changelog.
- **Wait for the stamp before updating the next branch.** About a minute after each merge, the
  release workflow's `tag` job pushes a `chore(release): v<x.y.z> [skip ci]` commit that moves
  `main` again. Run `gh pr update-branch` after that, or the branch needs a second update and a
  second CI run.

## After the merge

**Find the release run by commit.** Select the `Release` run whose `headSha` is the merge commit
(`gh run list --workflow release.yml --json databaseId,headSha,status,conclusion`); right after a
merge, `--limit 1` can return the previous one. Its `tag` job stamps the merge's section into
`CHANGELOG.md`, deletes its fragment, pushes the stamp commit as the release App's bot, tags the
merge commit, creates the GitHub Release and attaches `hopover-<version>.zip`. Confirm with
`git tag --points-at <merge commit>`: the tag is on the merge, not on `main`'s new tip.

- **A run that ends "main moved during this run" is not a failure**: the run queued behind it
  releases both merges. Any other failed run leaves its merges untagged until a later run succeeds,
  so re-run it once the cause is fixed.
- **A release App token that fails to mint** means the `RELEASE_APP_CLIENT_ID` variable, the
  `RELEASE_APP_PRIVATE_KEY` secret (both in the `release` environment) or the App's installation
  on this repository is gone. A stamp push rejected with `GH013` means a rule the App cannot
  bypass now applies to `main`: `main`'s protection lives only in rulesets, with the App as the
  `Main branch rules` bypass actor.
- **The stamp commit runs no workflow.** Its `[skip ci]` keeps CI and `Release` off it, so its
  CodeQL analysis is the only run it shows. Nothing deploys from `main`.

## Release workflow

`release.yml`
