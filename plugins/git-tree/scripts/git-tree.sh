#!/bin/bash
#
# Create a git worktree in a parallel directory with symlinks to dependencies
#
# Usage: git-tree.sh <branch-name> [--repo <path>] [--create] [--dry-run]
#

set -e
set -o pipefail

# Cleanup function for partial failures
WORKTREE_CREATED=""
cleanup() {
	if [[ -n "$WORKTREE_CREATED" && -d "$WORKTREE_CREATED" ]]; then
		echo "Cleaning up partial worktree at $WORKTREE_CREATED..."
		git -C "$REPO_PATH" worktree remove --force "$WORKTREE_CREATED" 2>/dev/null || rm -rf "$WORKTREE_CREATED"
	fi
}
trap cleanup ERR

# Parse command line arguments
BRANCH=""
REPO_PATH=""
CREATE_BRANCH=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
	case $1 in
		--repo)
			REPO_PATH="$2"
			shift 2
			;;
		--create)
			CREATE_BRANCH=true
			shift
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		-h|--help)
			echo "Usage: $0 <branch-name> [--repo <path>] [--create] [--dry-run]"
			echo ""
			echo "Arguments:"
			echo "  branch-name    Required. The branch to checkout in the new worktree"
			echo "  --repo <path>  Optional. Path to repository (defaults to current directory)"
			echo "  --create       Optional. Create branch if it doesn't exist"
			echo "  --dry-run      Optional. Show what would be done without making changes"
			echo ""
			echo "Environment:"
			echo "  GIT_TREE_WORKTREES_DIR  Optional. Create worktrees at \$GIT_TREE_WORKTREES_DIR/<repo>/<branch> instead of ../gittree-<branch>"
			exit 0
			;;
		*)
			if [[ -z "$BRANCH" ]]; then
				BRANCH="$1"
			else
				echo "Error: Unknown argument $1"
				exit 1
			fi
			shift
			;;
	esac
done

# Validate required arguments
if [[ -z "$BRANCH" ]]; then
	echo "Error: Branch name is required"
	echo "Usage: $0 <branch-name> [--repo <path>] [--create] [--dry-run]"
	exit 1
fi

# Default to current directory if not specified
if [[ -z "$REPO_PATH" ]]; then
	REPO_PATH=$(pwd)
fi

# Get absolute path and ensure we're in a git repo
REPO_PATH=$(cd "$REPO_PATH" && pwd)
if ! git -C "$REPO_PATH" rev-parse --git-dir > /dev/null 2>&1; then
	echo "Error: $REPO_PATH is not a git repository"
	exit 1
fi

# Get the repository name
REPO_NAME=$(basename "$REPO_PATH")

# GIT_TREE_WORKTREES_DIR set: <root>/<origin repo name>/<branch, slashes as dashes>, deps linked absolutely.
# Unset: a gittree-<branch> sibling of the repo, deps linked relatively.
if [[ -n "${GIT_TREE_WORKTREES_DIR:-}" ]]; then
	ORIGIN_URL=$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null || true)
	REPO_KEY=$(basename "${ORIGIN_URL:-$REPO_PATH}" .git)
	WORKTREE_PATH="${GIT_TREE_WORKTREES_DIR%/}/${REPO_KEY}/${BRANCH//\//-}"
	LINK_BASE="$REPO_PATH"
else
	WORKTREE_PATH="$(dirname "$REPO_PATH")/gittree-${BRANCH}"
	LINK_BASE="../${REPO_NAME}"
fi

# Check if worktree already exists
if [[ -d "$WORKTREE_PATH" ]]; then
	echo "Error: Worktree directory already exists: $WORKTREE_PATH"
	exit 1
fi

# Check if branch exists
BRANCH_EXISTS=false
if git -C "$REPO_PATH" rev-parse --verify "$BRANCH" > /dev/null 2>&1; then
	BRANCH_EXISTS=true
fi

if [[ "$BRANCH_EXISTS" == false && "$CREATE_BRANCH" == false ]]; then
	echo "Error: Branch '$BRANCH' does not exist"
	echo "Hint: Use --create flag to create a new branch, or run:"
	echo "  git branch $BRANCH"
	exit 1
fi

# Dry run output
if [[ "$DRY_RUN" == true ]]; then
	echo "Dry run - would perform:"
	echo ""
	if [[ "$BRANCH_EXISTS" == true ]]; then
		echo "1. Create worktree at: $WORKTREE_PATH (branch exists)"
		echo "   Command: git worktree add \"$WORKTREE_PATH\" \"$BRANCH\""
	else
		echo "1. Create worktree at: $WORKTREE_PATH (creating new branch)"
		echo "   Command: git worktree add -b \"$BRANCH\" \"$WORKTREE_PATH\""
	fi
	echo ""
	echo "2. Create symlinks (if sources exist):"
	[[ -d "$REPO_PATH/vendor" ]] && echo "   - vendor → ${LINK_BASE}/vendor"
	[[ -d "$REPO_PATH/node_modules" ]] && echo "   - node_modules → ${LINK_BASE}/node_modules"
	[[ -f "$REPO_PATH/.env" ]] && echo "   - .env → ${LINK_BASE}/.env"
	[[ ! -d "$REPO_PATH/vendor" && ! -d "$REPO_PATH/node_modules" && ! -f "$REPO_PATH/.env" ]] && echo "   (none found)"
	echo ""
	exit 0
fi

# Create the worktree
if [[ "$BRANCH_EXISTS" == true ]]; then
	echo "Branch '$BRANCH' exists"
else
	echo "Branch '$BRANCH' does not exist, will create it"
fi

echo "Creating worktree at: $WORKTREE_PATH"
if [[ "$BRANCH_EXISTS" == true ]]; then
	git -C "$REPO_PATH" worktree add "$WORKTREE_PATH" "$BRANCH"
else
	git -C "$REPO_PATH" worktree add -b "$BRANCH" "$WORKTREE_PATH"
fi
WORKTREE_CREATED="$WORKTREE_PATH"

# Verify worktree was created
if ! git -C "$REPO_PATH" worktree list | grep -q "$WORKTREE_PATH"; then
	echo "Error: Worktree creation failed - not found in git worktree list"
	exit 1
fi

echo ""
echo "Worktree created successfully"
echo ""

# Create symlinks for dependencies
SYMLINKS_CREATED=0

# Symlink vendor directory
if [[ -d "$REPO_PATH/vendor" ]]; then
	echo "Creating symlink: vendor → ${LINK_BASE}/vendor"
	ln -s "${LINK_BASE}/vendor" "$WORKTREE_PATH/vendor"
	SYMLINKS_CREATED=$((SYMLINKS_CREATED + 1))
fi

# Symlink node_modules directory
if [[ -d "$REPO_PATH/node_modules" ]]; then
	echo "Creating symlink: node_modules → ${LINK_BASE}/node_modules"
	ln -s "${LINK_BASE}/node_modules" "$WORKTREE_PATH/node_modules"
	SYMLINKS_CREATED=$((SYMLINKS_CREATED + 1))
fi

# Symlink .env file
if [[ -f "$REPO_PATH/.env" ]]; then
	echo "Creating symlink: .env → ${LINK_BASE}/.env"
	ln -s "${LINK_BASE}/.env" "$WORKTREE_PATH/.env"
	SYMLINKS_CREATED=$((SYMLINKS_CREATED + 1))
fi

echo ""
if [[ $SYMLINKS_CREATED -eq 0 ]]; then
	echo "Warning: No symlinks created (no vendor, node_modules, or .env found)"
else
	echo "Created $SYMLINKS_CREATED symlink(s)"
	# Verify symlinks are valid
	BROKEN_LINKS=0
	for link in "$WORKTREE_PATH/vendor" "$WORKTREE_PATH/node_modules" "$WORKTREE_PATH/.env"; do
		if [[ -L "$link" && ! -e "$link" ]]; then
			echo "Warning: Broken symlink: $link"
			BROKEN_LINKS=$((BROKEN_LINKS + 1))
		fi
	done
	if [[ $BROKEN_LINKS -gt 0 ]]; then
		echo "Warning: $BROKEN_LINKS broken symlink(s) detected"
	fi
fi

# Clear trap since we succeeded
WORKTREE_CREATED=""
trap - ERR

echo ""
echo "Worktree location: $WORKTREE_PATH"
echo ""
echo "To switch to the new worktree:"
echo "  cd $WORKTREE_PATH"
