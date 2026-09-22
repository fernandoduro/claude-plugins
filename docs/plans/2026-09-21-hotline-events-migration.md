# hotline: migrate the dial transport onto cmux events

Bead: claude-plugins-056z. Branch: `hotline-events-migration`.
Contract: `plugins/cmux-cli/skills/using-cmux-cli/references/events.md` — verified
against cmux 0.64.25. Do not re-derive it.

## Scope, corrected

The bead names four scripts. The class is "every place hotline infers cmux state
from a screen or a sleep", which is six files and 3,733 lines:

| file | lines | what events replace |
|---|---|---|
| `scripts/repl-state.sh` | 843→1030 | **DONE** — the shared primitives live here |
| `skills/dial/scripts/surface-ready.sh` | 140 | `surface.created`, keeping the PTY probe |
| `skills/dial/scripts/wait-for-session.sh` | 500 | `agent.hook.SessionStart` |
| `skills/dial/scripts/cmux-paste.sh` | 641 | **submit forensics** — highest value, not on the bead |
| `skills/dial/scripts/cmux-reuse-surface.sh` | 396 | preflight box inspection |
| `skills/dial/scripts/wait-for-response.sh` | 1213 | the *when-to-read* gate only |

Two corrections to the bead worth carrying:

1. **`repl-state.sh` is first, not last.** It is sourced by 11 scripts, so the
   event primitives had to land before anything could consume them. Four agents
   each writing their own `cmux events | jq` is the duplication that has already
   cost this repo twice in the transcript parser.
2. **`cmux-paste.sh` holds the submit forensics, not `cmux-reuse-surface.sh`.**
   The bead points at reuse-surface for "submit verification via
   workspace.prompt.submitted", but reuse-surface only does preflight (is the
   REPL busy, is something parked). The `CONFIRM_TRIES=10` × `CONFIRM_SLEEP=0.3`
   retry loop, the baseline box diff, the marker matching and the tiered
   "positive evidence it submitted" ladder are all in `cmux-paste.sh`
   lines 404–560. That is what one `workspace.prompt.submitted` frame answers.

`wait-for-response.sh`'s primary tier is already transcript-based and stays that
way — events do not replace the *read*. Only its 2s poll changes, into an
`agent.hook.Stop` gate, exactly as its herdr mode already does it with
`herdr agent wait` (see its own header, lines 30–33).

## Phase 1 — the primitives (done)

`plugins/hotline/scripts/repl-state.sh`, new section before the scroll-immune
reads. Suite: `plugins/hotline/tests/events-primitives_test.sh`, 28 cases.

| function | answers |
|---|---|
| `cmux_events_supported` | can this cmux answer at all (cached; `HOTLINE_CMUX_EVENTS=0\|1` forces) |
| `cmux_events_seq` | the before-marker; **empty, never 0**, on failure |
| `cmux_events_first` | first matching frame, returns as soon as it arrives |
| `cmux_events_all` | every match in the window; always costs the full window |
| `cmux_wait_surface_created` | the surface exists (**not** that its PTY is attached) |
| `cmux_wait_session_start` | the callee's `session_id`, matched on cwd |
| `cmux_wait_turn_end` | Stop / SubagentStop / SessionEnd, phase-deduped |
| `cmux_submit_lengths` | one `message_length` per submit frame |
| `cmux_send_landed_on` | did the send resolve to the surface we meant |

### What phase 1 measured, so phases 2–3 need not

- **A naive `| head -1` does not return early.** cmux holds the stream open for
  its whole `--timeout`, and `head` exiting only SIGPIPEs jq on jq's *next*
  write — which never comes, because non-matching frames produce no output. So
  jq drains the window: measured 6s of a 6s window for a frame delivered at 0s.
  A 600s `cmux_wait_turn_end` would have cost 600s, making every migrated waiter
  **slower than the polling it replaced**. `jq -n 'first(inputs|…)'` alone does
  not fix it either, because a command substitution waits for every process in
  the pipeline. `cmux_events_first` therefore runs cmux into a FIFO in the
  background and kills it once jq exits.
- **Process substitution measured the same 0s but orphaned a
  `cmux events --timeout N` per wait.** Hence the explicit kill.
- **`$want | index(.name)` is a jq scoping bug** — inside the pipe `.` is the
  array, so `.name` indexes an array with a string and the filter errors out to
  nothing. Capture first: `(.name // "") as $n | $want | index($n)`.
- **The `--name` narrowing is cmux's, server-side.** The builders also check
  `.name` client-side, so no filter can be satisfied by a frame of another name.
- `set +o pipefail` and `|| true` on these captures are **not** what protect the
  pipeline; neither is load-bearing, and both were removed where they were dead.

### Watch the test stubs, not just the tests

Three cases in the new suite passed with every guard removed before the stubs
were fixed. All three for the same reason: **a stub that has already exited
cannot exhibit the hazard.**

- A stub that `cat`s a finished file can never SIGPIPE or hold the reader up, so
  it cannot test early return. The stream stub stays open.
- A stub that sleeps a fixed time instead of honouring `--timeout` makes the
  no-match case look like an overrun that is really the stub's own nap.
- An orphan detector built from the FIFO path matches nothing, because the FIFO
  is a `>` redirect and never appears in cmux's argv. Match the stub's path.

Every guard in phase 1 was verified by breaking it and watching a case go red
(6 controls). Do the same for anything you add. Two of the controls initially
reported "MUTATION FAILED" against strings that also appear in comments — check
that a mutation landed on the code before believing a green run.

## Phases 2–3 — work orders

Sequence is blast radius. Each phase runs against the target's existing suite
plus the new primitives suite.

**Every agent, every phase:**

- Work in a **git worktree** when two agents run at once, so they are not
  editing the same files under each other. This is ordinary isolation, not a
  transport hazard: `/hotline:dial` runs the *installed* plugin copy under
  `~/.claude/plugins/cache/jtsternberg/hotline/<version>/`, so edits to this
  working tree cannot break the dial carrying your own work order. It is at
  **publish** time that a bad `repl-state.sh` reaches the live transport — it is
  sourced by 11 scripts including `dial.sh`, `cmux-paste.sh` and
  `wait-for-response.sh`.
- **Keep every screen-reading path as a documented fallback.** They are the only
  thing that works outside cmux or on a build predating the stream. Gate on
  `cmux_events_supported`; delete nothing.
- Tests never touch real cmux, a real beads DB or a real API. Stub `cmux` on
  PATH like the existing suites. New suites go at
  `plugins/hotline/tests/<name>_test.sh` — the runner globs that path and
  anything elsewhere is silently never run.
- A read consuming an empty lookup is fatal under `set -euo pipefail`; append
  `|| true`. This took out every cmux hotline dial in a previous session.
- The Bash tool's shell is **zsh**: unquoted expansions do not word-split, so
  `for f in $LIST` gets one word, silently.
- Pass `--no-color` to any git output you parse.

### Phase 2 (parallel — consume-only, no shared file)

**2a. `surface-ready.sh`** → `cmux_wait_surface_created` in place of the
readiness poll. **Keep the PTY-attach probe.** `surface.created` means the
surface exists; a `cmux send` is still what attaches the PTY, so a read before
the probe still fails. Suite: `surface-placement_test.sh`.

**2b. `wait-for-session.sh`** → `cmux_wait_session_start` in place of the
banner-regex tier (lines ~300, ~390) and the two `sleep 1` loops (408, 493).
The payload carries `session_id`, `surface_id` and `cwd`, which is also how a
live claude session id maps onto a cmux surface. Suite: `wait-for-cmux_test.sh`
(case S1 covers the read-screen promotion path — keep it passing on the
fallback).

### Phase 3 (sequential — highest value first)

**3a. `cmux-paste.sh`** — **fragmentation detection only.** The length half of
this idea is dead, measured live on cmux 0.64.25:

`workspace.prompt.submitted`'s `message_length` **is capped at 240** — it is the
length of the 240-char `message_preview`, not of the message. Over a 900-frame
replay: 21 submissions, all 21 with
`message_length == (message_preview | length)`, 14 at exactly 240, none above,
and those 14 were 6 distinct messages whose previews end mid-token. The earlier
"character-exact" reading came from two plaintexts of 119 and 43 chars — both
under the cap, so both agreed. Every real hotline work order is far longer than
240, so a whole payload and a truncated one both report 240 and the field can
never detect truncation of one.

So do NOT replace the confirmation ladder, and do not add a length verdict. The
PRIMARY tier is already byte-definitive (a `grep -F` for the call-id nonce in the
callee's transcript) and remains the only thing that covers a long payload.

What is still worth adding, and needs no calibration: **a frame COUNT**. Two
`workspace.prompt.submitted` frames for one send is fragmentation — the callee
received the work order split across turns — and the current ladder reports that
as a clean delivery. Baseline `cmux_events_seq` before the paste, count frames
after, and report the count in an additive JSON field beside `confirmed`.
`delivered`/`confirmed` must NOT change: a fragmented payload IS in the callee's
queue, and calling it undelivered invites a double-delivery.

Mind the cost: `cmux_events_all` cannot return early, so `cmux_submit_lengths`
spends its whole settle window (default 2s) on every call, against a ladder that
confirms in well under a second. Either accept that on the confirm path only, or
gate it behind an env flag. Do not raise the window.

**3b. `cmux-reuse-surface.sh`** — preflight only. `cmux_send_landed_on` after
each send is the mechanical form of the substituted-target check that
`cmux_handle_ok` can only refuse in advance. Suite:
`cmux-reuse-surface_test.sh` — note its scroll-immunity contract at lines
1281–1334 asserts *every bare `read-screen` is a pane measurement*. That
contract must survive; do not "fix" it to accommodate a change.

**3c. `wait-for-response.sh`** — the gate only. Replace the 2s cmux-mode poll
with a turn-end wait, then read the transcript exactly as now. Leave the
transcript tier, the nonce bracketing and the 0/3/4/5 exit contract alone.
Suite: `wait-for-response_test.sh`, `transport-signal_test.sh`.

**`cmux_wait_turn_end` as it stands is NOT sufficient here.** Measured live:
`agent.hook.Stop` carries a null `surface_id` on most real frames, so the null
fallback in that filter is what makes it match at all — and that same fallback
means ANY session's turn end satisfies it, including the operator's own. A
caller waiting on callee X would wake on the user finishing a turn. Real frames
do carry `payload.cwd` and `payload.session_id`, so discriminate on those.

Note `payload.session_id` is a composite, `cmux-feed-v1:<base64 agent
name>:<base64 session uuid>` — see `cmux_wait_session_start` in `repl-state.sh`
for the match-and-decode already written for it. An equality test against a bare
uuid never matches.

## Before dispatching anything: the install is stale

The installed plugin is **0.34.1** while the repo ships **0.34.3**:
`~/.claude/plugins/cache/jtsternberg/hotline/` tops out at 0.34.1, whose
`error-recovery.md` predates the 0.34.2 rewrite, and whose `installed_plugins.json`
entry was last updated at 2026-09-21T16:09 — before those commits landed. The
three call-dir bugs 0.34.3 fixed are therefore **live in the transport any
`/hotline:dial` would use on this machine**, which is why phase 2 was done
in-session rather than dispatched.

`repl-state.sh` in the install is byte-identical to the repo at the anchor
commit, which is expected — 0.34.2/0.34.3 did not touch it.

Refresh the install before dispatching dialed agents for phase 3. The
`publish-release` runbook's Claude-side probe is the step that would have caught
this at ship time.

## Ship gate

`bash tests/run-all.sh` redirected to a file — **do not pipe to `tail`**, which
reports tail's exit code and reads a real failure as success. A green run
reports `skipped 1` (`codex: live-plugin`). Then the `compounding-preflight`
skill, then `publish-release`.

hotline ships **both** `.claude-plugin/plugin.json` and
`.codex-plugin/plugin.json` and their versions must stay aligned;
`tests/manifest-alignment.test.mjs` fails if they drift. One release, one bump.
hotline is not mapped to the internal skills directory, so no publish there.

Do not run two `tests/run-all.sh` concurrently — suites run in parallel and a
concurrent run has produced a spurious `hotline: herdr-transport` failure that
passed 373/0 in isolation moments later.
