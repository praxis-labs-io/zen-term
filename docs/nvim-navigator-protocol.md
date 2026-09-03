# nvim ⇄ ZenTerm navigator protocol

The durable contract between ZenTerm and the companion Neovim plugin
(`zen-navigator.nvim`). ZenTerm implements this side; the plugin is written
against it. Both ends are backend-agnostic: nothing here depends on the terminal
backend behind the seam.

The goal: `Ctrl-hjkl` walks across nvim splits and ZenTerm panes as one motion.
It is **opt-in**: default `⌘-hjkl` pane nav is untouched. A user enables it by
(a) binding `ctrl+hjkl → nav_*` in their ZenTerm keybind config and
(b) installing the plugin.

## Environment

ZenTerm injects two variables into every pane's shell:

| Var        | Value                                                        |
| ---------- | ----------------------------------------------------------- |
| `ZEN_SOCK` | Absolute path to the nav command socket (see below).        |
| `ZEN_PANE` | This pane's integer token, stable for the pane's lifetime. |

The plugin **degrades to plain `wincmd`** when either is absent (i.e. Neovim is
not running under ZenTerm).

> **Long-lived sessions:** both vars are captured at shell launch, and the
> socket is per app instance. A shell that outlives its instance (a reattached
> tmux/screen session) holds a dead `$ZEN_SOCK`; hand-offs silently no-op there
> until nvim is restarted in a fresh pane. `⌘-hjkl` always works.

## Socket

- Path: `$ZEN_SOCK` (currently
  `~/Library/Application Support/ZenTerm/nav.<pid>.sock`, one per app instance, so
  two running ZenTerms never fight over one socket). Always discover it via the
  env var, never hardcode.
- Type: `AF_UNIX`, `SOCK_STREAM`. Neovim connects natively with
  `sockconnect('pipe', $ZEN_SOCK)`, with no per-keystroke process spawn.
- Framing: newline-delimited (`\n`) UTF-8 JSON, one command per line. A
  short-lived connection that writes one line and closes is fine, but a client
  that wants clear-on-death presence holds one connection open (see below).
- ZenTerm silently drops malformed lines, unknown commands, unknown directions,
  and commands naming a token with no live pane.

## Commands (plugin → ZenTerm)

### `focus`: hand off at an nvim edge

Sent when nvim is at its edge split and can't move further, so ZenTerm should
move pane focus in that direction, starting from the sending pane.

```json
{ "cmd": "focus", "dir": "left", "pane": 7 }
```

- `dir`: one of `left` `right` `up` `down`.
- `pane`: the sender's `$ZEN_PANE` token.

Direction mapping the plugin uses: `h→left`, `j→down`, `k→up`, `l→right`.

### `setvim`: advertise nvim presence

Sent so ZenTerm knows not to steal `Ctrl-hjkl` from a pane running nvim (the key
pass-through guard).

```json
{ "cmd": "setvim", "pane": 7, "vim": true, "hold": true }
```

- `pane`: the sender's `$ZEN_PANE` token.
- `vim`: `true` to flag the pane as nvim, `false` to clear. Omitted `vim` is
  treated as `false`.
- `hold`: optional. `true` means the sending connection owns this flag for as
  long as it stays open. Omitted or `false` is the legacy latch. Ignored
  alongside `vim: false`.

## Presence lifetime

The flag has two shapes, and a client picks one with `hold`.

**Held** (`vim: true, hold: true`) is what the plugin sends. ZenTerm remembers
which connection made the claim and clears the flag when that connection reaches
EOF. The kernel closes the fd however the process dies, so a crash, a `SIGKILL`,
and a death nested inside a long-running foreground command all clear the pane.
A held connection may sit idle indefinitely; ZenTerm drops the silence bound it
applies to anonymous clients as soon as the hold arrives.

**Latched** (`vim: true`, no `hold`) persists until an explicit `vim: false`.
This is what a plugin predating `hold` sends, and it stays supported so an older
client is never downgraded to a presence that clears the moment it hangs up.
Its failure mode is the reason `hold` exists: an nvim that dies without running
`VimLeave` leaves the pane flagged for the rest of the session, and `Ctrl-hjkl`
then reaches the recovered shell and does nothing.

A clean quit sends `vim: false` and then closes. ZenTerm treats that as one
clear, not two.

`⌘-hjkl` pane nav is never routed through any of this and always works.

## Plugin behavior (reference)

For the crossing to hold, the plugin:

1. On the mapped `Ctrl-h/j/k/l`: `let nr = winnr()` → `wincmd h/j/k/l` →
   `at_edge = (nr == winnr())` (the `vim-tmux-navigator` edge test).
2. If `at_edge`, send a `focus` command with the mapped direction; otherwise the
   `wincmd` already moved within nvim.
3. Opens one connection lazily and keeps it. Every command rides it, so the
   channel's lifetime is the pane's nvim presence.
4. On `VimEnter`/`VimResume` sends `setvim` with `vim: true, hold: true`; on
   `VimLeave`/`VimSuspend` sends `vim: false`. The EOF clear is the backstop for
   when those never run, not the primary path.
5. If a send fails (ZenTerm restarted, socket replaced), reconnects once and
   re-sends the `setvim` hold before retrying. The old connection's EOF already
   dropped the flag.

## Manual verification

With the app running (`swift run ZenTerm`) and `$ZEN_SOCK` set in a pane:

```sh
# Move focus left from pane <token>:
echo '{"cmd":"focus","dir":"left","pane":<token>}' | nc -U "$ZEN_SOCK"

# Latch / unlatch pane <token> as running nvim (the legacy shape; `nc` closes
# immediately, so this is also the escape hatch for a flag stuck by anything):
echo '{"cmd":"setvim","pane":<token>,"vim":true}'  | nc -U "$ZEN_SOCK"
echo '{"cmd":"setvim","pane":<token>,"vim":false}' | nc -U "$ZEN_SOCK"

# Hold the flag for as long as nc runs, then Ctrl-C and watch it clear:
{ echo '{"cmd":"setvim","pane":<token>,"vim":true,"hold":true}'; cat; } \
  | nc -U "$ZEN_SOCK"
```
