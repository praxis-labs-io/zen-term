# Control ZenTerm from the command line

Status: in flight · scratch spec, lives on feature/cli-control only and is deleted before it merges to main

Nothing outside the app can drive ZenTerm. An agent that wants a worktree, a new tab running a dev server, or the text of the pane next to it has to ask a person to press the chord. The only way in today is the nav socket, and it's built for one client: two fire-and-forget commands, no replies, malformed lines dropped silently, a 2s receive timeout. Most of the verbs a CLI needs already exist inside `WindowController` (`openWorkspace`, `newWorkspace`, `addTab`, `activate`, `reveal`, `closeTab`, `requestCloseWorkspace`), but they're private and assume a person is looking: they close the modal, slide the canvas, and activate what they open. Worktree creation is worse, since `createWorktree(_:from:)` reports its progress into the `NewWorktreeOverlay` card while it runs.

## Solution

A second socket, `control.<pid>.sock`, speaks request and response JSON. A `zen` executable ships inside `ZenTerm.app` and is the supported client. The app side adds headless verbs that the chrome's own paths and the socket both call, so there is one path per operation.

- **Separate socket, not an extension of the nav socket.** The nav contract (`docs/nvim-navigator-protocol.md`) stays byte for byte. Control needs replies, error codes and no silent drops, which would change what an nvim client sees.
- **Shared listener.** Bind, listen, stale sweep and the per-pid path move out of `NavSocketServer` into one listener both servers use. This is the second use, so it gets extracted now.
- **Shared wire types in a new leaf target, `ControlProtocol`.** Foundation only, imported by `ZenTerm` and the `zen` target. The CLI can't import an executable target, and duplicating the types is how the two ends drift.
- **`zen` target** links `ControlProtocol` and `swift-argument-parser` (approved). Nothing else in the package takes the dependency.

## Wire protocol

Newline-delimited UTF-8 JSON, one request per line, one response per line, matched by `id`. A connection may send several requests.

```json
{"v":1,"id":1,"cmd":"tab.new","args":{"cwd":"/path","cmd":"npm run dev"},"caller":{"pane":7}}
{"v":1,"id":1,"ok":true,"result":{"tab":"w1.t14","pane":31}}
{"v":1,"id":2,"ok":false,"error":{"code":"refused","message":"2 panes are running","details":{...}}}
```

- `v` is the protocol version. A request with a newer `v` than the app speaks gets `unsupported_version` and the version the app does speak. `hello` returns app version and protocol version.
- `caller.pane` is the client's `$ZEN_PANE` when it has one. It's how "this pane", "this tab" and "this workspace" resolve.
- Error codes: `bad_request`, `unknown_command`, `unsupported_version`, `not_found`, `ambiguous`, `refused`, `failed`. `refused` always carries `details` that say what a `--force` would end.
- Every request is decoded off-main, applied on main, and answered from main. Anything that can block (git, filesystem) runs off-main and answers when it finishes. Never `waitUntilExit` on main.

## Security

The socket can run any command as the user through `pane.send`, so it's stricter than the nav socket.

- Socket file `0600`. The directory is created `0700` if missing.
- Every accepted connection checks `getpeereid` and drops a peer whose uid isn't ours.
- On by default. No config key in v1.

## Discovery

- Every pane and drawer shell gets `$ZEN_CONTROL_SOCK` next to `$ZEN_SOCK` and `$ZEN_PANE`. Tool floats launch with no environment, so a `zen` inside one falls back to the search below.
- Without the env var, `zen` probes `~/Library/Application Support/ZenTerm/control.*.sock` with a connect, the same liveness test the nav sweep uses. One live socket: use it. None: exit 3 with "ZenTerm isn't running". More than one (a dev build next to the installed app): exit 3 and list them, and `--socket <path>` picks one.
- `zen` never launches the app in v1.

## Addressing

Window, tab and workspace ids are minted per window, so they aren't unique on their own. Pane tokens are unique app-wide and never reused.

| Thing | Address | Notes |
|---|---|---|
| Pane | the `$ZEN_PANE` token, e.g. `31` | Drawers have tokens too. Floats don't. |
| Tab | `w<window>.t<tab>`, e.g. `w1.t14` | Returned by `list` and by every create. |
| Workspace | its folder path, or its title | Folder identity already spans windows. A title matching more than one workspace is `ambiguous`. |
| SSH host workspace | `ssh:<host>` | One session per host across the app (ZEN-503), so the host is the key. The prefix can't collide with a title or path. |
| Window | `w<window>` | Rarely needed. |

With no target, a command applies to the caller: `caller.pane`, its tab, its workspace. With no caller (run from another terminal), it applies to the key window's active workspace, tab and focused pane.

## Focus

A command never moves what the user is looking at unless it's asked to. `--focus` (`"focus": true`) opts in and goes through `activate(_:)` and `reveal(_:)` like a click. Without it:

- A new tab is added to its workspace without becoming the active tab and without mounting.
- A new workspace is appended to the sidebar without being activated.
- No command closes a modal, a confirm, a float or scroll mode.

`TabList.add` always activates today, so TabKit needs an insert that doesn't. A surface started before it's mounted runs on libghostty's 49x17 default grid (spiked: vim survived it and resized on mount), and `pushSize` can't correct it without a window. So a background surface starts at the size of the canvas it will mount into, or its program lays out at 49 columns and `pane.read` returns 49-column rows.

## Destructive commands

The app confirms before ending running processes or losing work. The CLI refuses instead and returns what's at stake, and `--force` proceeds.

- `pane.close`, `tab.close` and `workspace.close` refuse when a process is running, using the same `isRunning` reading the close confirms use. `details` lists the busy panes with title and cwd.
- Closing the last workspace closes the window, which the app always confirms. The CLI refuses it without `--force` regardless of running state.
- `worktree.remove` refuses on uncommitted files, untracked files or lost commits, read through `WorktreeStore.state(at:countingLostCommits:)`, and always refuses a locked worktree. Removal goes through `WorktreeRemovalTracker` so open windows close its tabs and show "Removing …" the way they do today.

## Commands

| Command | Args | Result |
|---|---|---|
| `hello` | | app version, protocol version |
| `list` | | windows → workspaces → tabs → panes, see below |
| `workspace.open` | `path` or `title`, `focus` | workspace. An open one is returned, not duplicated. A configured entry opens with its recipe. |
| `workspace.new` | `path?`, `focus` | workspace. Unconfigured, named the way ⌘⌃T names one. |
| `workspace.switch` | workspace | |
| `workspace.close` | workspace, `force` | |
| `tab.new` | `workspace?`, `cwd?`, `cmd?`, `focus` | tab id, pane token |
| `tab.select` | tab | |
| `tab.rename` | tab, `title` (empty clears) | |
| `tab.close` | tab, `force` | |
| `pane.split` | `pane?`, `dir` (`right` or `down`), `cmd?`, `focus` | pane token |
| `pane.focus` | `pane` | reveals its tab |
| `pane.close` | `pane`, `force` | |
| `pane.send` | `pane?`, `text`, `enter` | through `paste`, so multi-line text arrives as one block. `enter` sends `"\r"` as a second paste. |
| `pane.read` | `pane?`, `lines?` | the viewport by default. `lines` returns the last N lines including scrollback. Trailing blanks trimmed. |
| `worktree.list` | `workspace?` | worktrees of the workspace's repo |
| `worktree.create` | `workspace?`, `branch`, `base` (`default` or `current`), `existing`, `focus` | worktree path, carry report, opened workspace |
| `worktree.remove` | worktree path or branch, `force` | |
| `action` | `name` | runs a keymap action by its config name (`split_vertical`, `toggle_sidebar`) through `handle(_:)` against the key window. Same modal gate as a chord. |

`list` reports, per pane: token, title, cwd, busy, agent name and state (`working`, `waiting`, `idle`) when the roster has one. Per tab: id, title, active. Per workspace: title, folder, configured, worktree origin, active. Per window: id, key.

The CLI maps them as `zen <noun> <verb>`: `zen tab new --cmd "npm run dev"`, `zen worktree create feat/x --focus`, `zen pane send "make test" --enter`. `zen list` prints JSON. `--pretty` prints an indented tree.

Exit codes: 0 ok, 1 the app answered with an error, 2 usage, 3 no instance or the connection failed.

## Implementation notes

- **One path per operation.** `addTab(cwd:)` and friends split into a headless verb (create, insert, start) and the chrome's wrapper (close the modal, mount, slide). The chord and the socket both call the verb. No second copy of the logic for the CLI.
- **Worktree create leaves the card.** The off-main pipeline in `createWorktree(_:from:)` (create, mirror, carry, open) moves into one place that takes a progress callback. The card passes `setPhase`. The socket passes nothing and answers at the end. A request's `workspace` resolves to a workspaces-file entry the same way `presentNewWorktree(forEntryAt:)` reads it fresh. A workspace with no config entry is `refused`, since worktrees hang off configured workspaces.
- **Split with a command** needs `PaneCanvasController.split` to take an optional command and launch the new leaf with `ShellLaunch.program`. Below `TerminalSurface`: no protocol change.
- **Reading scrollback** grows `TerminalSurface` by one read of the last N lines. The backend already reads the whole screen, history included, for VoiceOver (`GhosttyHostViewAccessibility.readScreenText`). Spiked at about 4 ms on main for a full history at the default limit (about 7.5k rows at 97 columns), so it reads the whole screen and trims.
- **Pane lookup** extends `NavRegistry` (it already maps token to route) or sits beside it. Resolving a token to its window, tab and surface is needed by most commands.
- **Packaging.** `bin/package-app` builds `zen` into `Contents/MacOS/zen` and signs it before the outer app. `bin/release`'s `codesign --verify --strict --deep` covers it. Installing is `ln -s /Applications/ZenTerm.app/Contents/MacOS/zen /usr/local/bin/zen` for v1. A Settings button that does it is out of scope.

## Docs

- `docs/control-protocol.md`: the wire contract, like the nav protocol doc. Written with the first ticket and grown by each one after.
- `docs/architecture.md`: the control socket next to the nav socket paragraph, and the headless verb rule under Windows, workspaces and tabs.
- `docs/CONTRIBUTING.md` only if the gate changes. User guide on the website.

## Tickets

Linear project **CLI control**.

1. ZEN-596 Control socket, `ControlProtocol`, `zen` skeleton, `hello` and `list`
2. ZEN-597 Workspace and tab commands, background creation
3. ZEN-598 Pane commands, split with a command
4. ZEN-599 Worktree commands, create pipeline out of the card
5. ZEN-600 Ship `zen` in the app bundle, and the `action` escape hatch

Each ticket adds its commands to `docs/control-protocol.md`. ZEN-597 and ZEN-600 depend on ZEN-596. ZEN-598 and ZEN-599 depend on ZEN-597 and can run in parallel.

## SSH hosts

Host workspaces don't exist yet (Workspaces S1). Whichever of this epic and ZEN-503 lands second wires these.

- `ssh:<host>` addresses a host workspace in every command that takes a workspace. Until hosts exist, an `ssh:` address is `not_found`.
- `workspace.open ssh:<host>` opens the host at its Connect screen and never connects. Login can prompt for a host key or password in the pane, so a person presses ↵.
- `zen` doesn't work from a shell on the remote host in v1. Host panes forward nothing, so it finds no socket and exits 3. Forwarding the socket hands control of the Mac to anyone with access to that host, which needs its own design.

## Non-goals

- Launching ZenTerm from `zen`.
- Writing the workspaces file (`workspace add`, editing entries). It waits for ZEN-498.
- Subscriptions or events (`zen wait --agent-idle`). Polling `list` covers v1.
- Driving floats, drawers' open state, Settings or themes, except through `action`.
- Session restore.
- `zen` on a remote host.
