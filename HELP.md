# /team — agent team emulation

Runs a small team of Claude sessions on one task. Each role is a separate
interactive `claude` session in its own pane; this session is the **lead**:
it plans the roles, relays findings between teammates for challenge rounds,
and writes the final synthesis.

## Usage
    /team <task> [options]

## Options
    --tickets [slug] Ticket run: implement the feature's /to-tickets slices in parallel
                     (see Run types). The slug picks a .scratch/<slug>/ feature when there
                     are several; without tickets the lead plans them with you first
    --roles N        Number of teammates, 2–8 (default ~3); on a ticket run, the most
                     slices in flight at once (default: every runnable slice, cap 8)
    --rounds N       Challenge rounds after the first reports (default 1)
    --autoroles      Scan the project (README, layout, tests, git diff, stack) and propose
                     roles from it; waits for your OK before spawning
    --model M        Force one model for every teammate: opus, sonnet, or a full id of
                     either tier. Default: the lead picks per role (see Choosing models)
    --tabs           One tab per teammate instead of panes (cmux or ArcaTerm)
    --no-caveman     Teammates write normal prose instead of caveman terse style
    --autoclose      Close the team right after the final synthesis
    --inline         No panes: teammates run as in-session subagents (no cmux or ArcaTerm required)
    --no-monitor     Skip the auto-refreshing status pane that opens by default after the
                     teammates spawn. The pane shows each teammate's state, current step and
                     flags, with anything that needs you pinned at the top. Not counted toward
                     the teammate cap; closed with the team. Never opened under --inline
                     (no registry to read).
    --help           Show this help

## Before spawning
Every run starts with the lead closing any leftover teammates from earlier runs (it
lists them for your approval first), then grilling the task with you (`grill-with-docs` when
it builds something in a git repo, which also records the glossary and ADRs; `grilling`
otherwise), every question through the lead's question prompt: it re-reads the
earlier conversation, `.team/facts.md` and the last run's synthesis, asks whatever
questions change the work, then writes back the task, the roles, what is out of scope and
how the result gets verified. Teammates spawn only after you approve that — a wrong
assumption otherwise gets paid once per teammate.

## Choosing roles
- List them in the task (`Roles: security: …, perf: …, skeptic: …`) — used as-is.
  A bare name loads a saved role: this project's `.team/roles/<name>.md` first,
  else your shared library `~/.claude/team/roles/<name>.md`.
- Or `--autoroles` — derived from the project (reusing saved roles first),
  shown with reasons, you confirm. Approved new roles are saved for reuse.
- Otherwise the lead picks roles from the task text alone.
- Best practice: one distinct lens per role, one adversarial role, separate
  files per role when editing, 2–3 roles.

## Choosing models
Only two tiers are offered: **opus** and **sonnet**. Ticket implementers run on sonnet;
every other role — reviewers, the adversarial role, researchers, build-run roles — runs on
opus. `team.sh models` lists what this machine offers in those tiers (the set is
org-managed, so it is read at run time, not hardcoded), and `team.sh pick-model opus|sonnet`
returns the newest `claude-*` id of a tier; with no opus it falls back to sonnet and exits 1.
A haiku-tier id (including GLM / Kimi, which behave as haiku) is refused before any pane
opens, and a teammate spawned without a model gets the newest opus. Subagents run on
sonnet by default, and every subagent call names its model (sonnet, or opus for judgment;
never cheaper). The roster you approve shows each role's model, so you can change any of
them before spawning, and the run record notes what each role ran on. `--model` forces
one model everywhere.

## Run types
    Review run   Read-only task, or not a git repo. Teammates share the working tree;
                 editing roles get exclusive files.
    Build run    Task edits code in a git repo. Each teammate works like a separate
                 person: own worktree (.team/worktrees/<team>-<role>), own branch
                 (team/<team>-<role>), own commits, and the project's checks before it
                 reports. Nothing is pushed: the summary lists every branch and its last
                 commit and flags overlapping files, and you merge the branches you want.
                 Judgment calls are forwarded to the lead via NEEDS INPUT; you answer
                 them in the lead pane.
    Ticket run   Implements a feature's /to-tickets slices in parallel. No tickets yet:
                 the lead grills the feature with you, then writes the spec (to-spec)
                 and the tickets (to-tickets, which you approve). You approve the queue;
                 the lead claims every runnable slice (blockers done, no file or
                 Databricks-bundle overlap) and spawns one sonnet implementer per slice,
                 each in its own worktree, running /run-afk's Part B. As each one
                 reports, the lead rebases its `Slice NN:` commit onto the branch you
                 started from, fast-forwards it and marks the slice done, then claims
                 what that unblocked. A conflict goes back to that implementer. When the
                 queue is empty, an opus reviewer and an opus skeptic challenge the merged
                 diff. Same tickets and tracker as /run-afk, so either picks up where the
                 other stopped; GitHub mode closes each issue as its slice lands.
    Needs: run-afk's tracker tools (~/.claude/skills/run-afk/ralph/lib, or
    TEAM_TICKETS_LIB) and a tracker set up by /setup-matt-pocock-skills.

## Every teammate
- Opens in a two-column grid right of the lead, so panes stay readable as the team grows.
- Its pane closes when it has reported and the lead has verified the report, so the grid
  shows only who is working and the finished session frees its memory. Nothing is lost: the
  report is on disk, and the lead resumes the session (or starts a fresh one that reads the
  report) if a later round needs that teammate. Finishing is refused unless the report is
  complete and, on a build run, the worktree has no uncommitted changes.
- Pane/tab title is fixed to <team>-<role> (Claude's auto-titling is disabled).
- Starts in auto permission mode (TEAM_PERMISSION_MODE overrides it).
- Splits its own work across subagents: anything independent (separate files, checks or
  drafts) is dispatched in one message so it runs concurrently, and its report says what
  it parallelised. It still verifies what the subagents hand back before reporting it.
- Writes in caveman style (https://github.com/JuliusBrussee/caveman) to save tokens;
  code, paths and errors unchanged. The lead's summary to you stays normal prose.

## Later rounds: resumed teammates
A teammate is finished as soon as its report is verified, and every later round resumes it
(one resume spin-up per teammate per round, so a teammate exists only while it works). Its
session id is recorded, so a later round resumes that session
(`team.sh spawn --resume`; it keeps its full context) and falls back to a fresh teammate that
reads its earlier report when no session is recorded or its directory is gone. Shutting the
team down (`close`) drops finished rows, so nothing can be resumed afterwards.
Known behaviour to expect:
- **Edits to `teammate-rules.md` do not reach a resumed teammate.** Claude records the system
  prompt on the first request and replays it on resume; a changed prompt file is ignored with
  no error or warning. Anything a resumed teammate must be told differently goes in the lead's
  message to it. A fresh teammate does read the current rules.
- The permission mode is re-applied on resume (verified for `--permission-mode`).
- Resuming a build-run teammate after `team.sh clean` removed its worktree is refused (its
  directory is gone), so the lead starts a fresh teammate from its report.

## Project memory: .team/
Created at the project root on first run (git-ignored, along with CLAUDE.local.md;
a one-time pointer note is added to CLAUDE.local.md — never to CLAUDE.md):
    .team/facts.md             Consensus findings with evidence + date + run id;
                               every teammate reads it first and flags stale entries
    .team/roles/<role>.md      Roles saved in this project (override shared roles)
    .team/runs/<date>-<team>/  tasks.md · prompts/ · reports/ · status/ · synthesis.md
    .team/worktrees/           build-run worktrees (removed on shutdown if clean)
Only conclusions and pointers are stored — never secrets, PII, or raw data.

Shared role library: `~/.claude/team/roles/` (outside any repo; make it a private git
repo to sync machines). `team.sh role-pull <name>` brings a shared role into this
project; `team.sh role-promote <name>` publishes a project role to the shared library
(shows a diff and scans for secrets/PII before copying). `team.sh roles` lists all
available roles with a status column:
    in-sync          Project and library copies are identical
    local-ahead      Project copy has changes not in the library (promote candidate)
    global-ahead     Library is newer — run role-pull before promoting
    diverged         Both differ from the saved base — show both diffs before deciding
    diverged (no base)  Both differ but no saved base for comparison
    project-only     Role exists in the project but not in the library (promote to add it)
    library-only     Role exists in the library but not in this project (pull to add it)
On a new machine the shared library starts empty until you sync it.

## Where teammates appear
    In cmux (default)   Your tab splits: you on the left, teammates in a two-column
                        grid on the right; finished ones close.
                        Pane modes need cmux or ArcaTerm. Install: https://cmux.dev
    cmux + --tabs       A new tab per teammate in the current workspace
    In ArcaTerm         The same two-column split of your tab. ArcaTerm titles split
                        panes itself (process or agent), not <team>-<role>: tell them
                        apart in the status pane or `team.sh list`. ArcaTerm moves focus
                        to a new split; the lead takes it back.
    ArcaTerm + --tabs   A child tab of your tab per teammate, titled <team>-<role>
    --inline            No panes: teammates run as subagents inside your session.
                        Works without cmux or ArcaTerm.
  The terminal is the one you run /team from: a cmux pane uses cmux, an ArcaTerm pane
  ArcaTerm (TEAM_BACKEND=cmux|arcaterm forces one). A team stays in the terminal it started in.

## Progress (cmux sidebar)
The lead workspace shows a live status pill and progress bar: phase (spawning /
working / done) and "N/M reported". Events are logged to the cmux event stream
(`cmux log --source team`) so you can scroll back. A badge and ring light up when
any teammate reports or sends a question — the notification fires from `cmux notify`
inside that teammate. A report's notification is best-effort quiet (no macOS banner) and
NEEDS INPUT keeps the banner; cmux says its notification hooks "can still override" that,
so treat it as a preference. A report's ring is not a durable signal either, because the
reporting teammate's pane closes once it is finished — rely on the pill's `N/M reported`.
The lead calls `team.sh sync <team>` to update the sidebar; `team.sh sync --clear <team>`
removes it when the team closes. The status pane (see below) opens by default and is the
detailed view; the sidebar is the glance view.
ArcaTerm has no sidebar API and no notify command: there `sync` does nothing, and the
status pane is the progress view. ArcaTerm's own tab status still shows each teammate as
working, idle or needing input.

## Cleanup: team.sh reap [--yes] [--exclude <team>]
At the start of every run the lead lists leftover teammates from earlier runs of
this project and asks you to confirm before closing them. Rows marked "(run started
today: may be live in another lead session)" require extra care — you may want to
check before closing. Registries without a project root are left alone and counted
in a summary line. You can also run `team.sh reap` at any time to see the list, or
`team.sh reap --yes` to close without prompting. `--exclude <team>` skips the named
team. Teammates opened in the other terminal (cmux vs ArcaTerm) are listed as left
alone and never closed; reap them from there. Requires cmux or ArcaTerm; skipped under --inline.

## Examples
    /team review PR #42 for security, performance and test coverage
    /team why does the streaming job lag? --roles 4 --rounds 2 --model sonnet
    /team research vector search options for our RAG demo --tabs --autoclose
    /team review my current changes --autoroles
    /team add retry logic to the ingestion job and cover it with tests --autoroles
    /team quick sanity review of src/utils.py --roles 2 --inline
    /team implement the checkout-v2 tickets --tickets checkout-v2
    /team build CSV export for the usage report      (the lead offers a ticket run)

## While it runs
- Click into any teammate pane to talk to it directly or redirect it, or ask the lead to
  `show` it (brings its pane to the front and moves focus there). A finished teammate has
  no pane; ask the lead to resume it.
- Teammate *tool-permission* prompts appear in *their* pane — approve them there.
  **Known limitation (cmux):** a prompt produces no notification, so the status pane cannot flag
  it. The teammate shows `WORKING` for about 10 minutes, then `STALLED?`. If a teammate has
  been quiet that long, ask the lead to `show` it (brings its pane to the front) before assuming a bug.
  In ArcaTerm the prompt shows as `waiting` right away: ArcaTerm reports that the teammate needs input.
- A teammate that needs your input or a decision forwards the question to the lead via
  NEEDS INPUT with options and a recommendation; you answer it in the lead pane (with the
  recommended option presented first) and the lead relays it back — so you don't have
  to visit each pane. The lead always uses AskUserQuestion for your input.
- Build-run worktrees are pre-trusted, so they no longer prompt. A folder you have
  never opened with Claude can still show a trust prompt the first time.
- `.team/runs/<date>-<team>/tasks.md` tracks each role's status.
- Run `team.sh status <team>` to see one frame: a summary line (`<team> · N/M reported ·
  time`), a progress bar, and a table of ROLE · STATE · STEP · AGE. Each state is a symbol
  plus a word, so colour is never the only cue; colour is off when output is not a terminal,
  `NO_COLOR` is set or `TERM=dumb`, and symbols fall back to ASCII in a non-UTF-8 locale.
  A `NEEDS YOU` block is pinned above the table only when a teammate is in one of the first
  four states below; the STEP column is dropped below 60 columns.
    waiting      AskUserQuestion notification detected — teammates must not use this;
                 `show` its pane and SendMessage it to send NEEDS INPUT to the lead instead.
                 In ArcaTerm, also a tool-permission prompt waiting for you: `show` it first.
    model gone   Its model is no longer available — respawn with a different model
    dead         Session exited — respawn it (a note says when its report is safe on disk;
                 in ArcaTerm a note also says when claude exited and left its pane open)
    stalled?     No status update for 10 minutes while mid-work. This is "no update in a
                 while", not "stuck": a teammate in a long hook or subagent wait looks the
                 same, so look at its pane before messaging it
    working      Doing its work (a note says "report on disk" once it has reported)
    idle         Turn ended with no report yet; routine while it waits on a peer or the lead,
                 so it is not pinned under NEEDS YOU (it becomes stalled? after 10 minutes)
    unknown      Opened in another terminal, or the terminal could not be queried, so its
                 state cannot be read
    finished     Reported, verified and closed by the lead
  State is read from the terminal for each *live* teammate — the hooks cmux injects, or
  ArcaTerm's agent status — not from its screen. A finished teammate has no surface, so its
  state comes from its report on disk and the registry.
  The status pane opens automatically (unless `--no-monitor`) and repaints only when the
  frame changes, checking every 30 s (override with `TEAM_STATUS_INTERVAL`). It exits when
  the team is closed. Requires cmux or ArcaTerm. Under `--inline` there is no registry and no pane; track
  teammates by their returned reports and tasks.md.
  In the pane each row is numbered: press that number to focus that teammate's pane, `r` to
  repaint, `q` to quit. Clicking a row does the same. Clicking captures the mouse, so
  click-drag no longer selects text in that pane (shift+drag still does); set
  `TEAM_MONITOR_MOUSE=0` to keep the number keys and leave selection alone. A finished
  teammate has no pane, so focusing it just says so. One-shot `team.sh status` prints no
  numbers and takes no input.
  The pane closes itself a few seconds after the last teammate reaches `finished`, so a
  completed run does not leave a pane behind (`TEAM_MONITOR_AUTOCLOSE=0` keeps it open,
  `TEAM_MONITOR_CLOSE_GRACE` sets the delay). It only closes on that *transition*: opening
  the monitor on an already-finished run leaves it up.
  The headline bar is the team's **average** self-reported progress (`~70%`), not the share
  of teammates that have reported — 4 teammates at 80% is not "0% done". A reported or
  finished teammate counts as 100. The hard `N/M reported` count stays next to it, and when
  nobody reports a percentage the bar falls back to `N/M` and drops the `~`. The sidebar pill
  and progress bar carry the same number as the pane.
  A PROGRESS bar and an `~ETA` appear per row only when a teammate reports a percentage on
  its status line, and only when the pane is at least 72 / 84 columns wide. Both are
  **self-reported** — the teammate's own estimate, since no measured per-teammate progress
  signal exists — so treat them as a rough indication, not a measurement. The ETA is a
  linear extrapolation (`elapsed x (100 - pct) / pct`) of that estimate.
- Say "shut down the team" to close all teammate panes/tabs (the run record stays;
  clean worktrees are removed, branches stay).

## Output
Consensus (findings that survived challenge, with evidence) · Disputed (each
side's best evidence) · Dropped (refuted) · Next steps.

## Notes
- Teammates start in auto permission mode (set TEAM_PERMISSION_MODE to override). Only
  opus- and sonnet-tier models are offered (see Choosing models).
- The hard cap is 8 teammates (spawn refuses beyond it).
- Cost: every teammate is a full Claude session with its own context window,
  so cost scales with team size. Prefer 2–3 sharp roles; the lead already fits a model
  to each role, so reach for `--model` only to force one model everywhere.
- Give roles separate files when the task edits code.
- This emulates Claude Code's experimental agent teams for setups where they're
  unavailable (e.g. disabled by managed settings); the lead relays challenge
  rounds instead of a native shared mailbox. Native `cmux claude-teams` is blocked
  by managed settings on this gateway — this skill remains the supported path.
