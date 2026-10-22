#!/usr/bin/env bash
# lib/tickets.sh — ticket runs: sub_tickets and sub_integrate for team.sh.
# Sourced by team.sh after its helpers (set -euo pipefail is already on). Functions only; no
# top-level side effects.
#
# A ticket run implements /to-tickets slices in parallel: the lead claims every runnable slice (up
# to the cap), spawns one sonnet teammate per slice in its own worktree, and integrates each finished
# slice into the branch the run started on, so a slice that depends on it starts from code that
# has it. The tracker work reuses run-afk's tools (TEAM_TICKETS_LIB, default
# ~/.claude/skills/run-afk/ralph/lib), so tickets read the same to /team and to /run-afk:
#   tracker.py   fetch-open / fetch-in-flight / claim / release / mark-done / comment / handoff
#   graph.py     next-runnable: blocking edges, plus no two in-flight slices touching the same files
#   dabs_guard.py pick-safe: no two in-flight slices deploying the same Databricks bundle (local mode)
# The run's tracker mode, slug and branch are kept in $TEAM_REG_DIR/team-<team>.tickets, written by
# the first `tickets` call of the run.

_tk_lib() { echo "${TEAM_TICKETS_LIB:-$HOME/.claude/skills/run-afk/ralph/lib}"; }
_tk_conf() { echo "$(_reg_dir)/team-$1.tickets"; }

# Exit 3 unless run-afk's tracker tools are here.
_tk_require() {
  local lib; lib=$(_tk_lib)
  [ -f "$lib/tracker.py" ] && [ -f "$lib/graph.py" ] || {
    echo "team.sh: ticket runs need run-afk's tracker tools (tracker.py, graph.py) in $lib; install run-afk or set TEAM_TICKETS_LIB" >&2; exit 3; }
  _need_py
}

# python3 <tool> <args...>, run from the project root: the tools resolve .scratch/ against the cwd.
_tk() { local tool=$1; shift; (cd "$(_root)" && python3 "$(_tk_lib)/$tool" "$@"); }

# "<mode> <slug|->" for this project, decided as run-afk's A1 does: a slug means local; else
# docs/agents/issue-tracker.md (written by /setup-matt-pocock-skills); else a .scratch/*/issues/ dir
# means local, a GitHub remote with gh signed in means github. Prints the reason and returns 2 or 3
# when it cannot decide.
_tk_detect() {
  local slug=$1 root mode= f d n
  root=$(_root)
  if [ -n "$slug" ]; then
    [ -d "$root/.scratch/$slug/issues" ] || { echo "tickets: no .scratch/$slug/issues/ in $root" >&2; return 3; }
    echo "local $slug"; return 0
  fi
  f="$root/docs/agents/issue-tracker.md"
  if [ -f "$f" ]; then
    if grep -qiE 'github|gh issue' "$f"; then mode=github
    elif grep -qiE 'local markdown|\.scratch/' "$f"; then mode=local
    elif grep -qi gitlab "$f"; then echo "tickets: GitLab trackers are not supported" >&2; return 3; fi
  fi
  if [ -z "$mode" ]; then
    if compgen -G "$root/.scratch/*/issues" >/dev/null; then mode=local
    elif gh auth status >/dev/null 2>&1 && git -C "$root" remote -v 2>/dev/null | grep -q 'github\.com'; then mode=github
    else echo "tickets: no tracker found; run /setup-matt-pocock-skills, then /to-spec and /to-tickets" >&2; return 3; fi
  fi
  [ "$mode" = local ] || { echo "github -"; return 0; }
  n=0
  for d in "$root"/.scratch/*/issues; do [ -d "$d" ] && { n=$((n+1)); slug=$(basename "$(dirname "$d")"); }; done
  [ "$n" != 0 ] || { echo "tickets: no .scratch/<slug>/issues/ in $root; run /to-spec and /to-tickets first" >&2; return 3; }
  [ "$n" = 1 ] || { echo "tickets: several features under .scratch/: $(cd "$root/.scratch" && ls -d */issues | sed 's#/issues##' | tr '\n' ' ')- pass --slug <slug>" >&2; return 2; }
  echo "local $slug"
}

# Tracker flags for a mode and slug.
_tk_flags() { if [ "$1" = local ]; then echo "--mode local --slug $2"; else echo "--mode github"; fi; }

# The ticket file of slice $3 in local mode (issues/, in-flight/ or done/), or nothing.
_tk_file() {
  local d="$1/.scratch/$2/issues" sub f
  for sub in in-flight "" done; do
    for f in "$d${sub:+/$sub}/$3"-*.md; do [ -f "$f" ] && { echo "$f"; return 0; }; done
  done
}

# The title of slice $1 (mode $2, slug $3): the ticket's heading without its "NN:" prefix.
_tk_title() {
  local f t
  if [ "$2" = local ]; then
    f=$(_tk_file "$(_root)" "$3" "$1")
    t=$(sed -n 's/^# *//p' "$f" 2>/dev/null | head -1 | sed -E 's/^(Slice )?[0-9]+ *(:|—|-) *//')
  else
    t=$(gh issue view "$1" --json title -q .title 2>/dev/null || true)
  fi
  echo "${t:-slice $1}"
}

# A slice id as a role name: s<id> (lowercase, no characters a role cannot have).
_tk_role() { echo "s$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-')"; }

# team.sh tickets [--slug S] [--max N] [--dry-run] [--release <slice>] <team>
# Claim every runnable slice that fits: up to --max implementers in flight (default 8) and the
# 8-teammate cap. One "claimed<TAB><slice><TAB><role><TAB><title><TAB><ticket>" line per claim
# (--dry-run: "runnable<TAB>..." and nothing claimed), then a "tickets:" summary line naming the
# branch and the commit the run started from; "tickets: queue empty" when nothing is open or in flight.
sub_tickets() {
  local slug= max=8 rel= dry= team usage="usage: team.sh tickets [--slug <slug>] [--max <n>] [--dry-run] [--release <slice>] <team>"
  while [ $# -gt 0 ]; do case $1 in
    --slug) slug=${2:?--slug <slug>}; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --max) max=${2:?--max <n>}; shift 2 ;;
    --release) rel=${2:?--release <slice>}; shift 2 ;;
    -*) echo "$usage" >&2; return 2 ;;
    *) break ;;
  esac; done
  team=${1:-}; [ -n "$team" ] && [ $# -eq 1 ] || { echo "$usage" >&2; return 2; }
  case $max in ''|*[!0-9]*) echo "tickets: --max must be a number" >&2; return 2 ;; esac
  _tk_require
  local conf root mode branch start det flags
  conf=$(_tk_conf "$team") root=$(_root)
  if [ -f "$conf" ]; then
    mode=$(sed -n 's/^mode=//p' "$conf"); branch=$(sed -n 's/^branch=//p' "$conf"); start=$(sed -n 's/^start=//p' "$conf")
    [ -z "$slug" ] || [ "$slug" = "$(sed -n 's/^slug=//p' "$conf")" ] || {
      echo "tickets: $team already runs slug '$(sed -n 's/^slug=//p' "$conf")'; start another team for '$slug'" >&2; return 2; }
    slug=$(sed -n 's/^slug=//p' "$conf")
  else
    det=$(_tk_detect "$slug") || return $?
    mode=${det%% *} slug=${det#* }
    branch=$(git -C "$root" symbolic-ref -q --short HEAD) || {
      echo "tickets: the main checkout is on a detached HEAD; check out the branch the slices should land on" >&2; return 2; }
    # Like /run-afk: never start on someone's uncommitted work (tracker files under .scratch/ aside).
    [ -z "$(git -C "$root" status --porcelain -- . ':(exclude).scratch' 2>/dev/null)" ] || {
      echo "tickets: the main checkout has uncommitted changes; commit or stash them first:" >&2
      git -C "$root" status --short -- . ':(exclude).scratch' | head -5 >&2; return 2; }
    start=$(git -C "$root" rev-parse --short HEAD)
    # A dry run records nothing: the run starts with the first real claim.
    [ -n "$dry" ] || printf 'mode=%s\nslug=%s\nbranch=%s\nstart=%s\n' "$mode" "$slug" "$branch" "$start" > "$conf"
  fi
  # shellcheck disable=SC2086
  flags=$(_tk_flags "$mode" "$slug")
  if [ -n "$rel" ]; then
    # shellcheck disable=SC2086
    if _tk tracker.py release "$rel" $flags >/dev/null; then echo "released $rel"; return 0; fi
    echo "tickets: could not release $rel" >&2; return 1
  fi

  local reg live impl slots open inflight ids picked n_open n_if
  reg=$(_reg "$team")
  live=$(_mates "$reg" | grep -c . || true)
  impl=$(_mates "$reg" | grep -c "^$team-s[0-9]" || true)   # implementer roles are s<slice id>
  slots=$(( 8 - live )); [ $(( max - impl )) -ge "$slots" ] || slots=$(( max - impl ))
  # shellcheck disable=SC2086
  open=$(_tk tracker.py fetch-open $flags) || { echo "tickets: tracker fetch-open failed" >&2; return 1; }
  # shellcheck disable=SC2086
  inflight=$(_tk tracker.py fetch-in-flight $flags) || inflight='[]'
  n_open=$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$open")
  n_if=$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$inflight")
  if [ "$n_open" = 0 ] && [ "$n_if" = 0 ]; then echo "tickets: queue empty"; return 0; fi
  if [ "$slots" -le 0 ]; then echo "tickets: 0 claimed (no free slot: $impl implementers, $live teammates live), $n_open open, $n_if in flight"; return 0; fi
  # shellcheck disable=SC2086
  ids=$(_tk graph.py next-runnable --in-flight "$inflight" --concurrency "$slots" $flags) || ids='[]'
  local deferred=0
  if [ "$mode" = local ] && [ "${TEAM_DABS_GUARD:-1}" != 0 ] && [ -f "$(_tk_lib)/dabs_guard.py" ]; then
    # In-flight slices go first, so a candidate deploying one of their bundles is the one deferred.
    local cand guard
    cand=$(python3 -c 'import json,sys; print(",".join(json.loads(sys.argv[1]) + json.loads(sys.argv[2])))' "$inflight" "$ids")
    guard=$(_tk dabs_guard.py pick-safe --candidates "$cand" --slug "$slug" --project-root "$root" 2>/dev/null) || guard=
    if [ -n "$guard" ]; then
      ids=$(python3 -c '
import json, sys
g = json.loads(sys.argv[1]); busy = set(json.loads(sys.argv[2]))
print(json.dumps([s for s in g.get("picked", []) if s not in busy]))' "$guard" "$inflight")
      deferred=$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1]).get("deferred", [])))' "$guard")
    fi
  fi
  local sid claimed=0 role title ticket
  for sid in $(python3 -c 'import json,sys; print(" ".join(json.loads(sys.argv[1])))' "$ids"); do
    if [ -z "$dry" ]; then
      # shellcheck disable=SC2086
      _tk tracker.py claim "$sid" $flags >/dev/null 2>&1 || continue   # lost the race (another run has it)
    fi
    claimed=$((claimed + 1)) role=$(_tk_role "$sid") title=$(_tk_title "$sid" "$mode" "$slug")
    if [ "$mode" = local ]; then ticket=$(_tk_file "$root" "$slug" "$sid"); else ticket="#$sid"; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$([ -n "$dry" ] && echo runnable || echo claimed)" "$sid" "$role" "$title" "${ticket:--}"
  done
  local where="branch $branch from $start, $mode${slug:+ $slug}" more=
  [ "$deferred" = 0 ] || more=", $deferred deferred (Databricks bundle in use)"
  if [ -n "$dry" ]; then echo "tickets: $claimed runnable now (dry run, nothing claimed), $n_open open, $n_if in flight$more — $where"
  else echo "tickets: $claimed claimed, $((n_open - claimed)) open, $((n_if + claimed)) in flight$more — $where"; fi
}

# team.sh integrate <team> <role>
# Land a finished implementer's slice on the run's branch: rebase its branch team/<team>-<role> onto
# that branch, fast-forward the branch, then mark the slice done (local: tick its criteria and move
# it to done/; tracked .scratch/: that bookkeeping is folded into the slice's commit; github: comment
# with the commit and close the issue). Refuses (exit 2, nothing changed) unless the teammate is
# finished, the main checkout is on the run's branch with no uncommitted changes outside .scratch/,
# and the branch has a "Slice <id>:" commit that leaves .scratch/ alone. Exit 5 = the rebase hit a
# conflict: it is aborted, nothing changed, and the conflicting files are listed for the teammate.
sub_integrate() {
  local team=${1:-} role=${2:-} usage="usage: team.sh integrate <team> <role>"
  [ -n "$team" ] && [ -n "$role" ] && [ $# -eq 2 ] || { echo "$usage" >&2; return 2; }
  _tk_require
  local conf reg root mode slug branch title row wt sid tb cur
  conf=$(_tk_conf "$team") reg=$(_reg "$team") root=$(_root) title="$team-$role"
  [ -f "$conf" ] || { echo "integrate: no ticket run recorded for $team (run team.sh tickets first)" >&2; return 3; }
  mode=$(sed -n 's/^mode=//p' "$conf"); slug=$(sed -n 's/^slug=//p' "$conf"); branch=$(sed -n 's/^branch=//p' "$conf")
  [ -f "$reg" ] || { echo "integrate: no teammates recorded for $team" >&2; return 3; }
  _lock "$reg"
  row=$(awk -v t="$title" '$4==t && ($3=="pane" || $3=="tab") {r=$0} END{print r}' "$reg")
  [ -n "$row" ] || { echo "integrate: no recorded teammate $title" >&2; return 3; }
  _finished "$row" || { echo "integrate: refused: $title is not finished; run team.sh finish $team $role first" >&2; return 2; }
  read -r _ _ _ _ _ _ _ _ _ _ wt <<<"$row"
  case $wt in "$root"/.team/worktrees/*) ;; *) echo "integrate: refused: $title did not work in a worktree (spawn it with --worktree)" >&2; return 2 ;; esac
  [ -d "$wt" ] || { echo "integrate: refused: $title's worktree $wt is gone" >&2; return 2; }
  sid=${role#s} tb="team/$title"
  cur=$(git -C "$root" symbolic-ref -q --short HEAD || true)
  [ "$cur" = "$branch" ] || { echo "integrate: refused: the main checkout is on '${cur:-a detached HEAD}', not the run's branch '$branch'" >&2; return 2; }
  [ -z "$(git -C "$root" status --porcelain -- . ':(exclude).scratch')" ] || {
    echo "integrate: refused: the main checkout has uncommitted changes outside .scratch/:" >&2
    git -C "$root" status --short -- . ':(exclude).scratch' | head -5 >&2; return 2; }
  [ -z "$(git -C "$wt" status --porcelain)" ] || { echo "integrate: refused: worktree $wt has uncommitted changes" >&2; return 2; }
  git -C "$root" log --format=%s "$branch..$tb" 2>/dev/null | grep -q "^Slice 0*${sid#0}:" || {
    echo "integrate: refused: $tb has no 'Slice $sid:' commit on top of $branch" >&2; return 2; }
  [ -z "$(git -C "$root" diff --name-only "$(git -C "$root" merge-base "$branch" "$tb")" "$tb" -- .scratch)" ] || {
    echo "integrate: refused: $tb changes .scratch/; the lead owns tracker files (revert them on the branch)" >&2; return 2; }

  local behind files err
  behind=$(git -C "$root" rev-list --count "$tb..$branch")
  if [ "$behind" -gt 0 ] && ! err=$(git -C "$wt" rebase -q "$branch" 2>&1 >/dev/null); then
    files=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || true)
    git -C "$wt" rebase --abort >/dev/null 2>&1 || true
    if [ -z "$files" ]; then
      # Not a conflict (no identity, a hook, a locked index...): say what git said.
      echo "integrate: rebasing $tb onto $branch failed (nothing changed): $(printf '%s' "$err" | grep -v '^\s*$' | tail -1)" >&2
      return 1
    fi
    echo "integrate: conflict rebasing $tb onto $branch (nothing changed). Conflicting files:" >&2
    printf '%s\n' "$files" | sed 's/^/  /' >&2
    return 5
  fi
  git -C "$root" merge -q --ff-only "$tb" || { echo "integrate: could not fast-forward $branch to $tb" >&2; return 1; }

  local f flags sha name
  flags=$(_tk_flags "$mode" "$slug")
  if [ "$mode" = local ]; then
    f=$(_tk_file "$root" "$slug" "$sid")
    if [ -n "$f" ]; then sed -i.bak 's/^\([[:space:]]*\)- \[ \]/\1- [x]/' "$f" && rm -f "$f.bak"; fi
    # shellcheck disable=SC2086
    _tk tracker.py mark-done "$sid" $flags >/dev/null || { echo "integrate: merged, but tracker mark-done $sid failed; run it by hand" >&2; return 1; }
    if ! git -C "$root" check-ignore -q .scratch; then
      # Tracked .scratch/: this slice's bookkeeping belongs in its own commit (one slice per commit).
      # --only keeps other slices' staged claim renames out of it.
      local spec=(":(glob).scratch/$slug/issues/$sid-*.md" ":(glob).scratch/$slug/issues/*/$sid-*.md")
      git -C "$root" add -A -- "${spec[@]}" 2>/dev/null || true
      if ! git -C "$root" diff --cached --quiet -- "${spec[@]}"; then
        git -C "$root" commit -q --amend --no-edit --only -- "${spec[@]}" || { echo "integrate: merged, but folding the ticket into the slice commit failed; commit .scratch/$slug/issues/ by hand" >&2; return 1; }
      fi
    fi
  fi
  sha=$(git -C "$root" rev-parse --short HEAD)
  if [ "$mode" = github ]; then
    # shellcheck disable=SC2086
    _tk tracker.py comment "$sid" --author team --body "Implemented in commit $sha on $branch by /team ($title). All acceptance criteria met." $flags >/dev/null || true
    # shellcheck disable=SC2086
    _tk tracker.py mark-done "$sid" $flags >/dev/null || { echo "integrate: merged as $sha, but closing #$sid failed; close it by hand" >&2; return 1; }
  fi
  name=$(_tk_title "$sid" "$mode" "$slug")
  echo "integrated slice $sid ($name) as $sha on $branch$([ "$behind" = 0 ] || echo "; rebased over $behind newer commit(s): run the feedback loops on $branch")"
}
