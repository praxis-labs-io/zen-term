# Releasing

How a public ZenTerm release is cut, and the parts of `bin/release` that are
load-bearing. The `release` skill drives the flow; this file is the reference
behind it.

Public releases are cut locally with `bin/release`: preflight (clean main, cert,
notary profile) → `bin/check` → assemble and Developer ID sign (`bin/package-app`)
→ notarize and staple app and DMG → verify gates → curated notes → tag `vX.Y.Z` →
publish the DMG and the appcast to this repo's Releases. arm64-only. The version's
source of truth is the git tag.

## Retiring zen-term-releases

Through v0.10.0 the downloads lived in a second repo, `zen-term/zen-term-releases`,
because a private repo's Releases are not downloadable. v1.0.0 moved them here.

`SUFeedURL` is frozen into each build's Info.plist, so a copy installed before 1.0.0
polls the old appcast forever and no change to `bin/package-app` reaches it. At the
1.0.0 cut that was **7 downloads of the 0.10.0 DMG** and around 18 appcast polls a
day: three to five machines, all of them people we can message. So it was a one-time
hand-off rather than anything `bin/release` carries.

**That hand-off is done.** v1.0.0's `dist/appcast.xml` was uploaded to the old repo on
2026-08-23, under its own name and with no DMG: the enclosure inside points at the
asset here and `SUPublicEDKey` never changed, so the signature verifies. Every
pre-1.0.0 install that checks for updates now lands on this repo's feed.

**The repo is archived, and that is where it should stay.** Archiving makes it
read-only, not invisible: its Releases still serve, so the frozen pre-1.0.0 feed URL
still returns 200 and still hands back the v1.0.0 hand-off item. Verified against the
live URL at the v1.2.0 cut. Anyone still on an old build crosses over on their next
check with nothing to do by hand.

**Deleting it is the step that strands people, and it cannot be undone.** Delete the
repo and that frozen URL 404s forever. An install that has not checked since, a laptop
that was shut for a month, has no path back except downloading the DMG by hand, and the
failure is silent: no card, no toast, nothing that says why updates stopped. Archived
costs nothing. There is no deadline here, and no reason to force one.

If it is ever deleted, the signal to watch is the hand-off item's fetch count going
flat, which means nothing is polling any more:

```
gh release view v1.0.0 --repo zen-term/zen-term-releases \
    --json assets --jq '.assets[] | "\(.name) \(.downloadCount)"'
```

Do not publish anything else to the old repo. Creating a release there moves its
`latest` and repoints every machine still on the old feed, and there is no error and
no recovery short of a manual download when that goes wrong. Archiving already blocks
this, which is another reason to leave it archived.

## The website reads the repo

`zen-term-website`'s `scripts/sync-docs.mjs` pulls the config references and the
shipped third-party notices from `praxis-labs-io/zen-term`, and the release notes from
this repo's Releases API. ZEN-423 repointed it off `zen-term-releases`; run
`pnpm sync-docs` on a branch there after a release, then commit and merge.

**It reads published state, so ordering is the whole trap.** Run it before
`bin/release` has published and it syncs the previous version, succeeds, and commits
nothing new. There is no error. Confirm the new `content/release-notes/vX.Y.Z.md`
exists before opening the PR, and confirm the version is live on the page after the
merge, because merging is not deploying.

Three details in that script are load-bearing and cost a wrong document if changed:

- **Every fetch is pinned to the release tag**, not `main`. The notices have to match
  the binary that shipped, and a reference read off `main` documents config nobody is
  running yet.
- **The notices come from `Sources/ZenTerm/Resources/THIRD-PARTY-NOTICES.md`.** The
  lowercase `docs/third-party-notices.md` beside it is a maintainer re-probe procedure
  about something else. raw.githubusercontent is case-sensitive, so pointing at the
  lowercase path publishes the wrong document as the app's license disclosure. APFS is
  case-insensitive, so check this with `git ls-files` rather than `ls`.
- **The theme file is `themes/rose-pine-zen`**, renamed from `rose-pine-moon` in
  ZEN-416.

## Versioning

Bare `bin/release` patch-bumps the last tag. `bin/release major|minor|patch` picks
a component; `bin/release X.Y.Z` names one outright. A version is refused if it
does not ascend past the last tag, including one named by hand.

**Three guards there are load-bearing. Do not simplify them away.**

- **A tag already at HEAD means resume, not bump.** This is what stops a rerun from
  stranding a half-published tag.
- **`git describe` is `--match`ed to `vX.Y.Z`, and the resolved version is
  re-checked against the semver regex.** An unfiltered describe hands a `checkpoint`
  tag to the bump arithmetic and publishes the garbage.
- **The version resolves after `git fetch --tags`.** A stale local tag set otherwise
  publishes below what is already released.

**Rerun a failed run the way you invoked it**, `bin/release minor` again rather than
bare. Until the tag exists nothing records which bump an interrupted run intended, so
a run that died in notarization and is restarted bare resolves to a patch: `0.10.1`
where `0.11.0` was meant, published and permanent. Once the tag is there, any
invocation resumes it.

Two rules are not negotiable, because a published tag is permanent: never reuse a
version, even after a release that failed halfway, and never go backwards.

**What each component means**, for an app rather than a library. Breaking is about
the things someone built a habit or a config around: a chord that no longer does
what it did, a config key renamed or dropped, a default that flipped.

| Bump | Example | Means |
|---|---|---|
| **patch** | `1.0.0` → `1.0.1` | Fixes only. Nothing new, nothing moved. |
| **minor** | `1.0.0` → `1.1.0` | New features, nothing existing broke. |
| **major** | `1.0.0` → `2.0.0` | Something people relied on changed or went away. |

New features are a minor bump no matter how large they are. v1.0.0 is where the
0.x freedom to move chords and config keys without a major bump ended: from here,
breaking someone's config costs a major.

## Notes

Notes live in `docs/release-notes/vX.Y.Z.md`, one file per version, curated from the
git log into copy for the person downloading (`docs/brand-voice.md`, the "Release
notes" surface). Write the file, then cut the release pointed at it:

```
bin/release --notes-file docs/release-notes/vX.Y.Z.md
```

Bare `bin/release` opens `$EDITOR` on a raw scaffold instead, which is a starting
point, not the notes.

## Variants

`bin/package-app` alone produces the ad-hoc-signed daily-driver build and stamps
`<last-tag>+<commits since>` (e.g. `0.1.0+7`), so a dogfood bug report names an
exact build. It counts **commits, not PRs**: main carries direct-to-main commits
alongside squash-merges. `CFBundleVersion` stays the total commit count, because it
must be globally monotonic for Sparkle and `+N` resets at every tag.

`bin/package-app` defaults to the `dev` variant: it builds "ZenTerm Dev"
(`com.drucial.ZenTerm.dev`, its own icon, no Sparkle feed) to `~/Applications`, so
the daily driver runs beside the installed release without either one hiding the
other in Raycast or the Dock. `bin/release` passes `--variant release` for the
shipping identity ("ZenTerm", `com.drucial.ZenTerm`, release icon, public appcast).
Both variants read the same `~/.config/zen-term` config.

## One-time setup

A "Developer ID Application" cert in the keychain, and:

```
xcrun notarytool store-credentials zenterm-notary --apple-id <id> --team-id <team>
```

with an app-specific password, plus `gh auth login` with push access to this repo.

Keychain reachability from the tool shell is not a fixed property: password items
are ACL-gated to the requesting context and the grant persists once made. Run the
probe before claiming a credential is unreachable. Finder Automation (AppleScript)
is a **separate** TCC permission, so `bin/make-dmg`, which drives Finder, can fail
even when keychain reads succeed.

## Third-party notices

`Sources/ZenTerm/Resources/THIRD-PARTY-NOTICES.md` has to be re-probed when the
`vendor/ghostty` pin moves. The procedure is `docs/third-party-notices.md`.

The one thing worth knowing before you start: **probe the linked executable
(`.build/release/ZenTerm`), never `libghostty-fat.a` or `build.zig.zon`.** An
archive is a bag of object files the linker draws from selectively, and the manifest
lists what *could* link, most of it Linux-only. Probing the archive undercounted the
shipped library set by eight libraries.

## Auto-updates

Sparkle setup, the appcast, and how an update is verified: `docs/sparkle-auto-updates.md`.
