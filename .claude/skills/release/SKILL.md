---
name: release
description: Cut a public ZenTerm release end to end. Resolves the version, curates docs/release-notes/vX.Y.Z.md from the git log into copy for the person downloading, checks the docs that publish alongside it, runs the gate, hands over the bin/release command, then verifies what published and syncs the marketing site. Manual invocation only, never auto-run: use it when Drew asks to cut a release, not because main looks ready.
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

Then propose the semver bump (`docs/releasing.md` under "Versioning" governs which) and
**get Drew's confirmation before going further**. The version becomes a permanent
public tag and cannot be walked back, so it is never chosen silently.

**Name what will be broken by this cut before anything publishes**, so it is a decision
rather than a discovery. A surprise in phase 7 arrives after the tag, the DMG and the
appcast are public and permanent.

For **v1.0.0 specifically**: ZEN-423 repoints the website's `sync-docs`, and it cannot
be verified until a v1.0.0 release exists to sync from, so the cut goes first on
purpose. Expect phase 7 to publish nothing and do not treat that as a failure. The site
holds at v0.10.0 until ZEN-423 lands, then a re-run picks v1.0.0 up. Nothing about the
app, the feed, or the download is affected. Say this out loud at phase 1 rather than
discovering it at phase 7.

## 2. Check the docs that ship with it

Run the `update-documentation` skill across the release range.

This matters more here than at merge time. `docs/onboarding.md`, `docs/config/*`,
and the shipped `THIRD-PARTY-NOTICES.md` are public the moment the tag lands, and
the marketing site reads them from it, so a doc that is wrong at this moment becomes
the public documentation for a shipped version. v0.2.1 was itself a case
of this: a Settings row and the config reference both named a drawer-resize chord
that does nothing.

Fix what the range made wrong before writing the notes.

## 3. Curate the notes

Write `docs/release-notes/vX.Y.Z.md`. **Read `docs/brand-voice.md` first**, the
"Release notes" surface: curated, not a git log, written for the person
downloading rather than the person who wrote the patch.

Structure, as the existing files establish it:

- One line at the top saying what this release is.
- A `<!-- card ... -->` block of two to five `-` bullets: the short list the
  in-app update card shows. See below.
- `## New` / `## Fixed` / `## Changed`, only the ones that apply. Bold lead-in
  naming the thing, then plain sentences about what changed.
- `## Install` and `## Reporting a bug`.

The card block feeds the update card and nothing else. `bin/release` pulls just
these bullets into the appcast `<description>`; the full prose stays on the GitHub
release page, which the card's "What's new" links. HTML comments don't render on
GitHub, so the block is invisible there. `bin/release` refuses to publish a
release whose notes yield no bullets at all: it falls back to any top-level `-`
lines (which is what keeps the bare git-log scaffold working), but a curated notes
file is pure prose, so in practice that fallback finds nothing and this block is
what stands between the release and a blank card (which is what shipped for five
releases before ZEN-211). Put it right under the opening line:

    <!-- card
    - The one-line thing this release is about
    - Each other change worth a glance, in the app's voice
    -->

These are glanceable, not the prose: a few words each, no trailing period, the
change not the section name. Brand voice still governs them.

Check `## Install` against current reality rather than copying the last file
forward. It has already gone stale once: the pre-v0.2.0 notes say "re-download to
update", which stopped being true when auto-update shipped.

Before showing Drew, run the mechanical checks. These are cheap and catch what
rereading your own copy does not:

    grep -c '—' docs/release-notes/vX.Y.Z.md    # must be 0, per brand-voice
    grep -nEi 'seamless|powerful|beautiful|just works|simply|easily|quickly' docs/release-notes/vX.Y.Z.md
    awk '/<!--[[:space:]]*card/{f=1;next} f&&/-->/{f=0} f' docs/release-notes/vX.Y.Z.md | grep -c '^-'  # card bullets, must be >0

Then show Drew the notes and get approval. Copy is the deliverable here.

## 4. Gate

`bin/check`, fully green. Build, test, `swift format lint --strict`, and
`swiftlint --strict` are all part of it, and CI enforces them.

## 5. Hand over

Commit the notes to `main`, then give Drew the command. **Name the version
explicitly** — the exact `X.Y.Z` confirmed in phase 1:

    bin/release X.Y.Z --notes-file docs/release-notes/vX.Y.Z.md

**Never hand over bare `bin/release`.** Bare, it patch-bumps the last tag, and
`--notes-file` does *not* set the version, so a notes file named `v0.4.0.md`
ships as a patch anyway. That is exactly how a minor feature release went out as
`v0.3.1` instead of `v0.4.0` (a published tag is permanent, so the number could
not be corrected). Naming `X.Y.Z` in the command makes it match the notes
filename by construction and removes the whole class of error. Before handing it
over, confirm the `X.Y.Z` in the command is the version phase 1 chose, not
whatever a bare patch-bump would land on.

Two things worth saying alongside it: a rerun after a partial failure is safe and
**resumes** rather than bumping (a tag already at HEAD is the signal), and the
run needs Finder Automation for the DMG styling, which preflight checks up front.

Stop here. Do not run it.

## 6. After the run

Resume once Drew reports the run finished, and verify what actually landed
instead of trusting the exit code:

- `gh release view vX.Y.Z --repo praxis-labs-io/zen-term --json assets` shows
  **both** the DMG and `appcast.xml`. A release missing the appcast leaves every
  installed copy unable to see the update.
- **v1.0.0 only:** the hand-off in `docs/releasing.md` under "Retiring
  zen-term-releases". Nothing in `bin/release` does it, and an install from
  v0.10.0 or earlier has no other path to the update.
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
*published* state: raw.githubusercontent for the docs, and the GitHub Releases API for
the notes.

**Check where `sync-docs.mjs` actually points before running it.** Until ZEN-423 lands
it reads `zen-term/zen-term-releases`, a repo this project no longer publishes to, and
it fails by syncing nothing rather than by erroring.

**At the v1.0.0 cut that is expected.** The fix needs a published v1.0.0 to verify
against, so the release goes first. Record that the site is unsynced, leave ZEN-423
open, and re-run this phase once it merges. Do not hand-edit the site to paper over it.

From v1.0.1 on, an unsynced site is a real failure. Repointing is not a URL swap:
`docs/releasing.md`, under "The website reads the repo", lists the three paths that do
not exist here and the one whose obvious fix publishes the wrong license document.

Separately, ordering still matters: run it before `bin/release` has published and it
syncs the previous version, succeeds, and commits nothing new. This step always follows
phase 6, never precedes it.

Verify the new `content/release-notes/vX.Y.Z.md` actually appeared before opening
the PR. An empty diff here means the release had not published yet.

**Then confirm the version is actually live**, because merging is not deploying:

    curl -sL https://zenterm.io/releases | grep -o 'vX\.Y\.Z'

A green merge is not evidence the site updated. On v0.2.2 every check passed, the
merge landed, and the site still served the previous version a quarter of an hour
later (ZEN-205). Nothing in the flow noticed, because nothing looked. The release
is finished when the new version is on the page, not when the PR closes.
