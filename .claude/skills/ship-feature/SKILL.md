---
name: ship-feature
description: Run my feature-complete PR process: full local check, push, open a draft PR, gather Copilot + /code-review findings, triage them (fix / mitigate / ignore, no tech debt), apply, push again, then mark the PR ready for review. Invoke when a feature build is complete and ready to ship.
---

# Ship a completed feature

Drive my feature-complete PR process end to end. Work through the steps in order; do not skip ahead, and report results at each gate rather than silently continuing.

**This file is the source of truth; the copies in project repos are downstream.** Each repo carries a real copy rather than a symlink, because a cloud session clones that repo on its own. A link into a sibling checkout would dangle there, and the skill would silently not exist in the one place it can't be fixed by hand. Propagation is manual: edit this file, then copy it into each repo yourself. Never edit a repo's copy directly, because the next copy-out silently discards it and the fix is lost.

**Every repo gets the same copy. No repo gets a bespoke version.** Nothing below names an ecosystem, a package manager, or a tracker. Where a step needs a project-specific command, it says how to find it in the repo rather than assuming one. If you hit something that seems to need a local fork of this file, that is a gap in this file: say so and fix it here.

## 1. Full local check

Find the repo's own check command before running anything. Look in its `CLAUDE.md` or `AGENTS.md` first, then its build manifest or task runner, then its CI workflow, which names the commands that have to pass anyway. Ask me if none of those settle it. Never assume an ecosystem's conventional command.

Run whatever that resolves to: format, lint, typecheck, and the test or coverage gate.

- If anything fails, fix it and re-run until green. Catch issues locally so they don't burn a CI run.
- Do not push until the check is fully green.
- Where the repo ships docs that describe the code you changed, check they still match. A stale doc is a defect the diff introduced.

## 2. Push the branch

Confirm you are on a feature branch first. If the work sits on the default branch, stop and say so rather than pushing; the commits need moving to a branch before anything else here applies.

Commit and push (`git push -u origin <branch>`). Use the tracker's generated branch name; don't invent one.

This is its own step deliberately. Buried inside the PR step as "confirm the branch is pushed", it stops reading as a discrete action, and becomes something to chain onto another command. Step 9 is where that chaining has already caused a silent CI failure.

## 3. Open the PR as a draft

- Open the PR **as a draft**, so review happens before a full CI run is spent (especially where CI is gated to skip drafts).
- Title and body reference every tracking ticket the PR closes, so the tracker auto-links them.

## 4. Request a Copilot review

One REST call, against the reviewer login `Copilot`. `{owner}/{repo}` resolves from the current repo, so this is the same line everywhere:

```bash
gh api -X POST 'repos/{owner}/{repo}/pulls/<PR#>/requested_reviewers' -f 'reviewers[]=Copilot'
```

The response carries `requested_reviewers`, and a live request shows `Copilot` there. That response is the confirmation. Read it instead of re-querying. It reviews as `copilot-pull-request-reviewer[bot]`, so `Copilot` and that login are one bot, not a failed request.

`gh pr edit <PR#> --add-reviewer @copilot` does the same thing in one line, but only on gh 2.96 or newer, and never against GitHub Enterprise Server. Use the REST call when you don't know which you have.

**An empty reviewer list is not a failed request.** A reviewer drops out of `requested_reviewers` the moment it submits, and Copilot is quick, so an empty list often means the review already landed. Check for the review itself with the step 6 command before concluding anything.

**Never confirm with `gh pr view --json reviewRequests`.** It omits Bot reviewers and returns `[]` while the request is live.

**Never fall back to GraphQL, and never resolve a bot id from `suggestedActors`.** That lookup returns `copilot-swe-agent`, the coding agent, not the reviewer. The `requestReviews` mutation accepts its id, reports success, and requests nothing. This file prescribed that route until 2026-08-02 and it cost two PRs' worth of false "Copilot is broken" diagnosis. Two more repos rebuilt it from scratch in 2026-08-09 after reading an empty reviewer list as a failure. If the REST call above returns an error, report the error; do not invent a second path.

**Never write `@copilot` in comment text**, on the PR or in its description. The call above is the only way to request a review. A mention in prose summons it out of band and re-fires on every edit of the comment carrying it. Read its findings from the review comments and write your triage as prose that does not address it.

It runs async; continue and re-check later.

## 5. Run /code-review, which I type, not you

**Stop here and ask me.** `/code-review` is marked `disable-model-invocation`. The Skill tool refuses it with "cannot be used with Skill tool", and no other route works either. The same holds for `/code-review ultra`. Don't try, and don't treat the refusal as a bug to route around.

Say plainly that you're blocked and what to type:

- `/code-review` for the working diff, effort per the global rule
- `/code-review ultra`, or `/code-review ultra <PR#>`, for the cloud multi-agent pass on a large or risky diff

**The plugin `/code-review:code-review` is not a substitute.** It checks draft state first and declines without reviewing, and the PR from step 3 is a draft by design.

**Do not substitute your own agent pass.** Fanning out finder agents over the diff and presenting the result is the exact failure this step exists to prevent.

Step 6 proceeds while you wait; Copilot runs on its own clock. Steps 7 to 10 block, because the triage in step 8 needs both sources. If I decline or say skip, continue with Copilot as the only source and **say so in the step 7 output**. Name which review produced each finding.

## 6. Pull down Copilot's review

Copilot writes to two places and you need both. Line comments:

```bash
gh api 'repos/{owner}/{repo}/pulls/<PR#>/comments' --jq '.[] | "\(.path):\(.line) \(.body)"'
```

And the review body, which carries its summary and per-file notes:

```bash
gh api 'repos/{owner}/{repo}/pulls/<PR#>/reviews' --jq '.[] | select(.user.login=="copilot-pull-request-reviewer[bot]") | .body'
```

**Zero line comments does not mean zero findings.** A review commonly lands with an empty `comments` array and everything in the review body. Read both before concluding Copilot flagged nothing.

The body states how many files it reviewed. If that falls short of the changed file count, say so in step 7 rather than treating the review as complete coverage.

Re-check if nothing is posted yet; it runs async.

## 7. Review the combined findings

Merge Copilot's comments and `/code-review`'s findings into a single list. De-duplicate where both flag the same thing.

## 8. Triage each finding

For every finding, recommend one of: **fix**, **mitigate**, or **ignore**, each with an explicit one-line reason.

- **Default to fixing.** Do not leave tech debt.
- **Mitigate** only when a full fix is out of scope for this PR. Capture the residual as a tracked follow-up, never a silent gap.
- **Ignore** only when the finding is wrong or genuinely not worth it. Say why.

Present the triage table to me, apply the agreed fixes, and re-run step 1 until green.

## 9. Push the fixes, then mark ready, as two separate actions

**Push, let the push register, and only then mark the PR ready. Never chain them** (`git push && gh pr ready`).

Both emit a webhook, `synchronize` and `ready_for_review`. Fired in the same instant they land in the same CI concurrency group, so one cancels the other, and the survivor is often the `synchronize` run, whose payload still says `draft: true` and therefore skips every job. The PR then shows skipped checks, which look like passes at a glance, with no CI having run at all. It is a failure that reports success.

Keying the concurrency group on `github.event.action` fixes it repo-side, but don't assume that's configured. Separate the two actions regardless.

After marking ready, **confirm CI actually started** (`gh pr checks` or the run list). "Skipping" is not "passing". If nothing ran, close and reopen the PR to fire a clean `reopened` event rather than pushing an empty commit.

## 10. Close out

- **Let the tracker move the ticket.** Where the tracker has a PR integration (Linear does, via the ticket id in the branch/PR), marking the PR ready moves it to **In Review** on its own. Don't write that status by hand. A manual move is a second copy of a transition the integration owns, and it drifts the moment the automation changes.
- **Move it yourself only when nothing else will:** no PR (a local-only ship), or a tracker with no PR integration. Note which case applies.
- **Tracking ticket:** update it with any scope changes uncovered during the build. If no ticket exists, note that and skip.
- **Never merge.** Shipping ends at "ready for review"; merge only on an explicit instruction to merge.

Report the final state: PR link, CI status (from an actual check, not an assumption), ticket status, and the triage summary. Say plainly what was verified and what wasn't. A green CI is not a substitute for anything that needed eyes on a screen.

If the change has manual checks, invoke the global `interactive-runbook` skill and work through them with me one at a time before declaring the shipping run complete. Do not substitute an unattended driver or print the whole checklist and leave it as a handoff.
