---
name: ship-feature
description: Run zen-term's feature-complete process. Full local Swift check, gather /code-review (and Copilot if there's a remote) findings, triage them (fix / mitigate / ignore, no tech debt), then mark the PR ready for review. Manual invocation only, never auto-run: use it when Drew asks to ship, not because a feature looks finished.
---

# Ship Feature (zen-term)

Swift/SwiftPM adaptation of the feature-complete process. Solo, terminal-native
tool, so the GitHub PR / Copilot steps are **conditional on a remote existing**.
Until zen-term has a remote, this runs as: local check → local review → triage →
move the Linear ticket. The discipline (no tech debt, everything triaged) is the
same regardless of remote.

## 1. Full local check

- Run `swift build`. Fix anything until it compiles clean.
- Run `swift test`. Fix until green.
- If a formatter/linter is configured (`.swift-format`, `swiftlint`), run it and
  resolve findings. If none is configured, skip; do not add one here.
- For work with GUI behavior no unit test covers, run `swift run ZenTerm` and
  confirm it yourself as far as the tool shell allows. What you can't verify
  (anything needing eyes on screen) becomes the handover runbook in step 8 —
  written in chat, never written to disk. See `docs/gui-runbook.md`.

Do not proceed until build + tests are green.

## 2. Documentation accuracy

Run the `update-documentation` skill against this change. It carries ZenTerm's
docs topology (the authoring source of truth in `docs/`, and what `bin/release`
and the website sync carry downstream), so any doc a change makes wrong gets
edited here and any cross-repo work gets flagged rather than silently dropped.

Do this **before** opening the PR so the doc edits land in the diff `/code-review`
and Copilot see. Fold any downstream flags into your close-out summary.

## 3. Determine remote state

- `git remote -v`. If there is **no remote**, this is a local-only ship: skip
  steps 3–5's Copilot/PR actions, keep the branch committed, and go to step 6
  running `/code-review` locally. Note in your summary that PR flow activates once
  a remote exists.
- If there **is** a remote, push the branch and open the PR **as a draft**, with
  the Linear issue id in the title/body. Use Linear's generated branch name.

## 4. Request a Copilot review (remote only)

If a draft PR was opened, request a Copilot review. It runs async, so continue and
re-check later.

**`gh pr edit --add-reviewer` cannot do this.** It lowercases the login and fails
with "Could not resolve user with login 'copilot'", and
`copilot-pull-request-reviewer[bot]` is the login Copilot *reviews as*, not a
requestable one. Both read like Copilot is unavailable; it isn't. Use the GraphQL
`requestReviews` mutation with the Bot's node id:

```bash
PR_ID=$(gh api graphql -f query='query { repository(owner:"zen-term",name:"zen-term"){ pullRequest(number:NNN){ id } } }' --jq '.data.repository.pullRequest.id')
BOT_ID=$(gh api graphql -f query='query { repository(owner:"zen-term",name:"zen-term"){ suggestedActors(capabilities:[CAN_BE_ASSIGNED],first:20){ nodes{ ... on Bot { id login } } } } }' --jq '.data.repository.suggestedActors.nodes[] | select(.login=="copilot-swe-agent") | .id')
gh api graphql -f query='mutation($pr:ID!,$bot:ID!){ requestReviews(input:{pullRequestId:$pr, botIds:[$bot], union:true}){ pullRequest{ reviewRequests(first:10){ nodes{ requestedReviewer{ ... on Bot { login } } } } } } }' -f pr="$PR_ID" -f bot="$BOT_ID"
```

The requestable actor is `copilot-swe-agent`; it comes back as
`copilot-pull-request-reviewer` in the confirmation, which is expected. Resolve the
id from `suggestedActors` rather than hardcoding it, and if that query returns no
Bot, say the request failed rather than that Copilot is unavailable.

## 5. Run /code-review

Invoke `/code-review` against the working branch diff (works with or without a
remote). Capture its findings.

## 6. Gather combined findings

Merge `/code-review` findings with Copilot's (if any), de-duplicated.

## 7. Triage each finding

For every finding, decide **fix / mitigate / ignore** with a one-line reason.

- **Default to fixing.** No tech debt.
- **Mitigate** only when a full fix is genuinely out of scope; capture the
  residual as a **Linear ticket** (ZenTerm team), never a silent gap or an
  in-code `TODO`.
- **Ignore** only when the finding is wrong; say why.

Present the triage table to the user, apply the agreed fixes, then re-run
`swift build` + `swift test` (step 1) until green again.

## 8. Close out

- **If a PR exists:** mark it ready for review. Linear moves the ticket to **In
  Review** itself from there (auto-linked via the issue id); don't set that
  status by hand.
- **Linear ticket:** update its description with any scope changes. On a
  local-only ship there's no PR to trigger the move, so set **In Review**
  yourself: `save_issue` with `state: "In Review"` on the ZenTerm team. Address
  the status by name, never a UUID (per CLAUDE.md) — the workspace move
  invalidated every hardcoded id. If no ticket exists yet, note that and skip.
- Report final state: branch, PR link (if any), build/test status, ticket status,
  and the triage summary.
- **Hand over a runbook for this PR, in the response itself.** A markdown
  checklist of what Drew should look at on screen, one per PR: the things a test
  can't judge (layout, motion, color, a new chord crossing `KeyInterceptor`) and
  anything the change could plausibly have broken that CI would still call green.
  Each item names where to go, what to do, and what right looks like, so it can be
  worked down without re-reading the diff. Lead with the check most likely to
  catch a regression, and say plainly which behavior has no test behind it.
  **Never write these to disk.** `docs/gui-runbook.md` is the one standing runbook
  and it holds the instructions for building a handover list, not the lists
  themselves. A per-ticket section written into `docs/` goes stale the moment it
  ships.
