---
name: update-documentation
description: Use when a change ships that could make documentation wrong: a new or changed config key, workspace field, theme concept, install/onboarding step, keyboard shortcut, or any user-facing behavior a doc describes. Also the doc-accuracy step of ship-feature, before marking a PR ready.
---

# Update documentation

## Overview

ZenTerm's docs have **one authoring source of truth: this repo's `docs/`**.
Automation carries most of it downstream to the public releases repo and the
marketing site. Your job on any change:

1. Edit the affected source doc **here**, in `docs/`.
2. **Flag** only the downstream work automation won't carry. Never reach into
   another repo from a zen-term branch.

**Verify the fact against the code before you write it.** The ticket's spelling
can be wrong: keys are ghostty-flavored dash form (`cursor-style`, not
`cursor.style`), unknown keys are silently ignored, so a wrong key documents a
value that does nothing. Read the parser/default, not the ticket.

## The map: what lives where, what it feeds

| Source doc (edit here) | Covers | Flows downstream to |
|---|---|---|
| `docs/config/config` | every config key + default | `bin/release` → releases repo → website `reference/config` (`sync-docs`, drift-checked) |
| `docs/config/workspaces` | workspace file fields | same path → website `reference/workspaces` |
| `docs/config/themes/` | example theme file | `bin/release` → releases repo → website `reference/themes` (`sync-docs`) |
| `docs/onboarding.md` | first-run / install narrative | `bin/release` → releases repo. Website has its own install Guide |
| `docs/architecture.md` | the one architecture doc | internal, not shipped |
| `docs/gui-runbook.md` | how to hand over a manual check list | internal, not shipped |
| `docs/releasing.md` | `bin/release`, versioning guards, notarization | internal, not shipped |
| `docs/third-party-notices.md` | re-probing the notices after a ghostty pin move | internal, not shipped |
| `docs/sparkle-auto-updates.md` | how updates ship, and how to verify one | internal, not shipped |
| `docs/release-notes/vX.Y.Z.md` | per-version notes | curated at release. One file per version; never edit a shipped one |
| `README.md` | this repo's readme | not mirrored; releases + website READMEs are separate, hand-kept (ZEN-123) |

**Never hand-edit downstream.** `zen-term-releases/docs/*` is written by
`bin/release`; `zen-term-website/content/reference/*` is synced verbatim and its
drift check reverts hand edits. Editing either by hand is overwritten.

## Flag triggers: automation stops here

A config or workspaces **value** change needs no flag: it flows on release and
the website's weekly drift check pulls it. Flag the rest, because automation does
not carry it:

| The change | Why it doesn't flow | Flag |
|---|---|---|
| A theme concept | the example theme file syncs on its own, but the website `theming` Guide is authored MDX | edit the website `theming` Guide |
| A **new** `docs/config/<file>` | `sync-docs` FILES is `config`, `workspaces`, `themes/rose-pine-moon`, so a new file is never fetched and no reference page exists | add it to `sync-docs.mjs` FILES + a website reference page |
| Behavior a Guide narrates (install, panes, shortcuts, workspaces, tool-floats, neovim) | those are authored MDX (`app/docs/*/page.mdx`), not parsed from facts | edit that website Guide |
| Install steps, download link, or positioning copy | releases + website READMEs are hand-kept | ZEN-123 |

**A flag is a Linear ticket (ZenTerm team) plus a line in your ship summary.**
Never a silent gap, never an in-code `TODO`. You can't commit another repo's
change from this branch, so name it and move on.

## Common mistakes

- **Treating "docs" as this repo only.** The strong instinct is to edit
  `docs/config/config` and stop. That file feeds a public mirror and a website;
  a new-file change, or behavior a Guide narrates, needs a flag or it silently
  never reaches users.
- **Hand-editing the releases mirror or `content/reference/`.** Both are
  regenerated; your edit is lost and the drift check reddens CI.
- **Fabricating a doc for a key that already exists** (or under a wrong
  spelling). Grep the reference and read the code first.
- **Editing a shipped `release-notes/vX.Y.Z.md`.** Those are per-version and
  frozen; a later change gets the next version's file at release time.
