#!/usr/bin/env bash
# tests/team-arcaterm.sh — the ArcaTerm backend (lib/arcaterm.sh and its team.sh / lib/status.sh call sites).
# A stateful `arcaterm` stub keeps a pane table in $AT_STATE, so a spawned pane shows up in the next
# snapshot and a closed one disappears, as in the real app. Nothing here reaches a real terminal: the
# stub is first on PATH, and a cmux stub logs any call so the cases can assert there was none.
# USAGE:
#   bash tests/team-arcaterm.sh
#   TEAM_SH=/path/to/team.sh bash tests/team-arcaterm.sh
set -euo pipefail

TEAM_SH="${TEAM_SH:-$(cd "$(dirname "$0")/.." && pwd)/team.sh}"
LIBDIR="$(cd "$(dirname "$TEAM_SH")" && pwd)/lib"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0; passes=0
pass() { echo "PASS  $1"; passes=$((passes+1)); }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }

unset TEAM_MEMBER TEAM_BACKEND CMUX_WORKSPACE_ID CMUX_SURFACE_ID

# ── PATH stubs — never open real panes, sessions, or terminals ──
mkdir -p "$W/bin"
AT_LOG="$W/arcaterm.log"; AT_STATE="$W/arcaterm.state"; CMUX_LOG="$W/cmux.log"; CLAUDE_LOG="$W/claude.log"
export AT_LOG AT_STATE CMUX_LOG CLAUDE_LOG

# arcaterm stub. $AT_STATE: one TAB-separated line per pane:
#   <pane> <tab> <session> <surface> <agent status|-> <claude session|-> <tab title>
# Env knobs: AT_CONNECTED=0 (app down), AT_APP_VERSION, AT_SNAPSHOT_FAIL=1, AT_FOCUS_FAIL=1 (remote
# host), AT_CLOSE_FAIL=1. Replies use the JSON shapes probed on ArcaTerm 1.15.4 / CLI 1.16.1.
cat > "$W/bin/arcaterm" <<'PY'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["AT_LOG"], "a") as f:
    f.write(" ".join(args) + "\n")
state = os.environ["AT_STATE"]
def load():
    with open(state) as f:
        return [l.rstrip("\n").split("\t") for l in f if l.strip()]
def save(rows):
    with open(state, "w") as f:
        f.write("".join("\t".join(r) + "\n" for r in rows))
def opt(name):
    return args[args.index(name) + 1] if name in args else None
def counter():
    p = state + ".n"
    n = (int(open(p).read()) if os.path.exists(p) else 0) + 1
    open(p, "w").write(str(n))
    return n
def die(msg):
    print("arcaterm: " + msg, file=sys.stderr); sys.exit(1)
cmd = args[:2]
if args[:1] == ["version"]:
    print(json.dumps({"app": {"version": os.environ.get("AT_APP_VERSION", "1.16.1")},
                      "cli": {"version": "1.16.1"}, "connected": os.environ.get("AT_CONNECTED", "1") == "1"}))
elif args[:1] == ["snapshot"]:
    if os.environ.get("AT_SNAPSHOT_FAIL") == "1":
        die("socket error")
    tabs = {}
    for p, t, s, surf, st, sid, title in load():
        tab = tabs.setdefault(t, {"id": t, "title": title, "panes": []})
        tab["panes"].append({"id": p, "session": s, "surface": surf, "state": "running", "focused": False,
                             "cwd": None, "process": None,
                             "agent": None if st == "-" else
                                 {"kind": "isaac-claude", "status": st, "sessionId": None if sid == "-" else sid}})
    print(json.dumps({"schemaVersion": 2, "cursor": "c", "environments": [], "launches": [], "agents": [],
                      "windows": [{"id": "w1", "title": "", "selected": True, "visible": True,
                                   "groups": [{"id": "g1", "title": "", "selected": True, "tabs": list(tabs.values())}],
                                   "ungrouped": {"id": "u1", "title": "", "selected": False, "tabs": []}}]}))
elif cmd == ["pane", "split"]:
    rows = load(); anchor = opt("--pane"); sess = opt("--session")
    src = next((r for r in rows if (anchor and r[0] == anchor) or (sess and r[2] == sess)), None)
    if not src:
        die("pane UUID did not resolve uniquely")
    n = counter(); pid = "aaaaaaaa-0000-4000-8000-%012d" % n
    rows.append([pid, src[1], "macterm-mate-%d" % n, "live", "checking", "-", src[6]]); save(rows)
    print(json.dumps({"pane": {"id": pid, "tabId": src[1], "session": "macterm-mate-%d" % n,
                               "focused": True, "state": "idle", "title": "zsh"}}))
elif cmd == ["tab", "new"]:
    rows = load(); n = counter()
    pid = "aaaaaaaa-0000-4000-8000-%012d" % n; tid = "bbbbbbbb-0000-4000-8000-%012d" % n
    rows.append([pid, tid, "macterm-mate-%d" % n, "live", "checking", "-", "zsh"]); save(rows)
    print(json.dumps({"pane": {"id": pid, "tabId": tid}, "tab": {"id": tid, "parentId": "lead-tab"}}))
elif cmd == ["tab", "rename"]:
    rows = load(); tid = opt("--tab")
    for r in rows:
        if r[1] == tid:
            r[6] = args[2]
    save(rows); print(json.dumps({"tab": {"id": tid, "title": args[2]}}))
elif cmd == ["pane", "focus"]:
    if os.environ.get("AT_FOCUS_FAIL") == "1":
        die("pane focus is available only on the Mac")
    print("{}")
elif cmd == ["pane", "close"]:
    rows = load(); pid = opt("--pane")
    if os.environ.get("AT_CLOSE_FAIL") == "1":
        die("boom")
    if not any(r[0] == pid for r in rows):
        die("pane UUID did not resolve uniquely")
    if "--force" not in args:
        die("that pane has a running program (closing kills its session)")
    save([r for r in rows if r[0] != pid]); print(json.dumps({"affectedTabs": []}))
else:
    print("stub: unhandled " + " ".join(args), file=sys.stderr); sys.exit(2)
PY
chmod +x "$W/bin/arcaterm"

cat > "$W/bin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
case "$1" in
  ping) echo PONG ;;
  --version) echo "cmux 0.65.0 (108) stub" ;;
  new-split|new-surface) printf 'ok surface:%d workspace:1\n' "$(wc -l < "$CMUX_LOG")" ;;
  *) true ;;
esac
SH
chmod +x "$W/bin/cmux"

cat > "$W/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDE_LOG"
SH
chmod +x "$W/bin/claude"
export PATH="$W/bin:$PATH"

mkdir -p "$W/home/.claude/team/roles"
cat > "$W/home/.claude/settings.json" <<'JSON'
{"modelPicker":{"options":[
  {"model":"system.ai.claude-opus-5-5","behavesAs":"opus"},
  {"model":"system.ai.claude-sonnet-4-6","behavesAs":"sonnet"},
  {"model":"system.ai.claude-haiku-4-5","behavesAs":"haiku"}
]}}
JSON
echo '{"projects":{}}' > "$W/home/.claude.json"
export HOME="$W/home" TEAM_ROLES_DIR="$W/home/.claude/team/roles" TEAM_MODELS_FILE="$W/home/.claude/settings.json"
export TEAM_REG_DIR="$W/regs"; mkdir -p "$TEAM_REG_DIR"
export MACTERM_SESSION=macterm-lead
SONNET=system.ai.claude-sonnet-4-6 HAIKU=system.ai.claude-haiku-4-5

_git() { git -c user.email=t@t -c user.name=T "$@"; }
_mkgit() { mkdir -p "$1"; _git -C "$1" init -q; _git -C "$1" commit -q --allow-empty -m init; }
# Fresh terminal: only the lead's pane, working, in tab lead-tab; logs emptied.
_at_reset() {
  printf 'lead-pane\tlead-tab\tmacterm-lead\tlive\tworking\t-\tlead\n' > "$AT_STATE"
  rm -f "$AT_STATE.n"; : > "$AT_LOG"; : > "$CMUX_LOG"; : > "$CLAUDE_LOG"
}
_at_status() { awk -F'\t' -v OFS='\t' -v p="$1" -v s="$2" '$1==p {$5=s} 1' "$AT_STATE" > "$AT_STATE.t" && mv "$AT_STATE.t" "$AT_STATE"; }
_at_drop() { awk -F'\t' -v p="$1" '$1!=p' "$AT_STATE" > "$AT_STATE.t" && mv "$AT_STATE.t" "$AT_STATE"; }
# A project with a run dir holding one prompt per role named in $@.
_mkproj() {
  local R=$1; shift; _mkgit "$R"
  mkdir -p "$R/run/prompts" "$R/run/reports" "$R/run/status"
  local r; for r in "$@"; do echo "do the $r work" > "$R/run/prompts/$r.md"; done
}
_spawn() { local R=$1; shift; (cd "$R" && bash "$TEAM_SH" spawn "$@" 2>&1); }
# The registry row of title $2 in team $1 ('' when there is none, so a broken build FAILs instead of aborting).
_row() { awk -v t="$2" '$4==t' "$TEAM_REG_DIR/team-$1.tabs" 2>/dev/null || true; }

# ═══ A1 — spawn: the two-column grid on pane UUIDs, focus handed back, nothing sent to cmux ═══
{
  _at_reset; R="$W/a1"; _mkproj "$R" sec perf tests
  for r in sec perf tests; do _spawn "$R" a1 "$r" "$R/run/prompts/$r.md" "$SONNET" >/dev/null || true; done
  p1=$(_row a1 a1-sec | awk '{print $2}'); p2=$(_row a1 a1-perf | awk '{print $2}')
  splits=$(grep '^pane split' "$AT_LOG" || true)
  [ "$(_row a1 a1-sec | awk '{print $1, $3}')" = "arcaterm pane" ] && [ -n "$p1" ] && [ -n "$p2" ] \
    && pass "A1: spawn records arcaterm pane rows with the pane UUID as ref" \
    || fail "A1: spawn records arcaterm pane rows with the pane UUID as ref" "$(cat "$TEAM_REG_DIR/team-a1.tabs" 2>/dev/null)"
  [[ $(sed -n 1p <<<"$splits") == "pane split --session macterm-lead --direction right --run bash "* ]] \
    && [[ $(sed -n 2p <<<"$splits") == "pane split --pane $p1 --direction right --run bash "* ]] \
    && [[ $(sed -n 3p <<<"$splits") == "pane split --pane $p1 --direction down --run bash "* ]] \
    && pass "A1: #1 right of the lead, #2 right of #1, #3 down from #1" \
    || fail "A1: #1 right of the lead, #2 right of #1, #3 down from #1" "$splits"
  [ "$(grep -c '^pane focus --session macterm-lead' "$AT_LOG")" = 3 ] \
    && pass "A1: each split hands focus back to the lead" \
    || fail "A1: each split hands focus back to the lead" "$(cat "$AT_LOG")"
  [ ! -s "$CMUX_LOG" ] && pass "A1: no cmux call in an ArcaTerm pane" || fail "A1: no cmux call in an ArcaTerm pane" "$(cat "$CMUX_LOG")"
}

# ═══ A2 — the launcher: short --run, the full claude command; running it starts claude; close removes it ═══
{
  _at_reset; R="$W/a2"; _mkproj "$R" sec
  _spawn "$R" a2 sec "$R/run/prompts/sec.md" "$SONNET" >/dev/null || true
  L="$TEAM_REG_DIR/team-a2-sec.launch.sh"
  sid=$(_row a2 a2-sec | awk '{print $10}')
  grep -q -- "--run bash $L\$" "$AT_LOG" \
    && pass "A2: ArcaTerm is told to type only 'bash <launcher>'" || fail "A2: ArcaTerm is told to type only 'bash <launcher>'" "$(cat "$AT_LOG")"
  grep -q "CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1" "$L" 2>/dev/null && grep -q "claude --session-id $sid --name a2-sec" "$L" \
    && pass "A2: launcher keeps claude's title updates off and starts the recorded session" \
    || fail "A2: launcher keeps claude's title updates off and starts the recorded session" "$(cat "$L" 2>/dev/null)"
  bash "$L" >/dev/null 2>&1 || true
  grep -q -- "--name a2-sec" "$CLAUDE_LOG" && grep -q "do the sec work" "$CLAUDE_LOG" \
    && pass "A2: running the launcher starts claude with the prompt" \
    || fail "A2: running the launcher starts claude with the prompt" "claude=$(cat "$CLAUDE_LOG")"
  (cd "$R" && bash "$TEAM_SH" close a2 >/dev/null 2>&1) || true
  [ ! -e "$L" ] && pass "A2: close removes the launcher" || fail "A2: close removes the launcher" "$L still there"
}

# ═══ A3 — --tabs: a child tab that keeps focus where it was, renamed to the teammate's title ═══
{
  _at_reset; R="$W/a3"; _mkproj "$R" docs
  out=$(_spawn "$R" --tabs a3 docs "$R/run/prompts/docs.md" "$SONNET") || true
  tid=$(awk -F'\t' '$3=="macterm-mate-1" {print $2}' "$AT_STATE")
  grep -q -- "^tab new --child --no-focus --run bash " "$AT_LOG" && grep -q "^tab rename a3-docs --tab $tid\$" "$AT_LOG" \
    && ! grep -q '^pane focus' "$AT_LOG" && [ "$(_row a3 a3-docs | awk '{print $1, $3}')" = "arcaterm tab" ] \
    && [[ $out == *"in a child tab of the lead's tab"* ]] \
    && pass "A3: --tabs opens a renamed child tab without moving focus" \
    || fail "A3: --tabs opens a renamed child tab without moving focus" "out=$out log=$(cat "$AT_LOG")"
}

# ═══ A4 — teammate rules: each terminal gets only its own fenced blocks, never the fences ═══
{
  _at_reset; R="$W/a4"; _mkproj "$R" ui
  _spawn "$R" a4 ui "$R/run/prompts/ui.md" "$SONNET" >/dev/null || true
  at=$(cat "$TEAM_REG_DIR/team-a4-ui.sysprompt.md" 2>/dev/null) || at=
  _at_reset; R="$W/a4c"; _mkproj "$R" ui
  (cd "$R" && CMUX_WORKSPACE_ID=ws-test CMUX_SURFACE_ID=surface:lead bash "$TEAM_SH" spawn a4c ui "$R/run/prompts/ui.md" "$SONNET" >/dev/null 2>&1) || true
  cm=$(cat "$TEAM_REG_DIR/team-a4c-ui.sysprompt.md" 2>/dev/null) || cm=
  [[ $at == *"No notify step in ArcaTerm"* ]] && [[ $at != *"cmux browser"* ]] && [[ $at != *"cmux notify"* ]] \
    && [[ $at == *"SendMessage to the lead your last act"* ]] \
    && pass "A4: an ArcaTerm teammate gets the ArcaTerm blocks and no cmux CLI" \
    || fail "A4: an ArcaTerm teammate gets the ArcaTerm blocks and no cmux CLI" "${at:0:200}"
  [[ $cm == *"cmux browser open"* ]] && [[ $cm == *"cmux notify --title"* ]] && [[ $cm != *"ArcaTerm"* ]] \
    && pass "A4: a cmux teammate keeps the cmux blocks and gets no ArcaTerm text" \
    || fail "A4: a cmux teammate keeps the cmux blocks and gets no ArcaTerm text" "${cm:0:200}"
  if grep -q -- '-only -->' <<<"$at$cm"; then fail "A4: fence lines never reach a teammate"; else pass "A4: fence lines never reach a teammate"; fi
}

# ═══ A5 — haiku allowlist: no `cmux notify` rule for an ArcaTerm teammate ═══
{
  _at_reset; R="$W/a5"; _mkproj "$R" sweep
  _spawn "$R" a5 sweep "$R/run/prompts/sweep.md" "$HAIKU" >/dev/null || true
  L="$TEAM_REG_DIR/team-a5-sweep.launch.sh"
  grep -q -- "--permission-mode dontAsk" "$L" && grep -q -- "--allowedTools" "$L" && ! grep -q "cmux" "$L" \
    && pass "A5: haiku tier keeps dontAsk + allowlist, minus the cmux notify rule" \
    || fail "A5: haiku tier keeps dontAsk + allowlist, minus the cmux notify rule" "$(grep allowedTools "$L" 2>/dev/null)"
}

# ═══ A6 — requirements: exit 3 before anything opens; a bad TEAM_BACKEND is refused ═══
{
  R="$W/a6"; _mkproj "$R" x
  _at_reset; out=$(cd "$R" && AT_CONNECTED=0 bash "$TEAM_SH" spawn a6 x "$R/run/prompts/x.md" "$SONNET" 2>&1) && rc=0 || rc=$?
  [ "$rc" = 3 ] && [[ $out == *"did not report it connected"* ]] && ! grep -q '^pane split' "$AT_LOG" \
    && pass "A6: app not connected → exit 3, no pane" || fail "A6: app not connected → exit 3, no pane" "rc=$rc $out"
  _at_reset; out=$(cd "$R" && AT_APP_VERSION=1.14.9 bash "$TEAM_SH" spawn a6 x "$R/run/prompts/x.md" "$SONNET" 2>&1) && rc=0 || rc=$?
  [ "$rc" = 3 ] && [[ $out == *">= 1.15.0"* ]] && pass "A6: app too old → exit 3" || fail "A6: app too old → exit 3" "rc=$rc $out"
  _at_reset; out=$(cd "$R" && MACTERM_SESSION= TEAM_BACKEND=arcaterm bash "$TEAM_SH" spawn a6 x "$R/run/prompts/x.md" "$SONNET" 2>&1) && rc=0 || rc=$?
  [ "$rc" = 3 ] && [[ $out == *"must run inside an ArcaTerm pane"* ]] \
    && pass "A6: TEAM_BACKEND=arcaterm outside a pane → exit 3" || fail "A6: TEAM_BACKEND=arcaterm outside a pane → exit 3" "rc=$rc $out"
  # A PATH with no arcaterm on it: only the tools team.sh needs, linked (the bash running this suite,
  # not /bin/bash, which is 3.2 on macOS).
  mkdir -p "$W/bin-noat"; cp "$W/bin/claude" "$W/bin-noat/"
  for t in bash python3 git; do ln -sf "$(command -v "$t")" "$W/bin-noat/$t"; done
  out=$(cd "$R" && PATH="$W/bin-noat:/usr/bin:/bin" bash "$TEAM_SH" spawn a6 x "$R/run/prompts/x.md" "$SONNET" 2>&1) && rc=0 || rc=$?
  [ "$rc" = 3 ] && [[ $out == *"arcaterm CLI is not on PATH"* ]] \
    && pass "A6: no arcaterm CLI → exit 3 with a hint" || fail "A6: no arcaterm CLI → exit 3 with a hint" "rc=$rc $out"
  out=$(cd "$R" && TEAM_BACKEND=tmux bash "$TEAM_SH" spawn a6 x "$R/run/prompts/x.md" "$SONNET" 2>&1) && rc=0 || rc=$?
  [ "$rc" = 2 ] && [[ $out == *"TEAM_BACKEND must be cmux or arcaterm"* ]] \
    && pass "A6: unknown TEAM_BACKEND → exit 2" || fail "A6: unknown TEAM_BACKEND → exit 2" "rc=$rc $out"
}

# ═══ A7 — backend choice: a cmux pane wins over an inherited MACTERM_SESSION; TEAM_BACKEND wins over both ═══
{
  _at_reset; R="$W/a7"; _mkproj "$R" x y
  (cd "$R" && CMUX_WORKSPACE_ID=ws-test CMUX_SURFACE_ID=surface:lead bash "$TEAM_SH" spawn a7 x "$R/run/prompts/x.md" "$SONNET" >/dev/null 2>&1) || true
  (cd "$R" && CMUX_WORKSPACE_ID=ws-test CMUX_SURFACE_ID=surface:lead TEAM_BACKEND=arcaterm bash "$TEAM_SH" spawn a7 y "$R/run/prompts/y.md" "$SONNET" >/dev/null 2>&1) || true
  [ "$(_row a7 a7-x | awk '{print $1}')" = cmux ] && [ "$(_row a7 a7-y | awk '{print $1}')" = arcaterm ] \
    && pass "A7: cmux env → cmux row; TEAM_BACKEND=arcaterm → arcaterm row" \
    || fail "A7: cmux env → cmux row; TEAM_BACKEND=arcaterm → arcaterm row" "$(cat "$TEAM_REG_DIR/team-a7.tabs" 2>/dev/null)"
}

# ═══ A8 — close: force-closes live panes, counts gone ones closed, keeps failures and cmux rows ═══
{
  _at_reset; R="$W/a8"; _mkproj "$R" a b c
  for r in a b c; do _spawn "$R" a8 "$r" "$R/run/prompts/$r.md" "$SONNET" >/dev/null || true; done
  pb=$(_row a8 a8-b | awk '{print $2}'); _at_drop "$pb"
  out=$(cd "$R" && bash "$TEAM_SH" close a8 2>&1) && rc=0 || rc=$?
  [ "$rc" = 0 ] && [ ! -f "$TEAM_REG_DIR/team-a8.tabs" ] && [ "$(grep -c '^pane close --pane .* --force$' "$AT_LOG")" = 2 ] \
    && [[ $out == *"closed arcaterm $pb (already gone)"* ]] && [ "$(wc -l < "$AT_STATE" | tr -d ' ')" = 1 ] \
    && pass "A8: close force-closes the live panes and drops the registry" \
    || fail "A8: close force-closes the live panes and drops the registry" "rc=$rc $out"
  _at_reset; R="$W/a8b"; _mkproj "$R" a
  _spawn "$R" a8b a "$R/run/prompts/a.md" "$SONNET" >/dev/null || true
  echo "cmux surface:7 pane a8b-old - - - $R live - $R" >> "$TEAM_REG_DIR/team-a8b.tabs"
  out=$(cd "$R" && AT_CLOSE_FAIL=1 bash "$TEAM_SH" close a8b 2>&1) && rc=0 || rc=$?
  [ "$rc" = 1 ] && [ "$(wc -l < "$TEAM_REG_DIR/team-a8b.tabs" | tr -d ' ')" = 2 ] \
    && [[ $out == *"could not close arcaterm"* ]] && [[ $out == *"kept cmux surface:7 (a8b-old)"* ]] && [ ! -s "$CMUX_LOG" ] \
    && pass "A8: a failed close and a cmux row are kept for a retry (exit 1), cmux untouched" \
    || fail "A8: a failed close and a cmux row are kept for a retry (exit 1), cmux untouched" "rc=$rc $out"
}

# ═══ A9 — finish: marks the row finished and closes the pane through ArcaTerm ═══
{
  _at_reset; R="$W/a9"; _mkproj "$R" sec
  _spawn "$R" a9 sec "$R/run/prompts/sec.md" "$SONNET" >/dev/null || true
  p=$(_row a9 a9-sec | awk '{print $2}')
  printf 'FINDINGS: none\nPARALLELISM: 2 subagents\n' > "$R/run/reports/sec.md"
  echo "- [x] a9-sec: scope" > "$R/run/tasks.md"
  out=$(cd "$R" && bash "$TEAM_SH" finish a9 sec 2>&1) && rc=0 || rc=$?
  [ "$rc" = 0 ] && [ "$(_row a9 a9-sec | awk '{print $9}')" = finished ] && grep -q "^pane close --pane $p --force$" "$AT_LOG" \
    && [[ $out == *"closed arcaterm $p"* ]] \
    && pass "A9: finish closes the ArcaTerm pane and keeps a finished row" || fail "A9: finish closes the ArcaTerm pane and keeps a finished row" "rc=$rc $out"
}

# ═══ A10 — list: working / dead (gone) / dead (claude exited) / unknown / finished / another terminal's row ═══
{
  _at_reset; R="$W/a10"; _mkproj "$R" w g x u f
  for r in w g x u f; do _spawn "$R" a10 "$r" "$R/run/prompts/$r.md" "$SONNET" >/dev/null || true; done
  ref() { _row a10 "a10-$1" | awk '{print $2}'; }
  pw=$(ref w); _at_status "$pw" working; _at_drop "$(ref g)"; _at_status "$(ref x)" stopped; _at_status "$(ref u)" unavailable
  awk -v OFS=' ' '$4=="a10-f" {$9="finished"} 1' "$TEAM_REG_DIR/team-a10.tabs" > "$W/t" 2>/dev/null && mv "$W/t" "$TEAM_REG_DIR/team-a10.tabs" || true
  echo "cmux surface:9 pane a10-c - - - $R live - $R" >> "$TEAM_REG_DIR/team-a10.tabs"
  out=$(cd "$R" && bash "$TEAM_SH" list a10 2>&1) || true
  [[ $out == *"a10-w  working ($pw)"* ]] && [[ $out == *"a10-g  dead  model"* ]] \
    && [[ $out == *"a10-x  dead (its claude session exited; the pane is still open)"* ]] \
    && [[ $out == *"a10-u  unknown (ArcaTerm cannot observe"* ]] && [[ $out == *"a10-f  finished"* ]] \
    && [[ $out == *"a10-c  unknown (cmux surface:9)"* ]] \
    && pass "A10: list reads every state from one snapshot" || fail "A10: list reads every state from one snapshot" "$out"
}

# ═══ A11 — show: focuses the pane; a remote host (no focus) exits 1; a gone pane exits 3 ═══
{
  _at_reset; R="$W/a11"; _mkproj "$R" sec
  _spawn "$R" a11 sec "$R/run/prompts/sec.md" "$SONNET" >/dev/null || true
  p=$(_row a11 a11-sec | awk '{print $2}'); : > "$AT_LOG"
  out=$(cd "$R" && bash "$TEAM_SH" show a11 sec 2>&1) && rc=0 || rc=$?
  [ "$rc" = 0 ] && grep -q "^pane focus --pane $p$" "$AT_LOG" && ! grep -qE '^(pane split|tab new)' "$AT_LOG" \
    && pass "A11: show focuses the teammate's pane (nothing moved or opened)" || fail "A11: show focuses the teammate's pane (nothing moved or opened)" "rc=$rc $out"
  out=$(cd "$R" && AT_FOCUS_FAIL=1 bash "$TEAM_SH" show a11 sec 2>&1) && rc=0 || rc=$?
  [ "$rc" = 1 ] && [[ $out == *"works only on the Mac"* ]] && pass "A11: focus refused (remote host) → exit 1" || fail "A11: focus refused (remote host) → exit 1" "rc=$rc $out"
  _at_drop "$p"; out=$(cd "$R" && bash "$TEAM_SH" show a11 sec 2>&1) && rc=0 || rc=$?
  [ "$rc" = 3 ] && [[ $out == *"is gone; respawn it"* ]] && pass "A11: gone pane → exit 3" || fail "A11: gone pane → exit 3" "rc=$rc $out"
}

# ═══ A12 — status records: ArcaTerm agent status → team state (lib/status.sh _st_records) ═══
# Columns: role title state milestone step age note pct elapsed.
recs() {  # <registry> <team> -> records, from a clean bash with both libraries sourced
  bash -c '
    _reg() { echo "$TEAM_REG_DIR/team-$1.tabs"; }; _root() { pwd; }; _need_py() { :; }
    . "$1/status.sh"; . "$1/arcaterm.sh"; _st_records "$2" "" "" "$3"' _ "$LIBDIR" "$1" "$2"
}
st() { awk -F'\t' -v t="$2" '$2==t {print $3 "|" $7}' <<<"$1"; }
{
  _at_reset; R="$W/a12"; _mkproj "$R" ask idle unread work stop gone fresh rep   # 8: the live cap
  for r in ask idle unread work stop gone fresh rep; do _spawn "$R" a12 "$r" "$R/run/prompts/$r.md" "$SONNET" >/dev/null || true; done
  ref() { _row a12 "a12-$1" | awk '{print $2}'; }
  _at_status "$(ref ask)" needs-input; _at_status "$(ref idle)" idle; _at_status "$(ref unread)" unread
  _at_status "$(ref work)" working; _at_status "$(ref stop)" stopped; _at_drop "$(ref gone)"
  _at_status "$(ref rep)" idle
  printf 'FINDINGS: x\nPARALLELISM: 1\n' > "$R/run/reports/rep.md"
  r=$(cd "$R" && recs "$TEAM_REG_DIR/team-a12.tabs" a12)
  got="$(st "$r" a12-ask) $(st "$r" a12-idle) $(st "$r" a12-unread) $(st "$r" a12-work) $(st "$r" a12-fresh)"
  [ "$got" = "WAITING|- IDLE|- IDLE|- WORKING|- WORKING|-" ] \
    && pass "A12: needs-input → WAITING, idle/unread → IDLE, working/checking → WORKING" \
    || fail "A12: needs-input → WAITING, idle/unread → IDLE, working/checking → WORKING" "$got"
  got="$(st "$r" a12-stop) $(st "$r" a12-gone) $(st "$r" a12-rep)"
  [ "$got" = "DEAD|claude exited; its pane is still open DEAD|- WORKING|report on disk" ] \
    && pass "A12: stopped/gone → DEAD (exited noted), idle with a report → WORKING" \
    || fail "A12: stopped/gone → DEAD (exited noted), idle with a report → WORKING" "$got"
  _at_status "$(ref work)" unavailable
  r=$(cd "$R" && recs "$TEAM_REG_DIR/team-a12.tabs" a12)
  [ "$(st "$r" a12-work)" = "UNKNOWN|-" ] && pass "A12: unavailable (ArcaTerm cannot observe the pane) → UNKNOWN" \
    || fail "A12: unavailable (ArcaTerm cannot observe the pane) → UNKNOWN" "$(st "$r" a12-work)"
  _at_status "$(ref work)" working
  r=$(cd "$R" && AT_SNAPSHOT_FAIL=1 recs "$TEAM_REG_DIR/team-a12.tabs" a12)
  [ "$(awk -F'\t' '$3!="UNKNOWN"' <<<"$r" | wc -l | tr -d ' ')" = 0 ] \
    && pass "A12: an unreadable snapshot makes every row UNKNOWN, never DEAD" || fail "A12: an unreadable snapshot makes every row UNKNOWN, never DEAD" "$r"
  awk -v OFS=' ' '$4=="a12-ask" {$5="'"$HAIKU"'"} 1' "$TEAM_REG_DIR/team-a12.tabs" > "$W/t" 2>/dev/null && mv "$W/t" "$TEAM_REG_DIR/team-a12.tabs" || true
  r=$(cd "$R" && recs "$TEAM_REG_DIR/team-a12.tabs" a12)
  [ "$(st "$r" a12-ask)" = "WORKING|-" ] && pass "A12: haiku tier never shows WAITING (it runs unattended)" || fail "A12: haiku tier never shows WAITING (it runs unattended)" "$(st "$r" a12-ask)"
}

# ═══ A13 — monitor: a split down from the lead via a launcher; a dash row; a second one is refused ═══
{
  _at_reset; R="$W/a13"; _mkproj "$R" sec
  _spawn "$R" a13 sec "$R/run/prompts/sec.md" "$SONNET" >/dev/null || true
  out=$(cd "$R" && bash "$TEAM_SH" monitor a13 2>&1) && rc=0 || rc=$?
  L="$TEAM_REG_DIR/team-a13-monitor.launch.sh"
  [ "$rc" = 0 ] && grep -q -- "^pane split --session macterm-lead --direction down --run bash $L\$" "$AT_LOG" \
    && grep -q "status --watch a13" "$L" && [ "$(_row a13 a13-monitor | awk '{print $1, $3}')" = "arcaterm dash" ] \
    && pass "A13: monitor opens below the lead and records a dash row" || fail "A13: monitor opens below the lead and records a dash row" "rc=$rc $out"
  out=$(cd "$R" && bash "$TEAM_SH" monitor a13 2>&1) && rc=0 || rc=$?
  [ "$rc" = 1 ] && [[ $out == *"already running"* ]] && pass "A13: a live monitor is not opened twice" || fail "A13: a live monitor is not opened twice" "rc=$rc $out"
}

# ═══ A14 — lead-title renames only the lead's tab; A16 — sync is a quiet no-op ═══
{
  _at_reset; R="$W/a14"; _mkproj "$R"
  out=$(cd "$R" && bash "$TEAM_SH" lead-title 2>&1) && rc=0 || rc=$?
  [ "$rc" = 0 ] && grep -q "^tab rename Main Board - a14 --tab lead-tab$" "$AT_LOG" && [ ! -s "$CMUX_LOG" ] \
    && pass "A14: lead-title renames the lead's tab, never its group" || fail "A14: lead-title renames the lead's tab, never its group" "rc=$rc $out $(cat "$AT_LOG")"
  _spawn "$R" a16 x "$(echo x > "$W/a16.md"; echo "$W/a16.md")" "$SONNET" >/dev/null || true
  : > "$AT_LOG"
  out=$(cd "$R" && bash "$TEAM_SH" sync a16 2>&1) && rc=0 || rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$CMUX_LOG" ] && ! grep -qvE '^(snapshot|version)' "$AT_LOG" \
    && pass "A16: sync changes nothing in ArcaTerm and prints nothing" || fail "A16: sync changes nothing in ArcaTerm and prints nothing" "rc=$rc out=$out at=$(cat "$AT_LOG")"
}

# ═══ A15 — reap: lists and closes an earlier team's live panes; leaves cmux rows and the lead alone ═══
{
  _at_reset; R="$W/a15"; _mkproj "$R" old
  _spawn "$R" a15old old "$R/run/prompts/old.md" "$SONNET" >/dev/null || true
  p=$(_row a15old a15old-old | awk '{print $2}')
  echo "cmux surface:4 pane a15old-other - - - $(cd -P "$R" && pwd) live - $R" >> "$TEAM_REG_DIR/team-a15old.tabs"
  echo "arcaterm lead-pane pane a15old-me - - - $(cd -P "$R" && pwd) live - $R" >> "$TEAM_REG_DIR/team-a15old.tabs"
  out=$(cd "$R" && bash "$TEAM_SH" reap --exclude a15new 2>&1) && rc=0 || rc=$?
  [[ $out == *"a15old  a15old-old  arcaterm $p  run -"* ]] && [[ $out == *"a15old-other  cmux surface:4  left alone"* ]] \
    && [[ $out != *"a15old-me"* ]] \
    && pass "A15: reap lists the live ArcaTerm pane, never the caller's own pane" || fail "A15: reap lists the live ArcaTerm pane, never the caller's own pane" "rc=$rc $out"
  out=$(cd "$R" && bash "$TEAM_SH" reap --yes --exclude a15new 2>&1) && rc=0 || rc=$?
  [ "$rc" = 0 ] && grep -q "^pane close --pane $p --force$" "$AT_LOG" && ! grep -q "lead-pane --force" "$AT_LOG" \
    && grep -q "a15old-other" "$TEAM_REG_DIR/team-a15old.tabs" && [ ! -s "$CMUX_LOG" ] \
    && pass "A15: reap --yes closes it and keeps the cmux row" || fail "A15: reap --yes closes it and keeps the cmux row" "rc=$rc $out"
}

# ═══ A17 — spawn --replace closes the live pane of the same title through ArcaTerm ═══
{
  _at_reset; R="$W/a17"; _mkproj "$R" sec
  _spawn "$R" a17 sec "$R/run/prompts/sec.md" "$SONNET" >/dev/null || true
  p=$(_row a17 a17-sec | awk '{print $2}')
  out=$(_spawn "$R" --replace a17 sec "$R/run/prompts/sec.md" "$SONNET") || true
  [[ $out == *"replaced: closed arcaterm $p (a17-sec)"* ]] && grep -q "^pane close --pane $p --force$" "$AT_LOG" \
    && [ "$(_row a17 a17-sec | wc -l | tr -d ' ')" = 1 ] && [ "$(_row a17 a17-sec | awk '{print $2}')" != "$p" ] \
    && pass "A17: --replace closes the old pane and records the new one" || fail "A17: --replace closes the old pane and records the new one" "$out"
}

echo
echo "team-arcaterm: $passes passed, $fails failed"
[ "$fails" = 0 ] && echo "all passed ($passes cases)" || exit 1
