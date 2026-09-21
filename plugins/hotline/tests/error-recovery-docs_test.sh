#!/usr/bin/env bash
# =============================================================================
# Doc canary: the `open-side-surface failed` recovery entry stays diagnostic.
#
# That entry is the residual bucket for opener failures, and its most common
# arrival is an opener that exited reporting NOTHING — `error.txt` carrying an
# empty stderr slot and `surface_err.txt` 0 bytes. A caller who followed the
# entry while hitting exactly that was sent to inspect two files guaranteed to
# be empty and to suspect two causes that structurally cannot produce this
# error: `cmux-call-async.sh` keys its `surface-context→detached` degrade on the
# opener's stderr TEXT, so a failed `cmux identify` degrades instead of landing
# here. Everything the entry named checked out fine, which is what made the
# failure unreadable. (claude-plugins-urc4, and the ledger's "an error hint must
# point at the doc section that handles that error".)
#
# Prose assertions, so grep-level — but the entry has been wrong once already,
# and this is what notices if the wrong shape comes back.
#
# Pure text: no cmux, no network, runs anywhere.
# =============================================================================
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
DOC="$HOTLINE_DIR/skills/dial/references/error-recovery.md"

PASS=0
FAIL=0
FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

echo "error-recovery docs: the opener-failure entry"

[[ -f "$DOC" ]] || { echo "error-recovery.md missing at $DOC"; echo "0 passed, 1 failed"; exit 1; }

# The entry itself.
grep -q 'open-side-surface failed. / .open-window-surface failed' "$DOC" \
  && pass "the opener-failure entry is still present" \
  || fail "the opener-failure entry is still present" "heading not found"

# 1. It must tell the reader to branch on whether stderr is empty — that branch
#    is the whole differential diagnosis.
if grep -qi 'stderr empty' "$DOC" && grep -qi 'stderr present' "$DOC"; then
  pass "branches on an empty vs present stderr slot"
else
  fail "branches on an empty vs present stderr slot" \
       "expected both 'Stderr present' and 'Stderr empty' branches"
fi

# 2. It must NOT promise that error.txt carries the opener's stderr. In the
#    common arrival it structurally cannot, and that sentence is what sent a
#    caller to read two empty files.
if grep -q 'the error.txt carries the opener' "$DOC"; then
  fail "does not promise error.txt always carries the opener's stderr" \
       "found the unconditional promise; the empty-slot case is the common one"
else
  pass "does not promise error.txt always carries the opener's stderr"
fi

# 3. It must NOT name a failed `cmux identify` as the usual cause. That failure
#    degrades to detached on its stderr text and never reaches this error — the
#    entry says so itself further down, so naming it up top contradicts the
#    entry AND misdirects the reader.
if grep -qi 'usually .cmux identify. failed' "$DOC"; then
  fail "does not blame a failed 'cmux identify' as the usual cause" \
       "that failure degrades to detached (see the 'never reach this error' bullet)"
else
  pass "does not blame a failed 'cmux identify' as the usual cause"
fi

# 4. The two degrades must still be documented as unreachable-from-here, because
#    assertion 3 depends on that being stated somewhere.
grep -q 'never reach this error' "$DOC" \
  && pass "still states which failures auto-degrade instead of arriving here" \
  || fail "still states which failures auto-degrade instead of arriving here" \
          "the 'Two failures never reach this error' bullet is what makes the rest coherent"

# 5. A reader with an empty stderr needs a way to get the real failure. The
#    resolver is how the command works on any install layout.
grep -q 'resolve-side-opener.sh' "$DOC" \
  && pass "gives a standalone reproduction via resolve-side-opener.sh" \
  || fail "gives a standalone reproduction via resolve-side-opener.sh" \
          "no runnable way to get the failure the dial swallowed"

# 5b. And that command must use the plugin-root token, not a doc-meaningless
#     $0 — a reader is not running a script.
if grep -q 'dirname "\$0"' "$DOC"; then
  fail "the reproduction command does not resolve paths from \$0" \
       "\$0 is the reader's shell in a doc; use \${CLAUDE_PLUGIN_ROOT}"
else
  pass "the reproduction command does not resolve paths from \$0"
fi

# 6. An empty stderr also defeats the orphan reap (it greps surface_id= out of
#    that same empty file), so the entry has to say a surface may be left.
if grep -qi 'no orphan was reaped' "$DOC"; then
  pass "warns that an empty stderr leaves an unreaped surface"
else
  fail "warns that an empty stderr leaves an unreaped surface" \
       "the reap greps surface_id= from surface_err.txt; empty means nothing fires"
fi

echo "error-recovery-docs: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || { printf 'failed: %s\n' "${FAILED_CASES[@]}"; exit 1; }
exit 0
