#!/usr/bin/env bash
# Drive an in-flight `bin/run` dev build of ZenTerm.
#
# THE SAFETY MODEL, in one line: the target is resolved by binary path, never by
# name. `bin/run` produces `.build/<triple>/debug/ZenTerm`; the installed app and
# ZenTerm Dev.app live in bundles under /Applications. This script only ever accepts
# a `.build/` path, so it structurally cannot drive the instance hosting a Claude
# Code session. Every input action re-confirms the frontmost pid immediately before
# sending, and refuses if it does not match.
#
# Both instances present to System Events as "ZenTerm". Targeting by name WILL
# eventually type into the wrong one. Do not add a by-name path to this script.
set -euo pipefail

die() { echo "✗ $*" >&2; exit 1; }
note() { echo "▸ $*"; }

# ---------------------------------------------------------------- blast radius
#
# This script's total power over the machine is "put one line in a shell and press
# Return". That line is therefore the entire security boundary, and it is worth more
# than the focus guard: the focus guard stops input reaching the WRONG window, this
# stops dangerous input reaching ANY window.
#
# TCC attributes Accessibility and Screen Recording to the responsible process,
# which for a shell in a pane is ZenTerm Dev.app itself. So these grants outlive
# this script and apply to anything running in any pane. Keep the boundary narrow.

[ "$(id -u)" -eq 0 ] && die "refusing to run as root"

# Text that must never be pasted into a shell, whatever the caller intended.
# Deliberately blunt: a runbook fixture never needs any of it, so a false positive
# costs a rephrase and a false negative costs the machine.
readonly FORBIDDEN=(
    'rm[[:space:]]+-[[:alnum:]]*[rf]'   # rm -rf / rm -f
    '\bsudo\b' '\bsu\b' '\bdoas\b'
    '\bdd\b' '\bmkfs' '\bdiskutil\b' '\bfdisk\b' '\bnewfs'
    '>[[:space:]]*/dev/(disk|rdisk)'    # redirection into a raw device
    '\bshutdown\b' '\breboot\b' '\bhalt\b'
    '\bkillall\b' 'kill[[:space:]]+-9[[:space:]]+-1'
    '\bchmod[[:space:]]+-R\b' '\bchown[[:space:]]+-R\b'
    '\bcsrutil\b' '\bspctl\b' '\btccutil\b' '\bnvram\b'
    '\blaunchctl[[:space:]]+(unload|bootout)\b'
    '\bdefaults[[:space:]]+delete\b'
    '\bgit[[:space:]]+(push|reset[[:space:]]+--hard|clean)\b'
    ':\(\)\{.*\|.*&.*\};:'             # fork bomb
    '\bcurl\b.*\|[[:space:]]*(sh|bash|zsh)'   # curl | sh
    '\bwget\b.*\|[[:space:]]*(sh|bash|zsh)'
)

validate_text() {
    local text="$1"
    # One line only. A newline is a second command the caller did not declare, and
    # is how an innocuous-looking string smuggles one in.
    case "$text" in
        *$'\n'*|*$'\r'*) die "refusing multi-line input — send one command per call" ;;
    esac
    [ ${#text} -gt 2000 ] && die "refusing input over 2000 chars"
    # Counted, not `grep -q`, for the same pipefail/SIGPIPE reason as `verify-symbol`. Here the
    # failure would be silent and the wrong way round: a denied pattern reading as allowed.
    local pat hits
    for pat in "${FORBIDDEN[@]}"; do
        hits=$(printf '%s' "$text" | grep -cE "$pat" || true)
        if [ "${hits:-0}" -gt 0 ]; then
            die "refusing dangerous input (matched /$pat/): $text"
        fi
    done
    # Fixtures belong in a scratch dir. A runbook that writes into the repo or the
    # home directory is doing something it should be doing from the tool shell.
    case "$text" in
        *"$HOME/Desktop"*|*"$HOME/Documents"*|*"$HOME/Library"*)
            die "refusing input touching a real home directory: $text" ;;
    esac
    return 0
}

# Never let a hung UI wedge the run. Every osascript call goes through this.
#
# The timeout is hand-rolled because `timeout(1)` is GNU coreutils and is NOT on a stock
# macOS. Shelling out to it made every call here fail with "command not found", which read
# as "the app would not respond" and silently drove nothing at all.
osa() {
    local out rc tmp waited=0 pid
    tmp=$(mktemp -t ztosa)
    osascript "$@" >"$tmp" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$tmp"
        die "osascript timed out after 10s (hung UI?)"
    fi
    # `|| rc=$?` rather than a bare `wait`: under `set -e` a non-zero wait aborts the script
    # before `rc` is ever read, so the die below never runs and the real osascript error is
    # swallowed. That turned a denied-permission error into a silent exit 1.
    rc=0
    wait "$pid" || rc=$?
    out=$(cat "$tmp")
    rm -f "$tmp"
    [ "$rc" -ne 0 ] && die "osascript failed: ${out:-<no output>}"
    printf '%s' "$out"
}

# A runaway loop that keeps synthesizing input is its own hazard. Cap the session.
ACTION_COUNT_FILE="${TMPDIR:-/tmp}/zt-drive-actions.$$"
readonly MAX_ACTIONS=200
count_action() {
    local n=0
    [ -f "$ACTION_COUNT_FILE" ] && n=$(cat "$ACTION_COUNT_FILE")
    n=$((n + 1)); echo "$n" > "$ACTION_COUNT_FILE"
    [ "$n" -gt "$MAX_ACTIONS" ] && die "action cap ($MAX_ACTIONS) reached — something is looping"
    return 0
}

# ---------------------------------------------------------------- target

# The pid of the running worktree build, or empty. Refuses to return a bundle app.
target_pid() {
    local pids
    pids=$(pgrep -f '\.build/.*/ZenTerm$' || true)
    [ -z "$pids" ] && return 1
    [ "$(echo "$pids" | wc -l)" -gt 1 ] && die "more than one .build ZenTerm running: $(echo "$pids" | tr '\n' ' ')"
    echo "$pids"
}

require_target() {
    local t
    t=$(target_pid) || die "no .build ZenTerm running — launch one with: $0 launch"
    # Belt and braces: prove the path really is a .build binary, never a bundle.
    local path
    path=$(ps -o comm= -p "$t")
    case "$path" in
        *.build/*/ZenTerm) : ;;
        *) die "refusing: pid $t is '$path', not a .build binary" ;;
    esac
    echo "$t"
}

# ---------------------------------------------------------------- focus guard

_focus() {
    osa -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $1) to true" >/dev/null
    sleep 0.8
}

_frontmost_pid() {
    osa -e 'tell application "System Events" to get unix id of first process whose frontmost is true'
}

# Focus the target and PROVE it is frontmost. Every input action calls this
# immediately before sending. A stale check is worthless: focus is racy, so the
# gap between proving and sending must stay as small as possible.
guard() {
    local t="$1" got
    _focus "$t"
    got=$(_frontmost_pid)
    [ "$got" = "$t" ] || die "refusing to send input: frontmost is pid $got, expected $t"
}

# ---------------------------------------------------------------- commands

cmd_preflight() {
    local ok=0
    # Probe UI-element access, not the process list. Reading `name of first process whose
    # frontmost is true` succeeds WITHOUT assistive access, so it reported "granted" while
    # every keystroke failed with error 1002. Touching a UI element needs the same permission
    # sending input does, and fails with -25211 when it is missing.
    if osascript -e 'tell application "System Events" to tell (first process whose frontmost is true) to count of windows' >/dev/null 2>&1; then
        note "Accessibility: granted (UI elements reachable)"
    else
        echo "✗ Accessibility: DENIED — keystrokes fail with error 1002, nothing is driven." >&2
        ok=1
    fi
    local tmp; tmp=$(mktemp -t ztshot).png
    if screencapture -x -o "$tmp" >/dev/null 2>&1 && [ -s "$tmp" ]; then
        note "Screen Recording: granted"
    else
        echo "✗ Screen Recording: DENIED — screenshots fail, so a failed step cannot be diagnosed." >&2
        ok=1
    fi
    rm -f "$tmp"

    if [ "$ok" -ne 0 ]; then
        cat >&2 <<'ASK'

  ── ACTION NEEDED FROM DREW ──────────────────────────────────────────────
  macOS will NOT prompt for these. TCC asks once per responsible process;
  after a decision (especially a revoke) it fails silently forever. Waiting
  for a dialog will wait forever. Grant by hand, tick the entry for the
  terminal hosting this session, then re-run preflight:

    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

  A toggle may need to be switched off and on again to take effect, and the
  host app usually has to be restarted before the new grant applies.
  ─────────────────────────────────────────────────────────────────────────
ASK
    fi
    if t=$(target_pid 2>/dev/null); then note "target: pid $t ($(ps -o comm= -p "$t"))"; else note "target: none running"; fi
    note "other ZenTerm instances (never targeted):"
    ps -Ao pid,comm | grep -E "MacOS/ZenTerm" | grep -v grep | sed 's/^/    /' || echo "    none"
    return $ok
}

cmd_launch() {
    target_pid >/dev/null 2>&1 && die "a .build ZenTerm is already running (pid $(target_pid))"
    [ -x bin/run ] || die "run this from the worktree root (no bin/run here)"
    note "launching bin/run in the background"
    nohup bin/run >/tmp/zt-drive-run.log 2>&1 &
    local i t
    for i in $(seq 1 60); do
        if t=$(target_pid 2>/dev/null); then note "up: pid $t"; sleep 2; return 0; fi
        sleep 2
    done
    die "did not come up in 120s — see /tmp/zt-drive-run.log"
}

# Prove the RUNNING binary contains a symbol your change introduced. Without this
# you can run a whole runbook against a stale build and learn nothing.
cmd_verify_symbol() {
    local sym="${1:?usage: verify-symbol <symbol>}" t path
    t=$(require_target); path=$(ps -o comm= -p "$t")
    note "binary: $path"
    note "built:  $(stat -f '%Sm' "$path")"
    # No `grep -q` on a pipe under `set -o pipefail`: grep exits at the first match, the
    # producer takes SIGPIPE, and the pipeline reports failure even though the symbol matched.
    # That made this check incapable of ever succeeding, which is worse than not having it:
    # it reports "stale build" against a binary compiled seconds ago. Count instead, so the
    # reader consumes the whole stream.
    local hits
    hits=$(nm -a "$path" 2>/dev/null | grep -ci -- "$sym" || true)
    [ "${hits:-0}" -eq 0 ] && hits=$(strings "$path" 2>/dev/null | grep -ci -- "$sym" || true)
    if [ "${hits:-0}" -gt 0 ]; then
        note "symbol '$sym' PRESENT ($hits hits) — this build has the change"
    else
        die "symbol '$sym' MISSING — the running build predates your change"
    fi
}

# Send a command line to the focused pane.
#
# Clipboard paste, never per-character `keystroke`: System Events drops characters
# on long strings (observed turning `python3` into `nepython3`). The clipboard is
# saved and restored so this does not clobber the user's.
cmd_run() {
    local text="${1:?usage: run <command>}" t saved
    validate_text "$text"
    count_action
    t=$(require_target)
    saved=$(pbpaste 2>/dev/null || true)
    printf '%s' "$text" | pbcopy
    guard "$t"
    osa -e 'tell application "System Events" to keystroke "v" using {command down}' >/dev/null
    sleep 0.4
    osa -e 'tell application "System Events" to key code 36' >/dev/null
    sleep 0.3
    printf '%s' "$saved" | pbcopy
    note "sent: $text"
}

# chord <key> [comma-separated mods]   e.g. chord w command   |   chord '\' command,shift
cmd_chord() {
    local key="${1:?usage: chord <key> [mods]}" mods="${2:-command}" t applemods=""
    # A chord is a single key plus modifiers. Anything longer is text trying to
    # arrive through the path that skips validate_text.
    [ ${#key} -eq 1 ] || die "chord takes a single key, got: $key"
    case "$mods" in
        *[!a-z,]*) die "modifiers must be comma-separated words (command,shift,option,control)" ;;
    esac
    count_action
    t=$(require_target)
    IFS=',' read -ra parts <<< "$mods"
    for m in "${parts[@]}"; do
        case "$m" in
            command|shift|option|control) applemods+="${applemods:+, }$m down" ;;
            *) die "unknown modifier: $m" ;;
        esac
    done
    guard "$t"
    osa -e "tell application \"System Events\" to keystroke \"$key\" using {$applemods}" >/dev/null
    note "chord: $mods+$key"
}

cmd_shot() {
    local out="${1:-/tmp/zt-drive-shot.png}" t
    t=$(require_target)
    _focus "$t"
    screencapture -x -o "$out" || die "screencapture failed (Screen Recording permission?)"
    note "$out"
}

# Poll for a condition. NEVER sleep-then-look-once: that is both a flake on a loaded
# machine and a tax on every passing run.
cmd_waitgone() {
    local pid="${1:?usage: waitgone <pid> [timeout]}" timeout="${2:-30}" start
    start=$(date +%s)
    while [ $(( $(date +%s) - start )) -lt "$timeout" ]; do
        kill -0 "$pid" 2>/dev/null || { note "pid $pid gone after $(( $(date +%s) - start ))s"; return 0; }
        sleep 0.5
    done
    die "pid $pid still alive after ${timeout}s"
}

cmd_port() {
    local p="${1:?usage: port <number>}"
    if lsof -i ":$p" -sTCP:LISTEN >/dev/null 2>&1; then echo LISTENING; else echo free; fi
}

cmd_quit() {
    local t; t=$(require_target)
    count_action
    guard "$t"
    osa -e 'tell application "System Events" to keystroke "q" using {command down}' >/dev/null
    note "sent ⌘Q to pid $t"
}

# Always run this at the end. Anything spawned for a runbook is the runbook's to
# clean up, and a leaked fixture is the user's machine, not a tidiness problem.
cmd_sweep() {
    note "worktree ZenTerm:  $(pgrep -f '\.build/.*/ZenTerm$' | tr '\n' ' ' || echo none)"
    note "high-CPU orphans:  $(ps -Ao pid,ppid,%cpu,comm | awk '$2==1 && $3>50 {print $1}' | tr '\n' ' ' || echo none)"
    note "check your own fixtures by name, e.g.: pgrep -fl slowserver.py"
}

case "${1:-}" in
    preflight)      shift; cmd_preflight "$@" ;;
    launch)         shift; cmd_launch "$@" ;;
    verify-symbol)  shift; cmd_verify_symbol "$@" ;;
    run)            shift; cmd_run "$@" ;;
    chord)          shift; cmd_chord "$@" ;;
    shot)           shift; cmd_shot "$@" ;;
    waitgone)       shift; cmd_waitgone "$@" ;;
    port)           shift; cmd_port "$@" ;;
    quit)           shift; cmd_quit "$@" ;;
    sweep)          shift; cmd_sweep "$@" ;;
    target)         require_target ;;
    *) cat >&2 <<EOF
usage: zt-drive.sh <command>

  preflight              check TCC permissions and list instances
  launch                 start bin/run in the background, wait for it
  verify-symbol <sym>    prove the RUNNING binary contains your change
  target                 print the target pid (refuses bundle apps)

  run <command>          paste a command line into the focused pane
  chord <key> [mods]     e.g. chord w command | chord '\\' command,shift
  quit                   send ⌘Q

  shot [path]            screenshot to inspect state
  waitgone <pid> [secs]  poll until a pid exits
  port <number>          LISTENING | free
  sweep                  report anything left running
EOF
       exit 2 ;;
esac
