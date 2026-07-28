---
name: ship-feature
description: Run zen-term's feature-complete process. Full local Swift check, doc accuracy pass, draft PR, gather Copilot + /code-review findings, triage them (fix / mitigate / ignore, no tech debt), apply, push again, then mark the PR ready for review. Manual invocation only, never auto-run: use it when Drew asks to ship, not because a feature looks finished.
---

# Ship Feature (zen-term)

Swift/SwiftPM adaptation of the feature-complete process. Solo, terminal-native
tool, so verification leans on a GUI someone has to look at — step 1 and the
step 9 handover runbook carry that weight, and no green CI substitutes for
either.

zen-term ran without a remote for part of its life; it has one now
(`zen-term/zen-term`), so the PR path is unconditional. That history is also why
the PR path is the one exercised least and trusted most — see step 8.

## 1. Full local check

- Run `swift build`. Fix anything until it compiles clean.
- Run `swift test`. Fix until green.
- If a formatter/linter is configured (`.swift-format`, `swiftlint`), run it and
  resolve findings. If none is configured, skip; do not add one here.
- For work with GUI behavior no unit test covers, run `swift run ZenTerm` and
  confirm it yourself as far as the tool shell allows. What you can't verify
  (anything needing eyes on screen) becomes the handover runbook in step 9 —
  written in chat, never written to disk. See `docs/gui-runbook.md`.

Do not proceed until build + tests are green.

### 1a. Offer to drive the machine-checkable steps — Drew's call

Some runbook steps have an outcome a machine can check: a process exited, a port
freed, a window closed. The `drive-dev-app` skill runs those against a real
`bin/run` build instead of spending Drew's attention on them.

**Offer it and wait. Never auto-run it.** It synthesizes real keyboard input into
a real session, and macOS cannot scope that to one app, so it goes when Drew asks
and not because a step looks automatable. Name the steps you mean:

> Steps 2, 4 and 5 have machine-checkable outcomes. Want me to drive them with
> `drive-dev-app`, or would you rather run the whole runbook yourself?

If he says yes, report those results in step 9 **as driven**, and say plainly
which steps a machine checked and which still need his eyes. The eyes-only ones
still go to him as the handover list. If he declines, or the TCC permissions are
missing, everything goes to the handover list as usual.

## 2. Documentation accuracy

Run the `update-documentation` skill against this change. It carries ZenTerm's
docs topology (the authoring source of truth in `docs/`, and what `bin/release`
and the website sync carry downstream), so any doc a change makes wrong gets
edited here and any cross-repo work gets flagged rather than silently dropped.

Do this **before** opening the PR so the doc edits land in the diff `/code-review`
and Copilot see. Fold any downstream flags into your close-out summary.

## 3. Push the branch and open the PR as a draft

Push the branch, then open the PR **as a draft** — review happens before a full
CI run is spent. Put the Linear issue id in the title and body so Linear
auto-links it, and use Linear's generated branch name rather than inventing one.

## 4. Request a Copilot review

Request a Copilot review on the draft PR. It runs async, so continue and re-check
later.

**`gh pr edit --add-reviewer` cannot do this.** It lowercases the login and fails
with "Could not resolve user with login 'copilot'", and
`copilot-pull-request-reviewer[bot]` is the login Copilot _reviews as_, not a
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

**Never `@copilot`, in a comment or anywhere else.** The mutation above is the only
way to request a review. An `@`-mention summons it out of band, and it re-fires on
every edit of the comment that carries it. Read its findings from the review
comments and write your triage as ordinary prose that does not address it. This
holds for every comment on the PR, the description included.

## 5. Run /code-review — Drew runs this, not you

**Stop here and ask.** `/code-review` is user-triggered and billed; a session
cannot invoke it — not via the Skill tool, not via Bash, not via a Workflow.
Don't try, and don't treat the failure as a bug to route around.

Say plainly that you're blocked on this and what to run:

- `/code-review` for the working diff
- `/code-review ultra` for a multi-agent review of the branch, or
  `/code-review ultra <PR#>` for the draft PR opened in step 3

Then **wait** for the findings before starting step 6. Don't run steps 6–9 while
you wait — the triage in step 7 needs every source in front of it.

If Drew declines or says to skip it, continue with whatever Copilot produced and
**say so in the step 6 output** — that leaves a solo repo's review resting on one
bot. What you must never do is run your own review pass and present it as
`/code-review`'s findings; name which review actually produced each finding.

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

## 8. Push the fixes, then mark ready — as two separate actions

**Push, let the push register, and only then mark the PR ready. Never chain
them** (`git push && gh pr ready`).

Both emit a webhook — `synchronize` and `ready_for_review`. Fired in the same
instant they land in the same CI concurrency group, so one cancels the other,
and the survivor is often the `synchronize` run, whose payload still says
`draft: true` and therefore skips every job. The PR then shows skipped checks,
which look like passes at a glance, with no CI having run at all. It is a
failure that reports success, and only reading the run list reveals it.

Keying the workflow's concurrency group on `github.event.action` fixes it
repo-side, but don't assume that's configured — separate the two actions
regardless.

After marking ready, **confirm CI actually started** (`gh pr checks` or the run
list). "Skipping" is not "passing". If nothing ran, close and reopen the PR to
fire a clean `reopened` event rather than pushing an empty commit.

This one bites harder here than elsewhere: zen-term spent part of its life
without a remote, so the PR path is the branch you exercise least and trust
most. Read the run list; don't infer from the checks badge.

## 9. Close out

- **Let Linear move the ticket.** Marking the PR ready in step 8 moves it to
  **In Review** on its own (auto-linked via the issue id in the branch/PR). Don't
  set that status by hand — a manual move is a second copy of a transition the
  integration owns, and it drifts the moment the automation changes.
- **Move it yourself only if the automation didn't fire.** Check first, then
  `save_issue` with `state: "In Review"` on the ZenTerm team. Address the status
  **by name, never a UUID** (per CLAUDE.md) — the workspace move invalidated
  every hardcoded id. Say in your summary that you moved it by hand and why.
- **Linear ticket:** update its description with any scope changes uncovered
  during the build. If no ticket exists yet, note that and skip.
- **Never merge.** Shipping ends at "ready for review"; merge only on an explicit
  instruction to merge. Solo repo, no second approver — nothing else stops it.
- Report final state: branch, PR link, CI status (from an actual check, not an
  assumption), build/test status, ticket status, and the triage summary.
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
