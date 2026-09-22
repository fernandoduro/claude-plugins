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
# A tree whose pane `.id`s are null is fixtured too, because it reaches the
# other `new-surface` branch — the one that targets the positional `pane:N` —
# and because that is the shape where a container UUID packed into the pane
# TSV would shift into the `--pane` slot. Both are asserted by exact argv
# value, not by substring. A tree whose window `.id` is null covers the
# ref fallback for `--window`.
#
# One case covers a different failure in the same code path: cmux echoing a
# `surface:N` it then does not resolve in a tree read. The opener looks that ref
# up to trade it for UUIDs and names, and the `read` consuming that lookup is
# fatal under `set -euo pipefail` when it comes back empty — so the script
# aborted with rc=1, no stdout and no stderr, one line above the fallback
# written for exactly that case, taking hotline's whole cmux transport with it
# (`stage: boot`, `detail: "open-side-surface.sh failed (rc=1): "`). The guard
# is `|| true`; this is what proves it is still there. (claude-plugins-99nu,
# and the ledger's "guard a `read` that consumes a lookup" entry.)
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
WIN_ID="EEEEEEEE-0000-0000-0000-0000000000E1"

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
WIN_ID="$WIN_ID"
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
    # Tree reads are COUNTED, because the live bug is a race: the surface is not
    # in the tree yet when the opener looks, and is there moments later. A stub
    # that answers the same way every time cannot exhibit that at all.
    tree_reads=$(( $(cat "$ST/tree_reads" 2>/dev/null || echo 0) + 1 ))
    echo "$tree_reads" > "$ST/tree_reads"
    # The tree call itself failing after the create — the other cause of an
    # unresolved id, and indistinguishable from the first without a diagnostic.
    # Only AFTER the create: the opener's pre-create tree read is what finds the
    # panes, and suppressing that one tests a different branch entirely.
    if [[ -n "${CMUX_FAKE_TREE_EMPTY_AFTER_CREATE:-}" && -s "$ST/create_calls" ]]; then
      exit 0
    fi
    t=$(jq -n \
      --arg wsx "$WS_X_ID" --arg wsy "$WS_Y_ID" --arg win "$WIN_ID" \
      --arg caller "$SURF_CALLER_ID" --arg adj "$PANE_ADJACENT_ID" '
      {windows: [{ref:"window:1", id:$win, index:0, workspaces: [
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
      ]}]}')
    # Older cmux (and any tree read without --id-format both) reports `.id` as
    # null. Model each level independently: the opener has a different handle
    # to fall back on for each.
    # tripwire: claude-plugins-7mff — this nulls panes[].id but leaves
    # surfaces[].pane_id set, which cmux cannot produce; a faithful fixture turns
    # cases 1-2 into the rc 4 refusal. Read the bead before making it faithful.
    [[ -n "${CMUX_FAKE_PANE_IDS_NULL:-}" ]] \
      && t=$(printf '%s' "$t" | jq '(.windows[].workspaces[].panes[].id) = null')
    [[ -n "${CMUX_FAKE_WINDOW_ID_NULL:-}" ]] \
      && t=$(printf '%s' "$t" | jq '(.windows[].id) = null')
    # cmux echoes `OK surface:258` and then a tree read does not resolve that
    # ref — observed live, and the shape that aborted the opener outright.
    [[ -n "${CMUX_FAKE_NEW_SURFACE_MISSING:-}" ]] \
      && t=$(printf '%s' "$t" | jq '(.windows[].workspaces[].panes[].surfaces) |=
               map(select(.ref != "surface:258"))')
    # The RACE, as observed live: absent from the first N tree reads taken after
    # the create, present from N+1 on. `--wait-ready --json` reported all four ids
    # null while `cmux tree` moments later resolved the same ref perfectly.
    if [[ -n "${CMUX_FAKE_NEW_SURFACE_AFTER:-}" && -s "$ST/create_calls" ]]; then
      post=$(( tree_reads - $(cat "$ST/tree_reads_at_create" 2>/dev/null || echo 0) ))
      if (( post <= CMUX_FAKE_NEW_SURFACE_AFTER )); then
        t=$(printf '%s' "$t" | jq '(.windows[].workspaces[].panes[].surfaces) |=
               map(select(.ref != "surface:258"))')
      fi
    fi
    printf '%s\n' "$t" ;;
  new-surface|new-pane)
    echo "$*" >> "$ST/create_calls"
    # Where the post-create tree reads start counting from.
    cat "$ST/tree_reads" 2>/dev/null > "$ST/tree_reads_at_create" || echo 0 > "$ST/tree_reads_at_create"
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

# The value cmux received for a flag, read back out of the recorded argv.
arg_after() {
  awk -v f="$1" '{for (i = 1; i <= NF; i++) if ($i == f) { print $(i+1); exit }}' \
    "$2" 2>/dev/null
}

want() {
  local label="$1" got="$2" expect="$3"
  if [[ "$got" == "$expect" ]]; then pass "$label"; else fail "$label" "got=[$got] want=[$expect]"; fi
}

# Assert the recorded create call carries the intended pane handle and the
# subject's real container. Exact values, because the failure mode being
# guarded is the right flag with the wrong value in it.
assert_pinned() {
  local label="$1" calls_file="$2" want_pane="$3" want_win="$4"
  local calls got_pane
  calls=$(cat "$calls_file" 2>/dev/null || echo NONE)
  got_pane=$(arg_after --pane "$calls_file")
  want "$label: targets the adjacent pane as $want_pane" "$got_pane" "$want_pane"
  want "$label: pins --workspace to the pane's real workspace, not the inherited one" \
       "$(arg_after --workspace "$calls_file")" "$WS_Y_ID"
  want "$label: pins --window alongside it" "$(arg_after --window "$calls_file")" "$want_win"
  # A container UUID in the --pane slot is `not_found: Pane not found` all over
  # again, and it is what a collapsed multi-column TSV read produces.
  if [[ "$got_pane" != "$WS_Y_ID" && "$got_pane" != "$WS_X_ID" && "$got_pane" != "$WIN_ID" ]]; then
    pass "$label: --pane never receives a container UUID"
  else
    fail "$label: --pane never receives a container UUID" "calls=$calls"
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
assert_pinned "identify caller:null" "$tmp/create_calls" "$PANE_ADJACENT_ID" "$WIN_ID"

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
assert_pinned "identify succeeds" "$tmp2/create_calls" "$PANE_ADJACENT_ID" "$WIN_ID"

# --- Case 3: pane `.id`s are null — the positional branch, still pinned ---
# The opener has no pane UUID to target, so it hands cmux `pane:3`; that ref
# only resolves inside the right window/workspace, so the container flags are
# what make the call work at all. The workspace and window still carry UUIDs
# here, which is the shape where a container UUID can end up in --pane.
tmp3=$(mktemp -d "${TMPDIR:-/tmp}/cmux-scope-c-XXXXXX"); make_shim "$tmp3"
out3=$(PATH="$tmp3/bin:$PATH" CMUX_FAKE_STATE="$tmp3" CMUX_FAKE_PANE_IDS_NULL=1 \
       CMUX_SURFACE_ID="$SURF_CALLER_ID" CMUX_WORKSPACE_ID="$WS_X_ID" \
       bash "$OPENER" --caller --title "scoped side surface" --json 2>"$tmp3/err.txt")
rc3=$?
if [[ $rc3 -eq 0 && "$(jq -r '.surface_ref' <<<"$out3" 2>/dev/null)" == "surface:258" ]]; then
  pass "pane .id null — opens side-by-side on the positional ref"
else
  fail "pane .id null — opens side-by-side on the positional ref" \
       "rc=$rc3 out=$out3 err=$(cat "$tmp3/err.txt")"
fi
assert_pinned "pane .id null" "$tmp3/create_calls" "pane:3" "$WIN_ID"

# --- Case 4: window `.id` is null — --window falls back to the ref ---
tmp4=$(mktemp -d "${TMPDIR:-/tmp}/cmux-scope-d-XXXXXX"); make_shim "$tmp4"
out4=$(PATH="$tmp4/bin:$PATH" CMUX_FAKE_STATE="$tmp4" CMUX_FAKE_WINDOW_ID_NULL=1 \
       CMUX_SURFACE_ID="$SURF_CALLER_ID" CMUX_WORKSPACE_ID="$WS_X_ID" \
       bash "$OPENER" --caller --title "scoped side surface" --json 2>"$tmp4/err.txt")
rc4=$?
if [[ $rc4 -eq 0 && "$(jq -r '.surface_ref' <<<"$out4" 2>/dev/null)" == "surface:258" ]]; then
  pass "window .id null — opens side-by-side"
else
  fail "window .id null — opens side-by-side" \
       "rc=$rc4 out=$out4 err=$(cat "$tmp4/err.txt")"
fi
assert_pinned "window .id null" "$tmp4/create_calls" "$PANE_ADJACENT_ID" "window:1"
# --- Case 5: cmux echoes a ref the tree does not resolve ---------------------
# THE CONTRACT HERE CHANGED, and the direction matters. The `read` consuming an
# empty lookup returns 1, which `set -euo pipefail` turns into an abort before the
# next line runs, so each attempt keeps its `|| true` (claude-plugins-h2et, -99nu)
# — but degrading to the positional ref and reporting `"surface_id": null` as a
# SUCCESS is the documented lead-in to the worst failure in this repo. A caller
# does `SID=$(jq -r '.surface_id' …)`, gets an empty string, and the next
# `cmux send --surface "$SID"` falls back to $CMUX_SURFACE_ID and types the payload
# into the CALLER'S OWN input box, exit 0, no warning. Observed live with all four
# ids null against a surface that was completely healthy.
#
# So an id that will not resolve is now rc 4 with a diagnostic, and these cases pin
# that it is never reported as a success instead.
tmp5=$(mktemp -d "${TMPDIR:-/tmp}/cmux-scope-e-XXXXXX"); make_shim "$tmp5"
out5=$(PATH="$tmp5/bin:$PATH" CMUX_FAKE_STATE="$tmp5" CMUX_FAKE_NEW_SURFACE_MISSING=1 \
       CMUX_SIDE_RESOLVE_TRIES=2 CMUX_SIDE_RESOLVE_SLEEP=0 \
       CMUX_SURFACE_ID="$SURF_CALLER_ID" CMUX_WORKSPACE_ID="$WS_X_ID" \
       bash "$OPENER" --caller --title "scoped side surface" --json 2>"$tmp5/err.txt")
rc5=$?
err5=$(cat "$tmp5/err.txt")
if [[ $rc5 -eq 4 ]]; then
  pass "unresolvable echoed ref — fails loudly (rc 4), never reports a null id as success"
else
  fail "unresolvable echoed ref — fails loudly (rc 4), never reports a null id as success" \
       "rc=$rc5 out=[$out5] err=[$err5]"
fi
# NO success payload on stdout. This is strictly stronger than the old assertion
# that `.surface_id` be JSON null rather than the string "null": `jq -r` renders
# both identically, so a consumer's `[[ -n "$SID" ]]` guard passes on either and
# hands cmux `--surface null` — not empty, so cmux substitutes a target instead of
# refusing. With no payload at all there is nothing for that guard to misread.
if [[ -z "$out5" ]] || ! jq -e 'has("surface_id")' <<<"$out5" >/dev/null 2>&1; then
  pass "unresolvable echoed ref — emits no JSON payload for a caller to misparse"
else
  fail "unresolvable echoed ref — emits no JSON payload for a caller to misparse" "out=[$out5]"
fi
# The surface EXISTS and is not closed, so the diagnostic has to name it. It must
# name the REF (a human can find it) and must NOT print a `surface_id=` line: the
# caller's reap path greps for exactly that and would try to close a UUID that was
# never resolved (cmux-call-async.sh).
if printf '%s' "$err5" | grep -qF 'surface:258'; then
  pass "unresolvable echoed ref — the diagnostic names the surface left behind"
else
  fail "unresolvable echoed ref — the diagnostic names the surface left behind" "err=[$err5]"
fi
if printf '%s' "$err5" | grep -q 'surface_id='; then
  fail "unresolvable echoed ref — never prints a surface_id= a reaper would act on" "err=[$err5]"
else
  pass "unresolvable echoed ref — never prints a surface_id= a reaper would act on"
fi
# Which of the two causes it was. Both produce an empty lookup and only the
# diagnostic can tell them apart.
if printf '%s' "$err5" | grep -qF 'held no surface with ref'; then
  pass "unresolvable echoed ref — says the tree read fine but had no such ref"
else
  fail "unresolvable echoed ref — says the tree read fine but had no such ref" "err=[$err5]"
fi

# --- Case 5b: the post-create tree read itself comes back empty --------------
# The other cause of an unresolved id. Same refusal, different sentence — a reader
# told "no such ref" would go hunting a renumbering bug that is not there.
tmp5b=$(mktemp -d "${TMPDIR:-/tmp}/cmux-scope-f-XXXXXX"); make_shim "$tmp5b"
out5b=$(PATH="$tmp5b/bin:$PATH" CMUX_FAKE_STATE="$tmp5b" CMUX_FAKE_TREE_EMPTY_AFTER_CREATE=1 \
        CMUX_SIDE_RESOLVE_TRIES=2 CMUX_SIDE_RESOLVE_SLEEP=0 \
        CMUX_SURFACE_ID="$SURF_CALLER_ID" CMUX_WORKSPACE_ID="$WS_X_ID" \
        bash "$OPENER" --caller --title "scoped side surface" --json 2>"$tmp5b/err.txt")
rc5b=$?
err5b=$(cat "$tmp5b/err.txt")
if [[ $rc5b -eq 4 && -z "$out5b" ]]; then
  pass "a tree read that returns nothing after the create also refuses (rc 4, no payload)"
else
  fail "a tree read that returns nothing after the create also refuses (rc 4, no payload)" \
       "rc=$rc5b out=[$out5b] err=[$err5b]"
fi
if printf '%s' "$err5b" | grep -qF 'returned nothing on every attempt'; then
  pass "…and names THAT cause rather than blaming a missing ref"
else
  fail "…and names THAT cause rather than blaming a missing ref" "err=[$err5b]"
fi

# --- Case 5c: the live shape — the surface shows up on a later tree read -----
# This is what was actually observed: `--wait-ready --json` reported all four ids
# null, and `cmux tree --all --json --id-format both` moments later resolved the
# same `surface:73` to a healthy, correctly-titled surface. A single snapshot
# taken in that gap finds nothing, so the lookup is retried — and the retry is the
# fix, not the refusal above it.
tmp5c=$(mktemp -d "${TMPDIR:-/tmp}/cmux-scope-g-XXXXXX"); make_shim "$tmp5c"
out5c=$(PATH="$tmp5c/bin:$PATH" CMUX_FAKE_STATE="$tmp5c" CMUX_FAKE_NEW_SURFACE_AFTER=2 \
        CMUX_SIDE_RESOLVE_TRIES=5 CMUX_SIDE_RESOLVE_SLEEP=0 \
        CMUX_SURFACE_ID="$SURF_CALLER_ID" CMUX_WORKSPACE_ID="$WS_X_ID" \
        bash "$OPENER" --caller --title "scoped side surface" --json 2>"$tmp5c/err.txt")
rc5c=$?
if [[ $rc5c -eq 0 ]]; then
  pass "a surface that appears on a later tree read resolves instead of failing"
else
  fail "a surface that appears on a later tree read resolves instead of failing" \
       "rc=$rc5c out=[$out5c] err=[$(cat "$tmp5c/err.txt")]"
fi
want "…and reports the UUID, not the ref it was looked up by" \
     "$(jq -r '.surface_id' <<<"$out5c" 2>/dev/null)" "SURF-NEW"
# The invariant, stated positively: a payload that IS emitted has all three ids.
# `pane_id` and `workspace_id` are not cosmetic — they are what pins the container
# on every follow-up call, and an unpinned one resolves in the caller's context.
if jq -e '(.surface_id | type == "string") and (.pane_id | type == "string")
          and (.workspace_id | type == "string")' <<<"$out5c" >/dev/null 2>&1; then
  pass "a successful payload never carries a null surface_id/pane_id/workspace_id"
else
  fail "a successful payload never carries a null surface_id/pane_id/workspace_id" "out=[$out5c]"
fi
# And the retry must not have been free of the guard it replaced: the run above
# consumed more than one post-create tree read, which is the only proof the retry
# ran rather than the fixture simply answering on the first look.
post_reads=$(( $(cat "$tmp5c/tree_reads" 2>/dev/null || echo 0) - $(cat "$tmp5c/tree_reads_at_create" 2>/dev/null || echo 0) ))
if (( post_reads >= 3 )); then
  pass "…having actually retried the lookup (${post_reads} post-create tree reads)"
else
  fail "…having actually retried the lookup" "only $post_reads post-create tree reads"
fi

echo
echo "side-surface-scope: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  failed: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
