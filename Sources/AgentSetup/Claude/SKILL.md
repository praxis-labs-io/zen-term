---
name: zen
description: Use ZenTerm's zen CLI to see and control the terminal you run in. List windows, workspaces, tabs and panes, read a pane's text, open panes, tabs and workspaces, type into a pane, and create or remove worktrees. Use when a session runs inside ZenTerm ($ZEN_CONTROL_SOCK is set), or when asked to control ZenTerm panes, tabs, workspaces or worktrees.
---

# zen (ZenTerm)

`zen` controls the running ZenTerm app. It ships inside the app and is on the
`PATH` in every pane.

For exact arguments, read the help. It comes from the installed `zen`, so it
matches the commands this version has:

```sh
zen --help
zen help <command> <verb>    # e.g. zen help worktree create
```

If `zen` fails with exit 3, ZenTerm isn't running or this shell outlived it.

## Where you are

- `$ZEN_PANE` is your pane's token. A command with no target acts on your pane,
  its tab and its workspace.
- `zen list --pretty` prints every window, workspace, tab, pane and drawer as a
  tree. `zen list` prints the same as JSON.
- Addresses: a pane is its token (`31`), a tab is `w1.t3`, a workspace is its
  folder (starting with `/`, `~` or `.`), `ssh:<host>`, or its title.

## Panes, tabs and workspaces

```sh
zen pane read --pane 31 --lines 100          # its last 100 lines
zen pane send --pane 31 --enter "npm test"   # paste it, then press Return
zen pane split --dir down --cmd "npm run dev" # prints the new pane's token
zen tab new --cmd "npm run dev"
zen workspace open ~/code/app
```

## Worktrees

```sh
zen worktree list
zen worktree create my-branch    # --open also opens it as a workspace
zen worktree remove my-branch
```

## Rules

- Nothing you open takes the screen unless you pass `--focus`. Pass it only
  when the user asked to see the thing.
- A close or remove refuses when it would stop running work or lose files, and
  prints what it would end. Pass `--force` only when the user asked for that.
- `zen pane send` pastes: control characters arrive as spaces. `--enter`
  presses Return once after it.
- Exit codes: 0 ok, 1 ZenTerm answered with an error, 2 usage, 3 no ZenTerm
  reachable.

## Preferences

- For worktree work, use `zen worktree` instead of `git worktree` or
  EnterWorktree, so the worktree gets the workspace's files and the user can
  open it from the workspace picker. Pass `--open` only when asked to open it.
- Run anything that doesn't exit on its own (a dev server, a watcher, an app
  launcher) in a tab of its own, never in your shell tool's background mode or
  with `&` or `nohup`. The user can watch a tab, and a background job keeps
  your session reading as working after your turn ends.

  ```sh
  zen tab new --cmd "npm run dev && exit"  # prints {"pane":34,"tab":"w1.t7"}
  zen pane read --pane 34 --lines 40       # its output, instead of restarting it
  ```

  End the command with `&& exit`: the tab closes when it ends cleanly and stays
  open on a failure, so the error is still there to read. When one fails, read
  it, report the error, then close the tab yourself. Leave a running one running
  when your turn ends unless asked to stop it.
- Close only what you opened.
