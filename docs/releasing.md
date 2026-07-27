# Releasing

How a public ZenTerm release is cut, and the parts of `bin/release` that are
load-bearing. The `release` skill drives the flow; this file is the reference
behind it.

Public releases are cut locally with `bin/release`: preflight (clean main, cert,
notary profile, releases repo) → `bin/check` → assemble and Developer ID sign
(`bin/package-app`) → notarize and staple app and DMG → verify gates → curated
notes → tag `vX.Y.Z` on this repo → publish the DMG to the **public**
`zen-term/zen-term-releases` repo. This repo is private, so its own Releases are
not downloadable. arm64-only. The version's source of truth is the git tag.

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
