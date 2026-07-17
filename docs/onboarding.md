# ZenTerm

A terminal for the modern era.

Ghostty renders the text and runs the shell. ZenTerm is the app around it:
floating panes, drawers, workspaces one keystroke away, and a keyboard-first way
through all of it.

## Install

1. Download `ZenTerm-<version>-arm64.dmg` from the
   [releases page](https://github.com/Drucial/zen-term-releases/releases).
2. Open it and drag **ZenTerm** onto **Applications**.
3. Launch it.

You should not see an "unidentified developer" warning. The app is signed and
notarized, so macOS opens it normally. If you get one, tell Drew. That is a real
problem, not something to click through.

Apple Silicon, macOS 14 or later. There is no Intel build.

**Install the font.** ZenTerm expects
[JetBrains Mono Nerd Font](https://www.nerdfonts.com/font-downloads), which macOS
does not ship. Without it, text falls back to another font and tool icons render
as empty boxes.

```sh
brew install --cask font-jetbrains-mono-nerd-font
```

## First launch

One window, one pane, your shell, in the Rosé Pine Moon theme.

ZenTerm ships with nothing configured. There are no workspaces, no tool floats,
and no config file on disk. It stays that way until you add something, and the
app writes the config when you do. You never have to edit a file by hand.

## Shortcuts

Six to start.

|                      |                       |
| -------------------- | --------------------- |
| Split side by side   | `⌘⇧\`                 |
| Split top and bottom | `⌘⇧-`                 |
| Move between panes   | `⌘H` `⌘J` `⌘K` `⌘L`   |
| Close the pane       | `⌘W`                  |
| New tab              | `⌘T`                  |
| Settings             | `⌘,`                  |

The split keys are shaped like the split they make. `\` is a vertical divider, so
you get panes side by side. `-` is a horizontal one, so you get panes stacked.

Pane movement is vim's arrow keys. **H** is left, **L** is right, **J** is down,
**K** is up. Your hands stay on home row.

<details>
<summary>Everything else</summary>

|                                  |                             |
| -------------------------------- | --------------------------- |
| Resize the pane                  | `⌘⇧H` `⌘⇧J` `⌘⇧K` `⌘⇧L`     |
| Zoom the pane to fill the window | `⌘F`                        |
| Bottom drawer                    | `⌘B`                        |
| Right drawer                     | `⌘\`                        |
| New window                       | `⌘N`                        |
| Previous and next tab            | `⌘[` `⌘]`                   |
| Tab 1 through 9                  | `⌘1` … `⌘9`                 |
| Command palette                  | `⌘P`                        |
| Workspace picker                 | `⌘⇧P`                       |
| Reload config                    | `⌘⌥R`                       |

**⌘P finds anything.** Press it and type what you want. Each action is listed
with its shortcut beside it, so it doubles as the reference for this page.

</details>

## Set up a workspace

A workspace is a folder plus the layout you want when you open it.

1. Press **⌘,** to open Settings, then choose **Workspaces**.
2. Choose **＋ Add workspace**.
3. Name it and point it at a folder.

**⌘⇧P** now opens a picker with that workspace in it. Choose it and you get a tab
in that folder, named after the workspace, with the layout you defined. Add one
per repo you work in.

A workspace can open your editor in the main pane and an agent in a drawer beside
it. One keystroke, and the tab is arranged.

## Add a tool float

A tool float is a command on a shortcut, floating over your work.

1. Press **⌘,** to open Settings, then choose **Tools**.
2. Choose **＋ Add tool float**.
3. Set a command (`lazygit`), a shortcut (⌘G), and an icon.

⌘G now floats lazygit over your work and closes it again. The float stays warm,
so reopening it is instant. The same works for `btop`, a dev server, or `gh dash`.

## Change how it looks

**Themes:** press ⌘, and choose **Appearance**. Fifteen ship with the app,
including Rosé Pine, Catppuccin, Tokyo Night, Nord, Gruvbox, and Dracula. A theme
colors the whole app, not only the terminal text.

**Shortcuts:** press ⌘, and choose **Keybinds**. Pick a shortcut and press the
new one. If it collides with an existing shortcut, the app tells you which action
already owns it.

## Two things that look like bugs

**Links need ⌘-click.** Hold ⌘ and a link underlines and becomes clickable. A
plain click does nothing, and the cursor stays a text cursor over links. That is
deliberate. A terminal is full of text that only looks like a link, and a stray
click should not open your browser.

**Esc does not close an open dropdown.** In Settings, with the theme dropdown or
the icon grid open, Esc will not back out of it. Click elsewhere instead. This
one is a real bug and Drew is fixing it.

## When something breaks

It will. This build goes to a handful of people, so you will hit things nobody
has hit yet.

Tell Drew, and include:

- **The version.** Press ⌘, and read the bottom of the left column.
- **What you did.** "I split a pane and the arrow keys went weird" is a useful
  report. Send it unpolished.
- A screenshot if it is visual.

If something felt awkward rather than broken, say that too.

## Updates

There is no auto-update yet. A new version means downloading the DMG again and
replacing the app. Drew will tell you when there is one.

## Editing config by hand

Everything in Settings is a plain text file in `~/.config/zen-term/`, and the app
picks up hand-edits. Annotated references for every option ship with the release:
[`config`](https://github.com/Drucial/zen-term-releases/blob/main/docs/config/config)
covers appearance, behavior, tools, and shortcuts, and
[`workspaces`](https://github.com/Drucial/zen-term-releases/blob/main/docs/config/workspaces)
covers workspaces. Copy them to `~/.config/zen-term/` if you want. Copying
changes nothing on its own, since every line starts commented out.
