#!/usr/bin/env bash
# lib/arcaterm.sh — the ArcaTerm backend for team.sh: open, close, focus and observe panes.
# Sourced by team.sh after its helpers (set -euo pipefail is already on). Functions only; no
# top-level side effects. team.sh picks the backend per call (_backend) and dispatches here.
#
# ArcaTerm (https://github.com/databricks-eng/arcaterm) is driven through its `arcaterm` CLI. A
# teammate's registry row starts with `arcaterm`, and its ref is the pane UUID. ArcaTerm never
# reuses a pane UUID (cmux reuses small surface:N refs), so a live pane id is always the teammate
# its row was recorded for: no title match is needed before closing it.
#
# Probed on ArcaTerm app 1.15.4 / CLI 1.16.1:
#   - `pane split --run` and `tab new --run` TYPE the command into the new pane's shell, so it lands in
#     shell history. spawn writes the full claude command to a launcher file and types only `bash <file>`.
#   - `pane split` takes keyboard focus and has no flag to stop it, so the caller's pane is focused
#     again right after. `tab new --child --no-focus` leaves focus alone.
#   - `pane close` refuses a pane with a running program unless --force. A pane that is already gone
#     fails with "did not resolve", the equivalent of cmux's not_found.
#   - `snapshot` lists every pane of every window with agent.status and agent.sessionId (the claude
#     session the pane runs), in one ~70 ms call. Statuses (ArcaTerm docs/agent-status.md): working,
#     needs-input (a question OR a tool-approval prompt), idle, unread (idle with unseen output),
#     checking, unavailable (status could not be observed), stopped (the agent session is absent:
#     claude exited and left a shell).
#   - A pane's title follows the terminal title (OSC 0), which the launcher sets before claude starts
#     (claude's own title updates are off for teammates). `tab rename` sets a tab's own title.
#   - `pane focus` works only on the Mac; from a remote host it fails, and callers say so.

_at_min=1.15.0

# Exit 3 unless the ArcaTerm app answers. `ws`: also require running inside an ArcaTerm pane.
_at_require() {
  command -v arcaterm >/dev/null 2>&1 || {
    echo "team.sh: '$sub' needs ArcaTerm >= $_at_min, but the arcaterm CLI is not on PATH. Open /team from an ArcaTerm pane (or a cmux pane)." >&2; exit 3; }
  _need_py
  local v
  v=$(arcaterm version --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(("up" if d.get("connected") else "down") + " " + ((d.get("app") or {}).get("version") or "?"))' 2>/dev/null) || v=
  [ "${v%% *}" = up ] || {
    echo "team.sh: '$sub' needs the ArcaTerm app, but 'arcaterm version --json' did not report it connected; start ArcaTerm (or check \$MACTERM_SOCKET)." >&2; exit 3; }
  awk -v a="${v#* }" -v b="$_at_min" 'BEGIN{split(a,x,"."); split(b,y,".")
    for (i=1;i<=3;i++) { if (x[i]+0 > y[i]+0) exit 0; if (x[i]+0 < y[i]+0) exit 1 } exit 0}' || {
    echo "team.sh: '$sub' needs the ArcaTerm app >= $_at_min, found '${v#* }'; update and restart ArcaTerm." >&2; exit 3; }
  [ "${1:-}" != ws ] || [ -n "${MACTERM_SESSION:-}" ] || {
    echo "team.sh: '$sub' must run inside an ArcaTerm pane (MACTERM_SESSION is unset)." >&2; exit 3; }
}

# One line per pane in every window, TAB-separated, no field empty ('-'):
#   <pane> <tab> <session> <surface> <agent status> <claude session id> <tab title>
# Fails with no output when the snapshot cannot be read, so callers can tell "gone" from "unknown".
_at_panes() {
  arcaterm snapshot 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
def clean(s):
    return " ".join(str(s or "").split()) or "-"
for w in d.get("windows") or []:
    for g in (w.get("groups") or []) + [w.get("ungrouped") or {}]:
        for t in g.get("tabs") or []:
            for p in t.get("panes") or []:
                a = p.get("agent") or {}
                print("\t".join([clean(p.get("id")), clean(t.get("id")), clean(p.get("session")),
                                 clean(p.get("surface")), clean(a.get("status")),
                                 clean(a.get("sessionId")), clean(t.get("title"))]))'
}

# The caller's "<pane> <tab>" (the pane running $MACTERM_SESSION), or nothing.
_at_self() {
  [ -n "${MACTERM_SESSION:-}" ] || return 0
  _at_panes 2>/dev/null | awk -F'\t' -v s="$MACTERM_SESSION" '$3==s {print $1" "$2; exit}' || true
}

# The _at_panes line of pane $1 in panes output $2 (empty when it is not there).
_at_line() { awk -F'\t' -v x="$1" '$1==x {print; exit}' <<<"$2"; }

# Write <file>: set the pane title to <title>, then run <command> (bash syntax, already quoted).
_at_launcher() {
  local f=$1 title=$2 cmd=$3
  { printf '#!/usr/bin/env bash\n'
    printf '# Written by team.sh: ArcaTerm types `bash <this file>` into the pane, not the command itself.\n'
    printf "printf '\\\\033]0;%%s\\\\007' %q\n" "$title"
    printf '%s\n' "$cmd"
  } > "$f"
}

# Open a pane running `bash <launcher>` and print "<pane> <tab>" of the new pane.
#   _at_open split <anchor pane|-> <right|down> <launcher>   (- = split the caller's own pane)
#   _at_open tab - - <launcher>                               (a child tab of the caller's tab)
_at_open() {
  local how=$1 anchor=$2 dir=$3 run out
  run="bash $(printf %q "$4")"
  if [ "$how" = tab ]; then
    out=$(arcaterm tab new --child --no-focus --run "$run") || return 1
  else
    if [ "$anchor" = - ]; then out=$(arcaterm pane split --session "$MACTERM_SESSION" --direction "$dir" --run "$run") || return 1
    else out=$(arcaterm pane split --pane "$anchor" --direction "$dir" --run "$run") || return 1; fi
    # The split took focus: hand it back to the caller (Mac only; a remote host keeps the new focus).
    arcaterm pane focus --session "$MACTERM_SESSION" >/dev/null 2>&1 || true
  fi
  printf '%s' "$out" | python3 -c '
import json, sys
p = json.load(sys.stdin).get("pane") or {}
if not p.get("id"):
    sys.exit(1)
print(p["id"], p.get("tabId") or "-")'
}

# Close pane $1 and kill its session. 0 closed or already gone; 1 failed (reason on stdout).
_at_close() {
  local err
  err=$(arcaterm pane close --pane "$1" --force 2>&1 >/dev/null) && return 0
  case $err in *"did not resolve"*) return 0 ;; esac
  printf '%s\n' "$err" | head -1; return 1
}

# Rename tab $2 to $1.
_at_rename_tab() { arcaterm tab rename "$1" --tab "$2" >/dev/null; }

# Focus pane $1, selecting its tab and bringing its window to the front. Mac only.
_at_focus() { arcaterm pane focus --pane "$1" >/dev/null 2>&1; }
