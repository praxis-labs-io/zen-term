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

Any process of that user can send any command and claim any `caller.pane`. `ssh.askpass`
is the one command whose answer is a secret, so it is checked against a token, not a
caller: each SSH host login gets a fresh random token, valid only until that login
connects, fails or is closed. A process that can read the login's environment can read
the token too, so it stops blind callers, not one that targets the login. The app never
logs an askpass prompt or answer.

## Discovery

Every pane, drawer and float pane shell gets:

| Var                | Value                                                |
| ------------------ | ---------------------------------------------------- |
| `ZEN_CONTROL_SOCK` | Absolute path to this instance's control socket.    |
| `ZEN_PANE`         | This pane's token (also the nav protocol's token).   |

Tool floats get neither: a float pane is one of its tab's panes, which a tool float is not. A shell that outlives its instance (a tmux session across a
relaunch) holds a dead `$ZEN_CONTROL_SOCK`, and its `$ZEN_PANE` names a pane in that
dead instance, since tokens restart in a new one.

The ssh of an SSH host's first login, started from its Connect screen, also gets
`SSH_ASKPASS` (the `zen` beside the app), `SSH_ASKPASS_REQUIRE=force` and
`ZEN_ASKPASS_TOKEN`. No other pane or float gets them.

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
- `caller.cwd`: the client's own working folder, absolute, sent with `caller.pane`. Optional.

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
| `refused`             | The command would end running work or lose it, or does not apply to its target: a split in Focus Mode, a worktree command on a workspace with no entry or on a remote host's workspace, or a `cmd` for a remote host's tab or pane. Carries `details` when `force` would go ahead. |
| `failed`              | The app could not do it.                                 |

A `refused` error says what `force` would end:

```json
{"code":"refused","message":"Closing tab w1.t3 would stop npm run dev.",
 "details":{"closesWindow":false,"floats":[],"panes":[{"token":31,"title":"npm run dev","cwd":"/Users/me/app","busy":true}]}}
```

`panes` are the running panes and drawers, in the shape `list` uses, the running children
that `pane.run` started from them included. `floats` are the
titles of running tool floats. `closesWindow` is true when the close would take a window with
it: its own, or another window whose last tab is a child that closes with it, whose running
floats are then counted too. The message says which.
A worktree removal's refusal adds `files`, its uncommitted and untracked files, and
`lostCommits`, the commits on it that no branch or other worktree holds.

Requests are decoded off the main thread, applied on it, and written back off it. The app
answers within 5 minutes, except `pane.wait` and `pane.send` with `wait`, which answer within their
`timeout` plus 5 seconds, and `pane.run` with `wait`,
within its `timeout` plus 65 seconds, and `ssh.askpass`, within 10 minutes 5 seconds.
A client that closes its connection before the answer ends a `pane.wait`. Shutting down only its
write side is not closing it: the answer still comes.

## Addressing

| Thing  | Address                           | Notes                                         |
| ------ | --------------------------------- | --------------------------------------------- |
| Pane   | its `$ZEN_PANE` token, e.g. `31`, or its name, e.g. `"review"` | A token is unique across the app and never reused. Drawers have tokens. A name is the one `pane.run` gave it, unique among the open panes one parent started, and is sent as a string; a string of digits is read as a token. A name reaches `caller.pane`'s own pane of that name first, else the one open pane with it anywhere; more than one there is `ambiguous`. When `caller.pane`'s own pane of that name has exited, the name is `not_found`, except to `pane.wait`. |
| Tab    | `w<window>.t<tab>`, e.g. `w1.t14` | Tab ids are minted per window, so the window is part of it. |
| Workspace | its folder as an absolute path, or its title | Matched across every window. The title is its current name, so after a rename the old one is `not_found`, except to `workspace.open`, which still reaches a renamed configured workspace through its entry's folder. More than one match is `ambiguous`. |
| Remote host workspace | `ssh:<host>`             | The host's alias in Settings, never its name. A host not in Settings is `not_found`, and so is one with no session or a failed login, except to `workspace.open` and the worktree commands, which refuse a host in Settings whether it has a session or not. A folder or title never names a host's workspace. |
| Window | `w<window>`                       |                                               |

A command with no target acts on the caller: `caller.pane`, its tab, its workspace.
Without a caller it acts on the active workspace, tab and focused pane of the key window.
When no terminal window is key, because the app is in the background or a window like
About is in front, it acts on the frontmost terminal window. A `caller.pane` that names no
pane is `not_found`.

Without `focus`, a command that opens something leaves the screen as it is: a new tab joins
its workspace's tab bar behind the active one, a new workspace joins the sidebar, and no
modal card, confirm, tool float or scroll mode closes. `workspace.switch`, `tab.select`
and `pane.focus` move the screen, since that is what they are for. `focus` switches to what was opened, as a click would,
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

No arguments. Every window, its workspaces in sidebar order with remote hosts' workspaces
last in Settings order, each workspace's tabs in tab order, and each tab's panes in split order followed by its drawers, then its float panes in the order they
opened. A drawer is listed from its first opening until it closes, shown or hidden; a float pane
is listed while it is open, shown or hidden.

```json
{"windows":[{"id":"w1","key":true,"workspaces":[{
  "title":"zen-term: feat-x","folder":"/Users/me/.zenterm/worktrees/zen-term/feat-x",
  "configured":true,"active":true,
  "worktree":{"name":"feat-x","parent":"/Users/me/src/zen-term"},
  "tabs":[{"id":"w1.t3","title":"zen-term","active":true,"panes":[
    {"token":31,"title":"claude","cwd":"/Users/me/.zenterm/worktrees/zen-term/feat-x","busy":true,
     "process":{"pid":81234,"program":"claude"},
     "agent":{"name":"claude","state":"waiting","status":"blocked","kind":"permission",
              "msg":"Claude needs your permission to use Bash","title":"Fix the build"}},
    {"token":32,"drawer":"bottom","title":"","busy":false},
    {"token":34,"title":"claude","busy":true,"name":"review","parent":31,"first_task":{"sent":true}}]}]}]}]}
```

- `key`: the window is the key window.
- `folder`: absent for a remote host's workspace.
- A workspace's `title` is its current name: a rename's while one is set, else its config
  title, else the name it opened with, else its active tab's folder.
- `host`: present for a remote host's workspace, as `{"alias":"devbox","state":"connected"}`.
  `state` is `connecting` or `connected`. A host whose login failed is left out.
- `worktree`: present when the workspace was opened from a worktree. `parent` is
  the folder of the workspace it belongs to.
- `drawer`: `bottom` or `right`, absent for a pane.
- `float`: `true` for a float pane, a pane its tab owns that shows in the window's float card
  instead of the split tree. Absent otherwise. A float pane closes with its tab and its
  parent like any pane, and with the agent above it (`pane.run`), never splits, and
  `pane.close` on it leaves its tab open.
- `title`: the title the program last set. A pane started with a command is titled with
  that command until its program sets one. Empty when nothing set one.
- `cwd`: absent when it is not known.
- `busy`: always false in a host's workspace, since a remote shell reports no prompts.
- `process`: the pane's foreground program: the shell at a prompt, else the job it runs.
  `pid` is its process group, which is also its leader's pid, and `program` is the name
  that process was run as (`claude`, `zsh`). Absent in a host's workspace, where it would
  be the local ssh, and when it cannot be read.
- `agent`: present when the pane runs an agent. `state` is `working`, `waiting` or
  `idle`; `name` is absent for an agent that has not been named.
- `agent.status`: the agent's own OSC 7501 state word, as it sent it: `idle`, `working`,
  `done`, `blocked` or `error`. Absent for an agent that sends none. `kind` joins
  `blocked` when the agent says what it waits on: `permission`, `question` or `auth`.
  `msg` and `title` are the report's text, each absent when it sent none.
- `name`, `parent`, `first_task`: present for a pane `pane.run` opened, when it was given a
  name, run from a pane, or given a task. `parent` is the token of the pane that ran it, and is
  absent once that pane has closed. `first_task` is the run's answer about its task, once it
  has one.
- `tab_named`: `true` when the pane's tab has a name someone gave it, with Rename Tab,
  `tab.rename` or `tab = <name>` in the workspaces file. Absent while the tab's title follows its panes.

### `workspace.open`

`args`: `workspace` (required), `focus`.

Returns a workspace that is already open, in whichever window holds it, rather than
opening a second copy, including a configured one a rename moved off its config title,
which is found through its entry's folder. Otherwise opens the workspaces-file entry whose
folder or title matches, with its tabs and launch focus, in the caller's window. When neither matches it is
`not_found`.

`ssh:<host>` returns the host's workspace when it has a session. Without one, `focus`
shows the host's Connect screen in the caller's window and does not connect, and without
`focus` it is `refused`. The Connect screen's result has no `workspace`, and `connect`
names the host:

```json
{"window":"w1","connect":"devbox"}
```

```json
{"window":"w1","workspace":{"title":"zen-term","folder":"/Users/me/src/zen-term",
  "configured":true,"active":false,"tabs":[...]}}
```

`workspace` is in the shape `list` uses.

### `workspace.new`

`args`: `path` (absolute, the home folder by default), `title`, `focus`.

Opens a workspace with no config entry at the end of the caller's window's sidebar, named
`title`, or the way a new workspace is named in the app when `title` is absent or empty. Returns it as `workspace.open` does.

### `workspace.switch`

`args`: `workspace`. Switches its window to it.

### `workspace.rename`

`args`: `workspace`, `title` (required). Names the workspace for this session; the
workspaces file is never written. An empty `title` gives it back its config title, the
name it opened with, or its active tab's folder. A host's workspace is `refused`: its name is its Settings display name.

### `workspace.close`

`args`: `workspace`, `force`. Closes each of its tabs. `refused` without `force` when
anything in it is running, or when it is the window's last workspace. A host's workspace
is never refused: it disconnects, connecting or not, and its window shows the host's Connect
screen when it was showing the workspace.

### `tab.new`

`args`: `workspace`, `cwd` (absolute), `cmd`, `focus`.

Opens a tab in the workspace running `cmd` in a shell, or a shell. It starts in `cwd`.
Else, when the caller is in that workspace, it starts in `caller.cwd`, else in the folder
the caller's pane last reported. Otherwise it starts where a new tab in the app would. An
inherited folder inside a removed worktree starts at the parent workspace's folder instead;
`cwd` is used as given. A
host's tab starts the host's login shell over its connection, so `cmd` or `cwd` for a host
is `refused`.

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
it is the window's last tab. A host tab holding the login while the host connects is
`refused`, and the message names the host and how many of its tabs would close. With
`force` the host stops connecting and its whole workspace closes, as `workspace.close`
on it would.

### `pane.split`

`args`: `pane`, `dir` (required, `right` or `down`), `cmd`, `focus`.

Splits the pane, running `cmd` in a shell or a shell. The new pane starts in `caller.cwd`
when the pane is the caller's, else in the folder the pane last reported. A folder inside a
removed worktree starts at the parent workspace's folder instead.
Focus stays on the pane that had it. A drawer does not split. `refused` when the pane's tab
is in Focus Mode or `cmd` is given for a host's pane, and `failed` when the pane is too small
to split.

```json
{"pane":32}
```

### `pane.focus`

`args`: `pane`. Shows its tab and focuses it, opening a drawer that is closed.

### `pane.close`

`args`: `pane`, `force`. `refused` without `force` when the pane is running something. From
the pane's `parent`, the pane's own program and the children that close with it are not
refused over; anything else the close would end still is. The last pane of a tab closes the
tab, refused as `tab.close` would be. The login pane of a host that is connecting is refused,
and closed with `force`, as `tab.close` on its tab is. A drawer is not closed.

### `pane.send`

`args`: `pane`, `text` (required), `enter`, `force`, `wait`, `timeout`.

Pastes `text`, so several lines arrive as one block. Text containing `<zen` or `</zen`, in any
case, is a `bad_request`, since it could pass for the envelope below. `enter` then sends Return outside the
paste, which runs the block once at a shell prompt. It delivers text, not keys: control
characters become spaces, and `pane.keys` presses keys. `failed` when the pane has not started, such as a host's pane
waiting for its connection. Nothing is sent.

Into a pane that runs an agent:

- `refused` while its `status` is `blocked`, since what it waits on is the user's decision.
  `force` sends anyway. A `pane.run` parent's send to its child blocked on a `question` is not
  refused, since a question about the task is the parent's to answer; a `permission` or `auth`
  block refuses the parent too. A `pane.run` child's send to its parent is never refused: while
  the parent is `blocked` it is queued as below and answers `{"queued":true}`, and it waits until
  the parent is not, with no 10-minute drop. A `working` agent takes the text into its running turn.
- While the person has unsent text at its prompt, the send is queued and answers
  `{"queued":true}` at once. Only keys and pastes that reach the pane's terminal count, not ones a
  card, field or button of the window takes. Text is unsent from the first typed character, Up or Down arrow, Tab or paste
  into the pane until Return sends it, Ctrl-C or Ctrl-U clears it, or Backspace deletes the last of
  what was typed. In Claude Code, the person's Ctrl-S sets their text aside, which ends it, and at an
  empty prompt brings set-aside text back, which starts one. Once the pane holds text the app could not count (recalled,
  completed or pasted text, a word or line deleted, or the cursor moved), Backspace never ends it. A Return that
  confirms an input method's text, or that follows a typed `\` with only cursor moves between, does not send it. Queued sends
  arrive in order, each on its own, right after the person's Return, or 2 seconds after the key
  that cleared it. A send within 2 seconds of any other key into the pane is queued the same way.
  Into Claude Code, a send with `enter` and text other than a slash command also arrives once 60
  seconds pass with no key into the pane: Ctrl-S sets the person's text aside, the send is pasted and
  submitted, and Claude Code puts the text back. The next send follows no sooner than 2 seconds
  after. Into any other agent, or as a slash command or without `enter`, the send waits until the
  person sends or clears their text.
  Keys or a paste into the agent while it is `blocked` answer its prompt and leave the text as it was. A queued
  send whose agent is `blocked` when its turn comes waits until it is not, and, unless it is a
  child's send to its parent, is dropped once the agent stays blocked 10 minutes from when the person
  sent or cleared their text. A queued send that
  is dropped, there or because its pane closed or refused it, answers a `wait` with a `failed` error
  that gives the reason. While a send with `enter` other than a slash command is queued, a stop
  of the agent's turn answers no wait on the pane and sends no `stopped` note, and `children`
  counts it as working, so each waits for the queued message's turn.
- From another pane, the text arrives wrapped, so the agent can tell it from its user:
  `<zen from="31 lead" reply="zen pane send --pane 31 --enter">text</zen>`. `from` is the caller's
  token, and its name after it when it has one, with `&`, `"`, `<` and `>` escaped as `&amp;`,
  `&quot;`, `&lt;` and `&gt;`. A send into a shell, into the caller's own
  pane, or of a single line starting with `/` (a slash command) is never wrapped. A child's
  note to its parent (`pane.run`) arrives the same way, its name escaped the same way.
- Into an agent, the text arrives as several pastes in a row, each at most 800 UTF-16 units and
  2 line breaks, so Claude Code keeps it inline as the message instead of folding it into
  pasted content. Claude Code folds a paste with fewer line breaks in a pane under 12 rows, so
  text with line breaks can still fold there.

`wait` then holds as `pane.wait` on the pane, with `timeout`, and answers as it does. A queued
send's wait begins when it is queued, and its `timeout` counts from then.

### `pane.run`

`args`: `cmd` (required), `name`, `task`, `split` (`right` or `down`), `float`, `pane`, `cwd`
(absolute), `focus`, `keep`, `outlive_parent`, `replace`, `wait`, `timeout`, `output`.

Runs `cmd` in a shell in a new pane and records `caller.pane` as its parent. Without `split`
it opens a hidden float pane in the tab of `pane` (the caller's by default), or a tab behind
the active one in that pane's workspace. `float` picks: `true` a float, `false` a tab. Absent,
it is a float when an agent runs in `caller.pane`, without `outlive_parent`, outside a remote
host's workspace, with `pane` in the caller's window; a tab otherwise. A float stays hidden
until its row in the Agents list, `pane.focus` or `focus` shows it. `float: true` is refused
unless an agent runs in `caller.pane` or a pane above it (its parent, and on up), when `pane`
is in another window than `caller.pane`, and in a remote host's workspace.
`float` with `split`, or `float: true` with `outlive_parent`, is a `bad_request`. It
starts in `cwd`, else in `caller.cwd` when `pane` is the caller's, else in the folder that pane
last reported. An inherited folder inside a removed worktree starts at the parent workspace's
folder instead; `cwd` is used as given. A pane launched as `cd <folder> && <program>` never
reports `<folder>`, which is why `caller.cwd` comes first. `cwd` that is not absolute, or sent with `split`, is a
`bad_request`. With `split` it splits `pane` the way `pane.split` does, and is
refused or fails the same way. `focus` shows the new pane.

A pane closes the children it started when it closes, and they close theirs, wherever they are
in any window, however it closes: `pane.close`, `tab.close`, `workspace.close`, its program
exiting, or the window closing. A close that would end a running child is refused without
`force`, and its `details` list that child; the app's close confirmation names it too. A
parent's own `pane.close` on its child is not refused over the child's work (`pane.close`).
`outlive_parent` keeps the pane open when its parent closes; it then has no `parent`. A float
pane also closes once no agent runs in its parent or any pane above it, so the agent above it
exiting closes it even when that agent's pane stays open; that close is not refused over its
work. An agent that quits while its pane stays open closes nothing else. A pane that must
outlive the agent that starts it takes `outlive_parent`, which opens a tab.

The pane closes when its program exits, with any exit code. `keep` drops it to a shell instead,
the way `tab.new` and `pane.split` run a `cmd`, unless the command ends in its shell's own `exit`
or, under zsh, an interrupt ends it.

`name` is refused when an open pane `caller.pane` started has it, and is a `bad_request` when it
is blank or all digits. The name then addresses the pane anywhere a token does, until it closes.
`replace` closes that pane first, as its parent's `pane.close` would, and is refused the same way,
leaving it open. The new pane opens where the other args put it, then takes the name. `replace`
without `name`, or with `split` on the pane it closes, is a `bad_request`; with no such pane it
runs as without it.

```json
{"pane":34,"first_task":{"sent":false,"reason":"blocked"}}
```

Without `task` it answers at once and `first_task` is absent. With one, it answers once the
program sends its first OSC 7501 status report, or after 60 seconds. A first report of `idle`
or `done` means it is ready: the task is pasted and Return sent, as `pane.send` with `enter`
does, in the caller's envelope, and `first_task` is `{"sent":true}`. A `task` with a `<zen` or
`</zen` tag, in any case, is a `bad_request`, as it is for `pane.send`. Otherwise the task is not sent and `reason` says why:

| `reason`    | When                                                                 |
| ----------- | -------------------------------------------------------------------- |
| `blocked`   | The first report was `blocked`: it waits on the person, such as a permission ask. |
| `not_ready` | The first report was `working` or `error`, or the pane closed before any report. |
| `no_status` | No report in 60 seconds. A program that sends none, or an agent under tmux. |

The pane keeps the answer as its `first_task` in `list`. The task is sent at most once: read the
pane before sending it yourself, never resend blind. After `no_status`, wait for the program's
prompt with `zen wait --output`, then send the task with `pane.send`.

`wait` takes `timeout` and, once it would answer, holds as `pane.wait` on the new pane instead
and answers as it does. The answer's `pane` carries `first_task`. `output` holds for that text as
`pane.wait` does, matched from the screen as the pane opens (with `task`, as the task is sent), so
a server's ready line cannot print before the wait begins. It is a `bad_request` without `wait`.

A parent that runs an agent hears from the children it ran, so a child that finishes after the
parent's turn ended still wakes it. Each change sends one line, in the child's envelope
(`<zen from="34 review" reply="zen pane send --pane 34 --enter">`), pasted with Return as `pane.send`
with `enter` sends it:

| Change    | When                                                       | Note                                                                    |
| --------- | ---------------------------------------------------------- | ----------------------------------------------------------------------- |
| `stopped` | The child's `status` left `working`, but not to `blocked`. | `review stopped (done): read it with zen pane read --pane 34`           |
| `blocked` | The child's `status` became `blocked`.                     | `review is blocked on a permission prompt; that decision is the user's` |
| `resumed` | The child's `status` went from `blocked` to `working`.     | `review is working again; wait on it with zen wait 34`                  |
| `exited`  | Its program exited, closing its pane.                      | `review exited with code 1`                                             |

- A child without a name is `pane 34`. `blocked` names `a permission prompt` or `a login` when
  the program says which. A child blocked on a question sends
  `review is asking a question: read it with zen pane read --pane 34 and answer it, or ask the user when it is a product or scope call`.
- There is no note when the parent runs no agent, when a `pane.wait` the parent holds on the
  child answers the same change, when one the parent held answered the child's exit before its pane
  closed, when one it holds on its `children` watches the child, since
  that wait reports the change, or for the report that settles `first_task`, which `pane.run`
  answers with. No wait answers `resumed`, so any wait the parent holds on the child stands in
  for it, and there is none when the parent sent or pressed anything into the child while it was
  `blocked`, since the parent answered it. A pane run with `keep` stays open when its program exits, and sends no `exited`.
- There is no `stopped` note when the child submitted a `pane.send` to its parent (text with `enter`) since its turn began,
  when its `status` last became `working` from anything but `blocked`, since that message carries
  the news, unless the parent has sent or pressed anything into it since. A `stopped`, `blocked` or `resumed`
  note still held when the child's pane closes, as when the parent closes it, is dropped, and so
  is a `blocked` note still held once the child's `status` has left `blocked`.
- A note holds for the parent's draft as `pane.send` does. While the parent is `blocked` it holds
  until it is not, since a paste would answer the parent's prompt, and after 10 minutes it is
  dropped.

### `pane.keys`

`args`: `pane`, `keys` (required), a list of key names, `force`.

Presses each key in order as a keystroke, not a paste, so a menu or a prompt reads it as
the key: `enter`, `escape`, `tab`, `shift-tab`, `backspace`, `space`, `up`, `down`, `left`,
`right`, `home`, `end`, `pageup`, `pagedown`, and `ctrl-a` through `ctrl-z`. A name that is
not a key is `bad_request` naming it, and nothing is pressed. `failed` when the pane has not
started. Into an agent whose `status` is `blocked`, it is `refused` without `force` under
`pane.send`'s rule: a `pane.run` parent's keys into its child blocked on a `question` are not
refused, and a `permission` or `auth` block refuses everyone. Nothing is pressed.

### `pane.interrupt`

`args`: `pane`.

Stops what the pane is doing without ending it. A pane running an agent gets Escape, which
ends Claude's or Codex's turn and leaves the agent running. Otherwise the terminal's
foreground process group gets SIGINT, as Ctrl-C would: the program, or the shell at a
prompt. A remote host's pane gets Ctrl-C as a key, so the host's terminal sends the signal.
`failed` when the pane has not started or its foreground process is not known.

### `pane.read`

`args`: `pane`, `lines`, `since` (`task`).

Returns the rows on screen, or with `lines` the last that many lines of the screen and its
scrollback, a prompt included. Trailing blank lines are dropped. `failed` when the pane has
not started or its screen cannot be read.

```json
{"text":"$ seq 3\n1\n2\n3"}
```

- With `since: "task"` it returns what the pane printed since its last task or message: a
  `pane.run` `task` or a `pane.send` with `enter`, read from the start of the cursor's row as it
  arrived, so the text starts with the prompt and its echo. A full-screen program showing as it arrived
  reads from that row, not its whole screen. Each such send replaces the last. The answer carries
  `truncated`, true when the scrollback dropped that spot, so the text starts at the oldest
  row, or when a full-screen program started since shows, so the text is that screen.
- It reads the cells as they stand, not a log: a program that redraws reads as it shows now.
- `lines` and `since` together are a `bad_request`. `failed` when the pane has had no task or
  message.

```json
{"text":"$ make test\n1 test failed","truncated":false}
```

### `pane.get`

`args`: `pane`.

Returns one pane or drawer in the shape `list` uses, without the tree around it.

```json
{"token":31,"title":"claude","cwd":"/Users/me/src/app","busy":true,
 "process":{"pid":81234,"program":"claude"},
 "agent":{"name":"claude","state":"working","status":"working","msg":"Reading x.swift"}}
```

### `pane.wait`

`args`: `pane` or `children` (`any` or `all`), `output`, `timeout` (seconds, at least 1, 90 by default, under the 2-minute default of agents' shell tools). A longer `timeout` than 600 waits 600, and the answer carries `timeoutCapped: 600`, on `pane.send` and `pane.run` with `wait` too.

Holds until something happens to the pane, then answers once with why:

| `reason`  | When |
| --------- | ---- |
| `stopped` | The agent's `status` left `working`. Without `output` only. |
| `exited`  | Its program exited, or the pane closed. |
| `output`  | `output` appeared in text printed after the wait began. |
| `message` | The pane waited on sent the caller's own pane a `pane.send` or a note. Anything else sent there still arrives, and leaves the wait standing. |
| `timeout` | Nothing happened within `timeout`. A check-in, not a failure: wait again. |

```json
{"reason":"exited","exitCode":1,"text":"$ make test\n1 test failed",
 "pane":{"token":34,"title":"make test","busy":false,...}}
```

- `pane` is the pane as `pane.get` reports it, or for a pane that closed, as it was last read.
- The program is the pane's foreground job, an agent included. A pane at a shell prompt waits
  for the next command to finish. An agent that sends no `status` waits as a plain program does.
- `exitCode` is the shell's report through its integration, and is absent when the shell
  integration is off. A `pane.run` command that ends in its shell's own `exit` reports none
  under a shell other than sh, bash, zsh and ksh, or under bash, sh and ksh once it set an `EXIT`
  trap of its own. `text` is the last 40 lines. Both are absent for a pane that closed, unless
  `pane.run` opened it.
- `output` is matched within one line, a soft-wrapped line read as one, without escapes, so a
  newline in it is a `bad_request`.
- A pane `pane.run` opened closes when its program exits, and a wait on it still answers
  `exited` with the `exitCode` and `text` read as it closed, also when the wait begins after.
  A name then reaches the most recent such pane with that name, `caller.pane`'s own first. The app keeps the 64 most
  recent such exits; an older one is `not_found`.

`children` waits on the panes `caller.pane` started with `pane.run`, as they are when the wait
begins, and takes no `pane`. Each child is watched as a wait on its pane would be.

| `children` | Answers |
| ---------- | ------- |
| `any`      | On the first child's news, with that child's `reason`: `stopped`, `exited`, or `output`. |
| `all`      | `stopped` once none is working, at once when none is. |

A child is working while its agent's `status` is `working`, or, with no `status`, while the app
reads its agent as working. A child that runs no agent is working while its program runs. A child
handed a task while its `status` was `idle` or `done`, as its first task or as `pane.send` text
with `enter` other than a slash command, counts as working until its `status` moves past `idle`
or `done`, clears, or its agent exits, so `all` does not answer before it starts on the task. A
child with such a send queued for its person's draft counts as working until the send arrives.
With `all`, each child's `reason` is its latest news while the wait held, so a child that
stopped and then exited answers `exited` with its `exitCode` and `text`. `message` answers when a child sends the
caller something, and `timeout` as it does for a pane, and `output` is a
`bad_request` with `all`.

```json
{"reason":"exited","children":[
  {"reason":"exited","exitCode":0,"text":"$ make test\nall passed","pane":{"token":34,...}},
  {"pane":{"token":35,"agent":{"name":"claude","state":"working","status":"working"},...}}]}
```

`children` lists every child the wait watched, each with its `pane` as `pane.get` reports it, or
as it was last read once it closed. A child's `reason`, `exitCode` and `text` are its own news
during the wait, absent when it had none. The answer has no `pane`. A caller with no children
gets `{"reason":"no_children","children":[]}` at once. A request without `caller.pane` is a
`bad_request`.

### `worktree.list`

`args`: `workspace`.

The worktrees of the workspace's repo, its main checkout left out. Every worktree command
resolves the workspace to its entry in the workspaces file, read fresh, and a worktree
workspace to the workspace it was made from. A workspace with no entry is `refused`, and so
is a remote host's workspace, by its `ssh:<host>` address or as the caller's.

```json
{"worktrees":[{"path":"/Users/me/.zenterm/worktrees/zen-term-1a2b3c4d/feat-x","branch":"feat/x",
  "head":"4f1c9e0d2b7a6c5e8f3a1b0c9d8e7f6a5b4c3d2e","locked":false}]}
```

`branch` is absent for a detached checkout.

### `worktree.create`

`args`: `branch` (required), `workspace`, `base`, `existing`, `open`, `focus`.

Makes a worktree on a new branch cut from `base`: `default`, the default branch, unless
`current` cuts it from what the workspace's checkout is on. `existing` checks out a branch
that already exists instead and ignores `base`. It copies the entry's `carry` into the
worktree and opens nothing. `open` also opens a workspace there, nested under the
workspace it was made from, in the window that has that workspace open, else the caller's
window. `focus` implies `open` and switches to it. It answers once the copy finishes.
Anything git refuses is `failed`, with the message the app's New Worktree card shows.

```json
{"path":"/Users/me/.zenterm/worktrees/zen-term-1a2b3c4d/feat-x",
 "carry":{"carried":[".env"],"skipped":[{"name":"node_modules","reason":"is tracked by git"}]},
 "window":"w1","workspace":{"title":"zen-term: feat/x",...}}
```

`skipped` holds what was there to copy and did not arrive. An entry with nothing to copy
is in neither list. `window` and `workspace` are present only when it opened one, and
`workspace` is in the shape `list` uses.

### `worktree.remove`

`args`: `path` (absolute) or `branch`, `workspace`, `force`.

Removes the workspace's worktree at that folder or on that branch, and closes every tab
open in it in any window. The branch stays. It answers once the folder is gone. `refused`
without `force` when anything in those tabs is running, when closing them would close a
window, when the worktree holds
uncommitted or untracked files or commits no branch holds, or when git can't say, so
removing the worktree a caller runs in needs `force`. A locked worktree is always
`refused`.

### `action`

`args`: `name` (required).

Runs a keymap action by its config name, like `toggle_sidebar` or `split_vertical`, in the
same window a command with no target acts on. It goes through the same gate as the
action's shortcut: with a card or confirm open, it does what the shortcut does there, which
can be nothing. The aliases a `keybind` line accepts work too. `toggle_float:<id>` takes the
id of a configured float. A name that is not an action is `not_found`, and its message
lists every action.

### `ssh.askpass`

`args`: `token`, `prompt` (both required), `ssh_pid`.

Asks a person the question an SSH host login's ssh asks (`prompt`, verbatim), on that
host's Connect screen, and answers `{"answer":"<text>"}` once they reply. `token` must be
the login's `ZEN_ASKPASS_TOKEN`; any other is `not_found`. `ssh_pid` is the asking ssh,
which tells a repeated question (the last answer didn't work) from the same text asked by
a ProxyJump's own ssh. A host key question answers exactly `yes` or nothing. A cancelled or
ended login answers `failed`, as does a newer question from the same login. A client that
closes its connection withdraws the question.

## `zen`

`zen hello` and `zen list` print the result as JSON. `zen list --pretty` prints an
indented tree instead. Exit codes: 0 ok, 1 the app answered with an error or didn't
answer within 10 seconds (5 minutes for `worktree create`, `worktree remove` and `pane run`, 10 minutes 10 seconds as askpass, and
the `--timeout` plus 10 seconds for `zen wait` and `zen pane send --wait`, or 70 more for
`zen pane run --wait`), 2 usage,
3 no instance or the connection failed. A wait (`zen wait`, `zen pane send --wait`, `zen pane run --wait`) prints
its answer, then exits 0 for `stopped`, `output`, `no_children` or `exited` with `exitCode` 0, 4 for `exited` with
any other `exitCode` or none, 5 for `timeout` and 6 for `message`. A wait on `children` exits 4 when any child's
`reason` is such an `exited`, unless the wait answered `timeout` or `message`.

`zen --version` prints the version of the ZenTerm.app it sits in, through a symlink too, and
`0.0.0+src` for a build from source. A response whose `v` is newer than the protocol `zen`
speaks is refused with exit 1, before its result is read, and the message names both
versions.

Each command is `zen <noun> <verb>`: `zen workspace open|new|switch|rename|close`,
`zen tab new|select|rename|close`, `zen pane run|split|focus|close|send|keys|interrupt|read|get` and
`zen worktree list|create|remove`, with `--focus` and `--force` for those fields.
`zen action <name>` runs a keymap action. `zen wait <pane>` waits on a pane, taking
`--output` and `--timeout`, and prints the answer as JSON.
With `ZEN_ASKPASS_TOKEN` set, exactly one argument and a parent named `ssh`, `zen` is ssh's askpass: it sends the
argument as `ssh.askpass`'s `prompt`, with `$ZEN_CONTROL_SOCK` and its parent's pid, prints
the answer, and exits 0. It never reads stdin. With `SSH_ASKPASS_PROMPT=confirm` it exits 1
without asking, which ssh reads as no; with `none`, a notice, it exits 0. Any failure exits 1,
or 3 without an instance, and prints neither prompt nor answer.
`zen setup claude` and `zen setup claude --remove` edit Claude Code's config, not the app,
and never open the socket. A command
that returns something prints it as JSON, except `zen pane read`, which prints the text; the
rest print nothing. `zen pane read --since-task` sends `since: "task"`, and says on stderr when the
answer is `truncated`. Every `zen pane` verb but `run`, and `zen wait`, takes its pane as an
argument or as `--pane`, and both is a usage error. `split`, `send`, `read` and `get` act on this
pane without one. `zen pane send` reads two arguments as the pane and the text, and one as the text.
`zen pane send --wait` and `zen pane run --wait` take `--timeout` and print the answer as
`zen wait` does. `zen pane send` without `--wait` prints `{"queued":true}` when the send was queued,
and nothing when it arrived. `zen pane run --wait` also takes `--output`.
`zen pane split` splits to the right unless `--dir down` says otherwise.
`zen pane keys [<pane>] <key>... [--force]` takes the keys as the arguments after the pane, or as
every argument with `--pane`, and a name that is not a key is a usage error.
`zen pane run [--name [--replace]] [--task] [--split right|down] [--float|--tab] [--pane] [--cwd] [--focus] [--keep] [--outlive-parent] [--wait [--output]] <command>` sends `--float` as `float: true` and `--tab` as `float: false`, and both together is a usage error. It takes
everything after its options, and after a `--`, as the command. One argument is a shell line as
written; several are each quoted, so `-- sh -c 'sleep 1'` arrives as typed. A leading `--help` or
`-h` prints the help, and `-- --help` runs `--help`. A pane argument,
`zen wait`'s included, is a token when it is all digits and a name otherwise.
`zen workspace new` takes `--title`, and `zen workspace rename <title>` takes the workspace
as `--workspace`. `zen worktree create <branch>` takes `--base default|current` or `--existing`, not both, and
opens a workspace on it only with `--open` or `--focus`.
`zen worktree remove` takes a folder when it starts with `/`, `~` or `.`, and a branch
otherwise. `zen` sends
folders as absolute paths, read against its own folder, and refuses a `--cwd` or
`workspace new` folder that does not exist. A workspace argument is a folder when it
starts with `/`, `~` or `.`, a host when it starts with `ssh:`, and a title otherwise. A refusal prints what it would stop,
one line each. A worktree refusal lists the files it would lose first.
