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
`latest` stops meaning 1.0.0 the moment 1.0.1 ships and the download 404s. Edit
`dist/appcast.xml` to the tagged form first:

```
https://github.com/praxis-labs-io/zen-term/releases/download/v1.0.0/ZenTerm-1.0.0-arm64.dmg
```

Then publish it:

```
gh release create v1.0.0 --repo zen-term/zen-term-releases \
    --title "ZenTerm 1.0.0" \
    --notes "ZenTerm moved to https://github.com/praxis-labs-io/zen-term. Releases are published there." \
    dist/appcast.xml
```

Every install picks 1.0.0 up on its next check and lands on the new feed. Give it a
week, compare the 1.0.0 download count against the 0.10.0 one, message whoever has
not moved, then delete the repo and the `zen-term` org.

## The website reads the repo, and it has already moved

`zen-term-website`'s `scripts/sync-docs.mjs` still pulls the docs and the releases
API from `zen-term/zen-term-releases`. **Repoint it before the first release cut from
this repo, not before deleting the old one.** It fails by syncing nothing rather than
by erroring, so a v1.0.0 cut against the old path publishes no release notes to the
site and every check in the flow still passes. Tracked as ZEN-423.

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

with an app-specific password.

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
