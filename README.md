# zen-term

Native macOS terminal where the chrome is the product: floating panes, drawers,
and keyboard-first navigation over a swappable terminal core. Swift + SwiftPM +
AppKit, no Xcode project. This repo is private; public builds ship through
[zen-term-releases](https://github.com/Drucial/zen-term-releases).

**Requires:** macOS 14+, Apple Silicon, full Xcode (the release toolchain needs
`notarytool`/`stapler` and the Metal compiler, not just the CLT).

## Architecture in one paragraph

`Sources/TerminalKit/` owns the `TerminalSurface` seam and is the only target
allowed to import a terminal backend (SwiftTerm today, libghostty behind
`GhosttyKit`). `Sources/ZenTerm/` is the chrome and depends on TerminalKit
alone; `PaneKit` and `TabKit` hold the pane-tree and tab models. Design source
of truth lives in `docs/superpowers/specs/` (architecture, epic charters) and
`docs/superpowers/plans/` (per-epic implementation plans). Agent-facing rules,
including the theme-color policy, live in `CLAUDE.md`.

## First-time setup

```sh
git clone https://github.com/Drucial/zen-term.git && cd zen-term
bin/build-ghosttykit   # inits the vendor/ghostty submodule, fetches Zig,
                       # builds GhosttyKit.xcframework + runtime resources
brew install swiftlint # bin/check needs it
```

`bin/build-ghosttykit` takes a few minutes and reruns only when the ghostty pin
or the script changes. Its outputs are gitignored and per-machine. Fresh git
worktrees need them symlinked in (`Frameworks/GhosttyKit.xcframework` and
`Sources/TerminalKit/Resources/ghostty-resources`) or the build fails.

## Develop

```sh
bin/run                # build + launch (guards that GhosttyKit artifacts exist)
bin/run --swiftterm    # launch on the SwiftTerm backend instead
swift test             # unit tests
bin/check              # the full local gate: build, test, swift-format
                       # (strict), swiftlint (strict). Mirrors CI. Run before
                       # every ship; --fix auto-applies format/lint fixes.
```

CI (`.github/workflows/ci.yml`) runs the same gate on pushes to `main` and on
non-draft PRs, with GhosttyKit cached on the ghostty pin. Open PRs as drafts
and mark them ready after review so CI runs once per branch.

Workflow: tickets live in Linear (ZenTerm team, `ZEN-` prefix), one ticket =
one branch = one PR, branched off the ticket's `gitBranchName`. `CLAUDE.md` has
the full flow.

## Daily-driver build

```sh
bin/package-app        # release build → ad-hoc-signed ZenTerm.app in ~/Applications
```

Dev builds stamp `<latest-tag>-dev` as their version and the commit count as
the build number. Flags: `--version X.Y.Z`, `--identity "NAME"` (Developer ID
signing with hardened runtime), `--dest DIR`.

## Release

Releases are cut locally by `bin/release` and published to the public
[zen-term-releases](https://github.com/Drucial/zen-term-releases) repo, since
Releases on this private repo can't be downloaded publicly. arm64-only. The
git tag `vX.Y.Z` on this repo is the version source of truth.

### One-time setup

1. A **Developer ID Application** certificate in the login keychain. Create it
   in Xcode → Settings → Accounts → Manage Certificates. Verify with:
   `security find-identity -v -p codesigning`
2. Stored notary credentials (uses an app-specific password from
   [account.apple.com](https://account.apple.com)):
   ```sh
   xcrun notarytool store-credentials zenterm-notary \
       --apple-id <apple-id> --team-id <team-id>
   ```
3. `gh auth login` with access to both repos.

### Cutting a release

```sh
bin/release 0.1.0
```

From a clean `main` in sync with origin, the script runs preflight (cert,
notary profile, tag/release collision, GhosttyKit present), gates on
`bin/check`, opens `$EDITOR` on a git-log scaffold of release notes (curate
them: these commit subjects go public), then builds, signs with hardened
runtime, notarizes and staples the app and the DMG, verifies with
`codesign`/`spctl`/`stapler`, tags `vX.Y.Z`, and publishes
`ZenTerm-X.Y.Z-arm64.dmg` to zen-term-releases.

Flags: `--notes-file FILE` to skip the editor pass, `--skip-checks` to skip
the `bin/check` gate.

A failed run is safe to rerun with the same version: curated notes survive, a
tag already at HEAD is reused, and a release created without its DMG gets the
asset uploaded instead of erroring. Notarization rejections print the
`notarytool log` command to inspect.

### Deferred distribution work

Sparkle auto-updates (ZEN-118), Homebrew cask (ZEN-119), tag-triggered CI
releases (ZEN-120), universal/Intel build (ZEN-121).
