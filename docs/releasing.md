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
day: three to five machines, all of them people we can message. So this is a
one-time hand-off rather than anything `bin/release` carries.

**When 1.0.0 publishes**, upload that release's `dist/appcast.xml` to the old repo by
hand. It needs no DMG: the enclosure inside already points at the asset here, the
bytes are identical, and `SUPublicEDKey` never changed, so the signature verifies.

**Pin the enclosure to the tag before uploading it.** `bin/release` writes the live
appcast with a `releases/latest/download/` URL, which is right for a feed that is
regenerated every release. The hand-off copy is written once and never again, so
`latest` stops meaning 1.0.0 the moment 1.0.1 ships and the download 404s.

Work on a copy, not `dist/appcast.xml` itself: a `bin/release` rerun regenerates that
file from a heredoc and your edit is gone without a word.

**The copy has to keep the name `appcast.xml`,** so put it in a subdirectory rather
than renaming it. `gh release create` names each asset by its basename, and the feed
every pre-1.0.0 build polls is literally `latest/download/appcast.xml`. Upload it as
`appcast-handoff.xml` and that URL 404s, which is the one thing this hand-off exists
to prevent.

```
mkdir -p dist/handoff && cp dist/appcast.xml dist/handoff/appcast.xml
```

Then edit the copy's enclosure to the tagged form:

```
https://github.com/praxis-labs-io/zen-term/releases/download/v1.0.0/ZenTerm-1.0.0-arm64.dmg
```

**Publish it as a draft first.** Creating this release moves `latest` on the old repo
off v0.10.0 the instant it is public, so the asset becomes the feed for every pre-1.0.0
install immediately. That is the intent, and it is also why a mistake here takes down
the only feed those machines have rather than merely failing to add a new one. There is
no error anywhere when it goes wrong, and no way for those installs to recover except a
manual download. Draft, check, then publish:

```
gh release create v1.0.0 --repo zen-term/zen-term-releases --draft \
    --title "ZenTerm 1.0.0" \
    --notes "ZenTerm moved to https://github.com/praxis-labs-io/zen-term. Releases are published there." \
    dist/handoff/appcast.xml
```

Confirm the asset kept its name and the enclosure resolves:

```
gh release view v1.0.0 --repo zen-term/zen-term-releases --json assets \
    --jq '.assets[].name'          # must print exactly: appcast.xml
curl -sI "$(grep -o 'https://[^"]*\.dmg' dist/handoff/appcast.xml)" | head -1
```

The `curl` must return `200` or a `302`, not `404`. Then release it:

```
gh release edit v1.0.0 --repo zen-term/zen-term-releases --draft=false
```

Finally, fetch the feed the old builds actually poll and confirm it returns the 1.0.0
item before you walk away:

```
curl -sL https://github.com/zen-term/zen-term-releases/releases/latest/download/appcast.xml | head -20
```

Every install picks 1.0.0 up on its next check and lands on the new feed. Give it a
week, compare the 1.0.0 download count against the 0.10.0 one, message whoever has
not moved, then delete the repo and the `zen-term` org.

## The website reads the repo, and it is not a URL swap

`zen-term-website`'s `scripts/sync-docs.mjs` still pulls the docs and the releases API
from `zen-term/zen-term-releases`. **Fix it before the first release cut from this
repo, not before deleting the old one.** It fails by syncing nothing rather than by
erroring, so a v1.0.0 cut against the old path publishes no release notes and every
check in the flow still passes. Tracked as ZEN-423.

Three of its source paths do not exist here, and one of them fails dangerously:

- **`docs/THIRD-PARTY-NOTICES.md` never existed in this repo.** The deleted
  `bin/release` block synthesized it in the releases repo by copying
  `Sources/ZenTerm/Resources/THIRD-PARTY-NOTICES.md`. What this repo has is
  `docs/third-party-notices.md`, a maintainer re-probe doc twenty times smaller and
  about something else. raw.githubusercontent is case-sensitive, so the repoint 404s,
  **and lowercasing the path to make it pass publishes the wrong document as the app's
  license disclosure.** Point it at `Sources/ZenTerm/Resources/THIRD-PARTY-NOTICES.md`.
  Check this on a case-sensitive filesystem or with `git ls-files`: APFS is
  case-insensitive, so `ls` finds a file that is not there.
- **`themes/rose-pine-moon` was renamed** to `rose-pine-zen` in ZEN-416.
- The notices used to be republished per tag, which is what kept the license text
  matched to the binary that shipped. Reading `main` loses that, so fetch these at the
  release tag rather than at `main`.

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
