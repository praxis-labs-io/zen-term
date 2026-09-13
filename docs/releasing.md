# Releasing

How a public ZenTerm release is cut, and the parts of `bin/release` that are
load-bearing. The `release` skill drives the flow; this file is the reference
behind it.

Public releases are cut locally with `bin/release`: preflight (clean main, tags,
cert, notary profile, Sparkle key, Finder access) → `bin/check` → curated notes →
assemble and Developer ID sign (`bin/package-app`) → notarize and staple app and DMG →
verify → appcast → tag `vX.Y.Z` → publish to this repo's Releases. arm64-only. The version's
source of truth is the git tag.

## zen-term-releases stays archived

Builds before v1.0.0 poll a frozen `SUFeedURL` in `zen-term/zen-term-releases`, which
now serves a hand-off appcast pointing here. **Never delete that repo** (the old feed
404s and those installs stop updating silently) and **never publish a release there**
(it moves `latest` for every old install).

## The website reads the repo

`zen-term-website`'s `scripts/sync-docs.mjs` pulls the config references and the
shipped third-party notices from `praxis-labs-io/zen-term`, and the release notes from
this repo's Releases API. Run
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
- **The example theme is `docs/config/themes/rose-pine-zen`.**

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
where `0.11.0` was meant, published and permanent. Once the tag is there, a bare or
bump invocation resumes it; naming a different version starts a new release.

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
git log into copy for the person downloading (the copy rules in `CLAUDE.md`). Write the file, then cut the release pointed at it:

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
are ACL-gated to the requesting context and the grant persists once made, so try the
read before calling a credential unreachable. Finder Automation (AppleScript)
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

Sparkle fetches `appcast.xml` from `releases/latest/download/`, verifies its EdDSA
signature and installs. `bin/release` uploads a single-item appcast beside each DMG, and
its enclosure points at `releases/download/vX.Y.Z/`, never `latest`, because the
signature covers one exact file. `ZenUpdateDriver` routes Sparkle's UI into
`UpdateCardView`. A `swift run` build has no `SUFeedURL`, so updates are inert in dev.

**The signing key exists. A new release machine imports it, never generates one.**
Every shipped build freezes the public half as `SUPublicEDKey`, so a second key signs
updates every install rejects. Move it over a trusted channel and shred the file:

```
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x zenterm-eddsa.key   # old machine
.build/artifacts/sparkle/Sparkle/bin/generate_keys -f zenterm-eddsa.key   # new machine
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p                     # must print SUPublicEDKey from bin/package-app
```
