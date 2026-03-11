#!/bin/bash
set -e

# Usage: git-reauthor.sh [repo_path] old_email new_name new_email
# Rewrites all commits matching OLD_EMAIL to use NEW_NAME + NEW_EMAIL.
# Example:
#   ./git-reauthor.sh . old@example.com "New Name" new@example.com

REPO_PATH="${1:-.}"
OLD_EMAIL="${2}"
NEW_NAME="${3}"
NEW_EMAIL="${4}"

if [[ -z "$OLD_EMAIL" ]]; then
  echo "Usage: $0 [repo_path] old_email [new_name] [new_email]"
  echo "  new_name and new_email default to current git config values if omitted."
  exit 1
fi

# Fall back to current git config
NEW_NAME="${NEW_NAME:-$(git -C "$REPO_PATH" config user.name)}"
NEW_EMAIL="${NEW_EMAIL:-$(git -C "$REPO_PATH" config user.email)}"

if [[ -z "$NEW_NAME" || -z "$NEW_EMAIL" ]]; then
  echo "Error: new_name/new_email not provided and git config user.name/email is not set."
  exit 1
fi

echo "Rewriting commits from <$OLD_EMAIL> to \"$NEW_NAME\" <$NEW_EMAIL>"

cd "$REPO_PATH"

# Backup mirror
git clone --mirror . ../repo-reauthor-backup || { echo "Backup failed"; exit 1; }

git filter-branch --env-filter "
  if [ \"\$GIT_AUTHOR_EMAIL\" = \"$OLD_EMAIL\" ]; then
    export GIT_AUTHOR_NAME=\"$NEW_NAME\"
    export GIT_AUTHOR_EMAIL=\"$NEW_EMAIL\"
  fi
  if [ \"\$GIT_COMMITTER_EMAIL\" = \"$OLD_EMAIL\" ]; then
    export GIT_COMMITTER_NAME=\"$NEW_NAME\"
    export GIT_COMMITTER_EMAIL=\"$NEW_EMAIL\"
  fi
" --tag-name-filter cat -- --all

# Clean up refs left by filter-branch
rm -rf .git/refs/original/
git reflog expire --expire=now --all
git gc --prune=now --aggressive

echo "Done. Run 'git log --format=\"%an <%ae>\"' to verify."
echo "Then force-push with: git push --force --all && git push --force --tags"
