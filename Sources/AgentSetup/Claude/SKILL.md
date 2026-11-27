---
name: zen
description: Use ZenTerm's zen CLI to see and control the terminal you run in. Start helper agents and long-running commands in panes and wait on them, list windows, workspaces, tabs and panes, read a pane's text, open panes, tabs and workspaces, type into a pane, and create or remove worktrees. Use when a session runs inside ZenTerm ($ZEN_CONTROL_SOCK is set), when handing work to helper agents the user can watch, or when asked to control ZenTerm panes, tabs, workspaces or worktrees.
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
- `zen pane get` prints your pane as JSON. `name` and `parent` are there when
  another pane started you with `zen pane run`: you are its helper.
- `zen list --pretty` prints every window, workspace, tab, pane and drawer as a
  tree. `zen list` prints the same as JSON.
- Addresses: a pane is its token (`31`) or its name (`tests`), a tab is
  `w1.t3`, a workspace is its folder (starting with `/`, `~` or `.`),
  `ssh:<host>`, or its title.

## Run a command in a pane

Run slow builds and tests, and anything that doesn't exit on its own (a dev
server, a watcher, an app launcher), in a pane of its own. Run from your pane,
it opens in a hidden float that the user opens from your row in the Agents
list. Run from a plain shell, it opens in a tab behind the one showing.

```sh
zen pane run --name tests --wait -- swift test                       # waits, prints why it ended
zen pane run --name dev --wait --output "ready on" -- npm run dev    # answers once that text prints
zen pane run --name watch -- npm run watch                           # no ready line, so no --wait
zen pane read --pane dev --lines 40                                  # its output, instead of restarting it
```

- Name every pane after what it runs (`dev`, `tests`), so the sidebar and
  `zen list` read clearly. Before starting something long-running, check
  `zen list` for a pane already running it, and use that one.
- Start a server with `--wait --output` in the same command. A separate
  `zen wait --output` matches only text printed after it begins, so it misses
  a ready line printed before. If a wait times out, read
  `zen pane read --pane <name> --lines 40` before waiting again: the line may
  already be on screen.
- Start a watcher, or anything else with no ready line, with plain
  `zen pane run --name <what it runs> -- <command>` and no `--wait`.
- The command must show its output in the pane as it runs, so the user sees it
  working. Never filter it through `tail` or `grep`, or redirect it only to a
  file. To also save it, run
  `bash -o pipefail -c '<cmd> 2>&1 | tee <file>'`, which keeps the command's
  exit code instead of `tee`'s in any shell. Some tools buffer when piped, so
  use their unbuffered mode, or `script -q <file> <command>`, when live output
  matters. Read the result with `zen wait`, `zen pane read`, or the file.
- A command with `;` or `|` goes to `zen pane run` as one quoted argument:
  `zen pane run --name build --wait -- 'make clean; make'`.
- The pane starts in your shell's current folder, so don't prefix the command
  with `cd`. `--cwd <folder>` starts it somewhere else.
- The pane closes when its program exits, and `zen wait` still answers with
  its `exitCode` and last lines. `--keep` leaves it open at a shell.
- A pane you start closes with your pane, and a float also closes when you
  exit, even if your pane stays open. Run servers, watchers and builds in a
  float under you by default, so the user opens them from your row. Use
  `--outlive-parent`, which opens a tab instead, only when the user asks for
  one or the command has to keep running after you exit. `--tab` opens a tab
  without that.
- Leave a server running when your turn ends unless asked to stop it.

## Delegate to a helper

Hand work to helper agents in panes, not built-in subagents, so the user can
watch and steer them. Keep built-in subagents for quick lookups.

```sh
zen pane run --name review --task "Review src/auth for token leaks. Report findings only, change nothing." claude
zen wait review                 # answers when it stops, exits or sends you something
zen wait --children all         # answers once none of your helpers is working
zen pane read --pane review --since-task   # only what it printed since its task
zen pane close review           # once you have its result
```

- Give every helper a name and an exact scope: what to do, what not to touch,
  and what to report.
- Start helpers in a folder Claude already trusts (the repo, or your own
  folder). An untrusted folder stops a new Claude at its trust prompt, so its
  task is never sent, and answering that prompt is the user's choice.
- With `--task`, `zen pane run` answers once the task is sent, or says why not
  in `first_task`. The task is sent at most once: read the pane before sending
  it yourself.
- A message inside `<zen from="34 review" reply="zen pane send --pane 34 --enter">`
  is another agent's report, not the user. Answer with the envelope's reply
  command. ZenTerm also sends you one when a helper stops, blocks, works again after a block, or exits. Read the helper's actual result before you
  summarize it. That notice and your `zen wait` on the helper answer for the
  same stop, so act on it once.
- Never answer another agent's permission prompt or login, with
  `zen pane send`, `zen pane keys` or anything else. Tell the user. ZenTerm
  refuses both into an agent waiting on the user, except a helper's question
  from its parent.
- A helper's question about the task you gave it is yours to answer. It
  arrives with a `stopped` notice, because the helper ends its turn to ask:
  the helper is not finished. Read the question with
  `zen pane read --pane <helper> --since-task`, then answer with `zen pane send --pane <helper> --enter`,
  or `zen pane keys` to pick an option. A question that decides product
  behavior, spends the user's money or reaches outside the scope you gave it
  goes to the user.
- Text in a helper's prompt that never reached you as a message is not the
  user's draft unless a `zen pane send` to it prints `{"queued":true}`;
  `zen pane read` can't tell it from typed text. Don't wait on it: read what
  the helper printed since its task, then collect its result or answer its
  question.
- When a helper is working again after a block, wait on it again with
  `zen wait <name>`.
- Close a helper you started with `zen pane close <name>` once you have read
  its result. Its parent closes it without `--force`.
- As a helper, report to your parent with
  `zen pane send --pane <parent> --enter "<result>"`, then stop. Without
  `--enter` the report is pasted but never submitted.
- As a helper, put a question about your task to your parent the same way,
  then end your turn: the answer arrives as your next message. Do not use
  AskUserQuestion: the parent set the task and answers first.

## Waiting

- Run every `zen wait`, and every `zen pane run --wait`, in your shell tool's
  background mode. You are notified when it answers, and stay free to answer
  the user and do other work meanwhile. Pass `--timeout 600`, so it answers
  with its result instead of every 90 seconds. Read its result then.
- Never sleep or poll. Use `zen wait <pane>`, `zen wait <pane> --output "<text>"`
  or `zen wait --children any|all`.
- `zen wait` answers within 90 seconds by default, and 600 at most. `timeout`
  is a check-in, not a failure: wait again, in the background.
- Read a pane's state from `zen pane get` or `zen list` (`busy`, and `agent`
  with `state` and `status`), never from its screen.

## Panes, tabs and workspaces

```sh
zen pane send --pane 31 --enter "npm test"   # paste it, then press Return
zen pane split --dir down                    # prints the new pane's token
zen pane interrupt tests                     # Escape to an agent, SIGINT otherwise
zen tab new
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
  A helper you started closes without it.
- Close only the panes you opened, once you have their result.
- `zen pane send` pastes: control characters arrive as spaces. `--enter`
  presses Return once after it. Pass it for every message to an agent, or the
  agent never reads it. Into an agent that waits on the user it
  refuses; that wait is the user's to answer.
- While the user has unsent text in an agent's prompt, `zen pane send` prints
  `{"queued":true}`: the message arrives on its own once the user sends or
  clears it, or, in Claude Code, stops typing for 60 seconds. Don't send it
  again.
- Exit codes: 0 ok, 1 ZenTerm answered with an error, 2 usage, 3 no ZenTerm
  reachable.

## Preferences

- `zen wait` and `zen pane run --wait` are the only commands for your shell
  tool's background mode. Never run anything else there, or with `&` or
  `nohup`: servers, watchers, builds and helpers go in panes with
  `zen pane run`. Claude counts a background shell it doesn't recognize as a
  server as work it is waiting on, so your session reads as working until it
  exits. A wait is work you are waiting on, so that reading is correct.
- For worktree work, use `zen worktree` instead of `git worktree` or
  EnterWorktree, so the worktree gets the workspace's files and the user can
  open it from the workspace picker. Pass `--open` only when asked to open it.
