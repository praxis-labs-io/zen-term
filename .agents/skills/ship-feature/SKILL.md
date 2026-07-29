---
name: ship-feature
description: Run ZenTerm's feature-complete process in Codex, including Swift checks, documentation accuracy, draft PR creation, Copilot and Codex review, triage, fixes, CI verification, and GUI handoff. Manual invocation only when Drew asks to ship.
---

# Ship a ZenTerm feature

Read `.claude/skills/ship-feature/SKILL.md` completely and follow it as the canonical ZenTerm workflow with these Codex translations:

- At step 5, stop and ask Drew to run `/review`. Do not invoke it yourself or substitute an ordinary self-review.
- Treat `/review` findings as the canonical workflow's `/code-review` findings.
- Recommend `/review` for either the working diff or draft PR; Codex chooses the review target interactively.
- Use connected GitHub and Linear tools when available, with `gh` only where connector coverage is insufficient.

Preserve every ZenTerm-specific gate, especially Swift build/test verification, the optional `drive-dev-app` handoff, documentation accuracy, separate push and ready actions, explicit triage, GUI runbook handoff, and the prohibition on merging without direct instruction.
