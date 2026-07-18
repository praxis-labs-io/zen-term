# zen-term

Native macOS terminal where the chrome is the product: floating panes, drawers,
and keyboard-first navigation over a swappable terminal core. Swift + SwiftPM +
AppKit, no Xcode project. This repo is private; public builds ship through
[zen-term-releases](https://github.com/zen-term/zen-term-releases).

**Requires:** macOS 14+, Apple Silicon, full Xcode (the release toolchain needs
`notarytool`/`stapler` and the Metal compiler, not just the CLT).

## Architecture in one paragraph

`Sources/TerminalKit/` owns the `TerminalSurface` seam and is the only target
allowed to import a terminal backend (libghostty, behind `GhosttyKit`).
`Sources/ZenTerm/` is the chrome and depends on TerminalKit alone; `PaneKit` and
`TabKit` hold the pane-tree and tab models. [`docs/architecture.md`](docs/architecture.md)
is the full picture, and it describes what exists rather than what was planned.
Agent-facing rules, including the theme-color policy, live in `CLAUDE.md`. The
history of how any of it got built is in Linear and git, not in `docs/`.

## First-time setup

```sh
git clone https://github.com/zen-term/zen-term.git && cd zen-term
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
bin/package-app        # dev build → ad-hoc-signed "ZenTerm Dev.app" in ~/Applications
```

Dev builds stamp the release they descend from plus the commit count since it
(`0.1.0+7`, or `0.0.0+<count>` before the first tag), and the total commit count
as the build number. `+7` is seven commits past `v0.1.0`, so a dogfood bug report
names an exact build. Flags: `--version X.Y.Z`, `--identity "NAME"` (Developer ID
signing with hardened runtime), `--dest DIR`, `--variant dev|release`. The default
`dev` variant is `ZenTerm Dev` (`com.drucial.ZenTerm.dev`, its own icon, no Sparkle
feed), so it runs beside the installed release; `bin/release` uses `--variant release`.

## Release

Releases are cut locally by `bin/release` and published to the public
[zen-term-releases](https://github.com/zen-term/zen-term-releases) repo, since
Releases on this private repo can't be downloaded publicly. arm64-only. The
git tag `vX.Y.Z` on this repo is the version source of truth.

### Version numbers

Releases follow [semantic versioning](https://semver.org): `MAJOR.MINOR.PATCH`.
Each component answers a different question for someone deciding whether to
update.

| Bump | Example | Means |
|---|---|---|
| **patch** | `0.1.0` → `0.1.1` | Fixes only. Nothing new, nothing moved. Safe. |
| **minor** | `0.1.0` → `0.2.0` | New features, nothing existing broke. |
| **major** | `0.9.0` → `1.0.0` | Something people relied on changed or went away. |

For an app rather than a library, "breaking" means the things a user built a
habit or a config around: a chord that no longer does what it did, a config key
that's been renamed or dropped, a default that flipped. New features are a minor
bump no matter how large they are.

**The leading zero is the point.** `0.x.y` is the convention for "this is real,
but I'm not promising it's stable yet" — it's why the first release is `0.1.0`
rather than `1.0.0`, and it buys the freedom to change chords and config keys
during v0 without owing anyone a major bump. Reaching `1.0.0` is a statement:
you'd hand this to a stranger and stand behind it, and from then on breaking
their config costs you a major bump. Take the time you want getting there.

Two rules that aren't negotiable, because a published tag is permanent:

- **Never reuse a version.** Even for a release that failed halfway. (Rerunning
  `bin/release` handles this correctly on its own — see below.)
- **Never go backwards.** Versions only ascend.

So: bug-fix round after the friends release → `bin/release` (0.1.1). Shipped the
command palette → `bin/release minor` (0.2.0). Both are automatic; you only name
a version by hand to skip ahead deliberately.

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
bin/release              # patch-bump the last tag (0.1.0 if there are none yet)
bin/release minor        # or major / patch
bin/release 1.2.3        # or name the version outright
```

The version is derived from the last release tag unless you name one. One
exception: if that tag already points at HEAD, the script resumes *that* release
instead of bumping, so rerunning after a failure can't strand a half-published
tag.

From a clean `main` in sync with origin, the script runs preflight (cert,
notary profile, tag/release collision, GhosttyKit present), gates on
`bin/check`, opens `$EDITOR` on a git-log scaffold of release notes (curate
them: these commit subjects go public), then builds, signs with hardened
runtime, notarizes and staples the app and the DMG, verifies with
`codesign`/`spctl`/`stapler`, tags `vX.Y.Z`, and publishes
`ZenTerm-X.Y.Z-arm64.dmg` to zen-term-releases.

Flags: `--notes-file FILE` to skip the editor pass, `--skip-checks` to skip
the `bin/check` gate.

**Rerun a failed run the same way you invoked it** (`bin/release minor` again,
not bare). The version only resolves back to the same one if you pass the same
argument, since nothing records which bump an interrupted run intended until the
tag exists. Once it does, any invocation resumes it. Curated notes survive per
version, and a release created without its DMG gets the asset uploaded instead of
erroring. Notarization rejections print the `notarytool log` command to inspect.

### Deferred distribution work

Homebrew cask (ZEN-119), tag-triggered CI releases (ZEN-120), universal/Intel
build (ZEN-121).
