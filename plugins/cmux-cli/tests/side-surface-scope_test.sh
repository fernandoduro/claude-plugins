#!/usr/bin/env bash
# =============================================================================
# open-side-surface.sh: `new-surface` always carries the container.
#
# `cmux new-surface` scopes its --pane lookup to --workspace, which defaults to
# $CMUX_WORKSPACE_ID — and that scoping applies to a pane UUID exactly as it
# does to a positional `pane:N`. A valid UUID in another workspace comes back
# `not_found: Pane not found`, which hotline's cmux-call-async.sh reads as the
# documented degrade, so every side-by-side dial from an agent-spawned session
# opened a detached tab instead. The shim below models that real scoping: a
# `new-surface` whose workspace is not the subject's is rejected the way cmux
# rejects it, so these cases fail if the opener ever stops pinning the context.
#
# Both directions are fixtured on purpose. The bug was found via `identify`
# returning caller:null (the env surface and workspace disagree, so the tree
# fallback supplies the placement), but the missing flags were in a branch that
# a normal `identify` reaches too. (claude-plugins-qyj1)
#
# Driven entirely by a shimmed `cmux` on PATH — never touches real cmux.
# =============================================================================
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TESTS_DIR/.." && pwd)"
OPENER="$PLUGIN_DIR/skills/using-cmux-cli/scripts/open-side-surface.sh"

# Workspace X: what the agent-spawned session inherited in its env.
# Workspace Y: where its surface actually lives, per the tree.
WS_X_ID="AAAAAAAA-0000-0000-0000-00000000000X"
WS_Y_ID="BBBBBBBB-0000-0000-0000-00000000000Y"
SURF_CALLER_ID="CCCCCCCC-0000-0000-0000-0000000000C1"
PANE_ADJACENT_ID="DDDDDDDD-0000-0000-0000-0000000000D1"

PASS=0
FAIL=0
FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

command -v jq >/dev/null 2>&1 || {
  echo "side-surface-scope: jq not installed — skipping suite"
  echo "0 passed, 0 failed (skipped: jq missing)"
  exit 0
}

# --- Shim -------------------------------------------------------------------
# Two workspaces in one window. The subject's workspace (Y) holds two panes, so
# the opener takes the new-surface branch and targets the adjacent pane.
make_shim() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/cmux" <<SHIM
#!/usr/bin/env bash
ST="\${CMUX_FAKE_STATE:?}"
WS_X_ID="$WS_X_ID"
WS_Y_ID="$WS_Y_ID"
SURF_CALLER_ID="$SURF_CALLER_ID"
PANE_ADJACENT_ID="$PANE_ADJACENT_ID"
SHIM
  cat >> "$dir/bin/cmux" <<'SHIM'
case "$1" in
  identify)
    if [[ -n "${CMUX_FAKE_IDENTIFY_EMPTY:-}" ]]; then
      # cmux returns caller:null whenever CMUX_SURFACE_ID and
      # CMUX_WORKSPACE_ID disagree — the agent-spawned-session shape.
      jq -n '{caller: null}'
    else
      jq -n '{caller: {pane_ref:"pane:4", workspace_ref:"workspace:70",
                       window_ref:"window:1", surface_ref:"surface:12"}}'
    fi
    ;;
  tree)
    jq -n \
      --arg wsx "$WS_X_ID" --arg wsy "$WS_Y_ID" \
      --arg caller "$SURF_CALLER_ID" --arg adj "$PANE_ADJACENT_ID" '
      {windows: [{ref:"window:1", id:"WIN-UUID", index:0, workspaces: [
        {ref:"workspace:9", id:$wsx, index:0, title:"inherited env workspace",
         panes: [{ref:"pane:1", id:"PANE-ELSEWHERE", index:0,
           surfaces: [{ref:"surface:2", id:"SURF-ELSEWHERE", pane_id:"PANE-ELSEWHERE", index:0, title:"zsh"}]}]},
        {ref:"workspace:70", id:$wsy, index:1, title:"real home workspace",
         panes: [
           {ref:"pane:3", id:$adj, index:0, surfaces: [
             {ref:"surface:11", id:"SURF-ADJACENT", pane_id:$adj, index:0, title:"zsh"},
             {ref:"surface:258", id:"SURF-NEW", pane_id:$adj, index:1, title:"zsh"}]},
           {ref:"pane:4", id:"PANE-CALLER", index:1, surfaces: [
             {ref:"surface:12", id:$caller, pane_id:"PANE-CALLER", index:0, title:"agent"}]}]}
      ]}]}' ;;
  new-surface|new-pane)
    echo "$*" >> "$ST/create_calls"
    # Model cmux's real scoping: the --pane lookup happens inside --workspace,
    # defaulting to $CMUX_WORKSPACE_ID. Anything but the subject's own
    # workspace cannot see the pane.
    ws=""
    prev=""
    for a in "$@"; do
      [[ "$prev" == "--workspace" ]] && ws="$a"
      prev="$a"
    done
    [[ -z "$ws" ]] && ws="${CMUX_WORKSPACE_ID:-}"
    if [[ "$ws" != "$WS_Y_ID" && "$ws" != "workspace:70" ]]; then
      echo "Error: not_found: Pane not found" >&2
      exit 1
    fi
    echo "OK surface:258 pane:3 workspace:70" ;;
  rename-tab) echo "OK" ;;
  focus-pane|send|read-screen) exit 0 ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$dir/bin/cmux"
}

# Assert the recorded create call pins pane UUID + the subject's real container.
assert_pinned() {
  local label="$1" calls_file="$2"
  local calls
  calls=$(cat "$calls_file" 2>/dev/null || echo NONE)
  if grep -q -- "--pane $PANE_ADJACENT_ID" <<<"$calls"; then
    pass "$label: targets the adjacent pane by UUID"
  else
    fail "$label: targets the adjacent pane by UUID" "calls=$calls"
  fi
  if grep -q -- "--workspace $WS_Y_ID" <<<"$calls"; then
    pass "$label: pins --workspace to the pane's real workspace, not the inherited one"
  else
    fail "$label: pins --workspace to the pane's real workspace, not the inherited one" \
         "calls=$calls"
  fi
  if grep -q -- "--window window:1" <<<"$calls"; then
    pass "$label: pins --window alongside it"
  else
    fail "$label: pins --window alongside it" "calls=$calls"
  fi
  if ! grep -q -- "--workspace $WS_X_ID" <<<"$calls"; then
    pass "$label: never hands cmux the inherited CMUX_WORKSPACE_ID"
  else
    fail "$label: never hands cmux the inherited CMUX_WORKSPACE_ID" "calls=$calls"
  fi
}

echo "open-side-surface.sh new-surface container scoping:"

# --- Case 1: identify returns caller:null; the tree supplies the placement ---
# The live shape from claude-plugins-qyj1: the env names workspace X, the
# surface actually lives in workspace Y.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmux-scope-a-XXXXXX"); make_shim "$tmp"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" CMUX_FAKE_IDENTIFY_EMPTY=1 \
      CMUX_SURFACE_ID="$SURF_CALLER_ID" CMUX_WORKSPACE_ID="$WS_X_ID" \
      bash "$OPENER" --caller --title "scoped side surface" --json 2>"$tmp/err.txt")
rc=$?
if [[ $rc -eq 0 && "$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)" == "surface:258" ]]; then
  pass "identify caller:null — opens side-by-side instead of failing not_found"
else
  fail "identify caller:null — opens side-by-side instead of failing not_found" \
       "rc=$rc out=$out err=$(cat "$tmp/err.txt")"
fi
assert_pinned "identify caller:null" "$tmp/create_calls"

# --- Case 2: identify succeeds normally — the flags are still there ---
# Same branch, reached the ordinary way. The env still names workspace X, so a
# bare --pane would fail here too.
tmp2=$(mktemp -d "${TMPDIR:-/tmp}/cmux-scope-b-XXXXXX"); make_shim "$tmp2"
out2=$(PATH="$tmp2/bin:$PATH" CMUX_FAKE_STATE="$tmp2" \
       CMUX_SURFACE_ID="$SURF_CALLER_ID" CMUX_WORKSPACE_ID="$WS_X_ID" \
       bash "$OPENER" --caller --title "scoped side surface" --json 2>"$tmp2/err.txt")
rc2=$?
if [[ $rc2 -eq 0 && "$(jq -r '.surface_ref' <<<"$out2" 2>/dev/null)" == "surface:258" ]]; then
  pass "identify succeeds — opens side-by-side"
else
  fail "identify succeeds — opens side-by-side" \
       "rc=$rc2 out=$out2 err=$(cat "$tmp2/err.txt")"
fi
assert_pinned "identify succeeds" "$tmp2/create_calls"

echo
echo "side-surface-scope: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  failed: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
