# ZenTerm

A modern macOS terminal for developers, built to the pixel.

**Built on [libghostty](https://ghostty.org)**, the core the Ghostty project
publishes so other terminals can share one engine: terminal emulation, font
handling, and rendering. ZenTerm builds it from a pinned `vendor/ghostty`
submodule, so the emulation under your shell is Ghostty's from first launch.

ZenTerm tiles panes with a cursor that moves by direction, holds two drawers per
tab, summons tool floats on a chord, and opens a project from a workspace with
its layout and its processes already running. Each of those sits on a keystroke
you can rebind, and seventeen themes color the terminal, the tabs, and the chrome
around them. The layout engine, the input routing, scroll mode, the theming, and
the chrome are ZenTerm's own.

The release notes, the full documentation, and the guides live at
[zenterm.io](https://zenterm.io).

![Neovim in the main pane, a dev server in the bottom drawer, and an agent in the right drawer, in one tab](docs/images/drawers.png)

One tab, three shells. ⌘B opens the drawer along the bottom and ⌘\ opens the one
down the right side, each with its own shell and its own chord printed in the
corner. Hide a drawer and its process keeps running, so the dev server here is
still serving while the drawer is gone. The numbered tabs along the bottom are
⌘1 through ⌘9.

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

ZenTerm updates itself from then on. [`docs/onboarding.md`](docs/onboarding.md) walks
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
- **A command palette over every action.** ⌘⇧P lists them by group with each
  one's live shortcut, filters as you type, and runs the selection on Enter. A
  rebind shows up in the row, so the palette never advertises a stale chord.
- **Scroll mode and Find, in vim keys.** ⌘⇧S moves through the scrollback with
  `hjkl`, `w`/`b`/`e`, and `{`/`}`; `v` and `V` select, `y` copies.
- **One motion across Neovim splits and ZenTerm panes.** Bind `ctrl+hjkl` to the
  `nav_*` actions and install
  [zen-navigator.nvim](https://github.com/praxis-labs-io/zen-navigator.nvim):
  nvim walks its own splits and hands off to ZenTerm at the edge. ⌘⌥ arrows keep
  working either way.
- **Seventeen themes**, and a bring-your-own theme file. A theme colors the whole
  app, not the terminal text alone.
- **A notification when an agent needs you.** With ZenTerm in the background and
  an agent stopped for input, macOS posts a banner and the tab's number takes the
  theme's attention color until you visit it.
- **No telemetry, no analytics, no account.** The only request ZenTerm makes on its
  own is an update check, which asks GitHub for a version number and sends nothing
  about you.

## A look around

![Three panes tiled in one tab, the focused one carrying a colored halo](docs/images/panes.png)

⌘D splits right and ⌘⇧D splits down. The focused pane carries the halo, so where
the next keystroke lands is visible without hunting for a cursor. ⌘⌥ plus an
arrow moves by direction rather than by order, and the gap between panes and the
padding around them are both yours to set.

![The same three panes on a light theme, with the theme picker open over them listing bundled themes marked Dark or Light](docs/images/themes-light.png)

The same window on Catppuccin Latte. A theme colors the terminal, the tab bar,
the toolbar, the focus halo, and Settings itself, so a light theme stays light
through the whole app. Seventeen ship, each marked Dark or Light in the picker,
and a `theme = ` line pointed at any Ghostty theme file works the same way.

![The command palette open over an empty pane, its Tools group listing each command with the shortcut that runs it](docs/images/palette.png)

⌘⇧P filters as you type and runs the selection on Enter. Each row carries the
shortcut that runs it, read from your config, so a rebind shows up here instead
of leaving the palette advertising a chord that stopped working.

![The workspace picker open, listing named workspaces with a search field above them](docs/images/workspaces.png)

⌘P lists the workspaces you named, each one a folder plus a layout. The list is
deliberate: ZenTerm does not scan a directory to fill it, so nothing you did not
write appears here.

![lazygit open as a tool float over the panes, with its own numbered panes, and the work still visible around it](docs/images/tool-float.png)

A float is one `float =` line in the config: a command, a chord, and an icon for
the toolbar. It opens over the work instead of taking a pane, so the panes and
drawers underneath keep their places. `persist:dir` keeps one warm per
repository, which makes the first open cold and every reopen instant.

## Configure it

One file, `~/.config/zen-term/config`, in Ghostty's config syntax. Settings (⌘,)
writes the same file, so the two never disagree.
[`docs/config/config`](docs/config/config) is the annotated reference: every key,
its default, and what a bad line does.

![The Appearance pane of Settings: theme, accent color, window buttons, toolbar buttons, backdrop alpha, window gutter, and pane gap](docs/images/settings.png)

Picking a theme here writes the `theme =` line you would have typed. The row says
it applies instantly, and it recolors the terminal, the tabs, and the chrome
while the pane is still open. The pane and the file hold the same keys, so
neither one can tell you something the other contradicts.

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
- [`docs/swift-conventions.md`](docs/swift-conventions.md) collects the AppKit
  traps that cost us a release each.
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
