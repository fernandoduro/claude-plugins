#!/usr/bin/env bash
# Exercises git-tree.sh worktree placement with and without GIT_TREE_WORKTREES_DIR.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_TREE="$SCRIPT_DIR/../scripts/git-tree.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ $# -gt 1 ]] && echo "      got: $2"; }

[[ -f "$GIT_TREE" ]] || { echo "missing $GIT_TREE"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git not available; skipping"; exit 0; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

G() { git -c user.email=t@t -c user.name=T -c init.defaultBranch=main "$@"; }

REPO="$TMP/src/local-name"
mkdir -p "$REPO/vendor" "$REPO/node_modules"
G -C "$REPO" init -q
G -C "$REPO" commit -q --allow-empty -m init
G -C "$REPO" remote add origin git@github.com:acme/widget.git
echo "A=1" > "$REPO/.env"

echo "GIT_TREE_WORKTREES_DIR set"
ROOT="$TMP/trees"
GIT_TREE_WORKTREES_DIR="$ROOT" bash "$GIT_TREE" fd/feat/thing --repo "$REPO" --create >/dev/null 2>&1
WT="$ROOT/widget/fd-feat-thing"
[[ -d "$WT" ]] && ok "worktree at <root>/<origin repo>/<branch slug>" || bad "worktree at $WT" "$(ls -R "$ROOT" 2>&1 | head -5)"
[[ "$(G -C "$WT" branch --show-current 2>/dev/null)" == fd/feat/thing ]] && ok "branch keeps its slashes" || bad "branch name"
for dep in vendor node_modules .env; do
  if [[ -L "$WT/$dep" && -e "$WT/$dep" && "$(readlink "$WT/$dep")" == "$REPO/$dep" ]]; then
    ok "$dep links absolutely to the main checkout"
  else
    bad "$dep link" "$(readlink "$WT/$dep" 2>&1)"
  fi
done

echo "GIT_TREE_WORKTREES_DIR unset"
bash "$GIT_TREE" other --repo "$REPO" --create >/dev/null 2>&1
SIB="$TMP/src/gittree-other"
[[ -d "$SIB" ]] && ok "worktree is a gittree-<branch> sibling" || bad "sibling worktree at $SIB"
[[ "$(readlink "$SIB/vendor" 2>/dev/null)" == "../local-name/vendor" && -e "$SIB/vendor" ]] && ok "vendor links relatively" || bad "relative vendor link" "$(readlink "$SIB/vendor" 2>&1)"

echo "dry run"
out=$(GIT_TREE_WORKTREES_DIR="$ROOT" bash "$GIT_TREE" dry/run --repo "$REPO" --create --dry-run 2>&1)
[[ $out == *"$ROOT/widget/dry-run"* && ! -e "$ROOT/widget/dry-run" ]] && ok "dry run reports the root path and creates nothing" || bad "dry run" "$out"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
