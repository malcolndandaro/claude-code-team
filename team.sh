#!/usr/bin/env bash
# Run each teammate as an interactive `claude` session in its own cmux or ArcaTerm pane or tab.
#   team.sh spawn [--tabs] [--worktree] [--replace] [--resume] [--no-caveman] <team> <role> <prompt-file> [model]
#                         --resume: continue the session id recorded for <team>-<role> (normally a finished row)
#                         in its recorded cwd, with <prompt-file> as the new instruction; exit 3 when no session
#                         is recorded or its dir is gone (then spawn without --resume)
#   team.sh close <team>  -> force-closes every recorded pane/tab (incl. the monitor) whose live title still matches
#                            its row (a reused ref is skipped, row dropped) and drops finished rows (the team is over);
#                            exit 1 (rows kept for a retry) if one could not be closed
#   team.sh init <team>   -> creates .team/ (idempotent) + a run dir; prints the run dir path
#   team.sh lead-title    -> renames the lead's cmux workspace and tab (ArcaTerm: its tab) to "Main Board - <project>"
#                            (project = basename of the main checkout); idempotent; a no-op inside a teammate
#   team.sh reap [--yes] [--exclude <team>]  -> live teammates left over from earlier teams of THIS project
#                            (every registry, scoped by the project root in each row). Without --yes it only
#                            lists them, one "<team>  <title>  <backend> <ref>  run <run-dir name>" line each, marked when
#                            the run started today (may be live in another lead session); --yes closes them and
#                            clears each fully reaped team's sidebar pill (the progress bar is per workspace, so
#                            that also clears the caller's bar: run reap at step 0, before the new team syncs).
#                            Rows of other projects are never shown or touched; live rows with no root (legacy) are only counted, never named or closed.
#                            Rows opened in the other terminal (a cmux row seen from ArcaTerm, or the reverse) are kept, never closed.
#                            exit 1 if one could not be closed
#   team.sh clean <team>  -> removes the team's worktrees that have no uncommitted changes (branches kept)
#   team.sh finish <team> <role> -> after the lead received a teammate's report: mark its row finished (session id
#                                  and cwd kept), then close its pane. exit 2 refused, nothing changed: the report did
#                                  not grow since spawn or gained no new PARALLELISM: line, tasks.md lacks
#                                  "- [x] <team>-<role>:", or its --worktree has uncommitted changes; exit 3 not
#                                  recorded; exit 1 the close failed (row stays finished; re-run to retry)
#   finish, close and reap --yes also close the browser surfaces a teammate listed in <run>/browser/<role>.txt
#   (only refs still of type browser; best-effort: a failure warns, keeps the ref for a retry, never changes the exit code)
#   team.sh show <team> <role>  -> bring a teammate's pane to the front and focus it (a --tabs teammate is first
#                                  moved out of your pane into its own); exit 3 finished, gone or not recorded,
#                                  exit 1 cmux could not resolve its pane (it may still be running), or ArcaTerm could
#                                  not focus it (pane focus works only on the Mac)
#   team.sh list <team>         -> each teammate: working (<pane>) / tab (in your pane, running) / finished / dead
#                                  (cmux says not found; ArcaTerm: pane gone, or its claude session exited) / unknown
#                                  (a row of the other terminal, or no answer); MODEL_GONE when its model left the picker
#   team.sh models              -> models /team offers here (opus and sonnet tier only), best tier first
#   team.sh pick-model <tier>   -> newest claude-* model id for opus|sonnet; exit 1 = fell back a tier
#                                  (warning on stderr), 2 = bad tier, 3 = nothing matches
#   team.sh role <name>         -> print a role spec path (project override, then shared library); exit 2 bad name, 3 if none
#   team.sh roles               -> list roles available here: "<name>  project|user  <path>  <status>", status one of
#                                  in-sync|local-ahead|global-ahead|diverged|diverged (no base)|project-only|library-only
#   team.sh role-pull <name> [--force]     -> copy the shared library role into .team/roles/ (records .team/roles/.base/);
#                                             fast-forwards when the local copy is unchanged since .base/.
#                                             exit 0 ok/no-op, 2 bad name/option, 3 not in library, 5 conflict (needs --force)
#   team.sh role-promote <name> [--force]  -> copy a project role into the shared library, secret/PII scan first;
#                                             library ahead always refuses (run role-pull).
#                                             exit 0 ok/no-op, 2 bad name/option or PII hit, 3 not in project, 5 conflict (needs --force)
#   team.sh status [--watch] <team>        -> one frame: "<team> · N/M reported · HH:MM:SS", a progress bar, a NEEDS YOU block
#                                             (only when a teammate is waiting/dead/model gone/stalled?), then ROLE | STATE | STEP | AGE;
#                                             --watch repaints only on change, syncs the sidebar each tick and exits once
#                                             the registry is removed. Width: TEAM_COLS, else tput cols. exit 3 no registry
#   team.sh monitor <team>                 -> open one pane running `status --watch` (layout dash, title
#                                             <team>-monitor; not a teammate, not in the cap; `close` closes it).
#                                             exit 1 already running
#   team.sh sync [--clear] <team>          -> lead sidebar status pill + progress bar and a `cmux log --source team`
#                                             event; --clear removes both. Best-effort (warns, never fails the caller).
#                                             A no-op in ArcaTerm, which has no sidebar API (the monitor pane shows progress)
#   team.sh tickets [--slug <slug>] [--max <n>] [--dry-run] [--release <slice>] <team>
#                                          -> ticket runs: claim every runnable /to-tickets slice that fits (blockers done,
#                                             no file or Databricks-bundle overlap with in-flight slices, at most --max
#                                             implementers (default 8) and the 8-teammate cap), one
#                                             "claimed<TAB><slice><TAB><role s<id>><TAB><title><TAB><ticket>" line each, then a
#                                             "tickets:" summary with the branch and start commit ("tickets: queue empty" when nothing
#                                             is open or in flight); --dry-run lists "runnable" slices and claims nothing.
#                                             The first claiming call records the tracker mode, slug, branch and start commit; it refuses
#                                             a detached HEAD or uncommitted changes outside .scratch/ (exit 2). --release puts
#                                             a claimed slice back. Needs run-afk's tracker tools (TEAM_TICKETS_LIB); exit 3 without
#   team.sh integrate <team> <role>        -> land a finished implementer's slice on the run's branch: rebase team/<team>-<role>
#                                             onto it, fast-forward, mark the slice done (tracked .scratch/: folded into the
#                                             slice commit; github: comment + close). exit 2 refused, nothing changed (not
#                                             finished, wrong branch, dirty checkout, no "Slice <id>:" commit, or it touches
#                                             .scratch/); exit 5 rebase conflict, aborted, nothing changed, files listed
#   (role, roles, role-pull, role-promote live in lib/roles.sh; status, monitor, sync in lib/status.sh;
#    the ArcaTerm pane calls in lib/arcaterm.sh; tickets and integrate in lib/tickets.sh)
#   team.sh facts-lint [--pre-append <file>]  -> freshness of .team/facts.md facts (FRESH/CHECK/GONE/NOANCHOR + DUP); --pre-append scans <file> for secrets
#   team.sh doccheck            -> doc drift guard: retired phrases, subcommands documented, SKILL flags present in HELP
#   team.sh --help              -> prints this header. Any other unknown subcommand exits 2 (it never falls through to spawn).
# Exit codes: 0 ok; 1 fallback/warning; 2 refused (usage, bad input, secret/PII hit, removed --tmux flag);
# 3 not found / missing dependency (role, model, registry, python3, cmux); 4 team cap reached or spawn lock busy;
# 5 role-promote/role-pull direction refused.
# .team/ always means the MAIN checkout's .team/, also when run from inside a linked worktree.
# Needs python3 (models, pick-model, spawn, close, finish, reap, show/list); those subcommands exit 3 without it.
# Needs a terminal backend for spawn, close, finish, reap, lead-title, show/list and monitor; those exit 3 without it.
# The backend is picked per call: TEAM_BACKEND=cmux|arcaterm wins; else cmux inside a cmux pane ($CMUX_SURFACE_ID
# set), else ArcaTerm inside an ArcaTerm pane ($MACTERM_SESSION set), else cmux (for its install hint).
#   cmux: >= 0.65.0, answering `cmux ping`. spawn, lead-title, show/list and monitor must also run inside a cmux pane
#     ($CMUX_WORKSPACE_ID and $CMUX_SURFACE_ID set).
#   ArcaTerm: app >= 1.15.0, `arcaterm version --json` reporting it connected. spawn, lead-title, show/list and
#     monitor must also run inside an ArcaTerm pane ($MACTERM_SESSION set). No sidebar (sync is a no-op), no
#     `notify`, no integrated-browser rules for teammates.
# A row records the backend that opened it (col 1); close, finish and reap act only on rows of the current backend.
# init, status, roles, models and the facts/doc checks need no terminal.
# TEAM_MODELS_FILE: read the model picker (and the default "model") from this JSON file instead of
# managed-settings/settings.json.
# --worktree: the teammate works in its own git worktree .team/worktrees/<team>-<role>
# on branch team/<team>-<role> (created from HEAD, or reused if it survived a `clean`), like a
# separate person. Needs at least one commit. Each new worktree is pre-accepted in ~/.claude.json
# so the workspace-trust prompt does not appear in every pane (a worktree is its own git
# top-level, so it cannot inherit it).
# spawn checks before opening anything: the prompt file is readable (made absolute), the role is
# kebab-case (no leading, trailing or double hyphen) and not the reserved name `monitor`, and the model is listed. Under a lock it then
# drops registry rows whose pane is gone (finished rows are kept), refuses a live teammate with the same
# title unless --replace (which closes the old one first), and refuses a 9th live teammate (exit 4).
# A finished row with the same title is superseded by the new session and dropped. The monitor
# pane (layout dash) does not count toward the 8.
# Every pane/tab is titled <team>-<role> (Claude's own terminal-title updates are disabled so it sticks;
# ArcaTerm: tabs only, see Layout),
# and the session is started as `claude --session-id <uuid> --name <team>-<role>` with TEAM_MEMBER=<team>-<role>
# in its env; the uuid is generated per spawn and recorded in the registry row.
# Every teammate gets teammate-rules.md appended to its system prompt (parallelise with
# subagents, verify what they return), plus the caveman output style unless --no-caveman.
# Only a fresh spawn does: `spawn --resume` replays the system prompt recorded at the session's first
# request and silently ignores a new one, so anything a resumed teammate must be told goes in <prompt-file>.
# Every teammate runs with CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4, and with
# CLAUDE_CODE_SUBAGENT_MODEL=<newest sonnet> when `pick-model sonnet` finds one exactly (omitted on fallback).
# Layout: default splits the lead's tab -- teammates fill a two-column grid to the right of the lead.
# --tabs: one tab per teammate in the lead's workspace (ArcaTerm: a child tab of the lead's tab) instead.
# --tmux was removed (cmux or ArcaTerm only): exit 2.
# ArcaTerm types the launch command into the new pane's shell, so spawn writes it to
# $TEAM_REG_DIR/team-<team>-<role>.launch.sh and types only `bash <that file>`; close and reap remove it.
# ArcaTerm titles a split pane itself (its process or agent), so only a --tabs teammate carries <team>-<role>.
# Models: /team offers only opus- and sonnet-tier models (by `behavesAs`, so GLM/Kimi and every other
# haiku-tier id are not offered and spawn refuses them, exit 3). With no [model] a teammate gets the
# newest opus (`pick-model opus`). Every teammate uses TEAM_PERMISSION_MODE (default auto).
# Spawned tabs/panes are recorded in $TEAM_REG_DIR/team-<team>.tabs (default /tmp; tests point it at a
# scratch dir so they never read or rewrite live registries), one row each (written by _reg_add):
# "<backend:cmux|arcaterm> <ref> <layout:pane|tab|dash> <title> <model|-> <subagent-model|-> <run-dir|-> <project-root>
#  <state:live|finished> <session-id|-> <cwd>". <state> is `finished` once `finish` closed the teammate on
# purpose: such a row is kept by prune and reap (only `close`, which ends the team, drops it), holds no cap
# slot and does not block a respawn; it is the record a resume reads its session id and cwd from. Rows older than rev5 stop at
# <project-root> and count as live. Rows older than rev4 have no <project-root> (reap derives it from a <run-dir> under <root>/.team/runs/, else
# treats it as unknown). Paths with whitespace never match a project root, so such rows are never reaped.
set -euo pipefail
# Dispatch: anything not listed is refused here, because an unknown word would
# otherwise fall through to the spawn path below and open a real pane.
subs="init lead-title reap clean close finish models pick-model role roles role-pull role-promote status monitor sync tickets integrate facts-lint doccheck show list spawn"
here=$(cd "$(dirname "$0")" && pwd)
_usage() { sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
case ${1:-} in
  -h|--help|help) _usage; exit 0 ;;
  '') _usage >&2; exit 2 ;;
esac
case " $subs " in
  *" $1 "*) ;;
  *) echo "team.sh: unknown subcommand '$1' (see: team.sh --help)" >&2; exit 2 ;;
esac
sub=$1; shift
# Secret/PII pattern (grep -Ei). facts-lint --pre-append refuses on a hit, scanning
# through _secret_lines (stdin -> "n:line" per hit).
# Git remotes (git@host:org/repo, ssh://git@host/...) are not emails: _secret_lines turns
# the "git@" user into "git " first, so every other address still hits, whatever follows it.
secret='(dapi|dose)[0-9a-f]{32}|gh[pousr]_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{22,}|sk-(ant|proj|svcacct)-[0-9A-Za-z_-]{16,}|sk-[0-9A-Za-z]{16}|AKIA[0-9A-Z]{16}|(xox[abposr]|xapp)-[0-9A-Za-z-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[0-9A-Za-z_-]{8,}\.eyJ[0-9A-Za-z_-]{8,}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
_secret_lines() { sed -E 's/(^|[^A-Za-z0-9._%+-])git@/\1git /g' | grep -nEi -- "$secret"; }

# --- Helpers. lib/*.sh may call these; keep their names and output stable. ---
# The main checkout's root, also from inside a linked worktree or a submodule (the first
# porcelain row is always the main worktree). Outside git, `git` fails, pipefail makes the
# pipeline fail, and it falls back to $PWD.
_root() { git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p' || pwd; }
_roles_lib() { echo "${TEAM_ROLES_DIR:-$HOME/.claude/team/roles}"; }
_reg_dir() { echo "${TEAM_REG_DIR:-/tmp}"; }
_reg() { echo "$(_reg_dir)/team-$1.tabs"; }
_need_py() {
  command -v python3 >/dev/null 2>&1 && return 0
  echo "team.sh: python3 is required for '$sub' but was not found on PATH" >&2; exit 3
}

# Models available here. The option list is org-managed (managed-settings.json) and
# changes without notice, so it is read at run time instead of hardcoded. Emits
# "<label>TAB<id>TAB<tier>", best tier first. `behavesAs` is the capability tier a
# model is gated at, which is what decides whether it fits a role.
_team_models() {
  _need_py
  python3 - <<'PY'
import json, os, re
options = None
paths = ([os.environ["TEAM_MODELS_FILE"]] if os.environ.get("TEAM_MODELS_FILE") else
         ["/Library/Application Support/ClaudeCode/managed-settings.json",
          os.path.expanduser("~/.claude/settings.json")])
for path in paths:
    try:
        with open(path, encoding="utf-8") as fh:
            picker = json.load(fh).get("modelPicker") or {}
    except Exception:
        continue
    if picker.get("options"):
        options = picker["options"]
        break

rows = []
if options:
    for o in options:
        mid = o.get("model") or ""
        if not mid:
            continue
        hit = re.search(r"opus|sonnet|haiku", o.get("behavesAs") or mid)
        rows.append((o.get("label") or mid, mid, hit.group(0) if hit else "?"))
else:
    # No managed picker: the built-in aliases are all that can be relied on.
    rows = [("Opus", "opus", "opus"), ("Sonnet", "sonnet", "sonnet")]

# Only opus and sonnet tier are offered: a teammate on anything cheaper (haiku, or a model that
# behaves as haiku) is not worth its session, and dontAsk allowlists do not survive managed
# settings that keep only managed permission rules.
rows = [r for r in rows if r[2] in ("opus", "sonnet")]
order = {"opus": 0, "sonnet": 1}
rows.sort(key=lambda r: order[r[2]])
for r in rows:
    print("\t".join(r))
PY
}

# Newest claude-* model of a tier (user decision: version beats the org's list order;
# equal versions keep list order). Non-claude models that behave as a tier (GLM, Kimi) are
# only ever used by explicit id. An empty opus tier falls back to sonnet:
# warning on stderr, return 1. Return 2 = bad tier, 3 = nothing at or below the tier.
_pick_model() {
  case ${1:-} in opus|sonnet) ;; *) echo "pick-model: tier must be opus|sonnet" >&2; return 2 ;; esac
  local rows; rows=$(_team_models) || return 3
  printf '%s\n' "$rows" | python3 -c '
import re, sys
want = sys.argv[1]; chain = ["opus", "sonnet"]
rows = [l.rstrip("\n").split("\t") for l in sys.stdin if l.count("\t") == 2]
def key(mid):
    base = re.sub(r"\[.*?\]", "", mid).rsplit(".", 1)[-1]
    return tuple(int(x) for x in re.findall(r"\d+", base))
for t in chain[chain.index(want):]:
    mids = [m for _, m, tier in rows if tier == t and ("claude-" in m or m == t)]
    if mids:
        best = max(mids, key=key)
        if t != want:
            print(f"warn: no {want}-tier claude model; falling back to {t} ({best})", file=sys.stderr)
            print(best); sys.exit(1)
        print(best); sys.exit(0)
print(f"pick-model: no claude model at or below tier {want}", file=sys.stderr); sys.exit(3)
' "$1"
}

# Tier of a model id or alias (opus|sonnet), or nothing when it is not offered.
_model_tier() {
  case ${1:-} in opus|sonnet) echo "$1"; return 0 ;; ''|-) return 0 ;; esac
  _team_models | awk -F'\t' -v m="$1" '$2==m{print $3; exit}'
}
# 0 when a recorded model id is no longer offered here, so the pane's next call will fail.
_model_gone() {
  case ${1:-} in ''|-|opus|sonnet) return 1 ;; esac
  ! _team_models | awk -F'\t' -v m="$1" '$2==m{f=1} END{exit !f}'
}

# cmux pane ref holding surface $1, or "gone". identify still exits 0 for a surface that is
# gone, returning a null pane_ref, so treat null/missing as "gone" rather than trusting the exit status.
_pane_of() {
  cmux identify --surface "$1" 2>/dev/null \
    | python3 -c 'import json,sys; c=json.load(sys.stdin).get("caller") or {}; print(c.get("pane_ref") or "gone")' 2>/dev/null \
    || echo gone
}
# "<pane_ref> <surface_ref>" of the calling session (the lead), or empty. ArcaTerm has no surfaces
# inside panes, so there both are the caller's pane id.
_lead_pane() {
  # TEAM_LEAD_PANE overrides discovery: inside the monitor pane `cmux identify`
  # would resolve the monitor itself as the lead, so `show` dispatched from the
  # monitor's key handler would focus into the wrong pane.
  if [ -n "${TEAM_LEAD_PANE:-}" ]; then printf '%s\n' "$TEAM_LEAD_PANE"; return 0; fi
  if [ "$(_backend)" = arcaterm ]; then
    local s; s=$(_at_self)
    [ -z "$s" ] || echo "${s%% *} ${s%% *}"
    return 0
  fi
  cmux identify 2>/dev/null \
    | python3 -c 'import json,sys; c=json.load(sys.stdin).get("caller") or {}; print(c.get("pane_ref") or "", c.get("surface_ref") or "")' 2>/dev/null || true
}
# 0 if the recorded pane/surface still exists. Only a definite "gone" answer counts as dead:
# a missing tool, an unreachable cmux, or unparseable output keeps the row (never prune blind).
_alive() {
  local out
  case $1 in
    cmux)
      command -v cmux >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 0
      out=$(cmux identify --surface "$2" 2>&1) || { case $out in *not_found*) return 1 ;; esac; return 0; }
      printf '%s' "$out" | python3 -c '
import json, sys
try: c = json.load(sys.stdin).get("caller")
except Exception: sys.exit(0)
sys.exit(1 if isinstance(c, dict) and not c.get("pane_ref") else 0)' ;;
    arcaterm)
      # Gone only when the snapshot was read and the pane is not in it.
      command -v arcaterm >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 0
      out=$(_at_panes) || return 0
      [ -n "$(_at_line "$2" "$out")" ] ;;
    *) return 0 ;;   # legacy tmux rows: tmux support is gone, never prune them blind
  esac
}
# The terminal this call runs in (see the header): TEAM_BACKEND wins, then a cmux pane, then an
# ArcaTerm pane, else cmux, so running outside both still gets cmux's install hint.
_backend() {
  if [ -n "${TEAM_BACKEND:-}" ]; then echo "$TEAM_BACKEND"
  elif [ -n "${CMUX_SURFACE_ID:-}${CMUX_WORKSPACE_ID:-}" ]; then echo cmux
  elif [ -n "${MACTERM_SESSION:-}" ]; then echo arcaterm
  else echo cmux; fi
}
# Pane commands need a live cmux: fail fast (exit 3) with an install hint instead of opening
# nothing. `ws`: also require running inside a cmux pane (the lead's workspace and surface).
_cmux_min=0.65.0
_require_cmux() {
  command -v cmux >/dev/null 2>&1 || {
    echo "team.sh: '$sub' needs cmux >= $_cmux_min, which is not on PATH. Install it (brew install --cask cmux, https://www.cmux.dev/) and run /team from a cmux pane." >&2; exit 3; }
  [ "$(cmux ping 2>/dev/null)" = PONG ] || {
    echo "team.sh: '$sub' needs cmux, but 'cmux ping' got no PONG; start the cmux app (or check \$CMUX_SOCKET_PATH)." >&2; exit 3; }
  local v; v=$(cmux --version 2>/dev/null | awk '{print $2}')
  awk -v a="$v" -v b="$_cmux_min" 'BEGIN{split(a,x,"."); split(b,y,".")
    for (i=1;i<=3;i++) { if (x[i]+0 > y[i]+0) exit 0; if (x[i]+0 < y[i]+0) exit 1 } exit 0}' || {
    echo "team.sh: '$sub' needs cmux >= $_cmux_min, found '${v:-unknown}'; update it (brew upgrade --cask cmux)." >&2; exit 3; }
  [ "${1:-}" != ws ] || { [ -n "${CMUX_WORKSPACE_ID:-}" ] && [ -n "${CMUX_SURFACE_ID:-}" ]; } || {
    echo "team.sh: '$sub' must run inside a cmux pane (CMUX_WORKSPACE_ID/CMUX_SURFACE_ID are unset)." >&2; exit 3; }
}
# The same check for whichever backend this call runs in (_backend).
_require_term() {
  case $(_backend) in
    cmux) _require_cmux "$@" ;;
    arcaterm)
      declare -F _at_require >/dev/null || { echo "team.sh: '$sub' needs $here/lib/arcaterm.sh, which is missing" >&2; exit 3; }
      _at_require "$@" ;;
    *) echo "team.sh: TEAM_BACKEND must be cmux or arcaterm, not '$TEAM_BACKEND'" >&2; exit 2 ;;
  esac
}
# Force-close <ref> of backend $1 (a running teammate needs the force). 0 closed or already gone;
# otherwise the reason on stdout and 1, so callers keep the row for a retry.
_term_close() {
  local err
  case $1 in
    arcaterm) _at_close "$2" ;;
    *) err=$(cmux close-surface --surface "$2" --force 2>&1 >/dev/null) && return 0
       case $err in *not_found*) return 0 ;; esac
       printf '%s\n' "$err"; return 1 ;;
  esac
}
# The lead's name in the workspace title, its tab title and the Claude session name.
_lead_title() { echo "Main Board - $(basename "$(_root)")"; }
# The one writer of registry rows: <ref> <layout> <title> <model|-> <submodel|-> <rundir|-> <session-id|-> <cwd>,
# written as "cmux <ref> .. <rundir> <project-root> live <session-id> <cwd>". The project root (col 8) scopes
# `reap`; cols 9-11 come after it because reap reads cols 7-8 by position. <cwd> is last so a path with
# spaces still reads whole (`read ... cwd`), and it is where the session's transcript is keyed.
_reg_add() {
  local team=$1; shift
  echo "$(_backend) $1 $2 $3 $4 $5 $6 $(_root) live ${7:--} ${8:--}" >> "$(_reg "$team")"
}
# 0 when a registry row (whole line) carries the terminal marker: its teammate was finished on purpose
# (`team.sh finish`), its pane is gone by design, and the row holds the session id to resume from.
_finished() { [ "$(awk '{print $9}' <<<"$1")" = finished ]; }
# A report's last mandatory section header (plain, bold or heading markdown); `finish` counts these.
# No `>`: a blockquoted PARALLELISM: is a peer's report being quoted, not this teammate's trailer.
_trailer='^[#*_ -]*PARALLELISM:'
# Project root of a row (col 7 run dir, col 8 root), as a physical path, or nothing when unknown.
# Rows older than rev4 have no root: derive it from a run dir under <root>/.team/runs/.
_row_root() {
  local r=${2:-}
  if [ -z "$r" ] || [ "$r" = - ]; then
    case ${1:-} in */.team/runs/*) r=${1%/.team/runs/*} ;; *) return 0 ;; esac
  fi
  (cd -P "$r" 2>/dev/null && pwd) || echo "$r"
}
# "<surface_ref>TAB<title>TAB<type>" for every live cmux surface (all windows). Closing by ref alone is
# unsafe: a gone surface's small ref can be reused by an unrelated live one, so callers match the title
# (or, for a teammate's browser, the type) too.
_surface_titles() {
  cmux tree --all --json 2>/dev/null | python3 -c '
import json, sys
def walk(o):
    if isinstance(o, dict):
        if str(o.get("ref", "")).startswith("surface:"):
            print(o["ref"] + "\t" + (o.get("title") or "") + "\t" + (o.get("type") or "")); return
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(json.load(sys.stdin))'
}
# _surface_titles for backend $1. A live ArcaTerm pane reads as title "@live": its UUID is never
# reused, so there is no stale ref to guard against and _live_title answers with the row's own title.
_term_titles() {
  case $1 in
    arcaterm) _at_panes | awk -F'\t' -v OFS='\t' '{print $1, "@live", $4}' ;;
    *) _surface_titles ;;
  esac
}
# The live title of ref $2 in _term_titles output $1, or nothing when it is gone ($3: the row's title).
_live_title() {
  local cur; cur=$(awk -F'\t' -v x="$2" '$1==x {print $2; exit}' <<<"$1")
  [ "$cur" != @live ] || cur=$3
  printf '%s' "$cur"
}
# Close the browser surfaces a teammate recorded in <run-dir>/browser/<role>.txt, one ref per line
# (teammate-rules.md has it append every `cmux browser open` / `tab new` ref there), so a teammate
# that skipped its own cleanup does not leave pages open after its pane is gone. $3 = _surface_titles
# output. A browser's title is its page title, so a ref is matched by type instead: only a ref that is
# still a browser surface is closed. Best-effort (warns, never fails the caller); refs that could not be
# closed stay in the file so the next finish/close/reap retries them, and the file goes once none are left.
_close_browsers() {
  local f="$1/browser/$2.txt" left="" r err
  [ "$1" != - ] && [ -s "$f" ] || return 0
  while read -r r _; do
    case $r in surface:*) ;; *) continue ;; esac
    [ "$(awk -F'\t' -v x="$r" '$1==x {print $3; exit}' <<<"$3")" = browser ] || continue
    err=$(cmux close-surface --surface "$r" --force 2>&1 >/dev/null) && err=
    case $err in ''|*not_found*) echo "closed browser $r ($2)" ;;
      *) echo "could not close browser $r ($2): $err" >&2; left+="$r"$'\n' ;; esac
  done < "$f"
  if [ -z "$left" ]; then rm -f "$f"; else printf '%s' "$left" > "$f"; fi
}
# Drop registry rows whose pane is gone, so a reused slug or a dead teammate never holds a
# cap slot, anchors the grid, or blocks a respawn with the same name. A finished row is kept:
# its pane is gone on purpose, and it is the only record of the session id to resume.
_reg_prune() {
  [ -f "$1" ] || return 0
  local keep="" row b r
  while IFS= read -r row; do
    read -r b r _ <<<"$row" || true
    [ -n "${r:-}" ] || continue
    if _finished "$row" || _alive "$b" "$r"; then keep+="$row"$'\n'; fi
  done < "$1"
  printf '%s' "$keep" > "$1.tmp" && mv "$1.tmp" "$1"
}
# Registry lock: anything that reads-then-appends the registry holds it. mkdir is atomic; a
# lock whose holder pid is dead is broken, a live one is waited on for up to 30s, then exit 4.
# Released on exit via an EXIT trap, which replaces any earlier EXIT trap: call once per process.
_lock() {
  local lock="$1.lock" i holder
  for i in $(seq 1 300); do
    if mkdir "$lock" 2>/dev/null; then echo $$ > "$lock/pid"; trap 'rm -rf "'"$lock"'"' EXIT; return 0; fi
    holder=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
    sleep 0.1
  done
  echo "registry lock busy: $lock (another spawn/monitor is running; remove it if not)" >&2; exit 4
}
# Distinct titles of live teammate rows (layout pane|tab; the dash monitor is not a teammate, and a
# finished teammate has no session running, so neither holds one of the 8 slots).
_mates() { [ -f "$1" ] || return 0; awk '($3=="pane" || $3=="tab") && $9!="finished" {print $4}' "$1" | sort -u; }

# Libraries: functions only (sub_<name> per subcommand), sourced after the helpers they use,
# so a missing lib only disables its own subcommands.
for _lib in "$here/lib/roles.sh" "$here/lib/status.sh" "$here/lib/arcaterm.sh" "$here/lib/tickets.sh"; do
  # shellcheck source=/dev/null
  if [ -f "$_lib" ]; then . "$_lib"; fi
done
case $sub in
  role|roles|role-pull|role-promote|status|monitor|sync|tickets|integrate)
    fn="sub_${sub//-/_}"
    declare -F "$fn" >/dev/null || {
      case $sub in status|monitor|sync) l=status ;; tickets|integrate) l=tickets ;; *) l=roles ;; esac
      echo "team.sh: '$sub' needs $here/lib/$l.sh, which is missing" >&2; exit 3; }
    "$fn" "$@"; exit $? ;;
esac

if [ "$sub" = init ]; then
  team=${1:?team}
  root=$(_root)
  d="$root/.team"
  mkdir -p "$d/roles" "$d/runs" "${TEAM_ROLES_DIR:-$HOME/.claude/team/roles}"
  [ -f "$d/README.md" ] || cat > "$d/README.md" <<'MD'
# .team — /team skill workspace (git-ignored)
- `facts.md` — verified facts from past runs (consensus only, with evidence). Read before working; flag stale entries.
- `roles/<role>.md` — reusable teammate role specs (lens, owns, constraints, model).
- `runs/<date>-<team>/` — per run: `tasks.md`, `prompts/`, `reports/`, `synthesis.md`.
Never store secrets, PII, or raw data here — conclusions and pointers only.
MD
  [ -f "$d/facts.md" ] || printf '# Facts

<!-- - <fact> — evidence: <file:line | command> @<short-sha> — <YYYY-MM-DD>, run <run-id>  (@nogit outside a repo) -->
' > "$d/facts.md"
  if git -C "$root" rev-parse 2>/dev/null; then
    gi="$root/.gitignore"
    for p in .team/ CLAUDE.local.md; do
      git -C "$root" check-ignore -q "$p" 2>/dev/null && continue
      # A last line with no newline would merge with ours ("node_modules.team/").
      if [ -s "$gi" ] && [ -n "$(tail -c1 "$gi")" ]; then echo >> "$gi"; fi
      echo "$p" >> "$gi"
    done
  fi
  mem="$root/CLAUDE.local.md"
  grep -q '<!-- team-skill -->' "$mem" 2>/dev/null || cat >> "$mem" <<'MD'

<!-- team-skill -->
## /team workspace
`.team/` (git-ignored) holds /team skill state: `.team/facts.md` = verified facts from past team runs (read before investigating this project; treat entries as leads to re-check, not ground truth), `.team/roles/` = reusable teammate roles, `.team/runs/` = past run records.
MD
  run="$d/runs/$(date +%Y-%m-%d)-$team"
  mkdir -p "$run/prompts" "$run/reports"
  echo "$run"
  exit 0
fi

# The lead's name in all three places it shows: the cmux workspace title, the lead's tab title and
# (via SKILL.md) the Claude session name. Targets the caller's workspace and surface explicitly, never
# the focused one. A teammate shares the lead's workspace, so a call from one (TEAM_MEMBER set) is a no-op.
if [ "$sub" = lead-title ]; then
  [ -z "${TEAM_MEMBER:-}" ] || { echo "lead-title: skipped inside teammate $TEAM_MEMBER (only the lead renames)"; exit 0; }
  _require_term ws
  t=$(_lead_title)
  if [ "$(_backend)" = arcaterm ]; then
    # Only the tab: an ArcaTerm group holds the user's other tabs too, so it is never renamed.
    me=$(_at_self)
    [ -n "$me" ] || { echo "lead-title: ArcaTerm did not resolve this pane (MACTERM_SESSION=$MACTERM_SESSION)" >&2; exit 1; }
    _at_rename_tab "$t" "${me#* }"
  else
    cmux rename-workspace --workspace "$CMUX_WORKSPACE_ID" -- "$t" >/dev/null
    cmux rename-tab --surface "$CMUX_SURFACE_ID" -- "$t" >/dev/null
  fi
  echo "$t"
  exit 0
fi

# Leftovers of earlier runs of THIS project. Every registry is read, but a registry is only
# acted on when all of its rows record this project's root: another project's rows are never shown,
# and a row with no root (or a registry that mixes roots) is listed as "unknown project" and never
# closed. Only a live surface whose title still matches its row counts (refs get reused), and the
# caller's own surface is never a candidate. --yes closes them under each registry's lock.
if [ "$sub" = reap ]; then
  yes= excl=
  while [ $# -gt 0 ]; do case $1 in
    --yes) yes=1; shift ;;
    --exclude) excl=${2:?--exclude <team>}; shift 2 ;;
    *) echo "usage: team.sh reap [--yes] [--exclude <team>]" >&2; exit 2 ;;
  esac; done
  _require_term; _need_py
  be=$(_backend)
  me=$(cd -P "$(_root)" && pwd)
  titles=$(_term_titles "$be") || { echo "reap: could not read the $be pane list; nothing done" >&2; exit 1; }
  _lead=$(_lead_pane); leadsurface=${_lead##* }
  today=$(date +%Y-%m-%d)
  rc=0 found=0 unknown=0 dir=$(_reg_dir)
  for reg in "$dir"/team-*.tabs; do
    [ -f "$reg" ] || continue
    t=${reg#"$dir"/team-}; t=${t%.tabs}
    [ "$t" != "$excl" ] || continue
    # Classify the registry: ours only when every row has our root.
    ours=1 any=0
    while read -r b r _ _ _ _ rd rt _; do
      [ -n "${r:-}" ] || continue
      any=1
      [ "$(_row_root "${rd:-}" "${rt:-}")" = "$me" ] || ours=
    done < "$reg"
    [ "$any" = 1 ] || continue
    keep="" failed= held=
    while IFS= read -r row; do
      read -r b r _ title _ _ rd rt _ <<<"$row" || true
      [ -n "${r:-}" ] || continue
      root=$(_row_root "${rd:-}" "${rt:-}")
      [ -z "$root" ] || [ "$root" = "$me" ] || continue   # another project: never shown
      cur=$(_live_title "$titles" "$r" "$title")
      live=; [ "$b" = "$be" ] && [ -n "$cur" ] && [ "$cur" = "$title" ] && [ "$r" != "$leadsurface" ] && live=1
      if [ -z "$ours" ]; then
        # No (or mixed) project root: may well belong to another project, so only count it.
        [ -z "$live" ] || unknown=$((unknown+1))
        continue
      fi
      # A finished teammate has no pane to close; its row holds the session id, so it is kept.
      if _finished "$row"; then keep+="$row"$'\n'; continue; fi
      # Opened in the other terminal (cmux vs ArcaTerm): this one cannot see it, so it is never dropped.
      case $b in cmux|arcaterm) if [ "$b" != "$be" ]; then
        echo "$t  $title  $b $r  left alone (opened in $b; reap it from there)"; keep+="$row"$'\n'; held=1; continue
      fi ;; esac
      [ -n "$live" ] || continue   # gone or ref reused: the row is stale and dropped on --yes
      found=1
      # The run dir name tells an earlier run from one another lead session started today.
      run=-; case ${rd:-} in */.team/runs/*) run=$(basename "$rd") ;; esac
      note=; case $run in "$today"-*) note=" (run started today: may be live in another lead session)" ;; esac
      if [ -z "$yes" ]; then echo "$t  $title  $b $r  run $run$note"; keep+="$row"$'\n'; held=1; continue; fi
      err=$(_term_close "$b" "$r") && err=
      if [ -z "$err" ]; then echo "$t  $title  $b $r  closed"; rm -f "$dir/team-$t-${title#"$t"-}.round" "$dir/team-$t-${title#"$t"-}.launch.sh"
        _close_browsers "${rd:--}" "${title#"$t"-}" "$titles"
      else echo "$t  $title  $b $r  could not close: $err" >&2; keep+="$row"$'\n'; held=1; failed=1; fi
    done < "$reg"
    [ -n "$yes" ] && [ -n "$ours" ] || continue
    # Rewrite our registry under its lock (subshell: _lock's EXIT trap releases it per registry).
    ( _lock "$reg"; if [ -z "$keep" ]; then rm -f "$reg"; else printf '%s' "$keep" > "$reg"; fi )
    # A fully reaped team (only finished rows left, if any) must not leave its sidebar pill/progress
    # behind (lib/status.sh; best-effort).
    if [ -z "$held" ] && declare -F sub_sync >/dev/null; then sub_sync --clear "$t" || true; fi
    [ -z "$failed" ] || rc=1
  done
  [ "$found" = 1 ] || echo "reap: no live teammates left from earlier runs of $(basename "$me")"
  [ "$unknown" = 0 ] || echo "reap: $unknown live teammate(s) in registries with no project root left alone (never closed)"
  [ -n "$yes" ] || [ "$found" = 0 ] || echo "reap: re-run with --yes to close the rows above"
  exit "$rc"
fi

if [ "$sub" = clean ]; then
  team=${1:?team}
  root=$(_root)
  for wt in "$root"/.team/worktrees/"$team"-*; do
    [ -d "$wt" ] || continue
    if git -C "$root" worktree remove "$wt" 2>/dev/null; then echo "removed $wt"
    else echo "kept $wt (uncommitted changes)"; fi
  done
  exit 0
fi

if [ "$sub" = close ]; then
  team=${1:?team}; reg=$(_reg "$team")
  [ -f "$reg" ] || { echo "no tabs recorded for $team"; exit 0; }
  _require_term; _need_py
  be=$(_backend)
  _lock "$reg"
  titles=$(_term_titles "$be") || { echo "close: could not read the $be pane list; nothing closed" >&2; exit 1; }
  # Teammates are live claude sessions, and cmux refuses to close a surface with a
  # running process unless forced. A pane that is already gone counts as closed, and so does
  # a ref now held by a surface with another title (the ref was reused: never close it);
  # any other failure is reported and its row kept, so a re-run can retry it.
  # `close` ends the team, so finished rows (no pane; closed by `finish`) are dropped too: no later
  # round resumes them, and a kept row would leak into the next team that reuses this slug.
  keep=""
  while IFS= read -r row; do
    read -r backend id _ title _ _ rd _ <<<"$row" || true
    [ -n "${id:-}" ] || continue
    rm -f "$(_reg_dir)/team-$team-${title#"$team"-}.round" "$(_reg_dir)/team-$team-${title#"$team"-}.launch.sh"
    _close_browsers "${rd:--}" "${title#"$team"-}" "$titles"
    if _finished "$row"; then echo "dropped finished $title (no pane)"; continue; fi
    case $backend in
      cmux|arcaterm) if [ "$backend" != "$be" ]; then
        echo "kept $backend $id ($title): opened in $backend, which this $be pane cannot close; run close from $backend" >&2
        keep+="$row"$'\n'; continue
      fi ;;
      *) echo "dropped $backend $id ($title): only cmux and ArcaTerm panes are closed now; close it by hand"; continue ;;
    esac
    cur=$(_live_title "$titles" "$id" "$title")
    if [ -z "$cur" ]; then echo "closed $backend $id (already gone)"; continue; fi
    if [ "$cur" != "$title" ]; then echo "skipped $backend $id: now titled '$cur', not '$title' (ref reused); row dropped"; continue; fi
    err=$(_term_close "$backend" "$id") && err=
    if [ -z "$err" ]; then echo "closed $backend $id"
    else echo "could not close $backend $id: $err" >&2; keep+="$row"$'\n'; fi
  done < "$reg"
  # Clear the lead sidebar pill/progress for this team (lib/status.sh); best-effort.
  if declare -F sub_sync >/dev/null; then sub_sync --clear "$team" || true; fi
  [ -z "$keep" ] && { rm -f "$reg"; exit 0; }
  printf '%s' "$keep" > "$reg"; exit 1
fi

if [ "$sub" = models ]; then
  _need_py
  _team_models | awk -F'\t' '
    {l[NR]=$1; m[NR]=$2; t[NR]=$3
     if (length($1)>a) a=length($1); if (length($2)>b) b=length($2)}
    END {for (i=1;i<=NR;i++) {
           s=l[i]; while (length(s)<a) s=s" "
           u=m[i]; while (length(u)<b) u=u" "
           print s"  "u"  ["t[i]"]"}}'
  exit 0
fi

if [ "$sub" = pick-model ]; then
  _need_py
  _pick_model "${1:-}"; exit $?
fi

# Facts ledger health. Default: classify each fact in .team/facts.md by freshness of its
# SHA-anchored evidence (FRESH = cited file unchanged since the SHA; CHECK = changed or
# unanchorable; GONE = cited file deleted; NOANCHOR = legacy/@nogit line) and flag exact
# duplicate facts (DUP). With --pre-append <file>: scan <file> for secret/PII patterns and
# refuse (exit 2) on a hit, before new facts are written. Pure bash + git, no python3.
if [ "$sub" = facts-lint ]; then
  if [ "${1:-}" = --pre-append ]; then
    f=${2:?file to scan}
    if _secret_lines < "$f"; then
      echo "facts-lint: secret/PII pattern above — refusing to append" >&2; exit 2
    fi
    echo "facts-lint: no secret/PII pattern found in $f"; exit 0
  fi
  root=$(_root)
  facts="$root/.team/facts.md"
  [ -f "$facts" ] || { echo "no $facts" >&2; exit 3; }
  while IFS= read -r line; do
    case $line in
      '- '*) [ "${line#- \~\~}" = "$line" ] || continue ;;  # skip struck-through facts
      *) continue ;;
    esac
    sha=$(printf '%s\n' "$line" | sed -n 's/.*@\([0-9a-f]\{7,40\}\).*/\1/p')
    # || true: evidence with no file:line makes grep exit 1, which pipefail + set -e
    # would turn into a silent abort of the whole lint.
    file=$(printf '%s\n' "$line" | grep -oE '[A-Za-z0-9_./-]+:[0-9]+' | head -1 | cut -d: -f1 || true)
    if printf '%s\n' "$line" | grep -q '@nogit' || [ -z "$sha" ]; then st=NOANCHOR
    elif [ -z "$file" ]; then st=CHECK
    elif [ ! -e "$root/$file" ] && [ ! -e "$file" ]; then st=GONE
    elif git -C "$root" diff --quiet "$sha" -- "$file" 2>/dev/null; then st=FRESH
    else st=CHECK
    fi
    printf '%s\t%s\n' "$st" "$line"
  done < "$facts"
  # exact-duplicate fact text (the part before " — evidence"); || true so an empty
  # ledger (grep finds no facts, exits 1) doesn't trip set -o pipefail.
  { grep -E '^- ' "$facts" | grep -v '^- ~~' | sed 's/ — evidence:.*//' \
    | sort | uniq -d | while IFS= read -r d; do [ -n "$d" ] && printf 'DUP\t%s\n' "$d"; done; } || true
  exit 0
fi

# Deterministic doc-drift guard (the user's rule: deterministic checks belong in a hook,
# not prose). Flags retired drift phrases, confirms every subcommand is documented in the
# header, and confirms every --flag in SKILL.md's argument-hint is explained in HELP.md.
# Exit 1 if anything is off. Edit the owner file (see CLAUDE.md), then re-run.
if [ "$sub" = doccheck ]; then
  rc=0
  for pat in 'inherit the lead' 'stacked' '3–5' '2–5' 'as much as possible' '--tmux' 'tmux pane' 'tmux attach' 'tmux session' 'team.sh park' 'superpowers:' 'dontAsk' 'no-mistakes' '--no-gate' 'gate-init'; do
    grep -rnF -- "$pat" "$here/SKILL.md" "$here/HELP.md" "$here/README.md" 2>/dev/null && rc=1
  done
  hdr=$(sed '/^set -euo pipefail/q' "$here/team.sh")
  for s in $subs; do
    printf '%s\n' "$hdr" | grep -qw -- "$s" || { echo "doccheck: subcommand '$s' not documented in the header" >&2; rc=1; }
  done
  for fl in $(sed -n '4p' "$here/SKILL.md" | grep -oE '\-\-[a-z-]+'); do
    grep -qF -- "$fl" "$here/HELP.md" || { echo "doccheck: $fl is in SKILL.md but not HELP.md" >&2; rc=1; }
  done
  [ "$rc" = 0 ] && echo "doccheck: ok"
  exit "$rc"
fi

# Finish one teammate whose report the lead has received: persist its row as `finished` (session id
# + cwd kept for a resume), then close its pane to free the session. An explicit lead action, never
# inferred from polling the filesystem. Refuses (exit 2, nothing changed) unless the round's work is
# durable: the report grew past the size recorded when this session was spawned and has more
# `PARALLELISM:` headers (the report's last mandatory section) than it had then, `tasks.md` has
# "- [x] <team>-<role>:", and a --worktree teammate's worktree has no uncommitted changes (a forced
# close kills the session, so uncommitted code would be lost). The marker is written under the
# registry lock BEFORE the close, so a failed close leaves a finished row and a re-run retries it.
if [ "$sub" = finish ]; then
  team=${1:?usage: team.sh finish <team> <role>} role=${2:?usage: team.sh finish <team> <role>}
  title="$team-$role" reg=$(_reg "$team")
  _need_py; _require_term
  be=$(_backend)
  [ -f "$reg" ] || { echo "finish: no teammates recorded for $team" >&2; exit 3; }
  _lock "$reg"
  n=$(awk -v t="$title" '$4==t && ($3=="pane" || $3=="tab") {n=NR} END{print n+0}' "$reg")
  [ "$n" -gt 0 ] || { echo "finish: no recorded teammate $title" >&2; exit 3; }
  row=$(sed -n "${n}p" "$reg")
  read -r b ref lay _ mdl smdl rd rt st sid cwd <<<"$row" || true
  if [ -z "${cwd:-}" ] || [ "$cwd" = - ]; then
    cwd=-; [ -d "$(_root)/.team/worktrees/$title" ] && cwd="$(_root)/.team/worktrees/$title"
  fi
  if [ "${st:-}" != finished ]; then
    [ -n "${rd:-}" ] && [ "$rd" != - ] || { echo "finish: refused: $title has no run dir, so its report cannot be checked" >&2; exit 2; }
    rep="$rd/reports/$role.md"
    [ -s "$rep" ] || { echo "finish: refused: $rep is missing or empty" >&2; exit 2; }
    # Baseline written by spawn: "<bytes> <PARALLELISM: lines>" of the report when this session
    # started (none: an empty report). Counting the trailer lines is order-independent: a round's
    # block inserted above the previous round's trailer must still add a trailer of its own.
    bb=0 bn=0; round="$(_reg_dir)/team-$team-$role.round"
    if [ -f "$round" ]; then read -r bb bn _ < "$round" || true; fi
    case ${bb:-} in ''|*[!0-9]*) bb=0 ;; esac; case ${bn:-} in ''|*[!0-9]*) bn=0 ;; esac
    size=$(wc -c < "$rep" | tr -d ' ')
    np=$(grep -cE "$_trailer" "$rep" || true)
    [ "$size" -gt "$bb" ] || {
      echo "finish: refused: $rep did not grow since $title was spawned (recorded $bb bytes, now $size): no new report this round" >&2; exit 2; }
    [ "$np" -gt "$bn" ] || {
      echo "finish: refused: $rep has no new PARALLELISM: section this round ($bn at spawn, $np now): report incomplete or still being written" >&2; exit 2; }
    grep -qF -e "- [x] $title:" -e "- [X] $title:" "$rd/tasks.md" 2>/dev/null || {
      echo "finish: refused: $rd/tasks.md has no '- [x] $title:' line" >&2; exit 2; }
    case $cwd in
      "$(_root)"/.team/worktrees/*)
        # Fail closed: a git status that cannot run is treated as "maybe dirty".
        dirty=$(git -C "$cwd" status --porcelain 2>&1) || {
          echo "finish: refused: cannot check worktree $cwd for uncommitted changes: $dirty" >&2; exit 2; }
        # Untracked files count: a new source file not yet committed is unfinished work. The paths are
        # named so the lead can tell scratch from real work.
        [ -z "$dirty" ] || {
          echo "finish: refused: worktree $cwd has uncommitted changes (untracked files included); $title has not finished committing. Have it commit, or remove scratch files:" >&2
          printf '%s\n' "$dirty" | head -5 | sed 's/^/  /' >&2
          [ "$(printf '%s\n' "$dirty" | wc -l)" -le 5 ] || echo "  ... $(( $(printf '%s\n' "$dirty" | wc -l) - 5 )) more" >&2
          exit 2; } ;;
    esac
    new_row="$b $ref $lay $title ${mdl:--} ${smdl:--} $rd ${rt:--} finished ${sid:--} $cwd"
    NEW_ROW=$new_row awk -v n="$n" 'NR==n {print ENVIRON["NEW_ROW"]; next} 1' "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
    rm -f "$(_reg_dir)/team-$team-$role.round"
    echo "finished $title (session ${sid:--}, cwd $cwd)"
  else
    echo "$title was already finished; retrying the close"
  fi
  rc=0
  if [ "$b" = "$be" ]; then
    titles=$(_term_titles "$be") || { echo "finish: could not read the $be pane list; row is finished, re-run finish to close the pane" >&2; exit 1; }
    cur=$(_live_title "$titles" "$ref" "$title")
    if [ -z "$cur" ]; then echo "pane $ref already gone"
    elif [ "$cur" != "$title" ]; then echo "pane $ref now titled '$cur', not '$title' (ref reused); not closed"
    else
      err=$(_term_close "$b" "$ref") && err=
      if [ -z "$err" ]; then echo "closed $b $ref"
      else echo "finish: could not close $b $ref: $err (row is finished; re-run finish to retry)" >&2; rc=1; fi
    fi
    _close_browsers "${rd:--}" "$role" "$titles"
  elif [ "$b" = cmux ] || [ "$b" = arcaterm ]; then
    echo "finish: $title's pane was opened in $b, which this $be pane cannot close (row is finished; re-run finish from $b, or close the pane by hand)" >&2; rc=1
  fi
  if declare -F sub_sync >/dev/null; then sub_sync "$team" || true; fi
  exit "$rc"
fi

# `show` brings a teammate's session to the front: a teammate that is a tab in the lead's pane
# (--tabs layout) is moved out into its own pane first. It deliberately takes focus off the lead:
# its job is surfacing a teammate blocked on a prompt (tool-permission prompts raise no
# notification). `list` prints each teammate's state.
if [ "$sub" = show ] || [ "$sub" = list ]; then
  team=${1:?team}; reg=$(_reg "$team")
  _need_py
  _require_term ws
  be=$(_backend)
  [ -f "$reg" ] || { echo "no teammates recorded for $team"; exit 3; }
  _lead=$(_lead_pane)
  leadpane=${_lead%% *}
  [ -n "$leadpane" ] || { echo "could not resolve this session's pane — run show/list from the lead's pane"; exit 3; }

  if [ "$sub" = list ]; then
    # Teammates only (layout pane|tab): the dash monitor is not a teammate. MODEL_GONE: the
    # teammate's or its subagents' model left the picker, so its next call fails; respawn it.
    # States: working (<pane>) | tab (in your pane, running) | finished | dead | unknown.
    # ArcaTerm: one snapshot serves every row; a pane whose claude session exited is dead too.
    panes=; [ "$be" != arcaterm ] || panes=$(_at_panes) || panes=
    while IFS= read -r row; do
      read -r b ref lay name mdl smdl _ <<<"$row" || true
      [ -n "${ref:-}" ] || continue
      case ${lay:-} in pane|tab) ;; *) continue ;; esac
      gone=""
      if _model_gone "${mdl:-}" || _model_gone "${smdl:-}"; then gone="  MODEL_GONE"; fi
      if _finished "$row"; then st=finished
      elif [ "$b" = arcaterm ] && [ "$be" = arcaterm ]; then
        line=$(_at_line "$ref" "$panes")
        if [ -z "$panes" ]; then st="unknown (ArcaTerm gave no pane list)"
        elif [ -z "$line" ]; then st=dead
        else
          case $(cut -f5 <<<"$line") in
            stopped) st="dead (its claude session exited; the pane is still open)" ;;
            unavailable) st="unknown (ArcaTerm cannot observe its pane $ref)" ;;
            *) st="working ($ref)" ;;
          esac
        fi
      elif [ "$b" != cmux ] || [ "$be" != cmux ]; then st="unknown ($b $ref)"
      elif ! _alive "$b" "$ref"; then st=dead   # only a definite "not found" counts as dead
      else
        pp=$(_pane_of "$ref")
        case "$pp" in
          gone) st="unknown (cmux did not resolve its pane)" ;;
          "$leadpane") st="tab (in your pane, running)" ;;
          *) st="working ($pp)" ;;
        esac
      fi
      echo "${name:-?}  $st  model=${mdl:--}$gone"
    done < "$reg"
    exit 0
  fi

  role=${2:?role}; title="$team-$role"
  row=$(awk -v t="$title" -v b="$be" '$1==b && ($3=="pane" || $3=="tab") && $4==t {r=$0} END{print r}' "$reg")
  ref=$(awk '{print $2}' <<<"$row")
  [ -n "$ref" ] || { echo "no recorded pane for $title (not spawned)"; exit 3; }
  if _finished "$row"; then echo "$title is finished (no pane); spawn it again to give it more work"; exit 3; fi
  if [ "$be" = arcaterm ]; then
    # ArcaTerm has no tabs inside panes, so nothing is moved: focusing the pane selects its tab too.
    _alive arcaterm "$ref" || { echo "$title is gone; respawn it"; exit 3; }
    _at_focus "$ref" || { echo "show: ArcaTerm could not focus $title's pane ($ref); pane focus works only on the Mac. Open its tab by hand" >&2; exit 1; }
    echo "showing $title ($ref, focused)"
    exit 0
  fi
  _alive cmux "$ref" || { echo "$title is gone; respawn it"; exit 3; }
  cur=$(_pane_of "$ref")
  # Alive but unresolved: cmux is failing, not the teammate. Never suggest a respawn (or --replace) here.
  [ "$cur" != gone ] || { echo "show: cmux did not resolve $title's pane ($ref); it may still be running. Retry, or check cmux" >&2; exit 1; }
  if [ "$cur" = "$leadpane" ]; then
    # Extend the teammate region rather than shrinking the lead: hang it off whoever
    # is already working, and only split the lead when no teammate is visible.
    anchor=""
    for r in $(awk '$1=="cmux" && ($3=="pane" || $3=="tab") && $9!="finished" {print $2}' "$reg"); do
      pr=$(_pane_of "$r")
      [ "$pr" != "$leadpane" ] && [ "$pr" != gone ] && anchor="$r"
    done
    if [ -n "$anchor" ]; then ph=$(cmux new-split down --surface "$anchor" --focus false | awk '{print $2}')
    else ph=$(cmux new-split right --surface "$CMUX_SURFACE_ID" --focus false | awk '{print $2}'); fi
    cur=$(_pane_of "$ph")
    cmux move-surface --surface "$ref" --pane "$cur" --focus false >/dev/null
    cmux close-surface --surface "$ph" >/dev/null 2>&1 || true
  fi
  # Moving a surface into the pane it is already in, with focus, brings it to the front.
  cmux move-surface --surface "$ref" --pane "$cur" --focus true >/dev/null
  echo "showing $title ($cur, focused)"
  exit 0
fi

layout=pane worktree= caveman=1 replace= resume=
while :; do case ${1:-} in
  --resume) resume=1; shift ;;
  --tmux) echo "--tmux was removed in rev4: /team runs in cmux or ArcaTerm (run it from one of their panes)" >&2; exit 2 ;;
  --tabs) layout=tab; shift ;; --worktree) worktree=1; shift ;;
  --replace) replace=1; shift ;; --no-caveman) caveman=; shift ;; *) break ;;
esac; done
spawn_usage="usage: team.sh spawn [--tabs] [--worktree] [--replace] [--resume] [--no-caveman] <team> <role> <prompt-file> [model]"
team=${1:?$spawn_usage} role=${2:?$spawn_usage} pfile=${3:?$spawn_usage} model=${4:-}
[ $# -le 4 ] || { echo "$spawn_usage (flags go before <team>; got extra: ${*:5})" >&2; exit 2; }

# Everything below up to the lock is a check: nothing is created and no pane opens until
# all of them pass. `monitor` is reserved for the status pane (title <team>-monitor), and a
# leading/trailing hyphen would make a title that collides with another team's.
case $role in
  ''|-*|*-|*--*|*[!a-z0-9-]*) echo "role names are kebab-case: '$role'" >&2; exit 2 ;;
  monitor) echo "role name 'monitor' is reserved for the status pane (team.sh monitor)" >&2; exit 2 ;;
esac
# The prompt is read with `cat` inside the pane, after `cd` into the teammate's dir, so a
# missing file or a relative path would start the teammate with an empty prompt.
[ -f "$pfile" ] && [ -r "$pfile" ] || { echo "prompt file not readable: $pfile" >&2; exit 2; }
pfile="$(cd "$(dirname "$pfile")" && pwd)/$(basename "$pfile")"
_need_py
_require_term ws
be=$(_backend)

# A wrong model does not fail the spawn: claude exits 0, the pane opens, and the
# session is dead on arrival -- easy to miss entirely once the teammate is out of sight
# into a tab. So reject an unknown model here, before any worktree or pane exists.
if [ -n "$model" ]; then
  model_ok=
  case "$model" in opus|sonnet) model_ok=1 ;; esac
  if [ -z "$model_ok" ] && _team_models | awk -F'\t' -v m="$model" '$2==m{f=1} END{exit !f}'; then model_ok=1; fi
  if [ -z "$model_ok" ]; then
    echo "model not offered: $model (/team offers opus- and sonnet-tier models only)" >&2
    echo "available (alias opus|sonnet also accepted):" >&2
    _team_models | awk -F'\t' '{print "  "$2"  ["$3"]"}' >&2
    exit 3
  fi
fi
if [ -z "$model" ]; then
  # No [model]: opus, the default for every role except ticket implementers (sonnet). Never
  # claude's own default model, which may be one /team does not offer.
  model=$(_pick_model opus 2>/dev/null) || { echo "spawn: no opus- or sonnet-tier model is offered here (team.sh models)" >&2; exit 3; }
  echo "note: no model given for $team-$role; using $model (pass one per role: team.sh pick-model opus|sonnet)" >&2
fi
title="$team-$role"
reg=$(_reg "$team")

# The run dir is the parent of the prompt's prompts/ dir; status uses it.
rundir=-
pdir=$(dirname "$pfile")
[ "$(basename "$pdir")" = prompts ] && rundir=$(dirname "$pdir")

pmode=${TEAM_PERMISSION_MODE:-auto}

# Subagents launched without a model default to haiku (managed settings can force it), which /team
# does not use, so point them at the newest sonnet -- resolved here, in-process, sonnet tier only.
if submodel=$(_pick_model sonnet 2>/dev/null) && [ -n "$submodel" ]; then :; else
  submodel=-
  echo "warn: no sonnet-tier model; CLAUDE_CODE_SUBAGENT_MODEL not set for $title" >&2
fi

if [ -n "$worktree" ]; then
  root=$(_root)
  git -C "$root" rev-parse -q --verify HEAD >/dev/null 2>&1 || {
    echo "--worktree needs a git repo with at least one commit (none at $root)" >&2; exit 2; }
fi

# Prune + duplicate check + cap + register must not interleave with a parallel spawn of the
# same team, or two spawns both see 7 teammates.
_lock "$reg"

_reg_prune "$reg"
# --resume continues the session recorded for this title (normally a finished row), in the cwd it
# was started in: transcripts are keyed by cwd, so it is read from the row, never recomputed.
if [ -n "$resume" ]; then
  src=$(awk -v t="$title" '$4==t && ($3=="pane" || $3=="tab") && NF>=11 && $10!="-" {r=$0} END{print r}' "$reg" 2>/dev/null || true)
  [ -n "$src" ] || { echo "--resume: no recorded session for $title (spawned before rev5, or never spawned); spawn it without --resume" >&2; exit 3; }
  read -r _ _ _ _ _ _ _ _ _ rsid rcwd <<<"$src"
  [ -d "$rcwd" ] || { echo "--resume: $title's session dir $rcwd is gone (worktree cleaned?); spawn it without --resume" >&2; exit 3; }
fi
# A live teammate with this title would be a second session SendMessage cannot tell apart.
# A finished row with this title is not live: the new session supersedes it (dropped below).
live=$(awk -v t="$title" '$4==t && $9!="finished" {print $1" "$2}' "$reg" 2>/dev/null || true)
if [ -n "$live" ]; then
  [ -n "$replace" ] || { echo "$title is already live ($(echo $live)); pass --replace to close it and respawn" >&2; exit 2; }
  while read -r b r; do
    [ "$b" != "$be" ] || _term_close "$b" "$r" >/dev/null 2>&1 || true
    echo "replaced: closed $b $r ($title)"
  done <<<"$live"
  awk -v t="$title" '$4!=t || $9=="finished"' "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
fi
n_mates=$(_mates "$reg" | grep -c . || true)
[ "$n_mates" -lt 8 ] || { echo "team $team already has $n_mates live teammates (cap 8); close or replace one first" >&2; exit 4; }
# The report as it stands now ("<bytes> <PARALLELISM: lines>", or none yet): `finish` requires this
# session's round to have grown it and added a trailer, since a later round appends to the same report.
round="$(_reg_dir)/team-$team-$role.round"
if [ "$rundir" != - ] && [ -s "$rundir/reports/$role.md" ]; then
  echo "$(wc -c < "$rundir/reports/$role.md" | tr -d ' ') $(grep -cE "$_trailer" "$rundir/reports/$role.md" || true)" > "$round"
else rm -f "$round"; fi

dir=$PWD
if [ -n "$resume" ]; then
  dir=$rcwd
elif [ -n "$worktree" ]; then
  dir="$root/.team/worktrees/$team-$role"
  if [ ! -d "$dir" ]; then
    # `clean` keeps the branch, so a respawn reuses it instead of failing on `-b`.
    if git -C "$root" show-ref -q --verify "refs/heads/team/$team-$role"; then
      git -C "$root" worktree add -q "$dir" "team/$team-$role"
    else
      git -C "$root" worktree add -q -b "team/$team-$role" "$dir" HEAD
    fi
  fi
  echo "worktree $dir (branch team/$team-$role)"
  # A worktree is its own git top-level, so it never inherits the repo's workspace
  # trust and `claude` would raise the trust prompt in every pane. Pre-accept this
  # one path. Best-effort: a failure here only means the prompt comes back.
  TEAM_TRUST_DIR="$dir" python3 - <<'PY' || echo "warn: could not pre-trust $dir; expect a trust prompt" >&2
import json, os, sys
p = os.path.expanduser("~/.claude.json")
d = os.path.abspath(os.environ["TEAM_TRUST_DIR"])
with open(p, encoding="utf-8") as f:
    cfg = json.load(f)
projects = cfg.setdefault("projects", {})
if projects.setdefault(d, {}).get("hasTrustDialogAccepted") is True:
    sys.exit(0)
projects[d]["hasTrustDialogAccepted"] = True
tmp = f"{p}.team-{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(json.dumps(cfg, indent=2, ensure_ascii=False))
os.replace(tmp, p)
PY
fi
cavefile="$HOME/.agents/skills/caveman/SKILL.md"
rulesfile="$here/teammate-rules.md"
# claude keeps only the LAST --append-system-prompt-file, so these are concatenated
# rather than passed as two flags: the always-on teammate rules (parallelise with
# subagents, verify what they return) plus the caveman style unless --no-caveman.
sysprompt="$(_reg_dir)/team-$team-$role.sysprompt.md"
: > "$sysprompt"
# teammate-rules.md fences terminal-specific bullets in <!-- cmux-only --> / <!-- arcaterm-only --> blocks:
# a teammate gets only its own terminal's blocks (fence lines dropped), so it is never told to run a CLI it lacks.
drop=arcaterm; [ "$be" != arcaterm ] || drop=cmux
if [ -f "$rulesfile" ]; then
  sed -e "/^<!-- $drop-only -->\$/,/^<!-- \/$drop-only -->\$/d" -e '/^<!-- \/\{0,1\}[a-z]*-only -->$/d' "$rulesfile" >> "$sysprompt"
fi
if [ -n "$caveman" ] && [ -f "$cavefile" ]; then printf '\n\n' >> "$sysprompt"; cat "$cavefile" >> "$sysprompt"; fi
envs="CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4 TEAM_MEMBER=$(printf %q "$title")"
[ "$submodel" != - ] && envs+=" CLAUDE_CODE_SUBAGENT_MODEL=$(printf %q "$submodel")"
# Our own session id, recorded in the registry, so a later round can `claude --resume` it. A resumed
# session keeps its id (live-probed). Permission mode and allowlist are passed again on resume; the
# system prompt is not: claude replays the one recorded at the session's first request and ignores a
# new --append-system-prompt-file, so new instructions for a resumed teammate go in the prompt file.
if [ -n "$resume" ]; then
  sid=$rsid
  cmd="cd $(printf %q "$dir") && $envs claude --resume $sid --name $(printf %q "$title") --permission-mode $(printf %q "$pmode")"
else
  sid=$(python3 -c 'import uuid; print(uuid.uuid4())')
  cmd="cd $(printf %q "$dir") && $envs claude --session-id $sid --name $(printf %q "$title") --permission-mode $(printf %q "$pmode")"
fi
if [ -z "$resume" ] && [ -s "$sysprompt" ]; then cmd+=" --append-system-prompt-file $(printf %q "$sysprompt")"; fi
[ -n "$model" ] && cmd+=" --model $(printf %q "$model")"
cmd+=" \"\$(cat $(printf %q "$pfile"))\""

if [ "$be" = arcaterm ]; then
  # Same two-column grid as cmux below, anchored on pane UUIDs. ArcaTerm types --run into the new
  # pane's shell, so the shell gets a short `bash <launcher>` instead of the whole command.
  launcher="$(_reg_dir)/team-$team-$role.launch.sh"
  _at_launcher "$launcher" "$title" "$cmd"
  if [ "$layout" = pane ]; then
    n=$(awk '$1=="arcaterm" && $3=="pane" && $9!="finished"{c++} END{print c+0}' "$reg" 2>/dev/null || echo 0)
    if [ "$n" -eq 0 ]; then opened=$(_at_open split - right "$launcher")
    elif [ "$n" -eq 1 ]; then opened=$(_at_open split "$(awk '$1=="arcaterm" && $3=="pane" && $9!="finished"{print $2; exit}' "$reg")" right "$launcher")
    else opened=$(_at_open split "$(awk '$1=="arcaterm" && $3=="pane" && $9!="finished"{print $2}' "$reg" | sed -n "$((n-1))p")" down "$launcher"); fi
  else
    opened=$(_at_open tab - - "$launcher")
  fi || { echo "spawn: ArcaTerm did not open a pane for $title" >&2; exit 1; }
  ref=${opened%% *}
  [ "$layout" != tab ] || _at_rename_tab "$title" "${opened#* }" || true
  [ ! -f "$reg" ] || { awk -v t="$title" '$4!=t' "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"; }
  _reg_add "$team" "$ref" "$layout" "$title" "${model:--}" "$submodel" "$rundir" "$sid" "$dir"
  where="in the lead's tab"; [ "$layout" != tab ] || where="in a child tab of the lead's tab"
  echo "arcaterm $layout $ref ($team-$role) $where"
  exit 0
fi

if [ "$layout" = pane ]; then
  # Two-column grid in the region right of the lead: #1 opens it, #2 sits beside
  # #1, and every later teammate splits down from the one two slots back. A 1-wide
  # stack gave each teammate 1/N of the screen height, which got unreadable fast.
  # Finished rows have no pane, so only live ones anchor the grid.
  n=$(awk '$3=="pane" && $9!="finished"{c++} END{print c+0}' "$reg" 2>/dev/null || echo 0)
  if [ "$n" -eq 0 ]; then
    out=$(cmux new-split right --surface "$CMUX_SURFACE_ID" --command "$cmd" --focus false)
  elif [ "$n" -eq 1 ]; then
    out=$(cmux new-split right --surface "$(awk '$3=="pane" && $9!="finished"{print $2; exit}' "$reg")" --command "$cmd" --focus false)
  else
    out=$(cmux new-split down --surface "$(awk '$3=="pane" && $9!="finished"{print $2}' "$reg" | sed -n "$((n-1))p")" --command "$cmd" --focus false)
  fi
else
  out=$(cmux new-surface --type terminal --workspace "$CMUX_WORKSPACE_ID" --command "$cmd" --focus false)
fi
ref=$(awk '{print $2}' <<<"$out")   # "OK surface:N ..."
cmux rename-tab --surface "$ref" "$title" >/dev/null
# The new session supersedes any finished row of this title; dropped only now, so a spawn that
# failed above still leaves the old session id to resume. A team's first spawn has no registry yet.
[ ! -f "$reg" ] || { awk -v t="$title" '$4!=t' "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"; }
_reg_add "$team" "$ref" "$layout" "$title" "${model:--}" "$submodel" "$rundir" "$sid" "$dir"
echo "cmux $layout $ref ($team-$role) in current workspace"
