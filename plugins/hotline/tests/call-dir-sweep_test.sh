#!/usr/bin/env bash
# =============================================================================
# Regression tests for two pieces of claude-plugins-x7m9 / -yded:
#
#   1. dial.sh's TTL sweep — abandoned `hotline-call-*` dirs under
#      HOTLINE_CALL_HOME are reaped at the start of the next dial once they
#      clear HOTLINE_CALL_SWEEP_DAYS (default 3), regardless of whether the
#      call that made them ever finished. A fresh dir is left alone.
#
#   2. cmux-call-async.sh's side-by-side opener failure, in the shape that
#      defeats its own orphan reap: the opener exits reporting NOTHING (empty
#      stderr, no surface_id, no positional ref) — a shell-level abort, not
#      something cmux refused. Neither the UUID reap nor its ref-only refusal
#      note can fire on an empty file, so the launcher has to say a surface
#      may exist anyway instead of going silent.
#
# Both are exercised directly against the scripts under test — no cmux, no
# claude, no network.
# =============================================================================
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
DIAL="$HOTLINE_DIR/skills/dial/scripts/dial.sh"
CMUX_ASYNC="$HOTLINE_DIR/skills/dial/scripts/cmux-call-async.sh"

TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT=${TMP_ROOT%/}

PASS=0
FAIL=0
FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
  return 0
}
check() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi }

# Poison stubs: this suite promises it never reaches a real cmux or claude.
POISON_BIN=$(mktemp -d "$TMP_ROOT/hotline-sweep-poison-XXXXXX")
for _poison in cmux claude; do
  cat > "$POISON_BIN/$_poison" <<EOF
#!/usr/bin/env bash
echo "TEST BUG: reached the real $_poison" >&2
exit 127
EOF
  chmod +x "$POISON_BIN/$_poison"
done
LEAKED=("$POISON_BIN")
trap 'rm -rf "${LEAKED[@]}"' EXIT

echo "call-dir sweep + empty-stderr orphan note"

# ---------------------------------------------------------------------------
# 1. TTL sweep — reaps a stale hotline-call-* dir, leaves a fresh one alone.
#
# Driven through an early, fast-failing dial (bad --target, no cmux needed):
# the sweep runs before that check, so the failure mode of the probe dial is
# irrelevant to what gets swept.
# ---------------------------------------------------------------------------
CALL_HOME=$(mktemp -d "$TMP_ROOT/hotline-sweep-home-XXXXXX")
LEAKED+=("$CALL_HOME")

STALE_DIR="$CALL_HOME/hotline-call-stale01"
FRESH_DIR="$CALL_HOME/hotline-call-fresh01"
mkdir -p "$STALE_DIR" "$FRESH_DIR"
echo "work order text" > "$STALE_DIR/pending_paste.md"
echo "work order text" > "$FRESH_DIR/pending_paste.md"
# Back-date the stale dir past the default 3-day floor. `touch -t` wants
# [[CC]YY]MMDDhhmm[.ss] — 5 days ago is safely past the default without
# depending on `date -d` (not portable to macOS's BSD `date`).
FIVE_DAYS_AGO_TS=$(( $(date +%s) - 5*86400 ))
if TSTAMP=$(date -r "$FIVE_DAYS_AGO_TS" +%Y%m%d%H%M 2>/dev/null); then
  : # BSD date (macOS)
else
  TSTAMP=$(date -d "@$FIVE_DAYS_AGO_TS" +%Y%m%d%H%M 2>/dev/null)
fi
touch -t "$TSTAMP" "$STALE_DIR" "$STALE_DIR/pending_paste.md" 2>/dev/null

HOME_SCRATCH=$(mktemp -d "$TMP_ROOT/hotline-sweep-caller-home-XXXXXX")
LEAKED+=("$HOME_SCRATCH")

PATH="$POISON_BIN:$PATH" HOME="$HOME_SCRATCH" HOTLINE_CALL_HOME="$CALL_HOME" \
  HOTLINE_CALLER_SESSION_ID="caller-sweep-1" \
  bash "$DIAL" --target "/nonexistent/path/for/sweep/probe" --mode quick \
    --label "sweep probe" --prompt "hi" >/dev/null 2>&1

[[ ! -d "$STALE_DIR" ]]
check "the TTL sweep reaps a hotline-call-* dir past the default age floor" $? \
  "still present: $(ls -d "$STALE_DIR" 2>/dev/null || echo NONE)"

[[ -d "$FRESH_DIR" && -f "$FRESH_DIR/pending_paste.md" ]]
check "…and leaves a fresh call dir (and its payload) alone" $? \
  "$(ls -A "$FRESH_DIR" 2>/dev/null | tr '\n' ' ')"

# HOTLINE_CALL_SWEEP_DAYS overrides the floor — a dir just past ONE day old
# survives the default (3), but not an override of 0. (`find -mtime +0` needs
# a full 24h-plus period to match at all — an hour old would never trip either
# floor, which is not what this case is testing.)
CALL_HOME2=$(mktemp -d "$TMP_ROOT/hotline-sweep-home2-XXXXXX")
LEAKED+=("$CALL_HOME2")
ONE_DAY_PLUS_AGO=$(( $(date +%s) - 25*3600 ))
RECENT_DIR="$CALL_HOME2/hotline-call-recent01"
mkdir -p "$RECENT_DIR"
echo x > "$RECENT_DIR/pending_paste.md"
if TSTAMP2=$(date -r "$ONE_DAY_PLUS_AGO" +%Y%m%d%H%M 2>/dev/null); then
  :
else
  TSTAMP2=$(date -d "@$ONE_DAY_PLUS_AGO" +%Y%m%d%H%M 2>/dev/null)
fi
touch -t "$TSTAMP2" "$RECENT_DIR" "$RECENT_DIR/pending_paste.md" 2>/dev/null

PATH="$POISON_BIN:$PATH" HOME="$HOME_SCRATCH" HOTLINE_CALL_HOME="$CALL_HOME2" \
  HOTLINE_CALLER_SESSION_ID="caller-sweep-2a" \
  bash "$DIAL" --target "/nonexistent/path/for/sweep/probe2a" --mode quick \
    --label "sweep probe" --prompt "hi" >/dev/null 2>&1

[[ -d "$RECENT_DIR" ]]
check "…the default 3-day floor leaves a 25-hour-old dir alone" $? \
  "missing: $RECENT_DIR"

PATH="$POISON_BIN:$PATH" HOME="$HOME_SCRATCH" HOTLINE_CALL_HOME="$CALL_HOME2" \
  HOTLINE_CALL_SWEEP_DAYS=0 HOTLINE_CALLER_SESSION_ID="caller-sweep-2b" \
  bash "$DIAL" --target "/nonexistent/path/for/sweep/probe2b" --mode quick \
    --label "sweep probe" --prompt "hi" >/dev/null 2>&1

[[ ! -d "$RECENT_DIR" ]]
check "…HOTLINE_CALL_SWEEP_DAYS=0 reaps that same dir once the floor drops" $? \
  "still present: $(ls -d "$RECENT_DIR" 2>/dev/null || echo NONE)"

# ---------------------------------------------------------------------------
# 2. cmux-call-async.sh: the opener dies reporting nothing at all.
# ---------------------------------------------------------------------------
make_min_surface_cmux() {
  mkdir -p "$1"
  cat > "$1/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  send) echo "$*" >> "$ST/send_calls" ;;
  read-screen) cat "$ST/screen.txt" 2>/dev/null ;;
  tree)  jq -nc '{windows:[{workspaces:[{id:"WORKSPACE-UUID-5",ref:"workspace:5",
           panes:[{selected_surface_id:"SURFACE-UUID-777",
                   surfaces:[{id:"SURFACE-UUID-777",ref:"surface:777"}]}]}]}]}' ;;
  close-surface) echo "$*" >> "$ST/close_calls" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$1/cmux"
}

tmp=$(mktemp -d "$TMP_ROOT/hotline-sweep-async-XXXXXX")
LEAKED+=("$tmp")
mkdir -p "$tmp/cwd"
: > "$tmp/screen.txt"
make_min_surface_cmux "$tmp/bin"

# The opener stub: exits 1, prints NOTHING to stdout or stderr — the shape
# `set -euo pipefail` produces when an unguarded `read` consumes an empty
# lookup (the environment trap this whole batch was warned about).
cat > "$tmp/open-side.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/open-side.sh"

out=$(PATH="$tmp/bin:$POISON_BIN:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" \
  bash "$CMUX_ASYNC" --cwd "$tmp/cwd" --prompt "hello" 2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty' 2>/dev/null)
LEAKED+=("$call_dir")

[[ -n "$call_dir" && -f "$call_dir/done" && -f "$call_dir/error.txt" ]]
check "an opener that reports nothing still writes the async error contract" $? \
  "call_dir=$call_dir stderr=$(cat "$tmp/stderr.txt" 2>/dev/null)"

if grep -q "before printing a surface_id" "$call_dir/surface_err.txt" 2>/dev/null; then
  pass "…and surface_err.txt names the possible orphan instead of staying silent"
else
  fail "…and surface_err.txt names the possible orphan instead of staying silent" \
       "surface_err=$(cat "$call_dir/surface_err.txt" 2>/dev/null || echo NONE)"
fi

if grep -q "before printing a surface_id" "$call_dir/error.txt" 2>/dev/null; then
  pass "…and that note reaches error.txt too, where dial.sh's boot-stage .recovery reads it"
else
  fail "…and that note reaches error.txt too, where dial.sh's boot-stage .recovery reads it" \
       "error.txt=$(cat "$call_dir/error.txt" 2>/dev/null || echo NONE)"
fi

# No UUID was ever named, so nothing was — and must not have been — closed.
[[ ! -s "$tmp/close_calls" ]]
check "…and nothing was closed (no UUID to close it by — see the ref-only refusal)" $? \
  "close_calls=$(cat "$tmp/close_calls" 2>/dev/null || echo NONE)"

echo "call-dir-sweep: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || { printf 'failed: %s\n' "${FAILED_CASES[@]}"; exit 1; }
exit 0
