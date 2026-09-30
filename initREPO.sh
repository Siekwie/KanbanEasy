#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <remote-url> [branch]"
  echo "Example: $0 https://github.com/you/project.git main"
  exit 1
}

REMOTE_URL="${1:-}"
BRANCH="${2:-main}"

if [[ -z "$REMOTE_URL" ]]; then
  usage
fi

# Ensure we're in a git repo, init if not
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[i] Git repo detected."
else
  echo "[i] Initializing new git repository..."
  git init -b "$BRANCH"
fi

# Ensure a default branch exists and is the name we want
current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

if [[ "$current_branch" == "HEAD" || -z "$current_branch" || "$current_branch" == "master" || "$current_branch" == "(unknown)" ]]; then
  # If no commits yet, create initial branch
  if ! git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "[i] Creating branch '$BRANCH'..."
    # If repo is unborn HEAD (no commits), create an empty initial commit
    if ! git rev-parse HEAD >/dev/null 2>&1; then
      # Stage everything if there are files
      if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        git add -A
        git commit -m "chore: initial commit"
      else
        # Create an orphan branch with an empty commit to establish the branch
        git checkout --orphan "$BRANCH"
        git commit --allow-empty -m "chore: initial commit"
      fi
    fi
  fi

  # Switch to desired branch if not already on it
  if [[ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]]; then
    git checkout "$BRANCH" 2>/dev/null || git switch -c "$BRANCH"
  fi

  # Set default branch name for new repos
  git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$BRANCH" >/dev/null 2>&1 || true
else
  # If user is on some branch already, respect it unless a branch arg was provided
  if [[ -n "${2:-}" && "$current_branch" != "$BRANCH" ]]; then
    echo "[i] Switching to branch '$BRANCH'..."
    git checkout "$BRANCH" 2>/dev/null || git switch -c "$BRANCH"
  else
    BRANCH="$current_branch"
  fi
fi

# Ensure there's at least one commit
if ! git rev-parse HEAD >/dev/null 2>&1; then
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    git add -A
  fi
  git commit --allow-empty -m "chore: initial commit"
fi

# Add or update 'origin' remote
if git remote get-url origin >/dev/null 2>&1; then
  existing_url="$(git remote get-url origin)"
  if [[ "$existing_url" != "$REMOTE_URL" ]]; then
    echo "[i] Updating origin from $existing_url to $REMOTE_URL"
    git remote set-url origin "$REMOTE_URL"
  else
    echo "[i] Origin already set to $REMOTE_URL"
  fi
else
  echo "[i] Adding origin $REMOTE_URL"
  git remote add origin "$REMOTE_URL"
fi

# Fetch from remote to check for conflicting changes
echo "[i] Fetching from remote..."
git fetch origin

# Check if remote branch exists
if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  echo "[i] Remote branch exists. Checking for differences..."
  
  # Check if we need to pull from remote
  if ! git merge-base --is-ancestor HEAD origin/$BRANCH 2>/dev/null; then
    echo "[i] Local and remote have diverged. Pulling changes..."
    
    # Try to pull with rebase first to maintain a clean history
    if git pull --rebase origin "$BRANCH"; then
      echo "[i] Successfully pulled changes from remote."
    else
      echo "[i] Rebase failed, trying regular merge..."
      
      # Abort any failed rebase
      git rebase --abort 2>/dev/null || true
      
      # Try a regular merge
      if git pull origin "$BRANCH"; then
        echo "[i] Successfully merged changes from remote."
      else
        echo "[!] Error: Failed to merge changes from remote."
        echo "[!] Please resolve conflicts manually and try again."
        exit 1
      fi
    fi
  fi
fi

# Set upstream if not set
if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  echo "[i] Upstream already set to $(git rev-parse --abbrev-ref --symbolic-full-name @{u})"
else
  echo "[i] Pushing and setting upstream: origin/$BRANCH"
  git push -u origin "$BRANCH"
  exit 0
fi

# Regular push (no upstream changes needed)
echo "[i] Pushing to origin/$BRANCH"
git push

echo "[✓] Done."