#!/usr/bin/env bash
# Exercises repo-cleanup-triage.sh against scratch repos.
#
# Every scenario here is one the classifier must not get wrong in the direction
# of data loss, plus the two `git branch -d` traps that make a safe branch look
# unsafe (standing on a third branch; a rebased branch whose remote diverged).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIAGE="$SCRIPT_DIR/../skills/triage-repo-cleanup/scripts/repo-cleanup-triage.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ $# -gt 1 ]] && echo "      got: $2"; }

[[ -f "$TRIAGE" ]] || { echo "missing $TRIAGE"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git not available; skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not available; skipping"; exit 0; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

G() { git -c user.email=t@t -c user.name=T -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }

# tier_of <json> <kind> <name>  -> prints the tier, or NONE
tier_of() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for i in d["items"]:
    if i["kind"]==sys.argv[2] and i["name"]==sys.argv[3]:
        print(i["tier"]); break
else: print("NONE")' "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
# Scenario A: branches. Built so HEAD sits on a THIRD branch, which is exactly
# the arrangement that makes `git branch -d` lie about a merged branch.
# ---------------------------------------------------------------------------
ORIGIN="$TMP/origin.git"; REPO="$TMP/a"
G init --bare -q "$ORIGIN"
G init -q "$REPO"
cd "$REPO"
G remote add origin "$ORIGIN"
echo base > f.txt; G add -A; G commit -qm base
BASE_SHA="$(G rev-parse HEAD)"
G push -q origin main

# merged: fully contained in main
G checkout -qb merged-branch
echo m >> f.txt; G commit -qam merged
G checkout -q main; G merge -q --no-ff -m merge merged-branch
G push -q origin main

# pushed-only: not in main, identical to its upstream
G checkout -qb pushed-only main
echo p > p.txt; G add -A; G commit -qm pushed
G push -q -u origin pushed-only

# local-only: not in main, on no remote
G checkout -qb local-only main
echo l > l.txt; G add -A; G commit -qm localonly

# stale-ref: a remote-tracking ref whose remote branch is deleted
G checkout -qb doomed main
echo d > d.txt; G add -A; G commit -qm doomed
G push -q -u origin doomed
G -C "$ORIGIN" branch -D doomed    # not `push --delete`: that prunes the local ref too
G checkout -q main

# Stand before the merge, so -d's HEAD-relative check refuses a branch that
# is nonetheless entirely contained in main.
G checkout -qb standing-here "$BASE_SHA"

J="$TMP/a.json"
bash "$TRIAGE" --json > "$J" 2>/dev/null

echo "Scenario A: branch classification"
[[ "$(tier_of "$J" branch merged-branch)" == SAFE ]] \
  && ok "branch merged into base -> SAFE (while HEAD is on a third branch)" \
  || bad "branch merged into base -> SAFE" "$(tier_of "$J" branch merged-branch)"

# The trap itself: git branch -d refuses the very branch we called SAFE.
if G branch -d merged-branch >/dev/null 2>&1; then
  bad "git branch -d should have refused the merged branch (trap not reproduced)"
else
  ok "git branch -d refuses that same branch -- why -d is not the oracle"
fi

[[ "$(tier_of "$J" branch pushed-only)" == RECOVERABLE ]] \
  && ok "branch identical to upstream, not in base -> RECOVERABLE" \
  || bad "pushed-only -> RECOVERABLE" "$(tier_of "$J" branch pushed-only)"

[[ "$(tier_of "$J" branch local-only)" == LOSES ]] \
  && ok "branch on no remote, not in base -> LOSES" \
  || bad "local-only -> LOSES" "$(tier_of "$J" branch local-only)"

[[ "$(tier_of "$J" branch main)" == KEEP ]] \
  && ok "base branch -> KEEP" || bad "main -> KEEP" "$(tier_of "$J" branch main)"

[[ "$(tier_of "$J" branch standing-here)" == KEEP ]] \
  && ok "current branch -> KEEP" || bad "current -> KEEP" "$(tier_of "$J" branch standing-here)"

if grep -q '"kind":"stale-ref"' "$J"; then
  ok "stale remote-tracking ref reported"
else
  bad "stale remote-tracking ref reported" "none found"
fi
grep -q '"tier":"SAFE","kind":"stale-ref"' "$J" \
  && ok "stale-ref classified SAFE" || bad "stale-ref classified SAFE"

# ---------------------------------------------------------------------------
# Scenario B: the rebased-branch trap. Local is fully in main, but its remote
# counterpart diverged, so -d refuses for a second, different reason.
# ---------------------------------------------------------------------------
echo
echo "Scenario B: rebased branch whose remote diverged"
G checkout -qb rebased main
echo r > r.txt; G add -A; G commit -qm "rebased v1"
G push -q -u origin rebased
G commit -q --amend -m "rebased v2 (rewritten)"   # diverges from origin/rebased
G checkout -q main; G merge -q --no-ff -m "merge rebased" rebased
# Stay on main: it contains `rebased`, so a -d refusal can only come from the
# diverged upstream, not from HEAD.

J2="$TMP/b.json"; bash "$TRIAGE" --json > "$J2" 2>/dev/null
[[ "$(tier_of "$J2" branch rebased)" == SAFE ]] \
  && ok "local fully in base though its upstream diverged -> SAFE" \
  || bad "rebased -> SAFE" "$(tier_of "$J2" branch rebased)"
if G branch -d rebased >/dev/null 2>&1; then
  bad "git branch -d should have refused the rebased branch"
else
  ok "git branch -d refuses it for the upstream reason -- second -d trap"
fi

# ---------------------------------------------------------------------------
# Scenario C: worktrees.
# ---------------------------------------------------------------------------
echo
echo "Scenario C: worktrees"
REPO2="$TMP/c"; ORIGIN2="$TMP/origin2.git"
G init --bare -q "$ORIGIN2"; G init -q "$REPO2"; cd "$REPO2"
G remote add origin "$ORIGIN2"
echo base > f.txt; G add -A; G commit -qm base; G push -q origin main

G branch wt-clean
G worktree add -q "$TMP/wt-clean" wt-clean
G branch wt-dirty
G worktree add -q "$TMP/wt-dirty" wt-dirty
echo dirt > "$TMP/wt-dirty/dirt.txt"

# detached at a commit that IS on a branch
G worktree add -q --detach "$TMP/wt-det-ok" main

# detached at a commit on NO branch
G checkout -qb doomed-wt main
echo x > x.txt; G add -A; G commit -qm orphan
ORPHAN_SHA="$(G rev-parse HEAD)"
G checkout -q main
G worktree add -q --detach "$TMP/wt-det-orphan" "$ORPHAN_SHA"
G branch -D doomed-wt >/dev/null 2>&1

J3="$TMP/c.json"; bash "$TRIAGE" --json > "$J3" 2>/dev/null

[[ "$(tier_of "$J3" worktree "$TMP/wt-clean")" == SAFE ]] \
  && ok "clean worktree -> SAFE (its branch keeps the commits)" \
  || bad "clean worktree -> SAFE" "$(tier_of "$J3" worktree "$TMP/wt-clean")"

[[ "$(tier_of "$J3" worktree "$TMP/wt-dirty")" == ASK ]] \
  && ok "dirty worktree -> ASK" || bad "dirty worktree -> ASK" "$(tier_of "$J3" worktree "$TMP/wt-dirty")"

[[ "$(tier_of "$J3" worktree "$TMP/wt-det-ok")" == SAFE ]] \
  && ok "detached worktree on a reachable commit -> SAFE" \
  || bad "detached reachable -> SAFE" "$(tier_of "$J3" worktree "$TMP/wt-det-ok")"

[[ "$(tier_of "$J3" worktree "$TMP/wt-det-orphan")" == LOSES ]] \
  && ok "detached worktree whose commit is on no branch -> LOSES" \
  || bad "detached orphan -> LOSES" "$(tier_of "$J3" worktree "$TMP/wt-det-orphan")"

[[ "$(tier_of "$J3" worktree "$REPO2")" == KEEP ]] \
  && ok "primary worktree -> KEEP" || bad "primary -> KEEP" "$(tier_of "$J3" worktree "$REPO2")"

# a branch checked out in a worktree must not also be offered for deletion
[[ "$(tier_of "$J3" branch wt-clean)" == KEEP ]] \
  && ok "branch checked out in a worktree -> KEEP (no contradictory verdict)" \
  || bad "checked-out branch -> KEEP" "$(tier_of "$J3" branch wt-clean)"

# tool-managed worktree inside .git
if G worktree add -q "$REPO2/.git/tool-wt/sync" -b toolbranch 2>/dev/null; then
  J3b="$TMP/c2.json"; bash "$TRIAGE" --json > "$J3b" 2>/dev/null
  t="$(tier_of "$J3b" worktree "$REPO2/.git/tool-wt/sync")"
  [[ "$t" == KEEP ]] && ok "worktree inside .git -> KEEP (tool-managed)" \
                     || bad "worktree inside .git -> KEEP" "$t"
else
  echo "  ⊘ skipped: this git refuses a worktree inside .git"
fi

# prunable: registration survives a deleted directory
rm -rf "$TMP/wt-clean"
J3c="$TMP/c3.json"; bash "$TRIAGE" --json > "$J3c" 2>/dev/null
[[ "$(tier_of "$J3c" worktree "$TMP/wt-clean")" == SAFE ]] \
  && ok "worktree whose directory is gone -> SAFE (prune)" \
  || bad "missing-dir worktree -> SAFE" "$(tier_of "$J3c" worktree "$TMP/wt-clean")"

# ---------------------------------------------------------------------------
# Scenario D: stashes are never auto-dropped.
# ---------------------------------------------------------------------------
echo
echo "Scenario D: stashes"
REPO3="$TMP/d"; G init -q "$REPO3"; cd "$REPO3"
echo base > f.txt; G add -A; G commit -qm base
echo wip >> f.txt; G stash -q
J4="$TMP/d.json"; bash "$TRIAGE" --base main --json > "$J4" 2>/dev/null
[[ "$(tier_of "$J4" stash "stash@{0}")" == ASK ]] \
  && ok "stash holding uncommitted state -> ASK" \
  || bad "stash -> ASK" "$(tier_of "$J4" stash "stash@{0}")"

bash "$TRIAGE" --base main --apply-safe >/dev/null 2>&1 || true
if [[ "$(G stash list | wc -l | tr -d ' ')" == "1" ]]; then
  ok "--apply-safe left the stash alone"
else
  bad "--apply-safe left the stash alone" "stash count changed"
fi

# ---------------------------------------------------------------------------
# Scenario E: --apply-safe touches the SAFE tier and nothing else.
# ---------------------------------------------------------------------------
echo
echo "Scenario E: --apply-safe scope"
cd "$REPO"
bash "$TRIAGE" --apply-safe >/dev/null 2>&1 || true
G show-ref -q --verify refs/heads/merged-branch \
  && bad "--apply-safe should have deleted the merged branch" \
  || ok "--apply-safe deleted the SAFE merged branch"
G show-ref -q --verify refs/heads/local-only \
  && ok "--apply-safe preserved the LOSES branch" \
  || bad "--apply-safe preserved the LOSES branch" "it was deleted"
G show-ref -q --verify refs/heads/pushed-only \
  && ok "--apply-safe preserved the RECOVERABLE branch (not SAFE)" \
  || bad "--apply-safe preserved the RECOVERABLE branch" "it was deleted"

# ---------------------------------------------------------------------------
# Scenario F: exit codes and base resolution.
# ---------------------------------------------------------------------------
echo
echo "Scenario F: exit codes and base resolution"
bash "$TRIAGE" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "exit 1 while something still needs a human" || bad "exit 1 when LOSES present" "rc=$rc"

REPO4="$TMP/e"; G init -q "$REPO4"; cd "$REPO4"
echo b > f.txt; G add -A; G commit -qm base
bash "$TRIAGE" --base main >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "exit 0 on a repo with nothing to decide" || bad "exit 0 when clean" "rc=$rc"

# master-only repo: base resolution must not assume main
REPO5="$TMP/f"; git -c user.email=t@t -c user.name=T -c init.defaultBranch=master init -q "$REPO5"; cd "$REPO5"
echo b > f.txt; G add -A; G commit -qm base
out="$(bash "$TRIAGE" 2>&1)"; rc=$?
if [[ $rc -le 1 ]] && grep -q 'base: master' <<<"$out"; then
  ok "resolves master when there is no main"
else
  bad "resolves master when there is no main" "$(head -2 <<<"$out")"
fi

cd "$REPO4"
bash "$TRIAGE" --base does-not-exist >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "bad --base exits 2 (usage error, not a verdict)" || bad "bad --base exits 2" "rc=$rc"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
