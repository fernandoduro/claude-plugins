#!/usr/bin/env bash
# =============================================================================
# resolve-side-opener.sh picks the NEWEST cached cmux-cli opener, not the oldest.
#
# WHY THIS IS LOAD-BEARING and not tidiness: cmux-cli and hotline ship as separate
# plugins on independent versions, so a machine routinely holds several cached
# copies of the opener at once. They are not equivalent — an opener released
# before the UUID became mandatory degrades to a positional `surface:N` and
# reports null ids, which hotline then has to accept and flag as a degraded handle.
# Resolving the OLDEST of them picks precisely the copy most likely to lack
# whatever the caller now depends on, every time, on every dial.
#
# It did exactly that while promising the opposite. A `for pat in <globs>` list is
# expanded by the shell BEFORE the loop body runs, so every match arrives as its
# own iteration in plain glob (lexicographic) order and the `sort -V` inside the
# body had a single item to sort. Measured against four cached versions: it
# returned 0.12.1.
#
# No real cmux, no real plugins dir — a sandbox of empty version directories.
# =============================================================================
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
RESOLVER="$HOTLINE_DIR/skills/dial/scripts/resolve-side-opener.sh"

PASS=0; FAIL=0; FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; return 0; }

echo "side-opener resolution:"
[[ -f "$RESOLVER" ]] || { echo "resolve-side-opener.sh missing at $RESOLVER"; echo "0 passed, 1 failed"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hotline-opener-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# plant <root> <version>... — a cmux-cli cache holding several versions.
plant() {
  local root="$1"; shift
  local v
  for v in "$@"; do
    mkdir -p "$root/cmux-cli/$v/skills/using-cmux-cli/scripts"
    printf '#!/usr/bin/env bash\necho %s\n' "$v" \
      > "$root/cmux-cli/$v/skills/using-cmux-cli/scripts/open-side-surface.sh"
    chmod +x "$root/cmux-cli/$v/skills/using-cmux-cli/scripts/open-side-surface.sh"
  done
}

version_of() { # the resolved path's version dir
  sed 's|.*/cmux-cli/||; s|/skills.*||' <<<"$1"
}

# --- 1. Several versions: the newest wins ------------------------------------
# Deliberately NOT in lexicographic order, and including a two-digit minor: plain
# string sorting puts 0.12.10 before 0.12.9, so a lexicographic pick is wrong
# twice over and `sort -V` is what makes the comparison a version comparison.
R1="$TMP/r1"; plant "$R1" 0.12.1 0.12.2 0.12.9 0.12.10 0.13.2
GOT=$(HOTLINE_PLUGINS_DIR="$R1" bash "$RESOLVER" 2>/dev/null || true)
V=$(version_of "$GOT")
[[ "$V" == "0.13.2" ]] \
  && pass "with five cached versions it resolves the newest (0.13.2)" \
  || fail "with five cached versions it resolves the newest (0.13.2)" "got '$V' ($GOT)"

# The specific regression: the OLDEST must never be the answer.
[[ "$V" != "0.12.1" ]] \
  && pass "…and never the oldest, which glob order would have handed back" \
  || fail "…and never the oldest, which glob order would have handed back" "got '$V'"

# --- 2. sort -V, not sort: 0.12.10 outranks 0.12.9 ---------------------------
R2="$TMP/r2"; plant "$R2" 0.12.9 0.12.10
GOT=$(HOTLINE_PLUGINS_DIR="$R2" bash "$RESOLVER" 2>/dev/null || true)
V=$(version_of "$GOT")
[[ "$V" == "0.12.10" ]] \
  && pass "0.12.10 outranks 0.12.9 (version order, not string order)" \
  || fail "0.12.10 outranks 0.12.9 (version order, not string order)" "got '$V' ($GOT)"

# --- 3. A version-less sibling is MORE specific and still wins ---------------
# The repo/Claude-install layout has no version dir. That pattern is first in the
# precedence list on purpose, and sorting within a pattern must not reorder the
# patterns themselves.
R3="$TMP/r3"; plant "$R3" 0.12.1 0.13.2
mkdir -p "$R3/cmux-cli/skills/using-cmux-cli/scripts"
printf '#!/usr/bin/env bash\necho versionless\n' \
  > "$R3/cmux-cli/skills/using-cmux-cli/scripts/open-side-surface.sh"
chmod +x "$R3/cmux-cli/skills/using-cmux-cli/scripts/open-side-surface.sh"
GOT=$(HOTLINE_PLUGINS_DIR="$R3" bash "$RESOLVER" 2>/dev/null || true)
[[ "$GOT" == "$R3/cmux-cli/skills/using-cmux-cli/scripts/open-side-surface.sh" ]] \
  && pass "a version-less sibling still outranks every versioned copy" \
  || fail "a version-less sibling still outranks every versioned copy" "got '$GOT'"

# --- 4. Nothing to find is not a crash --------------------------------------
# cmux without cmux-cli is legitimate; the dial skill degrades to headless on it,
# so this must be a clean non-zero rather than an error under set -euo pipefail.
R4="$TMP/r4"; mkdir -p "$R4"
set +e
GOT=$(HOTLINE_PLUGINS_DIR="$R4" bash "$RESOLVER" 2>"$TMP/err4")
RC=$?
set -e
[[ $RC -ne 0 && -z "$GOT" ]] \
  && pass "an empty plugins dir exits non-zero with no path (the headless degrade)" \
  || fail "an empty plugins dir exits non-zero with no path" "rc=$RC got='$GOT' err=$(cat "$TMP/err4")"

# --- 5. The explicit override skips the search entirely ----------------------
printf '#!/usr/bin/env bash\n' > "$TMP/explicit.sh"; chmod +x "$TMP/explicit.sh"
GOT=$(HOTLINE_OPEN_SIDE_SURFACE="$TMP/explicit.sh" HOTLINE_PLUGINS_DIR="$R1" \
        bash "$RESOLVER" 2>/dev/null || true)
[[ "$GOT" == "$TMP/explicit.sh" ]] \
  && pass "HOTLINE_OPEN_SIDE_SURFACE wins over the search" \
  || fail "HOTLINE_OPEN_SIDE_SURFACE wins over the search" "got '$GOT'"

echo
echo "side-opener-resolution: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  failed: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
