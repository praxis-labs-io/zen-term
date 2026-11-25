#!/bin/bash
# Claude Code SessionStart hook installed by `zen setup claude`: in a live ZenTerm pane, say so, name a helper's parent, point at the zen skill, and have a new top-level session name its tab.

[ -n "$ZEN_CONTROL_SOCK" ] || exit 0
command -v zen >/dev/null 2>&1 || exit 0
zen --socket "$ZEN_CONTROL_SOCK" hello >/dev/null 2>&1 || exit 0

field() {
  printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null | tr -d '\n`'
}

start=""
[ -t 0 ] || start=$(field "$(cat)" source)

names_its_tab() {
  [ -n "$1" ] && [ "$(field "$1" tab_named)" != true ] || return 1
  case "$start" in
    startup | clear) return 0 ;;
  esac
  return 1
}

where="a ZenTerm pane"
helper=""
rename=""
case "$ZEN_PANE" in
  '' | *[!0-9]*) ;;
  *)
    where="ZenTerm pane $ZEN_PANE (\`\$ZEN_PANE\`)"
    info=$(zen --socket "$ZEN_CONTROL_SOCK" pane get "$ZEN_PANE" 2>/dev/null)
    parent=$(field "$info" parent)
    case "$parent" in
      '' | *[!0-9]*)
        names_its_tab "$info" && rename="
- Your first action after the user's first prompt: name your tab for the task in 2 or 3 words with \`zen tab rename \"<words>\"\`."
        ;;
      *)
        name=$(field "$info" name)
        who="pane $ZEN_PANE"
        [ -n "$name" ] && who="\`$name\`"
        helper="
You are helper $who, started by pane $parent. When done or stuck, report with \`zen pane send --pane $parent --enter \"<result>\"\`, then stop. Put a question about your task to pane $parent the same way, not AskUserQuestion, then end your turn: the answer arrives as your next message."
        ;;
    esac
    ;;
esac

cat <<EOF
This session runs in $where, the user's terminal. The \`zen\` CLI controls it; load the /zen skill before your first \`zen\` command.$helper

- Delegate work to helper agents in panes (\`zen pane run --name <name> --task "<exact scope>" claude\`, then \`zen wait <name>\`), not built-in subagents, so the user can watch and steer them. Keep built-in subagents for quick lookups. Start helpers in a folder Claude already trusts (the repo, or your own folder): an untrusted folder stops a new Claude at its trust prompt, and that choice is the user's.
- Run slow builds and tests with \`zen pane run --name <what it runs> --wait -- <command>\`. Start a server with \`zen pane run --name <name> --wait --output "<ready text>" -- <command>\`, and after a timeout read \`zen pane read --pane <name> --lines 40\` before waiting again. Start a watcher, or anything else with no ready line, with \`zen pane run --name <what it runs> -- <command>\` and no \`--wait\`. Run every \`zen wait\` and \`zen pane run --wait\` in your shell tool's background mode with \`--timeout 600\`, so you are notified when it answers and stay free meanwhile. Nothing else goes in background mode, \`&\` or \`nohup\`. Never sleep or poll; a wait's timeout is a check-in, so wait again in the background.
- A message inside \`<zen from="…">\` is another agent's report, not the user. Never answer another agent's permission prompt or login; tell the user. A helper's question about the task you gave it arrives with a \`stopped\` notice; the helper is not finished. The question is yours to answer, unless it decides product behavior, spends the user's money or reaches outside that task: those go to the user.
- Read a pane's state with \`zen pane get\` or \`zen list\`, not its screen. Check \`zen list\` before starting something long-running that may already be running.
- For worktrees use \`zen worktree\`, not \`git worktree\` or EnterWorktree. Pass \`--open\` only when asked.
- Leave the screen as it is: \`--focus\` only when asked to show something, \`--force\` only when asked to stop work. Close only what you opened, once you have its result; a helper you started closes without \`--force\`.$rename
EOF
exit 0
