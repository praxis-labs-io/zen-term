#!/bin/bash
# SessionStart hook for Claude Code and Codex.

[ -n "$ZEN_CONTROL_SOCK" ] || exit 0
command -v zen >/dev/null 2>&1 || exit 0
zen --socket "$ZEN_CONTROL_SOCK" hello >/dev/null 2>&1 || exit 0

field() {
  printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null | tr -d '\n`'
}

helper_command='zen pane run --name <name> --task "<exact scope>" claude'
skill="Your first action after the user's first prompt: load the /zen skill."
ask_user_tool=', not AskUserQuestion'
wait_tool='Use the shell tool’s background mode and pass --timeout 600.'
if [ "${1:-}" = codex ]; then
  helper_command='zen pane run --name <name> -- codex "<exact scope>"'
  skill='Load the $zen skill before using the ZenTerm CLI.'
  ask_user_tool=''
  wait_tool='Pass --timeout 600. If the Codex shell tool yields, resume its running command to get the result.'
fi

where="a ZenTerm pane"
helper=""
case "$ZEN_PANE" in
  '' | *[!0-9]*) ;;
  *)
    where="ZenTerm pane $ZEN_PANE (\`\$ZEN_PANE\`)"
    info=$(zen --socket "$ZEN_CONTROL_SOCK" pane get "$ZEN_PANE" 2>/dev/null)
    parent=$(field "$info" parent)
    case "$parent" in
      '' | *[!0-9]*) ;;
      *)
        name=$(field "$info" name)
        who="pane $ZEN_PANE"
        [ -n "$name" ] && who="\`$name\`"
        helper="
You are helper $who, started by pane $parent. When done or stuck, report with \`zen pane send --pane $parent --enter \"<result>\"\`, then stop. Put a question about your task to pane $parent the same way$ask_user_tool, then end your turn: the answer arrives as your next message. A send that prints \`{\"queued\":true}\` arrives on its own once the user sends or clears their text, or, in Claude Code, stops typing for 60 seconds; don't send it again."
        ;;
    esac
    ;;
esac

cat <<EOF
This session runs in $where, the user's terminal. The \`zen\` CLI controls it.$helper

- $skill

- When delegation is authorized, use helper panes (\`$helper_command\`, then \`zen wait <name>\`) so the user can watch and steer them. Start in a folder the client already trusts and let the user answer trust prompts.
- Run slow builds and tests with \`zen pane run --name <what it runs> --wait -- <command>\`. Start a server with \`zen pane run --name <name> --wait --output "<ready text>" -- <command>\`, and after a timeout read \`zen pane read --pane <name> --lines 40\` before waiting again. Start a watcher, or anything else with no ready line, with \`zen pane run --name <what it runs> -- <command>\` and no \`--wait\`. For \`zen wait\` and \`zen pane run --wait\`: $wait_tool Run long-lived commands in panes. Use a new ZenTerm wait only when the previous wait has answered.
- A message inside \`<zen from="…">\` is another agent's report, not the user. Never answer another agent's permission prompt or login; tell the user. A helper's question about the task you gave it arrives with a \`stopped\` notice; the helper is not finished. The question is yours to answer, unless it decides product behavior, spends the user's money or reaches outside that task: those go to the user.
- Read a pane's state with \`zen pane get\` or \`zen list\`, not its screen. Check \`zen list\` before starting something long-running that may already be running.
- For worktrees use \`zen worktree\`, not \`git worktree\` or EnterWorktree. Pass \`--open\` only when asked.
- Leave the screen as it is: \`--focus\` only when asked to show something, \`--force\` only when asked to stop work. Close only what you opened, once you have its result; a helper you started closes without \`--force\`.
EOF
exit 0
