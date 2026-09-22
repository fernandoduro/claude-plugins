# Git Tree Plugin

Create git worktrees with symlinked dependencies for parallel branch work.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install git-tree@jtsternberg
```

## Description

Git Tree creates isolated worktrees in parallel directories with automatic symlinks to shared dependencies (vendor, node_modules, .env). Perfect for working on multiple branches simultaneously without losing your current work.

## Usage

The skill automatically triggers when you mention:
- "git worktree"
- "work on two branches"
- "parallel branch work"
- "review PR without switching"
- "keep my changes while checking out another branch"

### Direct Script Usage

```bash
# Codex: this path resolves under Claude Code; substitute the absolute path to the git-tree plugin root.
GIT_TREE_ROOT="${CLAUDE_PLUGIN_ROOT}"
"$GIT_TREE_ROOT/scripts/git-tree.sh" <branch-name> [--repo <path>] [--create]
```

**Flags:**
- `--repo <path>`: Target repository (defaults to current directory)
- `--create`: Create branch if it doesn't exist

## Example

```
User: "I want to review PR #123 without losing my current changes"

Claude: Creates a worktree for the PR branch with symlinked dependencies,
        allowing you to test the PR while your main directory stays intact.
```

## Skills

| Skill | Use it to |
|---|---|
| `create-git-tree` | Stand a worktree up, with vendor/node_modules/.env symlinked |
| `triage-repo-cleanup` | Tear leftovers down — worktrees, branches, stale refs, stashes |

### Cleaning up

`triage-repo-cleanup` answers the only question that makes a deletion safe —
*where else does this commit live?* — for worktrees, local branches, stale
remote-tracking refs, and stashes, then sorts each one into SAFE,
RECOVERABLE, NEEDS A DECISION, or WOULD LOSE WORK.

```bash
# Codex: this path resolves under Claude Code; substitute the absolute path to
# this skill's directory.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/repo-cleanup-triage.sh"              # read-only report
bash "$SKILL_DIR/scripts/repo-cleanup-triage.sh" --apply-safe # free tier only
```

It exits `1` whenever something still needs a human, and it never drops a stash
unattended — a stash is the one artifact with no second copy anywhere.

Two traps it exists to route around: `git branch -d` judges against your
*current HEAD* and the branch's *own upstream*, so it refuses branches that are
entirely contained in `main`; and removing a clean worktree deletes no commit at
all, because the branch ref keeps them.

## Additional Documentation

- [skills/create-git-tree/SKILL.md](skills/create-git-tree/SKILL.md) - Worktree creation
- [skills/triage-repo-cleanup/SKILL.md](skills/triage-repo-cleanup/SKILL.md) - Cleanup triage
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Common issues and solutions
- [WEBSERVER-WORKTREES.md](WEBSERVER-WORKTREES.md) - Special considerations for web servers
- [REVIEW.md](REVIEW.md) - Skill review and design notes
