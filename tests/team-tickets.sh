#!/usr/bin/env bash
# tests/team-tickets.sh — ticket runs: `team.sh tickets` and `team.sh integrate` (lib/tickets.sh).
# Drives the real loop against run-afk's tracker tools: claim -> spawn --worktree (cmux stub) ->
# a simulated implementer commit -> finish -> integrate, on a fixture repo with /to-tickets files,
# once with .scratch/ git-ignored and once with it tracked. Skips (exit 0) when run-afk's tools are
# not installed, since ticket runs need them.
# USAGE:
#   bash tests/team-tickets.sh
#   TEAM_SH=/path/to/team.sh TEAM_TICKETS_LIB=/path/to/ralph/lib bash tests/team-tickets.sh
set -euo pipefail

TEAM_SH="${TEAM_SH:-$(cd "$(dirname "$0")/.." && pwd)/team.sh}"
export TEAM_TICKETS_LIB="${TEAM_TICKETS_LIB:-$HOME/.claude/skills/run-afk/ralph/lib}"
if [ ! -f "$TEAM_TICKETS_LIB/tracker.py" ]; then
  echo "SKIP  team-tickets: run-afk's tracker tools not found in $TEAM_TICKETS_LIB"; exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0; passes=0
pass() { echo "PASS  $1"; passes=$((passes+1)); }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }

unset TEAM_MEMBER MACTERM_SESSION TEAM_BACKEND   # never reach a real terminal (see tests/team-build.sh)
mkdir -p "$W/bin"
export CMUX_LOG="$W/cmux.log" CLAUDE_LOG="$W/claude.log"; : > "$CMUX_LOG"
cat > "$W/bin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
n=$(wc -l < "$CMUX_LOG")
case "$1" in
  ping) echo PONG ;;
  --version) echo "cmux 0.65.0 (108) stub" ;;
  new-split|new-surface) printf 'ok surface:%d workspace:1\n' "$n" ;;
  identify) echo '{"caller":{"pane_ref":"pane-stub","surface_ref":"surface:lead"}}' ;;
  tree) echo '{"workspaces":[]}' ;;
  close-surface) echo OK ;;
  *) true ;;
esac
SH
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$CLAUDE_LOG"\n' > "$W/bin/claude"
chmod +x "$W/bin/cmux" "$W/bin/claude"
export PATH="$W/bin:$PATH"
mkdir -p "$W/home/.claude/team/roles"
cat > "$W/home/.claude/settings.json" <<'JSON'
{"modelPicker":{"options":[
  {"model":"system.ai.claude-opus-5-5[1m]","behavesAs":"opus"},
  {"model":"system.ai.claude-sonnet-5-5[1m]","behavesAs":"sonnet"}
]}}
JSON
echo '{"projects":{}}' > "$W/home/.claude.json"
export HOME="$W/home" TEAM_ROLES_DIR="$W/home/.claude/team/roles" TEAM_MODELS_FILE="$W/home/.claude/settings.json"
export TEAM_REG_DIR="$W/regs"; mkdir -p "$TEAM_REG_DIR"
# HOME is a scratch dir, so git has no identity there; integrate rebases and amends with it.
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@t
export CMUX_WORKSPACE_ID=ws-test CMUX_SURFACE_ID=surface:lead
SONNET=system.ai.claude-sonnet-5-5[1m]

_git() { git -c user.email=t@t -c user.name=T "$@"; }
_ticket() {  # <dir> <NN> <slug> <title> <blocked-by> <file>
  cat > "$1/$2-$3.md" <<MD
# $2: $4

**What to build:** $4.

**Blocked by:** $5

**Status:** ready-for-agent

Files: $6

- [ ] criterion one
- [ ] criterion two
MD
}
# A repo on branch main with src/a.txt and src/b.txt and four tickets in .scratch/feat/issues:
# 01 (a.txt), 02 (a.txt, blocked by 01), 03 (b.txt), 04 (a.txt: overlaps 01, so never alongside it).
# $2 = ignored|tracked decides whether .scratch/ is git-ignored.
_mkrepo() {
  local R=$1; mkdir -p "$R/src" "$R/.scratch/feat/issues"
  _git -C "$R" init -q -b main
  printf 'a1\na2\na3\n' > "$R/src/a.txt"; printf 'b1\n' > "$R/src/b.txt"
  printf '.team/\n' > "$R/.gitignore"; [ "$2" = ignored ] && printf '.scratch/\n' >> "$R/.gitignore"
  local d="$R/.scratch/feat/issues"
  _ticket "$d" 01 add-a "Add a" "None (can start immediately)" src/a.txt
  _ticket "$d" 02 extend-a "Extend a" "01" src/a.txt
  _ticket "$d" 03 add-b "Add b" "None (can start immediately)" src/b.txt
  _ticket "$d" 04 also-a "Also a" "None (can start immediately)" src/a.txt
  _git -C "$R" add -A; _git -C "$R" commit -q -m init
  mkdir -p "$R/.team/runs/r/prompts" "$R/.team/runs/r/reports"
}
# Spawn the implementer for slice $3 of team $2 in repo $1, make its commit (edit: line $4 of
# file $5 becomes "$6"), report, tick tasks.md and finish it.
_implement() {
  local R=$1 T=$2 id=$3 line=$4 file=$5 text=$6 run="$1/.team/runs/r"
  echo "implement slice $id" > "$run/prompts/s$id.md"
  echo "- [ ] $T-s$id: slice $id" >> "$run/tasks.md"
  (cd "$R" && bash "$TEAM_SH" spawn --worktree "$T" "s$id" "$run/prompts/s$id.md" "$SONNET" >/dev/null 2>&1) || true
  local wt="$R/.team/worktrees/$T-s$id"
  [ -d "$wt" ] || return 1
  sed -i.bak "${line}s/.*/$text/" "$wt/$file" && rm -f "$wt/$file.bak"
  _git -C "$wt" commit -q -am "Slice $id: change $file"
  printf 'RUN-AFK RESULT\nslice: %s\nstatus: done\nPARALLELISM: none\n' "$id" > "$run/reports/s$id.md"
  sed -i.bak "s/^- \[ \] $T-s$id:/- [x] $T-s$id:/" "$run/tasks.md" && rm -f "$run/tasks.md.bak"
  (cd "$R" && bash "$TEAM_SH" finish "$T" "s$id" >/dev/null 2>&1)
}
_tk() { local R=$1; shift; (cd "$R" && bash "$TEAM_SH" tickets "$@" 2>&1); }
_in() { local R=$1; shift; (cd "$R" && bash "$TEAM_SH" integrate "$@" 2>&1); }
_where() { local f; for f in "$1"/.scratch/feat/issues/{,in-flight/,done/}"$2"-*.md; do [ -f "$f" ] && { basename "$(dirname "$f")"; return; }; done; echo none; }

# ═══ K1 — tickets claims the runnable frontier: blockers and file overlap respected ═══
{
  R="$W/k1"; _mkrepo "$R" ignored
  out=$(_tk "$R" k1) && rc=0 || rc=$?
  [ "$rc" = 0 ] && [[ $out == *$'claimed\t01\ts01\tAdd a\t'* ]] && [[ $out == *$'claimed\t03\ts03\tAdd b\t'* ]] \
    && [[ $out != *$'claimed\t02'* ]] && [[ $out != *$'claimed\t04'* ]] \
    && [ "$(_where "$R" 01)" = in-flight ] && [ "$(_where "$R" 02)" = issues ] \
    && pass "K1: claims 01 and 03; 02 (blocked) and 04 (same file as 01) wait" \
    || fail "K1: claims 01 and 03; 02 (blocked) and 04 (same file as 01) wait" "rc=$rc $out"
  [[ $out == *"tickets: 2 claimed, 2 open, 2 in flight — branch main from $(git -C "$R" rev-parse --short HEAD), local feat"* ]] \
    && pass "K1: summary line" || fail "K1: summary line" "$out"
  grep -q '^mode=local$' "$TEAM_REG_DIR/team-k1.tickets" && grep -q '^branch=main$' "$TEAM_REG_DIR/team-k1.tickets" \
    && pass "K1: the run records mode, slug and branch" || fail "K1: the run records mode, slug and branch" "$(cat "$TEAM_REG_DIR/team-k1.tickets" 2>/dev/null)"
}

# ═══ K2 — --max caps implementers; --release puts a claim back ═══
{
  R="$W/k2"; _mkrepo "$R" ignored
  out=$(_tk "$R" --dry-run k2) || true
  [[ $out == *$'runnable\t01\ts01'* ]] && [[ $out == *"dry run, nothing claimed"* ]] && [ "$(_where "$R" 01)" = issues ] \
    && [ ! -f "$TEAM_REG_DIR/team-k2.tickets" ] \
    && pass "K2: --dry-run lists the runnable slices and claims or records nothing" \
    || fail "K2: --dry-run lists the runnable slices and claims or records nothing" "$out"
  out=$(_tk "$R" --max 1 k2) || true
  [ "$(grep -c '^claimed' <<<"$out")" = 1 ] && pass "K2: --max 1 claims one slice" || fail "K2: --max 1 claims one slice" "$out"
  out=$(_tk "$R" --release 01 k2) && rc=0 || rc=$?
  [ "$rc" = 0 ] && [ "$(_where "$R" 01)" = issues ] && pass "K2: --release returns the slice to the queue" || fail "K2: --release returns the slice to the queue" "rc=$rc $out"
}

# ═══ K3 — refusals before anything is claimed ═══
{
  R="$W/k3"; _mkrepo "$R" ignored; echo dirty >> "$R/src/a.txt"
  out=$(_tk "$R" k3) && rc=0 || rc=$?
  [ "$rc" = 2 ] && [[ $out == *"uncommitted changes"* ]] && [ "$(_where "$R" 01)" = issues ] \
    && pass "K3: uncommitted work → exit 2, nothing claimed" || fail "K3: uncommitted work → exit 2, nothing claimed" "rc=$rc $out"
  _git -C "$R" checkout -q -- src/a.txt; _git -C "$R" checkout -q --detach
  out=$(_tk "$R" k3) && rc=0 || rc=$?
  [ "$rc" = 2 ] && [[ $out == *"detached HEAD"* ]] && pass "K3: detached HEAD → exit 2" || fail "K3: detached HEAD → exit 2" "rc=$rc $out"
  out=$(cd "$R" && TEAM_TICKETS_LIB="$W/none" bash "$TEAM_SH" tickets k3x 2>&1) && rc=0 || rc=$?
  [ "$rc" = 3 ] && [[ $out == *"run-afk's tracker tools"* ]] && pass "K3: no tracker tools → exit 3" || fail "K3: no tracker tools → exit 3" "rc=$rc $out"
}

# ═══ K4 — integrate (ignored .scratch/): fast-forward, criteria ticked, ticket done ═══
{
  R="$W/k4"; _mkrepo "$R" ignored
  _tk "$R" k4 >/dev/null
  out=$(_in "$R" k4 s01) && rc=0 || rc=$?
  [ "$rc" = 3 ] || [ "$rc" = 2 ] && pass "K4: integrate before the teammate exists or finished is refused" || fail "K4: integrate before the teammate exists or finished is refused" "rc=$rc $out"
  _implement "$R" k4 01 1 src/a.txt "A1" || fail "K4: implementer spawned with a worktree"
  out=$(_in "$R" k4 s01) && rc=0 || rc=$?
  [ "$rc" = 0 ] && [[ $out == "integrated slice 01 (Add a) as "*" on main" ]] \
    && [ "$(git -C "$R" log -1 --format=%s)" = "Slice 01: change src/a.txt" ] && [ "$(head -1 "$R/src/a.txt")" = A1 ] \
    && [ "$(_where "$R" 01)" = done ] && ! grep -q -- '- \[ \]' "$R"/.scratch/feat/issues/done/01-*.md \
    && pass "K4: the slice lands on main, its ticket is done with every criterion ticked" \
    || fail "K4: the slice lands on main, its ticket is done with every criterion ticked" "rc=$rc $out"
  out=$(_tk "$R" k4) || true
  [[ $out == *$'claimed\t02\ts02'* ]] && pass "K4: integrating 01 unblocks 02 for the next tickets call" || fail "K4: integrating 01 unblocks 02 for the next tickets call" "$out"
}

# ═══ K5 — a slice that branched before another landed is rebased; a real conflict exits 5 untouched ═══
{
  R="$W/k5"; _mkrepo "$R" ignored
  _tk "$R" k5 >/dev/null
  _implement "$R" k5 01 1 src/a.txt "A1"
  _implement "$R" k5 03 1 src/b.txt "B1"
  _in "$R" k5 s01 >/dev/null
  out=$(_in "$R" k5 s03) && rc=0 || rc=$?
  [ "$rc" = 0 ] && [[ $out == *"rebased over 1 newer commit(s): run the feedback loops on main"* ]] \
    && [ "$(git -C "$R" log --format=%s -2 | tr '\n' '|')" = "Slice 03: change src/b.txt|Slice 01: change src/a.txt|" ] \
    && pass "K5: a slice behind main is rebased onto it, one commit per slice" || fail "K5: a slice behind main is rebased onto it, one commit per slice" "rc=$rc $out"

  R="$W/k5c"; _mkrepo "$R" ignored
  _tk "$R" k5c >/dev/null
  _implement "$R" k5c 01 1 src/a.txt "A1"
  _implement "$R" k5c 03 1 src/a.txt "CLASH"    # 03 strays outside its ticket into a.txt
  _in "$R" k5c s01 >/dev/null
  head_before=$(git -C "$R" rev-parse HEAD); tb_before=$(git -C "$R" rev-parse team/k5c-s03)
  out=$(_in "$R" k5c s03) && rc=0 || rc=$?
  [ "$rc" = 5 ] && [[ $out == *"src/a.txt"* ]] && [ "$(git -C "$R" rev-parse HEAD)" = "$head_before" ] \
    && [ "$(git -C "$R" rev-parse team/k5c-s03)" = "$tb_before" ] && [ -z "$(git -C "$R/.team/worktrees/k5c-s03" status --porcelain)" ] \
    && [ "$(_where "$R" 03)" = in-flight ] \
    && pass "K5: a conflict exits 5 with the file named; main, the branch and the ticket are unchanged" \
    || fail "K5: a conflict exits 5 with the file named; main, the branch and the ticket are unchanged" "rc=$rc $out"
}

# ═══ K6 — integrate refusals: wrong branch, dirty checkout, no Slice commit ═══
{
  R="$W/k6"; _mkrepo "$R" ignored
  _tk "$R" k6 >/dev/null
  _implement "$R" k6 01 1 src/a.txt "A1"
  _git -C "$R" checkout -q -b other
  out=$(_in "$R" k6 s01) && rc=0 || rc=$?
  [ "$rc" = 2 ] && [[ $out == *"not the run's branch 'main'"* ]] && pass "K6: another branch checked out → exit 2" || fail "K6: another branch checked out → exit 2" "rc=$rc $out"
  _git -C "$R" checkout -q main; echo wip >> "$R/src/b.txt"
  out=$(_in "$R" k6 s01) && rc=0 || rc=$?
  [ "$rc" = 2 ] && [[ $out == *"uncommitted changes outside .scratch/"* ]] && pass "K6: uncommitted work on main → exit 2" || fail "K6: uncommitted work on main → exit 2" "rc=$rc $out"
  _git -C "$R" checkout -q -- src/b.txt
  _git -C "$R/.team/worktrees/k6-s01" commit -q --amend -m "wip"
  out=$(_in "$R" k6 s01) && rc=0 || rc=$?
  [ "$rc" = 2 ] && [[ $out == *"no 'Slice 01:' commit"* ]] && [ "$(git -C "$R" log -1 --format=%s)" = init ] \
    && pass "K6: no 'Slice NN:' commit → exit 2, main untouched" || fail "K6: no 'Slice NN:' commit → exit 2, main untouched" "rc=$rc $out"
}

# ═══ K7 — tracked .scratch/: the slice's own bookkeeping is folded into its commit, nothing else ═══
{
  R="$W/k7"; _mkrepo "$R" tracked
  _tk "$R" k7 >/dev/null                       # claims 01 and 03: both renames staged on main
  _implement "$R" k7 01 1 src/a.txt "A1"
  out=$(_in "$R" k7 s01) && rc=0 || rc=$?
  files=$(git -C "$R" show --name-status --format= HEAD | sort)
  [ "$rc" = 0 ] && [ "$(git -C "$R" log -1 --format=%s)" = "Slice 01: change src/a.txt" ] \
    && grep -q $'^R[0-9]*\t.scratch/feat/issues/01-add-a.md\t.scratch/feat/issues/done/01-add-a.md' <<<"$files" \
    && grep -q $'^M\tsrc/a.txt' <<<"$files" && ! grep -q '03-add-b' <<<"$files" \
    && [ "$(_where "$R" 03)" = in-flight ] \
    && pass "K7: one commit holds the slice and its ticket's move to done/; 03's claim stays out" \
    || fail "K7: one commit holds the slice and its ticket's move to done/; 03's claim stays out" "rc=$rc $out | $files"
  _implement "$R" k7 03 1 src/b.txt "B1"
  echo touched >> "$R/.team/worktrees/k7-s03/.scratch/feat/issues/03-add-b.md"
  _git -C "$R/.team/worktrees/k7-s03" commit -q -am "Slice 03: also edits its ticket"
  out=$(_in "$R" k7 s03) && rc=0 || rc=$?
  [ "$rc" = 2 ] && [[ $out == *"changes .scratch/"* ]] && pass "K7: a slice branch that edits .scratch/ is refused" || fail "K7: a slice branch that edits .scratch/ is refused" "rc=$rc $out"
}

# ═══ K8 — queue empty once every slice is done ═══
{
  R="$W/k8"; _mkrepo "$R" ignored
  for id in 01 02 03 04; do mkdir -p "$R/.scratch/feat/issues/done"; mv "$R"/.scratch/feat/issues/$id-*.md "$R/.scratch/feat/issues/done/"; done
  out=$(_tk "$R" k8) && rc=0 || rc=$?
  [ "$rc" = 0 ] && [ "$out" = "tickets: queue empty" ] && pass "K8: nothing open or in flight → queue empty" || fail "K8: nothing open or in flight → queue empty" "rc=$rc $out"
}

echo
echo "team-tickets: $passes passed, $fails failed"
[ "$fails" = 0 ] && echo "all passed ($passes cases)" || exit 1
