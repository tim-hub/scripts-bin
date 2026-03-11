#!/bin/bash
set -e

# Usage: ./remove_env_filterbranch.sh /path/to/repo
REPO_PATH="${1:-.}"
FILE_PATH=".env"
REMOTE="origin"

cd "$REPO_PATH"

# Backup
git clone --mirror . ../repo-backup-mirror1 || { echo "Backup failed"; exit 1; }


# Remove file from all commits
git filter-branch --force --index-filter \
  "git rm --cached --ignore-unmatch $FILE_PATH" \
  --prune-empty --tag-name-filter cat -- --all

# Remove backup refs created by filter-branch
rm -rf .git/refs/original/
git reflog expire --expire=now --all
git gc --prune=now --aggressive

# Force-push rewritten history
git push --force --all "$REMOTE"
git push --force --tags "$REMOTE"

echo "Done. Revoke any secrets in $FILE_PATH and have collaborators re-clone."
