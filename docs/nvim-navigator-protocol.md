# nvim ⇄ ZenTerm navigator protocol

The durable contract between ZenTerm and the companion Neovim plugin
(`zen-navigator.nvim`). ZenTerm implements this side; the plugin is written
against it. Both ends are backend-agnostic — nothing here depends on the terminal
backend behind the seam.

The goal: `Ctrl-hjkl` walks across nvim splits and ZenTerm panes as one motion.
It is **opt-in** — default `⌘-hjkl` pane nav is untouched. A user enables it by
(a) binding `ctrl+hjkl → nav_*` in their ZenTerm keybind config and
(b) installing the plugin.

## Environment

ZenTerm injects two variables into every pane's shell:

| Var        | Value                                                        |
| ---------- | ----------------------------------------------------------- |
| `ZEN_SOCK` | Absolute path to the nav command socket (see below).        |
| `ZEN_PANE` | This pane's integer token — stable for the pane's lifetime. |

The plugin **degrades to plain `wincmd`** when either is absent (i.e. Neovim is
not running under ZenTerm).

> **Long-lived sessions:** both vars are captured at shell launch, and the
> socket is per app instance. A shell that outlives its instance (a reattached
> tmux/screen session) holds a dead `$ZEN_SOCK`; hand-offs silently no-op there
> until nvim is restarted in a fresh pane. `⌘-hjkl` always works.

## Socket

- Path: `$ZEN_SOCK` (currently
  `~/Library/Application Support/ZenTerm/nav.<pid>.sock` — per app instance, so
  two running ZenTerms never fight over one socket). Always discover it via the
  env var, never hardcode.
- Type: `AF_UNIX`, `SOCK_STREAM`. Neovim connects natively with
  `sockconnect('pipe', $ZEN_SOCK)` — no per-keystroke process spawn.
- Framing: newline-delimited (`\n`) UTF-8 JSON, one command per line. A
  short-lived connection that writes one line and closes is fine.
- ZenTerm silently drops malformed lines, unknown commands, unknown directions,
  and commands naming a token with no live pane.

## Commands (plugin → ZenTerm)

### `focus` — hand off at an nvim edge

Sent when nvim is at its edge split and can't move further, so ZenTerm should
move pane focus in that direction, starting from the sending pane.

```json
{ "cmd": "focus", "dir": "left", "pane": 7 }
```

- `dir`: one of `left` `right` `up` `down`.
- `pane`: the sender's `$ZEN_PANE` token.

Direction mapping the plugin uses: `h→left`, `j→down`, `k→up`, `l→right`.

### `setvim` — advertise nvim presence

Sent so ZenTerm knows not to steal `Ctrl-hjkl` from a pane running nvim (the key
pass-through guard). Send `true` on `VimEnter`/`VimResume`, `false` on
`VimLeave`/`VimSuspend`.

```json
{ "cmd": "setvim", "pane": 7, "vim": true }
```

- `pane`: the sender's `$ZEN_PANE` token.
- `vim`: `true` to flag the pane as nvim, `false` to clear. Omitted `vim` is
  treated as `false`.

> **Stale flag on hard crash:** the flag clears on `VimLeave`/`VimSuspend`, but a
> hard nvim crash can leave it set (Ctrl-h then reaches the recovered shell,
> doing nothing until the flag is reset). The `⌘-hjkl` fallback always works.

## Plugin behavior (reference)

For the crossing to be seamless, the plugin:

1. On the mapped `Ctrl-h/j/k/l`: `let nr = winnr()` → `wincmd h/j/k/l` →
   `at_edge = (nr == winnr())` (the `vim-tmux-navigator` edge test).
2. If `at_edge`, send a `focus` command with the mapped direction; otherwise the
   `wincmd` already moved within nvim.
3. On `VimEnter`/`VimResume` and `VimLeave`/`VimSuspend`, send the matching
   `setvim`.

## Manual verification

With the app running (`swift run ZenTerm`) and `$ZEN_SOCK` set in a pane:

```sh
# Move focus left from pane <token>:
echo '{"cmd":"focus","dir":"left","pane":<token>}' | nc -U "$ZEN_SOCK"

# Flag / unflag pane <token> as running nvim:
echo '{"cmd":"setvim","pane":<token>,"vim":true}'  | nc -U "$ZEN_SOCK"
echo '{"cmd":"setvim","pane":<token>,"vim":false}' | nc -U "$ZEN_SOCK"
```
