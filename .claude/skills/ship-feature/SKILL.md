---
name: ship-feature
description: Run zen-term's feature-complete process — full local Swift check, gather /code-review (and Copilot if there's a remote) findings, triage them (fix / mitigate / ignore, no tech debt), then mark the PR ready for review. Invoke when an epic task/feature is built and ready to ship.
---

# Ship Feature (zen-term)

Swift/SwiftPM adaptation of the feature-complete process. Solo, terminal-native
tool — so the GitHub PR / Copilot steps are **conditional on a remote existing**.
Until zen-term has a remote, this runs as: local check → local review → triage →
move the Linear ticket. The discipline (no tech debt, everything triaged) is the
same regardless of remote.

## 1. Full local check

- Run `swift build`. Fix anything until it compiles clean.
- Run `swift test`. Fix until green.
- If a formatter/linter is configured (`.swift-format`, `swiftlint`), run it and
  resolve findings. If none is configured, skip — do not add one here.
- For work with GUI behavior no unit test covers, run `swift run ZenTerm` and
  confirm the plan's manual runbook expectations.

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

If a draft PR was opened, request a Copilot review via the GitHub MCP tools. It
runs async — continue and re-check later.

## 5. Run /code-review

Invoke `/code-review` against the working branch diff (works with or without a
remote). Capture its findings.

## 6. Gather combined findings

Merge `/code-review` findings with Copilot's (if any), de-duplicated.

## 7. Triage each finding

For every finding, decide **fix / mitigate / ignore** with a one-line reason.

- **Default to fixing** — no tech debt.
- **Mitigate** only when a full fix is genuinely out of scope; capture the
  residual as a **Linear ticket** (ZenTerm team), never a silent gap or an
  in-code `TODO`.
- **Ignore** only when the finding is wrong; say why.

Present the triage table to the user, apply the agreed fixes, then re-run
`swift build` + `swift test` (step 1) until green again.

## 8. Close out

- **If a PR exists:** mark it ready for review. Linear moves the ticket to **In
  Review** itself from there (auto-linked via the issue id) — don't set that
  status by hand.
- **Linear ticket:** update its description with any scope changes. On a
  local-only ship there's no PR to trigger the move, so set **In Review**
  yourself (status `c8f755f6-5c17-4bdd-b41f-9161166fdb19`, ZenTerm team). If no
  ticket exists yet, note that and skip.
- Report final state: branch, PR link (if any), build/test status, ticket status,
  and the triage summary.
