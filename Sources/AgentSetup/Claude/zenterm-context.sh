#!/bin/bash
# Claude Code SessionStart hook installed by `zen setup claude`: in a live ZenTerm pane, say so and point at the zen skill.

[ -n "$ZEN_CONTROL_SOCK" ] || exit 0
command -v zen >/dev/null 2>&1 || exit 0
zen --socket "$ZEN_CONTROL_SOCK" hello >/dev/null 2>&1 || exit 0

pane=""
if [ -n "$ZEN_PANE" ]; then
  pane=" Your pane token is \`$ZEN_PANE\` (\`\$ZEN_PANE\`), and a \`zen\` command with no target acts on this pane, its tab and its workspace."
fi

cat <<EOF
This session runs in a ZenTerm pane, the user's terminal. The \`zen\` CLI controls it.$pane

Before your first \`zen\` command this session, load the /zen skill. Preferences:
- For worktree work, use \`zen worktree\` instead of \`git worktree\` or EnterWorktree, so the worktree opens as a workspace the user can see.
- Leave the user's screen as it is: pass \`--focus\` only when asked to show something, and \`--force\` only when asked to stop running work.
EOF
