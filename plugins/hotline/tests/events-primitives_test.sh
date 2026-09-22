#!/usr/bin/env bash
# =============================================================================
# The cmux-events primitives in repl-state.sh: contract and the five traps.
#
# These functions are the single binding of
# plugins/cmux-cli/skills/using-cmux-cli/references/events.md into the dial
# transport — every script that migrates off read-screen polling consumes them,
# so a regression here is a regression in all of them at once. Duplicating the
# `cmux events | jq` incantation per caller is the failure this exists to
# prevent; this repo has lost time to exactly that in the transcript parser,
# twice.
#
# `cmux` is a PATH stub serving canned NDJSON. No real cmux, no network.
# =============================================================================
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$HOTLINE_DIR/scripts/repl-state.sh"

PASS=0
FAIL=0
FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

echo "hotline events primitives"

[[ -f "$LIB" ]] || { echo "repl-state.sh missing at $LIB"; echo "0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  - jq absent; skipping"; echo "0 passed, 0 failed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

# --- The cmux stub -----------------------------------------------------------
# Serves $CMUX_FRAMES for `events`, prefixed by the ack frame and a heartbeat
# (trap 1: both must be tolerated) and followed by the timeout line on stderr.
# `--snapshot` answers the capability probe. It deliberately IGNORES --name, so
# every name narrowing under test is the client-side guard doing the work.
cat > "$TMP/bin/cmux" <<'STUB'
#!/usr/bin/env bash
[[ "$1" != "events" ]] && exit 0
shift
snap=0; noack=0
for a in "$@"; do
  [[ "$a" == "--snapshot" ]] && snap=1
  [[ "$a" == "--no-ack"   ]] && noack=1
done
if [[ -n "${CMUX_STUB_EVENTS_FAIL:-}" ]]; then
  echo "Error: unknown subcommand 'events'" >&2; exit 2
fi
if [[ $snap -eq 1 ]]; then
  printf '{"type":"ack","resume":{"oldest_seq":1,"latest_seq":%s,"gap":false}}\n' \
    "${CMUX_STUB_LATEST_SEQ:-500}"
  exit 0
fi
if [[ $noack -eq 0 ]]; then
  printf '{"type":"ack","resume":{"oldest_seq":1,"latest_seq":500,"gap":false}}\n'
fi
[[ -n "${CMUX_FRAMES:-}" && -f "$CMUX_FRAMES" ]] && cat "$CMUX_FRAMES"
echo "Error: Timed out waiting for a matching event" >&2
exit 0
STUB
chmod +x "$TMP/bin/cmux"

# shellcheck source=../scripts/repl-state.sh
set +u; source "$LIB"; set -u

frames() { CMUX_FRAMES="$TMP/frames.ndjson"; export CMUX_FRAMES; : > "$CMUX_FRAMES"; }
frame()  { printf '%s\n' "$1" >> "$CMUX_FRAMES"; }

SURF="F41D2405-AAAA"
WS="4C7FA894-BBBB"

# --- 1. Capability probe -----------------------------------------------------
unset HOTLINE_CMUX_EVENTS; HOTLINE_CMUX_EVENTS_CACHE=""
cmux_events_supported && pass "capability probe says yes on a cmux that answers --snapshot" \
  || fail "capability probe says yes on a cmux that answers --snapshot"

HOTLINE_CMUX_EVENTS_CACHE=""; CMUX_STUB_EVENTS_FAIL=1 
if CMUX_STUB_EVENTS_FAIL=1 HOTLINE_CMUX_EVENTS_CACHE="" bash -c "
  set -euo pipefail; source '$LIB'
  cmux_events_supported && exit 1 || exit 0" 2>/dev/null; then
  pass "capability probe says no on a cmux with no events subcommand (fallbacks stay live)"
else
  fail "capability probe says no on a cmux with no events subcommand"
fi
unset CMUX_STUB_EVENTS_FAIL; HOTLINE_CMUX_EVENTS_CACHE=""

HOTLINE_CMUX_EVENTS=0 bash -c "set -euo pipefail; source '$LIB'; cmux_events_supported" 2>/dev/null \
  && fail "HOTLINE_CMUX_EVENTS=0 forces the fallback path" \
  || pass "HOTLINE_CMUX_EVENTS=0 forces the fallback path (how the suites drive both)"

# --- 2. cmux_events_seq ------------------------------------------------------
GOT=$(CMUX_STUB_LATEST_SEQ=647 cmux_events_seq || true)
[[ "$GOT" == "647" ]] \
  && pass "cmux_events_seq reads latest_seq off the snapshot ack" \
  || fail "cmux_events_seq reads latest_seq off the snapshot ack" "got '$GOT'"

# A failed probe must NOT yield 0: passing --after 0 would replay all retained
# history and read unrelated frames as caused by our send.
if CMUX_STUB_EVENTS_FAIL=1 bash -c "
  set -euo pipefail; source '$LIB'
  out=\$(cmux_events_seq || true); [[ -z \"\$out\" ]]" 2>/dev/null; then
  pass "cmux_events_seq yields nothing (never 0) when it cannot read a marker"
else
  fail "cmux_events_seq yields nothing (never 0) when it cannot read a marker"
fi

# --- 3. Trap 1: the ack frame and the stderr timeout line ---------------------
frames
frame "{\"name\":\"surface.created\",\"seq\":5,\"pane_id\":\"PANE-1\",\"surface_id\":\"$SURF\"}"
GOT=$(cmux_wait_surface_created "PANE-1" 1 || true)
if [[ -n "$GOT" ]] && printf '%s' "$GOT" | jq -e '.seq == 5' >/dev/null 2>&1; then
  pass "an ack frame on stdout and a timeout line on stderr do not corrupt the result"
else
  fail "an ack frame on stdout and a timeout line on stderr do not corrupt the result" "got '$GOT'"
fi

GOT=$(cmux_wait_surface_created "PANE-OTHER" 1 || true)
[[ -z "$GOT" ]] \
  && pass "a surface.created for another pane is not a match" \
  || fail "a surface.created for another pane is not a match" "got '$GOT'"

# --- 4. Trap 4: agent.hook.* fires twice -------------------------------------
frames
frame "{\"name\":\"agent.hook.Stop\",\"seq\":10,\"surface_id\":\"$SURF\",\"payload\":{\"phase\":\"received\"}}"
frame "{\"name\":\"agent.hook.Stop\",\"seq\":11,\"surface_id\":\"$SURF\",\"payload\":{\"phase\":\"completed\"}}"
GOT=$(cmux_wait_turn_end "$SURF" 1 || true)
if printf '%s' "$GOT" | jq -e '.seq == 11 and .payload.phase == "completed"' >/dev/null 2>&1; then
  pass "the turn-end waiter takes the 'completed' phase, not the 'received' one"
else
  fail "the turn-end waiter takes the 'completed' phase, not the 'received' one" "got '$GOT'"
fi

# Only a "received" phase in the window is NOT a turn end.
frames
frame "{\"name\":\"agent.hook.Stop\",\"seq\":10,\"surface_id\":\"$SURF\",\"payload\":{\"phase\":\"received\"}}"
GOT=$(cmux_wait_turn_end "$SURF" 1 || true)
[[ -z "$GOT" ]] \
  && pass "a 'received'-only Stop is not reported as a finished turn" \
  || fail "a 'received'-only Stop is not reported as a finished turn" "got '$GOT'"

# --- 5. Trap 5: a null surface_id must not be dropped ------------------------
frames
frame "{\"name\":\"agent.hook.Stop\",\"seq\":12,\"surface_id\":null,\"payload\":{\"phase\":\"completed\"}}"
GOT=$(cmux_wait_turn_end "$SURF" 1 || true)
if printf '%s' "$GOT" | jq -e '.seq == 12' >/dev/null 2>&1; then
  pass "an unattributed (null surface_id) Stop still counts as a turn end"
else
  fail "an unattributed (null surface_id) Stop still counts as a turn end" "got '$GOT'"
fi

# --- 6. Trap 2b: the client-side name guard ----------------------------------
# The stub ignores --name, so only the client-side guard can reject this.
frames
frame "{\"name\":\"agent.hook.SessionStart\",\"seq\":20,\"surface_id\":\"$SURF\",\"payload\":{\"phase\":\"completed\",\"session_id\":\"S1\"}}"
GOT=$(cmux_wait_turn_end "$SURF" 1 || true)
[[ -z "$GOT" ]] \
  && pass "a SessionStart cannot satisfy a turn-end wait (client-side name guard)" \
  || fail "a SessionStart cannot satisfy a turn-end wait" "got '$GOT'"

# A frame with no .name at all (the ack shape) must never match.
frames
frame '{"type":"ack","resume":{"latest_seq":1}}'
GOT=$(cmux_wait_turn_end "$SURF" 1 || true)
[[ -z "$GOT" ]] \
  && pass "a frame with no .name never matches" \
  || fail "a frame with no .name never matches" "got '$GOT'"

# --- 7. Submit lengths: the four readings ------------------------------------
frames
GOT=$(cmux_submit_lengths "$WS" 1 || true)
[[ -z "$GOT" ]] \
  && pass "no submit frame → nothing submitted (the payload sits in the box)" \
  || fail "no submit frame → nothing submitted" "got '$GOT'"

frames
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":30,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":43}}"
GOT=$(cmux_submit_lengths "$WS" 1 || true)
[[ "$GOT" == "43" ]] \
  && pass "one frame with the sent length → a clean submit" \
  || fail "one frame with the sent length → a clean submit" "got '$GOT'"

frames
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":31,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":19}}"
GOT=$(cmux_submit_lengths "$WS" 1 || true)
[[ "$GOT" == "19" ]] \
  && pass "a short length is reported verbatim, so a caller can call byte loss" \
  || fail "a short length is reported verbatim" "got '$GOT'"

frames
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":32,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":20}}"
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":33,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":23}}"
GOT=$(cmux_submit_lengths "$WS" 1 | tr '\n' ',' || true)
[[ "$GOT" == "20,23," ]] \
  && pass "two frames for one send → fragmentation, both lengths reported" \
  || fail "two frames for one send → fragmentation" "got '$GOT'"

# Another workspace's submit is not ours.
frames
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":34,\"workspace_id\":\"OTHER-WS\",\"payload\":{\"message_length\":43}}"
GOT=$(cmux_submit_lengths "$WS" 1 || true)
[[ -z "$GOT" ]] \
  && pass "a submit in another workspace is not counted as ours" \
  || fail "a submit in another workspace is not counted as ours" "got '$GOT'"

# --- 8. The substituted-target check -----------------------------------------
frames
frame "{\"name\":\"surface.input_sent\",\"seq\":40,\"payload\":{\"params\":{\"text_length\":25},\"result\":{\"surface_id\":\"$SURF\"}}}"
cmux_send_landed_on "$SURF" 1 \
  && pass "a send whose result.surface_id is the intended surface verifies" \
  || fail "a send whose result.surface_id is the intended surface verifies"

frames
frame "{\"name\":\"surface.input_sent\",\"seq\":41,\"payload\":{\"params\":{\"text_length\":25},\"result\":{\"surface_id\":\"CALLERS-OWN-SURFACE\"}}}"
cmux_send_landed_on "$SURF" 1 \
  && fail "a send that landed on the caller's own surface is caught" \
        "reported a match against the wrong surface" \
  || pass "a send that landed on the caller's own surface is caught"

# --- 9. Session start --------------------------------------------------------
frames
frame "{\"name\":\"agent.hook.SessionStart\",\"seq\":50,\"surface_id\":null,\"payload\":{\"phase\":\"completed\",\"session_id\":\"abc-123\",\"cwd\":\"/Users/x/proj\"}}"
GOT=$(cmux_wait_session_start "/Users/x/proj" 1 || true)
[[ "$GOT" == "abc-123" ]] \
  && pass "session start yields the callee's session_id, matched on cwd" \
  || fail "session start yields the callee's session_id, matched on cwd" "got '$GOT'"

GOT=$(cmux_wait_session_start "/Users/x/other" 1 || true)
[[ -z "$GOT" ]] \
  && pass "a session start in another cwd is not ours" \
  || fail "a session start in another cwd is not ours" "got '$GOT'"

# A cwd is not unique to a call: the operator's own claude session in the same
# directory emits an identical-looking SessionStart. With a preset id known, the
# match must be exact, and the frame then confirms the preset.
GOT=$(cmux_wait_session_start "/Users/x/proj" 1 "abc-123" || true)
[[ "$GOT" == "abc-123" ]] \
  && pass "a known preset session id is confirmed by the frame" \
  || fail "a known preset session id is confirmed by the frame" "got '$GOT'"

GOT=$(cmux_wait_session_start "/Users/x/proj" 1 "some-other-session" || true)
[[ -z "$GOT" ]] \
  && pass "another session booting in the same cwd is not mistaken for ours" \
  || fail "another session booting in the same cwd is not mistaken for ours" "got '$GOT'"

# --- 10. The wait returns when the FRAME arrives, not when the window ends ----
# This is the case that decides whether migrating off read-screen polling is an
# improvement at all. cmux holds the stream open for its whole --timeout, so a
# reader that merely stops reading still pays for the window: the first
# implementation here returned the right frame 6s into a 6s window for a frame
# delivered at 0s, which would have made a 600s turn-end wait cost 600s.
#
# Modelling that needs a stub that STAYS OPEN after emitting the match, not one
# that `cat`s a file and exits — a stub that has already exited cannot hold
# anyone up, so the earlier shape of this case passed with every guard removed.
STREAM_STUB="$TMP/bin/cmux"
cp "$STREAM_STUB" "$TMP/cmux.orig"
cat > "$STREAM_STUB" <<'STREAM'
#!/usr/bin/env bash
[[ "$1" != "events" ]] && exit 0
shift
for a in "$@"; do
  [[ "$a" == "--snapshot" ]] && { printf '{"type":"ack","resume":{"latest_seq":500}}\n'; exit 0; }
done
printf '{"name":"agent.hook.Stop","seq":60,"surface_id":"%s","payload":{"phase":"completed"}}\n' "$STREAM_SURF"
# A real `cmux events --timeout N` holds the connection for the whole window and
# then exits, so honour the flag — a stub that sleeps a fixed time instead makes
# the no-match case look like an overrun that is really the stub's own nap.
hold="${STREAM_HOLD:-8}"
prev=""
for a in "$@"; do [[ "$prev" == "--timeout" ]] && hold="$a"; prev="$a"; done
sleep "$hold"
STREAM
chmod +x "$STREAM_STUB"
export STREAM_SURF="$SURF" STREAM_HOLD=8

S=$(date +%s)
GOT=$(bash -c "set -euo pipefail; source '$LIB'; cmux_wait_turn_end '$SURF' 8" 2>/dev/null || true)
ELAPSED=$(( $(date +%s) - S ))

if [[ -n "$GOT" ]]; then
  pass "the turn-end wait gets its frame off a stream that stays open"
else
  fail "the turn-end wait gets its frame off a stream that stays open" "got nothing"
fi

if [[ $ELAPSED -le 3 ]]; then
  pass "it returns when the frame arrives (${ELAPSED}s), not when the 8s window ends"
else
  fail "it returns when the frame arrives, not when the window ends" \
       "took ${ELAPSED}s of an 8s window — the wait is paying for the whole window"
fi

# And it must survive `set -euo pipefail`, which is what every dial script runs.
if bash -c "set -euo pipefail; source '$LIB'; out=\$(cmux_wait_turn_end '$SURF' 8); [[ -n \"\$out\" ]]" 2>/dev/null; then
  pass "the wait survives set -euo pipefail"
else
  fail "the wait survives set -euo pipefail" "non-zero status propagated out"
fi

# No match in the window must still cost only the window, and yield nothing.
S=$(date +%s)
GOT=$(bash -c "set -euo pipefail; source '$LIB'; cmux_wait_turn_end 'SOME-OTHER-SURFACE' 2 || true" 2>/dev/null || true)
ELAPSED=$(( $(date +%s) - S ))
if [[ -z "$GOT" && $ELAPSED -le 5 ]]; then
  pass "no matching frame yields nothing and does not overrun the window (${ELAPSED}s)"
else
  fail "no matching frame yields nothing and does not overrun the window" \
       "got '$GOT' after ${ELAPSED}s"
fi

# The producer must not be left running once we have the answer: an orphaned
# `cmux events --timeout 600` per wait is a leak, and the fast-return shape that
# used process substitution measured the same 0s while leaking one every time.
#
# Match on the STUB'S PATH, not on the FIFO: cmux's fifo is a `>` redirect and
# never appears in its argv, so a pattern built from the fifo name matches
# nothing and the check passes with the kill removed. The path is under $TMP, so
# this can never match the operator's own cmux processes.
STREAM_HOLD=20 bash -c "set -euo pipefail; source '$LIB'; cmux_wait_turn_end '$SURF' 20" >/dev/null 2>&1 || true
LEAKED=$(pgrep -f "$TMP/bin/cmux" 2>/dev/null | wc -l | tr -d ' ')
if [[ "${LEAKED:-0}" -eq 0 ]]; then
  pass "the event producer is not left orphaned after an early return"
else
  fail "the event producer is not left orphaned after an early return" \
       "$LEAKED still running against a 20s window we returned from immediately"
  pkill -f "$TMP/bin/cmux" 2>/dev/null || true
fi

cp "$TMP/cmux.orig" "$STREAM_STUB"
unset STREAM_SURF STREAM_HOLD

# --- 11. The empty-handle guard names the right surface ----------------------
# The guard must name the CALLER'S OWN pane. A cmux CLI verb falls back to the
# inherited $CMUX_*_ID, so that is where an empty handle delivers; only a
# malformed `cmux rpc` resolves against the FOCUSED surface. Blaming the focused
# surface here is what sends the next debugger to the wrong pane, so the wording
# is asserted, not left to drift.
MSG=$(cmux_handle_ok "a probe" "" 2>&1 || true)
if printf '%s' "$MSG" | grep -qi 'FOCUSED'; then
  fail "the empty-handle guard names the caller's own pane, not the focused surface" \
       "message still blames the focused surface"
elif printf '%s' "$MSG" | grep -qi 'THIS pane' && printf '%s' "$MSG" | grep -q 'CMUX_\*_ID'; then
  pass "the empty-handle guard names the caller's own pane, not the focused surface"
else
  fail "the empty-handle guard names the caller's own pane, not the focused surface" \
       "got: $MSG"
fi

cmux_handle_ok "a probe" "$SURF" \
  && pass "a non-empty handle passes the guard" \
  || fail "a non-empty handle passes the guard"

echo
echo "$PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  failed: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
