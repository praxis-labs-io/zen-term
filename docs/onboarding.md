# ZenTerm

A terminal for the modern era.

ZenTerm is a modern shell for a great terminal. Ghostty renders the text and runs
the shell. ZenTerm is the app around it: floating panes, drawers, projects one
keystroke away, and a keyboard-first way through all of it.

It's built for terminal devs of all kinds, with a lean toward people who live in
the terminal and people running agents there.

## Install

1. Download `ZenTerm-<version>-arm64.dmg` from the
   [releases page](https://github.com/Drucial/zen-term-releases/releases).
2. Open it, drag **ZenTerm** onto **Applications**.
3. Launch it.

You should not see an "unidentified developer" warning. The app is signed and
notarized, so macOS opens it normally. If you get one, tell Drew. That's a real
problem, not something to click through.

Apple Silicon, macOS 14 or later. There's no Intel build.

**Install the font.** ZenTerm expects
[JetBrains Mono Nerd Font](https://www.nerdfonts.com/font-downloads), which macOS
doesn't ship. Without it, text falls back to another font and tool icons render
as empty boxes.

```sh
brew install --cask font-jetbrains-mono-nerd-font
```

## First launch

One window, one pane, your shell. Rosé Pine Moon.

ZenTerm ships with nothing configured: no projects, no tool shortcuts, no config
file on disk. It stays that way until you add something, and the app writes the
config for you when you do. You never have to edit a file by hand.

## Shortcuts

Six to start.

| | |
|---|---|
| Split side by side | **⌘⇧\** |
| Split top and bottom | **⌘⇧-** |
| Move between panes | **⌘H ⌘J ⌘K ⌘L** |
| Close the pane | **⌘W** |
| New tab | **⌘T** |
| Settings | **⌘,** |

Pane movement is vim's arrow keys: **H** left, **L** right, **J** down, **K** up.
Your hands stay on home row.

<details>
<summary>Everything else</summary>

| | |
|---|---|
| Resize the pane | ⌘⇧H / ⌘⇧J / ⌘⇧K / ⌘⇧L |
| Zoom the pane to fill the window | ⌘F |
| Bottom drawer | ⌘B |
| Right drawer | ⌘\ |
| New window | ⌘N |
| Previous / next tab | ⌘[ / ⌘] |
| Tab 1 through 9 | ⌘1 … ⌘9 |
| Command palette | ⌘P |
| Project picker | ⌘⇧P |
| Reload config | ⌘⌥R |

**⌘P finds anything.** Press it and type what you want. Every action is there
with its shortcut next to it. It's the only one worth memorizing first.

</details>

## Set up a project

1. **⌘,** → **Workspaces** → **＋ Add workspace**.
2. Name it, point it at a folder.

**⌘⇧P** now opens a picker with that project in it. Pick it and you get a tab in
that folder, named after the project, with the pane layout you defined. Add one
per repo.

A project can open your editor in the main pane and an agent in a drawer beside
it. One keystroke, already arranged.

## Add a tool

1. **⌘,** → **Tools** → **＋ Add tool float**.
2. Set a command (`lazygit`), a shortcut (⌘G), an icon.

⌘G now floats lazygit over your work and closes it again. It stays warm, so
reopening is instant. Same for `btop`, a dev server, `gh dash`, anything.

## Change how it looks

**Themes:** ⌘, → Appearance. Fifteen built in, including Rosé Pine, Catppuccin,
Tokyo Night, Nord, Gruvbox, and Dracula. A theme colors the whole app, not just
the terminal text.

**Shortcuts:** ⌘, → Keybinds. Click one, press the new chord. Collisions are
reported rather than silently applied.

## Two things that look like bugs

**Links need ⌘-click.** Hold ⌘ and a link underlines and becomes clickable. Plain
clicks do nothing, and the cursor stays a text cursor over links. That's
deliberate: terminals are full of text that only looks like a link.

**Esc doesn't close an open dropdown.** In Settings, with the theme dropdown or
icon grid open, Esc won't back out. Click elsewhere. This one is a real bug, and
it's being fixed.

## When something breaks

It will. This build is going to a handful of people, so you'll hit things nobody
has hit yet.

Tell Drew, and include:

- **The version.** ⌘, then look at the bottom of the left column.
- **What you did.** "I split a pane and the arrow keys went weird" is a useful
  report. Don't polish it.
- A screenshot if it's visual.

If something felt awkward rather than broken, say that too.

## Updates

No auto-update yet. New versions mean downloading the DMG again and replacing the
app. Drew will tell you when there's one.

## Editing config by hand

Everything in Settings is a plain text file in `~/.config/zen-term/`, and the app
picks up hand-edits. Annotated references for every option ship with the release:
[`config`](https://github.com/Drucial/zen-term-releases/blob/main/docs/config/config)
for appearance, behavior, tools, and shortcuts, and
[`workspaces`](https://github.com/Drucial/zen-term-releases/blob/main/docs/config/workspaces)
for projects. Copy them to `~/.config/zen-term/` if you want. It changes nothing
on its own, since every line starts commented out.
