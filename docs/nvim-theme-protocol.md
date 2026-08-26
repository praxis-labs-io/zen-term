# nvim ⇄ ZenTerm theme protocol

The durable contract between ZenTerm and the companion Neovim plugin
([zen-theme.nvim](https://github.com/praxis-labs-io/zen-theme.nvim)). ZenTerm
publishes the theme it resolved; the plugin applies a colorscheme to match. Both
ends are backend-agnostic: nothing here depends on the terminal backend behind the
seam.

The goal: `theme = nord` in `config`, or a pick in Settings, recolors Neovim along
with the terminal and the chrome. It is **opt-in** on the Neovim side, and ZenTerm
publishes whether or not anything reads it.

## The state file

ZenTerm writes `~/Library/Application Support/ZenTerm/theme.json` at launch and on
every theme change. It is not deleted on quit, so a Neovim started later still has
an answer.

A **fixed path**, unlike the per-pid nav socket. A tool float launches with no
environment, so a reader inside one could not be handed a path in `$ZEN_*`. The
tradeoff: two running instances (a dev build beside the installed app) are
last-writer-wins. A stale value there is cosmetic and corrects itself on the next
theme change.

The write is atomic, so a watcher never reads a half-written file. **Watch the
directory rather than the file**: an atomic write replaces the inode, and a watch
bound to the old one stops firing after the first swap.

## The payload

```json
{
  "name": "nord",
  "dark": true,
  "nvimColorscheme": "nord",
  "background": "#2e3440",
  "foreground": "#d8dee9",
  "cursor": "#eceff4",
  "selectionBackground": "#eceff4",
  "accent": "#b48ead",
  "ansi": ["#3b4252", "#bf616a", "…14 more"]
}
```

| Key | Value |
| --- | --- |
| `name` | The `theme` config token, bundled or a user file. An absent `theme` key publishes the default token rather than nothing. |
| `dark` | The resolved background's own light/dark reading, so a user theme reports as accurately as a bundled one. Drives `vim.o.background`. |
| `nvimColorscheme` | What the theme file's `nvim-colorscheme` key names, or absent when it names none. |
| `background`, `foreground`, `cursor`, `selectionBackground` | `#rrggbb`, from the resolved theme. |
| `accent` | The chrome's accent role, so an `accent-color` override is reflected. |
| `ansi` | The 16 ANSI colors in order, `#rrggbb`: 0 to 7 normal, 8 to 15 bright. |

Every color is `#rrggbb` and opaque. The palette is published for a statusline to
tint from; the colorscheme choice itself rides `nvimColorscheme`.

Fields are added over time. Read the keys you know and ignore the rest.

## `nvim-colorscheme`

A theme file names the colorscheme Neovim should wear:

```
nvim-colorscheme = kanagawa-dragon
```

Every bundled theme carries one. Add the line to a `.ghostty` file in
`~/.config/zen-term/themes/` and your own theme is mapped too, in the same file that
holds its colors. A shared ZenTerm theme carries its Neovim mapping with it.

The key is inert to everything else. `GhosttyThemeParser` reads the color keys and
drops the rest, so the line changes no color, raises no config problem, and leaves
the file a valid ghostty theme.

## Plugin behavior (reference)

For the recolor to hold, the plugin:

1. Reads the state file on `setup()` and applies it. An absent file means Neovim is
   not running under ZenTerm, and every mapping stays inert.
2. Watches the containing directory and re-applies when `theme.json` changes,
   coalescing the several events one write fires.
3. Resolves the colorscheme in this order: a name from the user's own `themes`
   override, then `nvimColorscheme`, then nothing. "Nothing" leaves the current
   colorscheme alone rather than guessing.
4. Sets `vim.o.background` from `dark` before applying, so a light theme flips the
   editor with the terminal.
5. Applies through `pcall`, so a colorscheme the user has not installed leaves the
   current one up instead of raising an error.

## Manual verification

With the app running (`swift run ZenTerm`):

```sh
# What ZenTerm currently publishes:
cat "$HOME/Library/Application Support/ZenTerm/theme.json"

# Watch it across a theme switch in Settings (⌘,):
while :; do
  jq -r '"\(.name) dark=\(.dark) \(.nvimColorscheme)"' \
    "$HOME/Library/Application Support/ZenTerm/theme.json"
  sleep 1
done
```
