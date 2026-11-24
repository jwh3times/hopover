# Human follow-up

Required human actions left by completed agent work follow the procedure in the installed skills'
`human-follow-up` settings definition (`.agents/skills/end-session/settings/human-follow-up.md`).
Every setting there keeps its default here: a follow-up is an issue in the private issue repository
(`issue-tracker.md`), labelled `ready-for-human`, on the same board, with its steps on the private
repository's wiki. The agent that completes the work owns the follow-up; docs-updater, open-pr and
end-session verify it.
