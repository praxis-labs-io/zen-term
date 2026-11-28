#!/bin/bash
# Claude Code SessionStart hook installed by `zen setup claude`: in a live ZenTerm pane, say so, name a helper's parent, and point at the zen skill.

[ -n "$ZEN_CONTROL_SOCK" ] || exit 0
command -v zen >/dev/null 2>&1 || exit 0
zen --socket "$ZEN_CONTROL_SOCK" hello >/dev/null 2>&1 || exit 0

field() {
  printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null | tr -d '\n`'
}

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
You are helper $who, started by pane $parent. When done or stuck, report with \`zen pane send --pane $parent --enter \"<result>\"\`, then stop. Put a question about your task to pane $parent the same way, not AskUserQuestion, then end your turn: the answer arrives as your next message. A send that prints \`{\"queued\":true}\` arrives on its own once the user sends or clears their text, or, in Claude Code, stops typing for 60 seconds; don't send it again."
        ;;
    esac
    ;;
esac

cat <<EOF
This session runs in $where, the user's terminal. The \`zen\` CLI controls it.$helper

Your first action after the user's first prompt: load the /zen skill, then run \`zen list --pretty\` to see what is already running before you start anything.
EOF
exit 0
