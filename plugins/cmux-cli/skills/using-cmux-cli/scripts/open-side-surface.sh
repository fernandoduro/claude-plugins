#!/usr/bin/env bash
# open-side-surface — open a new surface side-by-side with the caller's (or
# the user's focused) pane. Encapsulates the case-1 decision tree so agents
# don't have to hand-roll it.
#
# Algorithm:
#   1. `cmux identify --json` → subject's pane_ref + workspace_ref.
#   2. `cmux tree --all --json --id-format both` → enumerate panes in that
#      workspace, WITH their UUIDs (see step 3 for why the UUIDs matter).
#   3. If subject's workspace has only ONE pane:
#        → `cmux new-pane --direction right --type <t> --workspace <ws> [--url]`
#          (new-pane is used instead of new-split because it supports both
#           terminal and browser types.)
#      Else pick the adjacent pane (subject's index + 1, or -1 if rightmost):
#        → `cmux new-surface --pane <adjacent-UUID> --type <t> [--url]`
#          (reuses the real estate the user has already allocated instead of
#           creating a third pane column.)
#          Targeted by UUID, not by `pane:N`: new-surface resolves a positional
#          ref inside a workspace context defaulting to $CMUX_WORKSPACE_ID, so a
#          bare ref fails as "not_found: Workspace not found" whenever the caller
#          lives in a different workspace than the pane it wants a sibling of.
#   4. Parse `OK surface:<n> pane:<p> workspace:<w>` from cmux's output, then
#      resolve UUIDs + human-readable names from a fresh `--id-format both` tree.
#   5. Apply `--title` via `cmux rename-tab` so the tab is findable in the UI,
#      and hand back surface_title / workspace_name — a positional ref is not
#      something the user can locate.

set -euo pipefail
trap 'exit 0' PIPE
trap 'exit 130' INT

SUBJECT="caller"     # caller | focused
SURFACE_TYPE="terminal"
URL=""
TITLE=""
OUTPUT_JSON=0
WAIT_READY=0
WAIT_READY_TIMEOUT=5

usage() {
  cat <<'EOF'
open-side-surface — open a new surface side-by-side with the caller's
(or the user's focused) pane.

Usage: open-side-surface [OPTIONS]

Options:
      --caller           Open next to the script caller's own pane (default).
                          Use when the agent wants a sibling for its own use.
      --focused          Open next to the pane the user is currently looking at.
                          Use when the user says "next to what I'm looking at".
      --type <t>         Surface type: terminal (default) or browser.
      --url <url>        URL for browser surfaces. Ignored for terminal.
      --title <text>     Human-visible tab title, applied with `cmux rename-tab`
                          right after creation. STRONGLY RECOMMENDED: without it
                          the tab keeps a generic auto-title (e.g. "zsh" or the
                          workspace's own name) that the user cannot pick out of
                          the tab bar. 2-5 words naming the activity.
      --json             Emit a JSON object on success. Default: human-readable.
      --wait-ready       For terminal surfaces, block until the PTY is attached
                          and the shell is actually executing input. The PTY
                          attaches on the first send (never by stealing focus);
                          round-trips a probe (echo <marker>) to verify
                          execution. No-op for browser surfaces.
      --wait-ready-timeout <seconds>
                          Override the --wait-ready timeout (default: 5).
  -h, --help             Show this help.

The script decides between `cmux new-pane --direction right` (when the
subject's workspace has only one pane) and `cmux new-surface --pane <adj-uuid>`
(when there's already an adjacent pane to reuse).

Output (text):
  OK surface:34 pane:12 workspace:9 (via new-surface)
  surface_id: F73756CC-...        # the UUID to target by
  title: dev server :3000         # what to tell the user (refs mean nothing to them)
  workspace: lindris frontend (workspace:9)

Output (--json): carries both the stable UUID (*_id — pass these to commands)
and the positional ref (*_ref — display only), plus the human-readable
names to report back (surface_title, workspace_name):
  {"surface_ref":"surface:34","surface_id":"F73756CC-...",
   "pane_ref":"pane:12","pane_id":"...","workspace_ref":"workspace:9","workspace_id":"...",
   "surface_title":"dev server :3000","workspace_name":"lindris frontend",
   "title_status":"applied",
   "mode":"new-surface","subject":"caller","surface_type":"terminal","url":null,"ready":"ready"}

Requires: cmux, jq.

Exit codes:
  0 = surface created (and ready, if --wait-ready)
  1 = cmux command failed (see stderr)
  2 = usage / dependency / context error
  3 = --wait-ready timed out (surface exists but PTY never echoed probe)
  4 = the surface was created but cmux never resolved it to a UUID; the ids are
      the point of the JSON, and a null one is how a payload reaches the CALLER'S
      own input box, so this refuses rather than reporting nulls as success
  130 = interrupted (Ctrl-C)
EOF
}

# --- Arg parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --caller)   SUBJECT="caller"; shift ;;
    --focused)  SUBJECT="focused"; shift ;;
    --type)     SURFACE_TYPE="${2:-}"; shift 2 ;;
    --url)      URL="${2:-}"; shift 2 ;;
    --title)    TITLE="${2:-}"; shift 2 ;;
    --json)     OUTPUT_JSON=1; shift ;;
    --wait-ready) WAIT_READY=1; shift ;;
    --wait-ready-timeout) WAIT_READY_TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "open-side-surface: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$SURFACE_TYPE" != "terminal" && "$SURFACE_TYPE" != "browser" ]]; then
  echo "open-side-surface: --type must be 'terminal' or 'browser' (got: $SURFACE_TYPE)" >&2
  exit 2
fi

# --- Preflight ---
command -v cmux >/dev/null 2>&1 || { echo "open-side-surface: cmux not on PATH" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "open-side-surface: jq required (brew install jq)" >&2; exit 2; }

# --- Resolve subject ---
# A freshly-spawned or just-moved caller surface can be momentarily unqueryable
# by `cmux identify` (it returns empty pane_ref/workspace_ref for the subject
# before cmux has registered the surface's current placement). That's a race,
# not a hard error, so retry a few times before giving up. `cmux identify`
# already derives workspace_ref from the live surface — the inherited
# CMUX_WORKSPACE_ID env var going stale after a move does NOT affect it — so a
# short retry is sufficient to ride out the registration lag.
subject_pane=""; subject_ws=""; subject_win=""; subject_surf=""
for attempt in 1 2 3 4 5; do
  if identify_json=$(cmux identify --json 2>/dev/null); then
    subject_pane=$(printf '%s' "$identify_json" | jq -r --arg s "$SUBJECT" '.[$s].pane_ref // empty')
    subject_ws=$(printf  '%s' "$identify_json" | jq -r --arg s "$SUBJECT" '.[$s].workspace_ref // empty')
    subject_win=$(printf '%s' "$identify_json" | jq -r --arg s "$SUBJECT" '.[$s].window_ref // empty')
    subject_surf=$(printf '%s' "$identify_json" | jq -r --arg s "$SUBJECT" '.[$s].surface_ref // empty')
    [[ -n "$subject_pane" && -n "$subject_ws" ]] && break
  fi
  [[ $attempt -lt 5 ]] && sleep 0.4
done

# Bash-tool shells are not attached to a tty. If identify returns `caller:null`
# while cmux's stable surface UUID is still available, use that stronger signal.
# A moved surface can also leave CMUX_WORKSPACE_ID stale. In either case the
# surface UUID is enough: resolve its CURRENT pane/workspace/window from one
# live tree snapshot instead of falling back to a detached workspace.
if [[ "$SUBJECT" == "caller" && ( -z "$subject_pane" || -z "$subject_ws" ) \
      && -n "${CMUX_SURFACE_ID:-}" ]]; then
  caller_tree=$(cmux tree --all --json --id-format both 2>/dev/null || true)
  if [[ -n "$caller_tree" ]]; then
    IFS=$'\t' read -r subject_pane subject_ws subject_win subject_surf < <(
      printf '%s' "$caller_tree" | jq -r --arg sid "$CMUX_SURFACE_ID" '
        .windows[] as $win
        | $win.workspaces[] as $ws
        | $ws.panes[] as $pane
        | $pane.surfaces[]
        | select(.id == $sid)
        | [$pane.ref, $ws.ref, $win.ref, .ref]
        | @tsv' 2>/dev/null | head -1
    ) || true
  fi
fi

if [[ -z "${identify_json:-}" ]]; then
  echo "open-side-surface: 'cmux identify' failed — are you inside cmux? is the socket reachable?" >&2
  exit 2
fi

if [[ -z "$subject_pane" || -z "$subject_ws" ]]; then
  echo "open-side-surface: could not resolve $SUBJECT.pane_ref / workspace_ref from identify or CMUX_SURFACE_ID (retried 5×; caller surface not registered?)" >&2
  exit 2
fi

# --- Enumerate panes in subject's workspace (ordered, with indexes) ---
# One snapshot, queried three ways: the ordered pane list, and the UUIDs of the
# window and workspace that list came out of.
# --id-format both is what puts `.id` (the UUIDs) in this snapshot; without it
# pane and surface ids come back null and the only thing we can hand `new-surface`
# is a positional ref, which is not safe to target by (see the branch below).
# Workspace ids are the exception — they are UUIDs either way (measured).
# tripwire: claude-plugins-7mff — whether side-by-side is supported at all on a
# cmux that ignores this flag is still open; the answer changes this header.
subject_tree=$(cmux tree --all --json --id-format both)

# TSV: pane_ref \t index \t pane_id
# Three columns, and the optional one is last on purpose: `read` with
# IFS=$'\t' treats tab as IFS whitespace, so a run of consecutive tabs is one
# delimiter. A container UUID packed in behind an empty pane `.id` would shift
# into `p_id` and be handed to `--pane`; the container UUIDs get their own
# queries below instead.
panes_tsv=$(printf '%s' "$subject_tree" | jq -r \
  --arg win "$subject_win" --arg ws "$subject_ws" '
    .windows[]
    | select(.ref == $win)
    | .workspaces[]
    | select(.ref == $ws)
    | .panes
    | sort_by(.index)
    | .[]
    | [.ref, (.index | tostring), (.id // "")]
    | @tsv
  ')

# `first(...)` rather than a `| head -1` pipe: `set -o pipefail` turns a jq
# killed by a closed pipe into a whole-script abort.
subject_ws_id=$(printf '%s' "$subject_tree" | jq -r \
  --arg win "$subject_win" --arg ws "$subject_ws" '
    first(.windows[] | select(.ref == $win) | .workspaces[] | select(.ref == $ws))
    | (.id // "")')
subject_win_id=$(printf '%s' "$subject_tree" | jq -r \
  --arg win "$subject_win" '
    first(.windows[] | select(.ref == $win)) | (.id // "")')

if [[ -z "$panes_tsv" ]]; then
  echo "open-side-surface: no panes found in $subject_ws (impossible?)" >&2
  exit 2
fi

# Read into parallel arrays (bash 3 compatible — no readarray/mapfile).
pane_refs=()
pane_indexes=()
pane_ids=()
while IFS=$'\t' read -r p_ref p_idx p_id; do
  pane_refs+=("$p_ref")
  pane_indexes+=("$p_idx")
  pane_ids+=("$p_id")
done <<< "$panes_tsv"

pane_count=${#pane_refs[@]}

# Find subject's position in the ordered pane list
my_pos=-1
for i in "${!pane_refs[@]}"; do
  if [[ "${pane_refs[$i]}" == "$subject_pane" ]]; then
    my_pos=$i
    break
  fi
done
if [[ $my_pos -lt 0 ]]; then
  echo "open-side-surface: subject pane $subject_pane not present in workspace pane list (stale state?)" >&2
  exit 2
fi

# --- Decide and execute ---
mode=""
if [[ $pane_count -eq 1 ]]; then
  # No adjacent pane exists — create one to the right.
  mode="new-pane"
  args=(new-pane --direction right --type "$SURFACE_TYPE" --workspace "$subject_ws")
  [[ "$SURFACE_TYPE" == "browser" && -n "$URL" ]] && args+=(--url "$URL")
else
  # Pick adjacent: prefer the pane immediately to the right (idx+1), else left.
  adj_pos=$((my_pos + 1))
  if [[ $adj_pos -ge $pane_count ]]; then
    adj_pos=$((my_pos - 1))
  fi
  adjacent_pane="${pane_refs[$adj_pos]}"
  adjacent_pane_id="${pane_ids[$adj_pos]}"
  mode="new-surface"
  # `cmux new-surface` scopes its --pane lookup to --workspace, which defaults
  # to $CMUX_WORKSPACE_ID (see `new-surface --help`). That scoping applies to a
  # pane UUID exactly as it does to a positional `pane:N`: a valid UUID whose
  # workspace is not the inherited one comes back `not_found: Pane not found`.
  # So the container is always pinned explicitly here — which is what a hotline
  # callee dialing onward needs, since its inherited workspace id names the
  # CALLER's workspace, not the one its own pane lives in. Every handle here is
  # a UUID when the snapshot carries one, ref only as a fallback: positional
  # refs renumber as surfaces open and close, so a ref read out of the snapshot
  # above can denote something else by the time this runs. (The new-pane branch
  # above pins --workspace for the same reason: never let cmux infer the
  # container.)
  subject_ws_target="${subject_ws_id:-$subject_ws}"
  subject_win_target="${subject_win_id:-$subject_win}"
  if [[ -n "$adjacent_pane_id" ]]; then
    args=(new-surface --pane "$adjacent_pane_id" --type "$SURFACE_TYPE" \
          --workspace "$subject_ws_target" --window "$subject_win_target")
  else
    # No pane UUID available: keep the positional ref, pinned to the same
    # context.
    args=(new-surface --pane "$adjacent_pane" --type "$SURFACE_TYPE" \
          --workspace "$subject_ws_target" --window "$subject_win_target")
  fi
  [[ "$SURFACE_TYPE" == "browser" && -n "$URL" ]] && args+=(--url "$URL")
fi

# --- Execute, capture, parse ---
if ! out=$(cmux "${args[@]}" 2>&1); then
  echo "open-side-surface: cmux ${args[*]} failed:" >&2
  printf '%s\n' "$out" >&2
  # cmux reports a context-resolution miss as a bare `not_found`, which reads as
  # if the target were gone when the real cause is usually that we could not
  # address it unambiguously. Say which, so the caller is not left guessing.
  if [[ "$out" == *"not_found"* ]]; then
    {
      echo "  The target was pinned explicitly ($subject_ws_target /"
      echo "  ${subject_win_target:-?} / ${adjacent_pane_id:-$adjacent_pane}), so this is not the"
      echo "  inherited-workspace miss: something moved between the tree snapshot above"
      echo "  and this call — the pane or its workspace closed, or the workspace was"
      echo "  moved to another window. Re-run to snapshot again."
    } >&2
  fi
  exit 1
fi

# Parse `OK surface:<n> pane:<p> workspace:<w>` (order may vary slightly).
new_surface=$(printf '%s' "$out" | grep -oE 'surface:[0-9]+' | head -1 || true)
new_pane=$(printf    '%s' "$out" | grep -oE 'pane:[0-9]+'    | head -1 || true)
new_ws=$(printf      '%s' "$out" | grep -oE 'workspace:[0-9]+' | head -1 || true)

# Fall back to what we know if the output surprises us.
[[ -z "$new_pane" && "$mode" == "new-surface" ]] && new_pane="$adjacent_pane"
[[ -z "$new_ws" ]] && new_ws="$subject_ws"

if [[ -z "$new_surface" ]]; then
  echo "open-side-surface: created a surface but could not parse its ref from cmux output:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# --- Resolve stable UUIDs (and human-readable names) for the new surface ---
# How hard to try before giving up: ~0.8s total, spent only on the failing path.
RESOLVE_TRIES="${CMUX_SIDE_RESOLVE_TRIES:-5}"
RESOLVE_SLEEP="${CMUX_SIDE_RESOLVE_SLEEP:-0.2}"
# The `OK ...` line only gives positional refs, which renumber as surfaces open
# and close. Look the new surface up in a fresh `--id-format both` tree so we can
# hand callers UUIDs (the `.id` fields) to target by — and use them ourselves for
# the readiness probes below. A ref that never resolves is a hard failure rather
# than a degrade: see the refusal below for why a reported null is worse than an
# error.
#
# The same lookup also pulls the surface's title and its workspace's name: a
# positional ref like `surface:258` is meaningless to the human (cmux's UI never
# shows it, and it renumbers), so callers need names to report back.
# A FRESH SURFACE IS NOT INSTANTLY ENUMERABLE, so the lookup is retried. The
# `OK surface:N` line comes back before the surface is necessarily in the tree,
# and a single snapshot taken in that gap finds nothing — observed live with a
# healthy surface that a tree taken moments later resolved perfectly.
#
# `read` consuming an empty lookup returns 1, which `set -euo pipefail` turns into
# an abort before the next line runs, so every attempt keeps its `|| true`
# (claude-plugins-h2et, -99nu). What that guard must NOT do is let an unresolved id
# leave this script as success — see the refusal below.
new_surface_id=""; new_pane_id=""; new_ws_id=""; new_surface_title=""; new_ws_name=""
resolve_tries=0
tree_read_ok=false
tree_err=""
while :; do
  tree_both=$(cmux tree --all --json --id-format both 2>/dev/null) || tree_both=""
  if [[ -n "$tree_both" ]]; then
    tree_read_ok=true
    IFS=$'\t' read -r new_surface_id new_pane_id new_ws_id new_surface_title new_ws_name < <(
      printf '%s' "$tree_both" | jq -r --arg s "$new_surface" '
        .windows[].workspaces[] as $ws
        | $ws.panes[].surfaces[]
        | select(.ref == $s)
        | [(.id // ""), (.pane_id // ""), ($ws.id // ""), (.title // ""), ($ws.title // "")]
        | @tsv' 2>/dev/null | head -1
    ) || true
  fi
  [[ -n "$new_surface_id" && -n "$new_pane_id" && -n "$new_ws_id" ]] && break
  resolve_tries=$((resolve_tries + 1))
  (( resolve_tries >= RESOLVE_TRIES )) && break
  sleep "$RESOLVE_SLEEP"
done

# --- An unresolved id is a hard failure, never a reported null. --------------
# Falling back to the positional ref and emitting `"surface_id": null` looked like
# the safe degrade, and it is the documented lead-in to the worst failure here: a
# caller does `SID=$(jq -r '.surface_id' …)`, gets an empty string, and the next
# `cmux send --surface "$SID"` falls back to $CMUX_SURFACE_ID and types the payload
# into THE CALLER'S OWN input box — exit 0, no warning. Only a caller that runs the
# guard this skill prescribes escapes it, and a JSON contract must not depend on
# every consumer remembering a guard.
#
# So: refuse.
#
# THE TRADEOFF, ACCEPTED DELIBERATELY. This is not a no-op for callers: hotline
# guards on `surface_ref`, not `surface_id` (`cmux-call-async.sh`, and
# `SURF_HANDLE="${SURF_ID:-$SURF_REF}"` below it), so it SURVIVED the old
# ref-degrade — a dial whose surface was healthy, titled and ready completed on the
# ref alone. Refusing therefore converts a limping-but-working dial into a hard
# failure, and that is the cost.
#
# It is worth paying because of the one cause a retry cannot fix. If the lookup
# failed because the echoed ref RENUMBERED — a `surface.moved` in the window
# between cmux minting the ref and this snapshot is exactly that
# (references/events.md) — then the ref no longer names the surface we created, and
# proceeding on it is how a work order gets pasted into a BYSTANDER'S live REPL.
# A failed dial is recoverable in one command; that is not recoverable at all.
#
# AND IT DELIBERATELY LEAVES AN ORPHAN. The surface exists and is not closed here,
# because there is nothing safe to close it BY: `cmux close-surface` needs a handle,
# and the only handle we have is the positional ref that may already name a
# different slot — closing on it would reap whatever occupies that slot now, which
# is the same reasoning that makes the caller's reap path refuse a ref
# (cmux-call-async.sh). A leaked surface a human can see and close is strictly
# better than a close that lands on a live tab. The diagnostic names the ref for
# that human and deliberately does NOT print a `surface_id=` line, so no reaper
# matches a UUID that was never resolved.
#
# Exit 4, distinct from 1 (create/parse), 2 (no panes / identify) and 3 (readiness
# or an empty handle), so a caller can tell "cmux would not name what it just made"
# from the failures it already handles.
if [[ -z "$new_surface_id" || -z "$new_pane_id" || -z "$new_ws_id" ]]; then
  {
    echo "open-side-surface: created $new_surface but cmux never resolved it to a UUID after ${RESOLVE_TRIES} attempts — refusing to report a null id as success."
    if ! $tree_read_ok; then
      echo "  Cause: \`cmux tree --all --json --id-format both\` returned nothing on every attempt, so no lookup ran at all."
    else
      echo "  Cause: the tree read fine but held no surface with ref $new_surface. Positional refs renumber as surfaces open and close, so the ref cmux echoed may already name a different slot."
    fi
    echo "  A null surface_id is how a payload ends up in the CALLER'S input box: an empty handle makes \`cmux send\` fall back to \$CMUX_SURFACE_ID."
    echo "  The surface was created and is NOT closed, because a positional ref is not safe to close by — it names whatever occupies that slot now. Find and close it by hand:"
    echo "    cmux tree --all --json --id-format both"
  } >&2
  exit 4
fi

surface_handle="$new_surface_id"
pane_handle="$new_pane_id"
ws_handle="$new_ws_id"

# --- Give the surface a human-visible name ---
# A freshly-created surface inherits a generic auto-title ("zsh", the cwd
# basename, or the workspace's own name). Reporting only `surface:<n>` for such a
# tab tells the user nothing they can act on — they cannot see refs in the UI and
# cannot distinguish three tabs all labelled the same generic word. So: name it,
# and if the caller didn't supply a name, say so loudly rather than silently
# handing back an unfindable surface.
title_status="unset"
if [[ -n "$TITLE" ]]; then
  if cmux rename-tab --workspace "$ws_handle" --tab "$surface_handle" -- "$TITLE" >/dev/null 2>&1; then
    new_surface_title="$TITLE"
    title_status="applied"
  else
    title_status="failed"
    {
      echo "open-side-surface: created $new_surface but 'cmux rename-tab' failed — the tab keeps its generic auto-title."
      echo "  Retry: cmux rename-tab --workspace $ws_handle --tab $surface_handle \"$TITLE\""
    } >&2
  fi
else
  {
    echo "open-side-surface: hint — no --title given, so $new_surface keeps a generic auto-title"
    echo "  (\"zsh\", the cwd, or the workspace name). The user cannot find it in the tab bar, and"
    echo "  \"$new_surface\" is not a locator they can use. Name it before reporting back:"
    echo "    cmux rename-tab --workspace $ws_handle --tab $surface_handle \"<2-5 word purpose>\""
  } >&2
fi

# --- Optional: wait for PTY readiness ---
#
# Solves two known footguns on freshly-spawned terminal surfaces:
#   1. `read-screen` fails ("Terminal surface not found", or "Failed to read
#      terminal text" on cmux 0.64.22) until something has SENT to the surface.
#      The send is the attachment mechanism — cmux attaches a surface's PTY
#      lazily, on first send — so the probe below is what makes the surface
#      readable, not something that waits for another step to do it.
#   2. The shell's `\n` gets swallowed by startup output, so `send "foo\n"` types
#      `foo` but never executes it. We round-trip an `echo <marker>` probe and
#      wait until the marker appears as command output (not just typed input).
#
# NO focus-pane here. It also attaches the PTY, eagerly, but it does so by moving
# the user's focus into this brand-new surface — so anything the user is typing at
# that instant goes to the new shell instead. That is a real incident, not a
# hypothetical: three stray keystrokes turned a launch command into
# `rkebash /tmp/…` on 2026-08-26. Measured cost of dropping it: ~0.1s.
#
# Re-sends the probe periodically — if a `\n` is swallowed by init, a later
# resend will land cleanly. Same nonce across resends; we only need ≥1 hit.
ready_status="skipped"
if [[ $WAIT_READY -eq 1 ]]; then
  if [[ "$SURFACE_TYPE" != "terminal" ]]; then
    ready_status="n/a"
  elif [[ -z "$surface_handle" ]]; then
    # `cmux send --surface ""` does NOT fail; it delivers to the focused surface.
    # A probe with no handle would therefore type into whatever the user is
    # looking at, so this is a hard error rather than a skipped check.
    echo "open-side-surface: created $new_surface but its handle came back empty — refusing to probe, because an empty --surface would send to the FOCUSED surface." >&2
    exit 3
  else

    nonce="$(date +%s)$$${RANDOM:-0}"
    marker="__CMUX_PTYREADY_${nonce}__"
    start_ts=$(date +%s)
    ready_status="timeout"
    attempt=0

    while :; do
      now_ts=$(date +%s)
      elapsed=$((now_ts - start_ts))
      if (( elapsed >= WAIT_READY_TIMEOUT )); then
        break
      fi

      # (Re)send the probe every ~1s in case earlier sends were swallowed.
      #
      # Ctrl-U (0x15) first, every time. The input line is shared with the user,
      # and a probe concatenated onto stray keystrokes produces `rkeecho MARKER`
      # — a shell error line that still carries the marker twice and so can
      # satisfy the ≥2-hit test below while proving nothing. Raw byte through the
      # TEXT path: `send-key ctrl+u` does not reach the program.
      if (( attempt % 5 == 0 )); then
        cmux send --surface "$surface_handle" $'\025' >/dev/null 2>&1 || true
        cmux send --surface "$surface_handle" "echo ${marker}\n" >/dev/null 2>&1 || true
      fi
      attempt=$((attempt + 1))
      sleep 0.2

      # The typed `echo MARKER` echoes back as input (1 hit); shell execution
      # adds the output line (2nd hit). >=2 hits => the shell actually ran it.
      hits=$(cmux read-screen --surface "$surface_handle" --scrollback --lines 200 2>/dev/null \
             | grep -Fc "${marker}" || true)
      if [[ "${hits:-0}" -ge 2 ]]; then
        ready_status="ready"
        break
      fi
    done

    if [[ "$ready_status" != "ready" ]]; then
      {
        echo "open-side-surface: --wait-ready timed out after ${WAIT_READY_TIMEOUT}s for $new_surface ($new_pane)."
        # THE UUIDs, in a parseable form, because this exit leaves a surface
        # behind and the caller's only description of it is this text. A
        # positional `surface:N` is not a safe thing to reap from: it names
        # whatever occupies slot N when the close runs, not the surface this
        # probe opened, and slots renumber the moment any sibling closes. Emitted
        # only when the tree resolved them — an unresolved id must read as absent,
        # not as the string "none".
        if [[ -n "$new_surface_id" ]]; then
          echo "  surface_id=$new_surface_id workspace_id=$new_ws_id pane_id=$new_pane_id"
        fi
        echo "  Possible causes:"
        echo "    • Shell still initializing (slow rc files, network mounts, login banner)"
        echo "    • Surface running a non-shell program that doesn't echo input"
        echo "    • The surface was closed while we were probing it"
        echo "  (The read is scroll-immune — --scrollback --lines — so a scrolled pane is not the cause.)"
      } >&2
      exit 3
    fi
  fi
fi

# --- Output ---
if [[ $OUTPUT_JSON -eq 1 ]]; then
  # *_id are the stable UUIDs — pass these to follow-up commands (send,
  # read-screen, close-surface, ...). *_ref are positional labels for display.
  jq -n \
    --arg surface    "$new_surface" \
    --arg surface_id "$new_surface_id" \
    --arg pane       "$new_pane" \
    --arg pane_id    "$new_pane_id" \
    --arg ws         "$new_ws" \
    --arg ws_id      "$new_ws_id" \
    --arg title      "$new_surface_title" \
    --arg ws_name    "$new_ws_name" \
    --arg title_st   "$title_status" \
    --arg mode       "$mode" \
    --arg subject    "$SUBJECT" \
    --arg type       "$SURFACE_TYPE" \
    --arg url        "$URL" \
    --arg ready      "$ready_status" \
    '{surface_ref: $surface, surface_id: (if $surface_id == "" then null else $surface_id end),
      pane_ref: $pane, pane_id: (if $pane_id == "" then null else $pane_id end),
      workspace_ref: $ws, workspace_id: (if $ws_id == "" then null else $ws_id end),
      surface_title: (if $title == "" then null else $title end),
      workspace_name: (if $ws_name == "" then null else $ws_name end),
      title_status: $title_st,
      mode: $mode, subject: $subject, surface_type: $type,
      url: (if $url == "" then null else $url end),
      ready: $ready}'
else
  printf 'OK %s %s %s (via %s, next to %s %s)\n' \
    "$new_surface" "$new_pane" "$new_ws" "$mode" "$SUBJECT" "$subject_pane"
  # The UUID to target by. Reaching this line means it resolved — an unresolved
  # one exits 4 above rather than printing a ref in a field callers read as a UUID.
  printf 'surface_id: %s\n' "$surface_handle"
  # Names, not refs, are what you report to the user.
  printf 'title: %s\n' "${new_surface_title:-(unnamed — rename it before reporting)}"
  printf 'workspace: %s (%s)\n' "${new_ws_name:-(unnamed)}" "$new_ws"
fi
