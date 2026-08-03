---
name: ship-feature
description: Run Drew's feature-complete process in Codex, including checks, draft PR creation, Copilot review, Codex review, triage, fixes, CI verification, and GUI handoff. Manual invocation only when Drew asks to ship.
---

# Ship a completed feature

Read `.claude/skills/ship-feature/SKILL.md` completely and follow it as the canonical workflow with these Codex translations:

- At step 5, stop and ask Drew to run `/review`. Do not invoke it yourself or substitute an ordinary self-review.
- Treat `/review` findings as the canonical workflow's `/code-review` findings.
- Recommend `/review` for either the working diff or the draft PR; Codex chooses the review target interactively.
- Use connected GitHub and Linear tools when available, with `gh` only where connector coverage is insufficient.

Preserve every gate, especially separate push and ready-for-review actions, explicit finding triage, the interactive-runbook closeout, and the prohibition on merging without direct instruction.
