# ZenTerm

A dev-first terminal for macOS.

Pixel-perfect panes, drawers, and tool floats, orchestrated into workspaces a
keystroke away, with a keyboard-first way through all of it. It runs on a
libghostty core, which renders the text and runs the shell. ZenTerm is
everything around that.

The chrome is the product. libghostty sits behind a `TerminalSurface` seam that
one target owns, and the other 200 files are panes, tabs, drawers, floats,
themes, and the keyboard that reaches them.

## Install

Download `ZenTerm-<version>-arm64.dmg` from the
[releases page](https://github.com/praxis-labs-io/zen-term/releases), open it, and drag
**ZenTerm** onto **Applications**. The app is signed and notarized, so macOS opens
it without an "unidentified developer" warning.

Apple Silicon, macOS 14 or later. There is no Intel build.

ZenTerm expects [JetBrains Mono Nerd Font](https://www.nerdfonts.com/font-downloads),
which macOS does not ship:

```sh
brew install --cask font-jetbrains-mono-nerd-font
```

It updates itself from then on. [`docs/onboarding.md`](docs/onboarding.md) walks
through the first hour.

## What it does

- **Panes that tile and a cursor that knows where it is.** ⌘D splits right, ⌘⇧D
  splits down, ⌘⌥ plus an arrow moves by direction rather than by order.
- **Two drawers per tab.** ⌘B along the bottom, ⌘\ down the right side, each
  holding its own shell and resizable from the keyboard.
- **Tool floats.** Any command you name in the config becomes a card over your
  work on a chord you pick: lazygit, btop, a dev server, a review tool. A float
  can stay warm between opens, or die on dismiss.
- **Workspaces.** A folder plus a layout on ⌘P, so a project opens the way you
  left it.
- **Scroll mode and Find, in vim keys.** ⌘⇧S moves through the scrollback with
  `hjkl`, `w`/`b`/`e`, and `{`/`}`; `v` and `V` select, `y` copies.
- **Seventeen themes**, and a bring-your-own theme file. A theme colors the whole
  app, not the terminal text alone.
- **Nothing leaves your machine.** No telemetry, no analytics, no account. The
  update check asks GitHub for a version number and sends nothing about you.

## Configure it

One file, `~/.config/zen-term/config`, in ghostty's syntax. Settings (⌘,) writes
the same file, so the two never disagree.
[`docs/config/config`](docs/config/config) is the annotated reference: every key,
its default, and what a bad line does.

## Build from source

```sh
git clone https://github.com/praxis-labs-io/zen-term.git && cd zen-term
bin/build-ghosttykit   # inits the vendor/ghostty submodule, fetches Zig,
                       # builds GhosttyKit.xcframework + runtime resources
brew install swiftlint # bin/check needs it
bin/run
```

`bin/build-ghosttykit` takes a few minutes and reruns only when the ghostty pin
or the script changes. You need Xcode 26 or later: the package manifest declares
`swift-tools-version: 6.2`, and the Metal compiler is not in the Command Line
Tools alone.

## Documentation

- [`docs/onboarding.md`](docs/onboarding.md) reads the app to someone opening it
  for the first time.
- [`docs/config/config`](docs/config/config) and
  [`docs/config/workspaces`](docs/config/workspaces) are the reference files.
- [`docs/architecture.md`](docs/architecture.md) is how the app fits together,
  and it describes what exists rather than what was planned.
- [`docs/swift-conventions.md`](docs/swift-conventions.md) is the AppKit traps
  that cost us a release each.
- [`docs/releasing.md`](docs/releasing.md) is how a build reaches an Applications
  folder.
- [`docs/release-notes/`](docs/release-notes) is every version, curated.

## Contributing

Read [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md). The short version: `bin/check`
is the gate, one branch is one pull request, and `CLAUDE.md` holds the rules an
agent working in this repo follows.

## Security

Report a vulnerability privately. [`SECURITY.md`](SECURITY.md) says how.

## License

MIT. See [LICENSE](LICENSE). Third-party notices ship inside the app and live in
[`Sources/ZenTerm/Resources/THIRD-PARTY-NOTICES.md`](Sources/ZenTerm/Resources/THIRD-PARTY-NOTICES.md).
