# Control protocol

The contract between a running ZenTerm and anything that drives it from outside,
`zen` first. ZenTerm implements the server; the wire types live in the
`ControlProtocol` target, which the app and `zen` both import.

## Transport

- `AF_UNIX`, `SOCK_STREAM`, one socket per app instance at
  `~/Library/Application Support/ZenTerm/control.<pid>.sock`.
- Newline-delimited (`\n`) UTF-8 JSON: one request per line, one response per
  line. A connection may send any number of requests. Responses come back in
  request order and are matched by `id`.
- A line longer than 64 KiB gets `bad_request` and the connection is closed. A
  connection that sends nothing for 30 seconds is closed.
- A line that is not a valid request gets an error response, never silence, and
  the connection stays open for the next one.

## Security

The socket file is `0600`, and its folder is created `0700` when missing. Every
accepted connection checks the peer with `getpeereid` and closes, unread, one
whose uid is not the app's. The server is on whenever the app runs.

## Discovery

Every pane and drawer shell gets:

| Var                | Value                                                |
| ------------------ | ---------------------------------------------------- |
| `ZEN_CONTROL_SOCK` | Absolute path to this instance's control socket.    |
| `ZEN_PANE`         | This pane's token (also the nav protocol's token).   |

Tool floats get neither. A shell that outlives its instance (a tmux session across a
relaunch) holds a dead `$ZEN_CONTROL_SOCK`, and its `$ZEN_PANE` names a pane in that
dead instance, since tokens restart in a new one.

`zen` uses `$ZEN_CONTROL_SOCK` when something accepts a connect on it, and sends
`$ZEN_PANE` as `caller.pane`. Otherwise it lists `control.*.sock` in the folder above
and connects to each: one that accepts is a running instance. It uses the only live
socket and sends no caller. It exits 3 when there is none, and exits 3 listing them
when there are several. `zen --socket <path>` is used as given, with no fallback, and
carries `caller.pane` only when it is the inherited socket.

## Requests

```json
{"v":1,"id":1,"cmd":"tab.new","args":{"cmd":"npm run dev"},"caller":{"pane":31}}
```

- `v`: the protocol version the client speaks. Required. This build speaks `1`.
- `id`: an integer, echoed on the response. Required.
- `cmd`: the command name. Required.
- `args`: an object of the command's arguments. Optional, and absent or `null` means none.
  A field of the wrong type is a `bad_request`.
- `caller.pane`: the client's `$ZEN_PANE`, when it runs in a pane. Optional.

Unknown fields are ignored, in `args` too.

## Responses

```json
{"v":1,"id":1,"ok":true,"result":{...}}
{"v":1,"id":2,"ok":false,"error":{"code":"unknown_command","message":"There is no command named tab.explode."}}
```

`v` is the version the app speaks. `id` is `null` when the request had no
integer `id` that could be read. A command with nothing to return answers `{}`.

| Code                  | When                                                     |
| --------------------- | -------------------------------------------------------- |
| `bad_request`         | Not a JSON object, or `v`, `id` or `cmd` missing or the wrong type. |
| `unknown_command`     | `cmd` names no command.                                  |
| `unsupported_version` | `v` is newer than the app speaks; the response's `v` says which it does. |
| `not_found`           | A target names nothing that exists.                      |
| `ambiguous`           | A target names more than one thing.                      |
| `refused`             | The command would end running work or lose it, or does not apply to its target: a split in Focus Mode, or a worktree command on a workspace with no entry. Carries `details` when `force` would go ahead. |
| `failed`              | The app could not do it.                                 |

A `refused` error says what `force` would end:

```json
{"code":"refused","message":"Closing tab w1.t3 would stop npm run dev.",
 "details":{"closesWindow":false,"floats":[],"panes":[{"token":31,"title":"npm run dev","cwd":"/Users/me/app","busy":true}]}}
```

`panes` are the running panes and drawers, in the shape `list` uses. `floats` are the
titles of running tool floats. `closesWindow` is true when the close would take the
window with it.
A worktree removal's refusal adds `files`, its uncommitted and untracked files, and
`lostCommits`, the commits on it that no branch or other worktree holds.

Requests are decoded off the main thread, applied on it, and written back off it.

## Addressing

| Thing  | Address                           | Notes                                         |
| ------ | --------------------------------- | --------------------------------------------- |
| Pane   | its `$ZEN_PANE` token, e.g. `31`  | Unique across the app and never reused. Drawers have tokens. |
| Tab    | `w<window>.t<tab>`, e.g. `w1.t14` | Tab ids are minted per window, so the window is part of it. |
| Workspace | its folder as an absolute path, or its title | Matched across every window. More than one match is `ambiguous`. |
| SSH host workspace | `ssh:<host>`             | Reserved. Nothing answers to it yet, so it is `not_found`. |
| Window | `w<window>`                       |                                               |

A command with no target acts on the caller: `caller.pane`, its tab, its workspace.
Without a caller it acts on the active workspace, tab and focused pane of the key window,
or of the frontmost ZenTerm window while the app is in the background. A `caller.pane`
that names no pane is `not_found`.

Without `focus`, no command moves what is on screen: a new tab joins its workspace's tab
bar behind the active one, a new workspace joins the sidebar, and no modal card, confirm,
tool float or scroll mode closes. `focus` switches to what was opened, as a click would,
and brings its window forward when it is not the key window. Closing the tab on screen
lands on its neighbour and closes a tool float or confirm over it, and leaves a modal card
open.

## Commands

### `hello`

No arguments.

```json
{"app":"0.0.0+src","protocol":1}
```

`app` is the app's version; a build from source reports `0.0.0+src`.

### `list`

No arguments. Every window, its workspaces in sidebar order, each workspace's tabs
in tab order, and each tab's panes in split order followed by its drawers. A drawer
is listed from its first opening until it closes, shown or hidden.

```json
{"windows":[{"id":"w1","key":true,"workspaces":[{
  "title":"zen-term: feat-x","folder":"/Users/me/.zenterm/worktrees/zen-term/feat-x",
  "configured":true,"active":true,
  "worktree":{"name":"feat-x","parent":"/Users/me/src/zen-term"},
  "tabs":[{"id":"w1.t3","title":"zen-term","active":true,"panes":[
    {"token":31,"title":"nvim","cwd":"/Users/me/.zenterm/worktrees/zen-term/feat-x","busy":true,
     "agent":{"name":"claude","state":"waiting"}},
    {"token":32,"drawer":"bottom","title":"","busy":false}]}]}]}]}
```

- `key`: the window is the key window.
- `worktree`: present when the workspace was opened from a worktree. `parent` is
  the folder of the workspace it belongs to.
- `drawer`: `bottom` or `right`, absent for a pane.
- `title`: the title the program last set. A pane started with a command is titled with
  that command until its program sets one. Empty when nothing set one.
- `cwd`: absent when it is not known.
- `agent`: present when the pane runs an agent. `state` is `working`, `waiting` or
  `idle`; `name` is absent for an agent that has not been named.

### `workspace.open`

`args`: `workspace` (required), `focus`.

Returns a workspace that is already open, in whichever window holds it, rather than
opening a second copy. Otherwise opens the workspaces-file entry whose folder or title
matches, with its tabs and launch focus, in the caller's window. When neither matches it is
`not_found`.

```json
{"window":"w1","workspace":{"title":"zen-term","folder":"/Users/me/src/zen-term",
  "configured":true,"active":false,"tabs":[...]}}
```

`workspace` is in the shape `list` uses.

### `workspace.new`

`args`: `path` (absolute, the home folder by default), `focus`.

Opens a workspace with no config entry at the end of the caller's window's sidebar,
named the way a new workspace is named in the app. Returns it as `workspace.open` does.

### `workspace.switch`

`args`: `workspace`. Switches its window to it.

### `workspace.close`

`args`: `workspace`, `force`. Closes each of its tabs. `refused` without `force` when
anything in it is running, or when it is the window's last workspace.

### `tab.new`

`args`: `workspace`, `cwd` (absolute), `cmd`, `focus`.

Opens a tab in the workspace running `cmd` in a shell, or a shell. It starts in `cwd`,
else in the caller's folder when the caller is in that workspace, else where a new tab
in the app would.

```json
{"tab":"w1.t14","pane":31}
```

### `tab.select`

`args`: `tab`. Shows it, switching its window to its workspace first.

### `tab.rename`

`args`: `tab`, `title` (required). An empty `title` gives the tab back the title its
program sets.

### `tab.close`

`args`: `tab`, `force`. `refused` without `force` when anything in it is running, or when
it is the window's last tab.

### `pane.split`

`args`: `pane`, `dir` (required, `right` or `down`), `cmd`, `focus`.

Splits the pane, starting the new one in its folder, running `cmd` in a shell or a shell.
Focus stays on the pane that had it. A drawer does not split. `refused` when the pane's tab
is in Focus Mode, and `failed` when the pane is too small to split.

```json
{"pane":32}
```

### `pane.focus`

`args`: `pane`. Shows its tab and focuses it, opening a drawer that is closed.

### `pane.close`

`args`: `pane`, `force`. `refused` without `force` when the pane is running something. The
last pane of a tab closes the tab, refused as `tab.close` would be. A drawer is not closed.

### `pane.send`

`args`: `pane`, `text` (required), `enter`.

Pastes `text`, so several lines arrive as one block. `enter` then sends Return outside the
paste, which runs the block once at a shell prompt. It delivers text, not keys: control
characters become spaces.

### `pane.read`

`args`: `pane`, `lines`.

Returns the rows on screen, or with `lines` the last that many lines of the screen and its
scrollback, a prompt included. Trailing blank lines are dropped.

```json
{"text":"$ seq 3\n1\n2\n3"}
```

### `worktree.list`

`args`: `workspace`.

The worktrees of the workspace's repo, its main checkout left out. Every worktree command
resolves the workspace to its entry in the workspaces file, read fresh, and a worktree
workspace to the workspace it was made from. A workspace with no entry is `refused`.

```json
{"worktrees":[{"path":"/Users/me/.zenterm/worktrees/zen-term-1a2b3c4d/feat-x","branch":"feat/x",
  "head":"4f1c9e0d2b7a6c5e8f3a1b0c9d8e7f6a5b4c3d2e","locked":false}]}
```

`branch` is absent for a detached checkout.

### `worktree.create`

`args`: `branch` (required), `workspace`, `base`, `existing`, `focus`.

Makes a worktree on a new branch cut from `base`: `default`, the default branch, unless
`current` cuts it from what the workspace's checkout is on. `existing` checks out a branch
that already exists instead and ignores `base`. It copies the entry's `carry` into the
worktree and opens a workspace there, nested under the workspace it was made from, in the
window that has that workspace open, else the caller's window. It answers once the copy
finishes. Anything git refuses is `failed`, with the message the app's New Worktree card
shows.

```json
{"path":"/Users/me/.zenterm/worktrees/zen-term-1a2b3c4d/feat-x",
 "carry":{"carried":[".env"],"skipped":[{"name":"node_modules","reason":"is tracked by git"}]},
 "window":"w1","workspace":{"title":"zen-term: feat/x",...}}
```

`skipped` holds what was there to copy and did not arrive. An entry with nothing to copy
is in neither list. `workspace` is in the shape `list` uses.

### `worktree.remove`

`args`: `path` (absolute) or `branch`, `workspace`, `force`.

Removes the workspace's worktree at that folder or on that branch, and closes every tab
open in it in any window. The branch stays. It answers once the folder is gone. `refused`
without `force` when the worktree holds uncommitted or untracked files or commits no
branch holds, or when git can't say. A locked worktree is always `refused`.

## `zen`

`zen hello` and `zen list` print the result as JSON. `zen list --pretty` prints an
indented tree instead. Exit codes: 0 ok, 1 the app answered with an error or didn't
answer within 10 seconds, 2 usage, 3 no instance or the connection failed.

Each command is `zen <noun> <verb>`: `zen workspace open|new|switch|close`,
`zen tab new|select|rename|close` and `zen pane split|focus|close|send|read`, with
`--focus` and `--force` for those fields. A command that returns something prints it as
JSON, except `zen pane read`, which prints the text; the rest print nothing.
`zen pane split` splits to the right unless `--dir down` says otherwise. `zen` sends
folders as absolute paths, read against its own folder, and refuses a `--cwd` or
`workspace new` folder that does not exist. A workspace argument is a folder when it
starts with `/`, `~` or `.`, and a title otherwise. A refusal prints what it would stop,
one line each.
