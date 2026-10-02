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
{"v":1,"id":1,"cmd":"list","caller":{"pane":31}}
```

- `v`: the protocol version the client speaks. Required. This build speaks `1`.
- `id`: an integer, echoed on the response. Required.
- `cmd`: the command name. Required.
- `caller.pane`: the client's `$ZEN_PANE`, when it runs in a pane. Optional.

Unknown fields are ignored.

## Responses

```json
{"v":1,"id":1,"ok":true,"result":{...}}
{"v":1,"id":2,"ok":false,"error":{"code":"unknown_command","message":"There is no command named tab.explode."}}
```

`v` is the version the app speaks. `id` is `null` when the request had no
integer `id` that could be read.

| Code                  | When                                                     |
| --------------------- | -------------------------------------------------------- |
| `bad_request`         | Not a JSON object, or `v`, `id` or `cmd` missing or the wrong type. |
| `unknown_command`     | `cmd` names no command.                                  |
| `unsupported_version` | `v` is newer than the app speaks; the response's `v` says which it does. |
| `not_found`           | A target names nothing that exists.                      |
| `ambiguous`           | A target names more than one thing.                      |
| `refused`             | The command would end running work or lose it.           |
| `failed`              | The app could not do it.                                 |

Requests are decoded off the main thread, applied on it, and written back off it.

## Addressing

| Thing  | Address                           | Notes                                         |
| ------ | --------------------------------- | --------------------------------------------- |
| Pane   | its `$ZEN_PANE` token, e.g. `31`  | Unique across the app and never reused. Drawers have tokens. |
| Tab    | `w<window>.t<tab>`, e.g. `w1.t14` | Tab ids are minted per window, so the window is part of it. |
| Window | `w<window>`                       |                                               |

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
- `title`: the title the program last set, empty when it set none.
- `cwd`: absent when it is not known.
- `agent`: present when the pane runs an agent. `state` is `working`, `waiting` or
  `idle`; `name` is absent for an agent that has not been named.

## `zen`

`zen hello` and `zen list` print the result as JSON. `zen list --pretty` prints an
indented tree instead. Exit codes: 0 ok, 1 the app answered with an error or didn't
answer within 10 seconds, 2 usage, 3 no instance or the connection failed.
