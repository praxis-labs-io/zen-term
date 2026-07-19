---
name: release
description: Cut a public ZenTerm release end to end. Resolves the version, curates docs/release-notes/vX.Y.Z.md from the git log into copy for the person downloading, checks the docs that publish alongside it, runs the gate, hands over the bin/release command, then verifies what published and syncs the marketing site. Invoke when main is ready to ship.
---

# Release (zen-term)

`bin/release` already handles the mechanical half: signing, notarizing, stapling,
tagging, the appcast, the docs sync, the upload. It is careful and rerun-safe, and
this skill does not reimplement any of it.

What it does not do is judgement. Which commits a stranger cares about, what the
version should be, whether a doc about to become public is still true, and how
the notes read. That is this skill.

**Drew runs `bin/release` himself.** It publishes a permanent public tag and a
downloadable build, so phases 1 to 5 stop at handing over the command. Phases 6
and 7 resume once he reports it finished: a release is not done until the
artifacts are verified and the website carries the new version.

## 1. Scope the release

- `git fetch --tags`, then confirm `main` is checked out, clean, and even with
  origin. Anything else stops here.
- `git log <last-tag>..HEAD --no-merges` for the range.
- Sort every commit into **user-facing** or **internal**, and show the split.
  Internal work is most of a typical range: build scripts, CI, agent config,
  refactors, test-only changes. It does not appear in the notes.
- A commit is user-facing if someone who only runs the app would notice, or if it
  changes what they download, install, or read.

Then propose the semver bump (the README's "Version numbers" governs which) and
**get Drew's confirmation before going further**. The version becomes a permanent
public tag and cannot be walked back, so it is never chosen silently.

## 2. Check the docs that ship with it

Run the `update-documentation` skill across the release range.

This matters more here than at merge time. `bin/release` publishes
`docs/onboarding.md`, `docs/config/*`, and `THIRD-PARTY-NOTICES.md` into the
public releases repo as part of the run, so a doc that is wrong at this moment
becomes the public documentation for a shipped version. v0.2.1 was itself a case
of this: a Settings row and the config reference both named a drawer-resize chord
that does nothing.

Fix what the range made wrong before writing the notes.

## 3. Curate the notes

Write `docs/release-notes/vX.Y.Z.md`. **Read `docs/brand-voice.md` first**, the
"Release notes" surface: curated, not a git log, written for the person
downloading rather than the person who wrote the patch.

Structure, as the existing files establish it:

- One line at the top saying what this release is.
- `## New` / `## Fixed` / `## Changed`, only the ones that apply. Bold lead-in
  naming the thing, then plain sentences about what changed.
- `## Install` and `## Reporting a bug`.

Check `## Install` against current reality rather than copying the last file
forward. It has already gone stale once: the pre-v0.2.0 notes say "re-download to
update", which stopped being true when auto-update shipped.

Before showing Drew, run the mechanical checks. These are cheap and catch what
rereading your own copy does not:

    grep -c '—' docs/release-notes/vX.Y.Z.md    # must be 0, per brand-voice
    grep -nEi 'seamless|powerful|beautiful|just works|simply|easily|quickly' docs/release-notes/vX.Y.Z.md

Then show Drew the notes and get approval. Copy is the deliverable here.

## 4. Gate

`bin/check`, fully green. Build, test, `swift format lint --strict`, and
`swiftlint --strict` are all part of it, and CI enforces them.

## 5. Hand over

Commit the notes to `main`, then give Drew the command:

    bin/release --notes-file docs/release-notes/vX.Y.Z.md

Two things worth saying alongside it: a rerun after a partial failure is safe and
**resumes** rather than bumping (a tag already at HEAD is the signal), and the
run needs Finder Automation for the DMG styling, which preflight checks up front.

Stop here. Do not run it.

## 6. After the run

Resume once Drew reports the run finished, and verify what actually landed
instead of trusting the exit code:

- `gh release view vX.Y.Z --repo zen-term/zen-term-releases --json assets` shows
  **both** the DMG and `appcast.xml`. A release missing the appcast leaves every
  installed copy unable to see the update.
- The `docs: sync from ZenTerm vX.Y.Z` commit landed in the releases repo.
- The appcast's `sparkle:version` matches the shipped build.
- Mount the DMG and check the volume root: only the app, the Applications
  symlink, `.background`, and `.DS_Store`. See `bin/make-dmg`'s header for why
  this is worth a look every time (ZEN-203).

Shipped tickets are already **Done** from their merges, so there is no Linear
status work here.

## 7. Sync the website

The release is not finished when the DMG is up. The marketing site carries the
docs and the release notes, and it does not update itself.

In `~/Dev/zen-term-website`, on a branch off `main`:

    pnpm sync-docs

Then commit the new `content/release-notes/vX.Y.Z.md` (plus any changed doc it
pulled), open a PR, and merge. Render deploys from `main`.

**Order matters and the failure is silent.** `scripts/sync-docs.mjs` reads the
*published* state: `raw.githubusercontent.com/zen-term/zen-term-releases/main/docs`
for the docs, and the GitHub Releases API for the notes. Run it before
`bin/release` has published and it syncs the previous version, succeeds, and
commits nothing new. This step always follows phase 6, never precedes it.

Verify the new `content/release-notes/vX.Y.Z.md` actually appeared before opening
the PR. An empty diff here means the release had not published yet.
