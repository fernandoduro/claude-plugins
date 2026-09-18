#!/usr/bin/env bash
# =============================================================================
# The call dir's routing signals: which backend owns this call, and which cmux
# placement hosts it.
#
# SOURCE this, don't execute it. Both waiters read transport.txt and must never
# disagree about what counts as a backend name, and Phase 1 gives both of them a
# herdr branch — so the judgement has two callers before it has its second value.
# The placement signal below has three callers for the same reason.
#
#   skills/dial/scripts/wait-for-session.sh   — which host do I boot-wait on?
#   skills/dial/scripts/wait-for-response.sh  — which host do I poll for STATUS,
#                                               and which verb closes it?
#   skills/dial/scripts/dial.sh               — did the placement degrade?
# =============================================================================

# Every backend the call-dir contract names. The set is the spec's
# (docs/plans/2026-08-13-hotline-transport-adapter-herdr.md §2.1), not this tree's:
# 'herdr' is accepted here before Phase 1 implements its verbs, so a herdr call
# dir stays READABLE by a Phase 0 waiter instead of being rejected by it.
HOTLINE_TRANSPORTS=(cmux herdr headless)

# call_dir_transport <call-dir>
#
# Echoes the backend named in <call-dir>/transport.txt, or "" when no backend is
# named — an absent file (a legacy or hand-staged call dir) or an empty one. Both
# mean "this file names nothing, so infer the backend from the host handles": a
# launcher that died between creating the dir and writing the value hands the waiter its
# own done+error.txt, and that is a better diagnosis than anything this function
# could say about a file it never finished writing.
#
# A value OUTSIDE the set above is a hard error. It says the call dir was made by
# a hotline that knows a backend this one does not, and every way of guessing is
# worse than saying so: inferring cmux polls a host of the wrong kind, and
# inferring headless file-watches a `done` nobody will write until --timeout
# expires — up to 30 minutes of silence bought by a one-word mismatch.
#
# Returns 1 on that error, message on stderr. Callers must run it as
#   TRANSPORT=$(call_dir_transport "$CALL_DIR") || exit 1
# because an `exit` inside the command substitution would leave only the subshell.
call_dir_transport() {  # <call-dir>
  local dir="${1:-}" value known
  [[ -f "$dir/transport.txt" ]] || return 0
  value=$(tr -d '[:space:]' < "$dir/transport.txt" 2>/dev/null || true)
  [[ -n "$value" ]] || return 0
  for known in "${HOTLINE_TRANSPORTS[@]}"; do
    [[ "$value" == "$known" ]] && { printf '%s' "$value"; return 0; }
  done
  printf "call_dir names transport '%s', which this hotline has no verbs for — known: %s (%s/transport.txt)\n" \
    "$value" "${HOTLINE_TRANSPORTS[*]}" "$dir" >&2
  return 1
}

# Every cmux placement the call-dir contract names, in the spelling dial.sh's
# `.placement` field uses.
HOTLINE_CMUX_PLACEMENTS=(side detached window)

# call_dir_placement <call-dir>
#
# Echoes which cmux placement HOSTS this call: 'side', 'detached' or 'window'.
# The launcher writes it to placement.txt once the placement is final — after any
# degrade — so every later reader gets the placement that actually happened
# rather than the one that was asked for.
#
# IT REPLACES AN ABSENCE. The sub-mode used to be inferred from which host-handle
# file existed: surface_ref.txt meant a surface placement, workspace_ref.txt alone
# meant detached. That coupled two unrelated questions — "which host do I poll and
# close?" and "do we know a surface to re-address on a follow-up?" — so a detached
# callee could not record its surface without also being read as a side placement
# and having its tab closed by the wrong verb (claude-plugins-zaus). A detached
# call now records BOTH handles, and this is what tells the two apart.
#
# An absent or unrecognised placement.txt is a legacy call dir (or one staged by
# hand), and falls back to exactly the old inference so those keep working.
# Returns 1 when neither the marker nor a handle says anything, which means the
# dir names no cmux host at all — headless, or a launcher that died before
# placing one.
call_dir_placement() {  # <call-dir>
  local dir="${1:-}" value known
  if [[ -f "$dir/placement.txt" ]]; then
    value=$(tr -d '[:space:]' < "$dir/placement.txt" 2>/dev/null || true)
    for known in "${HOTLINE_CMUX_PLACEMENTS[@]}"; do
      [[ "$value" == "$known" ]] && { printf '%s' "$value"; return 0; }
    done
  fi
  if [[ -f "$dir/surface_ref.txt" ]]; then
    printf 'side'
  elif [[ -f "$dir/workspace_ref.txt" ]]; then
    printf 'detached'
  else
    return 1
  fi
}
