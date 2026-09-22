#!/usr/bin/env bash
# Classify a repo's worktrees, branches, remote-tracking refs, and stashes by
# how much work deleting them would destroy.
#
# The only question that makes a deletion safe is "where else does this commit
# live?", so every verdict here is derived from reachability, never from
# `git branch -d`'s say-so: -d answers against the CURRENT HEAD and against the
# branch's own upstream, so it calls a branch fully merged into main "not fully
# merged" whenever you happen to be standing somewhere else.
#
# Read-only unless --apply-safe, which executes the SAFE tier and nothing else.
set -uo pipefail

BASE=""
AS_JSON=false
APPLY_SAFE=false
REMOTE="origin"

die() { echo "ERROR: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)       BASE="${2:-}"; shift 2 || die "--base needs a ref" ;;
    --remote)     REMOTE="${2:-}"; shift 2 || die "--remote needs a name" ;;
    --json)       AS_JSON=true; shift ;;
    --apply-safe) APPLY_SAFE=true; shift ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      echo
      echo "Usage: repo-cleanup-triage.sh [--base <ref>] [--remote <name>] [--json] [--apply-safe]"
      exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

# Resolve the integration branch. A repo may use main, master, or neither.
if [[ -z "$BASE" ]]; then
  for cand in "refs/remotes/$REMOTE/HEAD" "refs/heads/main" "refs/heads/master"; do
    if [[ "$cand" == *"/HEAD" ]] && git symbolic-ref -q "$cand" >/dev/null 2>&1; then
      BASE="$(git symbolic-ref --short -q "$cand")"; break
    elif git show-ref -q --verify "$cand" 2>/dev/null; then
      BASE="${cand#refs/heads/}"; break
    fi
  done
fi
[[ -n "$BASE" ]] || die "could not resolve a base branch; pass --base <ref>"
git rev-parse --verify -q "$BASE" >/dev/null || die "base ref '$BASE' does not exist"

CURRENT="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"

# verdict lines: TIER<TAB>KIND<TAB>NAME<TAB>DETAIL<TAB>COMMAND
VERDICTS=()
add() { VERDICTS+=("$1	$2	$3	$4	$5"); }

reachable_from_any_branch() {
  # Does any local or remote branch contain this commit?
  [[ -n "$(git for-each-ref --contains "$1" --format='%(refname)' refs/heads refs/remotes 2>/dev/null | head -1)" ]]
}

on_any_remote() {
  [[ -n "$(git for-each-ref --contains "$1" --format='%(refname)' refs/remotes 2>/dev/null | head -1)" ]]
}

# ---------------------------------------------------------------- worktrees ---
# Removing a CLEAN worktree destroys nothing: the branch ref keeps every commit.
# That is why worktree removal and branch deletion are triaged separately --
# conflating them is what makes people think cleanup has to risk work.
MAIN_WT="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
MAIN_WT="${MAIN_WT%/.git}"

wt_path=""; wt_head=""; wt_branch=""; wt_detached=false
wt_prunable=false; wt_locked=false; wt_bare=false

flush_worktree() {
  [[ -z "$wt_path" ]] && return 0

  # The primary worktree is the repo itself.
  if [[ "$wt_path" == "$MAIN_WT" ]]; then
    add KEEP worktree "$wt_path" "primary worktree (branch: $wt_branch)" ""
    return 0
  fi
  # Tool-managed trees live inside the git dir (beads-sync and friends). Their
  # owner recreates and reaps them; pruning them by hand breaks that tool.
  if [[ "$wt_path" == *"/.git/"* ]]; then
    add KEEP worktree "$wt_path" "tool-managed (inside .git) -- leave to its owner" ""
    return 0
  fi
  if [[ "$wt_prunable" == true || ! -d "$wt_path" ]]; then
    add SAFE worktree "$wt_path" "directory already gone -- only the registration remains" "git worktree prune"
    return 0
  fi
  if [[ "$wt_locked" == true ]]; then
    add ASK worktree "$wt_path" "locked -- unlock deliberately before removing" ""
    return 0
  fi

  local dirty
  dirty="$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${dirty:-0}" -gt 0 ]]; then
    add ASK worktree "$wt_path" "$dirty uncommitted file(s) -- removal would discard them" ""
    return 0
  fi

  if [[ "$wt_detached" == true ]]; then
    if reachable_from_any_branch "$wt_head"; then
      add SAFE worktree "$wt_path" "detached but ${wt_head:0:9} is reachable from a branch" "git worktree remove '$wt_path'"
    else
      add LOSES worktree "$wt_path" "detached at ${wt_head:0:9}, on NO branch -- removing orphans that commit" "git worktree remove '$wt_path'"
    fi
  else
    add SAFE worktree "$wt_path" "clean -- branch '$wt_branch' keeps its commits" "git worktree remove '$wt_path'"
  fi
}

while IFS= read -r line; do
  case "$line" in
    worktree\ *) flush_worktree
                 wt_path="${line#worktree }"; wt_head=""; wt_branch=""
                 wt_detached=false; wt_prunable=false; wt_locked=false; wt_bare=false ;;
    HEAD\ *)     wt_head="${line#HEAD }" ;;
    branch\ *)   wt_branch="${line#branch }"; wt_branch="${wt_branch#refs/heads/}" ;;
    detached*)   wt_detached=true ;;
    prunable*)   wt_prunable=true ;;
    locked*)     wt_locked=true ;;
    bare*)       wt_bare=true ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null)
flush_worktree

# ----------------------------------------------------------------- branches ---
# Branches checked out in a worktree cannot be deleted; record them so a branch
# verdict never contradicts a worktree verdict.
declare -a CHECKED_OUT=()
while IFS= read -r b; do [[ -n "$b" ]] && CHECKED_OUT+=("$b"); done < <(
  git worktree list --porcelain 2>/dev/null | sed -n 's|^branch refs/heads/||p'
)
is_checked_out() {
  local n="$1" c
  for c in ${CHECKED_OUT+"${CHECKED_OUT[@]}"}; do [[ "$c" == "$n" ]] && return 0; done
  return 1
}

while IFS='	' read -r name upstream; do
  [[ -z "$name" ]] && continue
  [[ "$name" == "$BASE" ]] && { add KEEP branch "$name" "base branch" ""; continue; }
  [[ "$name" == "$CURRENT" ]] && { add KEEP branch "$name" "currently checked out here" ""; continue; }
  if is_checked_out "$name"; then
    add KEEP branch "$name" "checked out in a worktree -- triage that worktree first" ""
    continue
  fi

  last="$(git log -1 --no-color --format='%cs' "$name" 2>/dev/null)"

  if git merge-base --is-ancestor "$name" "$BASE" 2>/dev/null; then
    add SAFE branch "$name" "every commit is already in $BASE (last $last)" "git branch -D '$name'"
    continue
  fi

  # Not in base. The next question is whether a remote still holds the work.
  if [[ -n "$upstream" ]] && git rev-parse --verify -q "$upstream" >/dev/null 2>&1; then
    local_only="$(git rev-list --count "$upstream..$name" 2>/dev/null || echo 0)"
    if [[ "${local_only:-0}" -eq 0 ]]; then
      add RECOVERABLE branch "$name" "not in $BASE, but identical to $upstream -- refetchable (last $last)" "git branch -D '$name'"
      continue
    fi
    add LOSES branch "$name" "$local_only commit(s) not in $BASE and not pushed to $upstream (last $last)" "git push $REMOTE '$name'"
    continue
  fi

  ahead="$(git rev-list --count "$BASE..$name" 2>/dev/null || echo 0)"
  if on_any_remote "$(git rev-parse "$name")"; then
    add RECOVERABLE branch "$name" "no upstream set, but its tip exists on a remote (last $last)" "git branch -D '$name'"
  else
    add LOSES branch "$name" "$ahead commit(s) on NO remote and not in $BASE -- delete destroys them (last $last)" "git push $REMOTE '$name'"
  fi
done < <(git for-each-ref --format='%(refname:short)	%(upstream:short)' refs/heads/)

# ----------------------------------------------- stale remote-tracking refs ---
# Refs for branches deleted on the remote. Pruning these removes no commits.
STALE_COUNT=0
while IFS= read -r r; do
  [[ -z "$r" ]] && continue
  STALE_COUNT=$((STALE_COUNT + 1))
  add SAFE stale-ref "$r" "branch is gone on $REMOTE -- ref is bookkeeping only" ""
done < <(git remote prune "$REMOTE" --dry-run 2>/dev/null | sed -n 's/^ \* \[would prune\] //p')
[[ "$STALE_COUNT" -gt 0 ]] && add SAFE stale-ref "($STALE_COUNT total)" "prune them in one call" "git remote prune $REMOTE"

# ------------------------------------------------------------------ stashes ---
# A dropped stash is gone: it is not on a branch and not on a remote. So a stash
# is never SAFE here, however old it looks.
while IFS='	' read -r ref subject when; do
  [[ -z "$ref" ]] && continue
  sha="$(git rev-parse "$ref" 2>/dev/null)"
  if [[ -n "$sha" ]] && reachable_from_any_branch "$sha"; then
    add SAFE stash "$ref" "already reachable from a branch -- content is committed ($when)" "git stash drop '$ref'"
  else
    add ASK stash "$ref" "$subject ($when) -- unrecoverable once dropped" ""
  fi
done < <(git stash list --no-color --format='%gd	%gs	%cr' 2>/dev/null)

# ------------------------------------------------------------------- output ---
# Exit 1 when something needs a human, so a caller can gate on it. Computed
# before output so --json and text mode can never disagree.
NEEDS_HUMAN=0
for v in ${VERDICTS+"${VERDICTS[@]}"}; do
  IFS='	' read -r t _ _ _ _ <<<"$v"
  if [[ "$t" == "LOSES" || "$t" == "ASK" ]]; then NEEDS_HUMAN=1; fi
done

tier_rank() { case "$1" in LOSES) echo 0;; ASK) echo 1;; RECOVERABLE) echo 2;; SAFE) echo 3;; *) echo 4;; esac; }

if [[ "$AS_JSON" == true ]]; then
  printf '{\n  "base": "%s",\n  "remote": "%s",\n  "items": [\n' "$BASE" "$REMOTE"
  first=true
  for v in ${VERDICTS+"${VERDICTS[@]}"}; do
    IFS='	' read -r tier kind name detail cmd <<<"$v"
    [[ "$first" == true ]] || printf ',\n'; first=false
    printf '    {"tier":"%s","kind":"%s","name":"%s","detail":"%s","command":"%s"}' \
      "$tier" "$kind" "${name//\"/\\\"}" "${detail//\"/\\\"}" "${cmd//\"/\\\"}"
  done
  printf '\n  ]\n}\n'
  exit "$NEEDS_HUMAN"
fi

echo "Repo cleanup triage  (base: $BASE, remote: $REMOTE)"
echo
for tier in LOSES ASK RECOVERABLE SAFE KEEP; do
  shown=false
  for v in ${VERDICTS+"${VERDICTS[@]}"}; do
    IFS='	' read -r t kind name detail cmd <<<"$v"
    [[ "$t" == "$tier" ]] || continue
    if [[ "$shown" == false ]]; then
      case "$tier" in
        LOSES)       echo "WOULD LOSE WORK -- do not delete without the user's explicit go-ahead:" ;;
        ASK)         echo "NEEDS A DECISION -- holds state nothing else has:" ;;
        RECOVERABLE) echo "RECOVERABLE -- not in $BASE, but a remote still has it:" ;;
        SAFE)        echo "SAFE -- deleting destroys no commit:" ;;
        KEEP)        echo "KEEP -- in use or owned by another tool:" ;;
      esac
      shown=true
    fi
    printf '  [%s] %s\n      %s\n' "$kind" "$name" "$detail"
    [[ -n "$cmd" ]] && printf '      -> %s\n' "$cmd"
  done
  [[ "$shown" == true ]] && echo
done

if [[ "$APPLY_SAFE" == true ]]; then
  echo "--- applying SAFE tier only ---"
  for v in ${VERDICTS+"${VERDICTS[@]}"}; do
    IFS='	' read -r t kind name detail cmd <<<"$v"
    [[ "$t" == "SAFE" && -n "$cmd" ]] || continue
    # A stash is content nothing else holds; never drop one unattended.
    [[ "$kind" == "stash" ]] && { echo "skip (stash needs confirmation): $name"; continue; }
    echo "+ $cmd"
    eval "$cmd" || echo "  (failed, continuing)"
  done
  echo "--- done; nothing outside the SAFE tier was touched ---"
fi

exit "$NEEDS_HUMAN"
