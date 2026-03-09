#!/usr/bin/env bash
# deliver.sh -- Phase 4: Commit, push, create PR, update bead
#
# This script handles the delivery of the agent's work:
#   1. Checks if there are actual changes
#   2. Commits with a conventional commit message
#   3. Pushes to origin on the feature branch
#   4. Creates a PR via GitHub CLI
#   5. Updates the bead with the PR reference
#   6. Creates a review-request child bead
#   7. Syncs beads state upstream

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

set_phase "deliver"
install_exit_trap

WORKSPACE="/workspace"

# ---------------------------------------------------------------------------
# 1. Check for actual changes
# ---------------------------------------------------------------------------
log "Checking for changes in $WORKSPACE..."
cd "$WORKSPACE"

# Unstage the AGENTS.md we injected -- don't include orchestrator artifacts in the PR
# (It may have been added to an existing file or be a new file)
git checkout -- AGENTS.md 2>/dev/null || true
git restore --staged AGENTS.md 2>/dev/null || true

DIFF_STAT=$(git diff --stat HEAD 2>/dev/null || true)
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || true)

if [[ -z "$DIFF_STAT" && -z "$UNTRACKED" ]]; then
  warn "No changes detected in workspace"
  bead_comment "$BEAD_ID" "Agent completed but produced no code changes."
  # Not a hard failure -- the agent may have determined no changes were needed
  exit "$EXIT_SUCCESS"
fi

log "Changes detected:"
echo "$DIFF_STAT" >&2
if [[ -n "$UNTRACKED" ]]; then
  log "Untracked files:"
  echo "$UNTRACKED" >&2
fi

# ---------------------------------------------------------------------------
# 2. Stage and commit
# ---------------------------------------------------------------------------
BEAD_TITLE=$(cat /tmp/bead-title.txt 2>/dev/null || echo "implement $BEAD_ID")
BRANCH_NAME="beads/${BEAD_ID}"

log "Staging all changes..."
git add -A

# Remove AGENTS.md from staging if it was added
git reset HEAD -- AGENTS.md 2>/dev/null || true

# Check if there's still something to commit after unstaging AGENTS.md
if git diff --cached --quiet 2>/dev/null; then
  warn "No changes remain after excluding AGENTS.md"
  bead_comment "$BEAD_ID" "Agent completed but produced no code changes (only AGENTS.md was modified)."
  exit "$EXIT_SUCCESS"
fi

COMMIT_MSG="feat: ${BEAD_TITLE} (${BEAD_ID})"
log "Committing: $COMMIT_MSG"
git commit -m "$COMMIT_MSG" 2>&1 || {
  error "git commit failed"
  bead_comment "$BEAD_ID" "Agent failed: git commit failed"
  exit "$EXIT_FAILURE"
}

# ---------------------------------------------------------------------------
# 3. Push to origin
# ---------------------------------------------------------------------------
log "Pushing branch $BRANCH_NAME to origin..."
git push -u origin "$BRANCH_NAME" 2>&1 || {
  error "git push failed"
  bead_comment "$BEAD_ID" "Agent failed: could not push to origin/$BRANCH_NAME"
  exit "$EXIT_FAILURE"
}

# ---------------------------------------------------------------------------
# 4. Create pull request
# ---------------------------------------------------------------------------
BEAD_DESCRIPTION=$(cat /tmp/bead-description.txt 2>/dev/null || echo "See bead $BEAD_ID for details.")

PR_TITLE="$BEAD_TITLE ($BEAD_ID)"
PR_BODY=$(cat <<EOF
## Summary

Automated implementation for bead **${BEAD_ID}**.

## Bead Description

${BEAD_DESCRIPTION}

## Changes

$(git diff --stat HEAD~1 HEAD 2>/dev/null || echo "See commits for details.")

---

*This PR was created automatically by [beads-coder](https://github.com/steveyegge/beads). Review the changes and provide feedback on the bead or this PR.*
EOF
)

log "Creating pull request..."
PR_URL=$(gh pr create \
  --title "$PR_TITLE" \
  --body "$PR_BODY" \
  --base "$REPO_BRANCH" \
  --head "$BRANCH_NAME" \
  2>&1) || {
  error "gh pr create failed"
  bead_comment "$BEAD_ID" "Agent pushed branch $BRANCH_NAME but failed to create PR"
  exit "$EXIT_FAILURE"
}

log "PR created: $PR_URL"

# ---------------------------------------------------------------------------
# 5. Update bead with PR reference
# ---------------------------------------------------------------------------
log "Updating bead with PR reference..."
bd update "$BEAD_ID" --notes "PR: $PR_URL" 2>/dev/null || warn "Failed to update bead notes with PR URL"
bead_comment "$BEAD_ID" "Pull request created: $PR_URL"

# ---------------------------------------------------------------------------
# 6. Create review-request child bead
# ---------------------------------------------------------------------------
log "Creating review-request bead..."
REVIEW_BEAD=$(bd create "Review: ${BEAD_TITLE}" \
  --description="PR ready for review: ${PR_URL}\n\nParent bead: ${BEAD_ID}" \
  -t task -p 2 --parent "$BEAD_ID" --json 2>/dev/null) || {
  warn "Failed to create review bead (non-fatal)"
}

if [[ -n "$REVIEW_BEAD" ]]; then
  REVIEW_ID=$(echo "$REVIEW_BEAD" | jq -r '.[0].id // empty')
  if [[ -n "$REVIEW_ID" ]]; then
    log "Review bead created: $REVIEW_ID"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Sync beads state upstream
# ---------------------------------------------------------------------------
beads_sync_push || warn "Final beads sync failed (non-fatal -- PR was already created)"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "Delivery complete. PR: $PR_URL"
