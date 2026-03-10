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

# Unstage orchestrator artifacts -- don't include them in the PR
# AGENTS.md: injected by setup.sh for the coding agent
# .beads: symlink to /app/.beads for bd discovery
git checkout -- AGENTS.md 2>/dev/null || true
git restore --staged AGENTS.md 2>/dev/null || true
git rm --cached .beads 2>/dev/null || true

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

# Remove orchestrator artifacts from staging -- don't include in the PR
git reset HEAD -- AGENTS.md 2>/dev/null || true
git reset HEAD -- .beads 2>/dev/null || true

# Check if there's still something to commit after unstaging artifacts
if git diff --cached --quiet 2>/dev/null; then
  warn "No changes remain after excluding orchestrator artifacts"
  bead_comment "$BEAD_ID" "Agent completed but produced no code changes (only orchestrator artifacts were modified)."
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

# Extract owner/repo from REPO_URL for REST API fallback
# Handles: https://github.com/owner/repo, https://github.com/owner/repo.git
REPO_SLUG=$(echo "$REPO_URL" | sed 's|\.git$||' | sed -E 's|.*/([^/]+/[^/]+)$|\1|')

# Try gh CLI first; if it fails (e.g. SAML/SSO on fork parent), fall back to REST API
PR_OUTPUT=$(gh pr create \
  --title "$PR_TITLE" \
  --body "$PR_BODY" \
  --base "$REPO_BRANCH" \
  --head "$BRANCH_NAME" \
  2>&1) || {
  warn "gh pr create failed: $PR_OUTPUT"
  log "Falling back to GitHub REST API for PR creation..."

  # Build JSON payload (use jq to handle special characters in title/body)
  PR_JSON=$(jq -n \
    --arg title "$PR_TITLE" \
    --arg body "$PR_BODY" \
    --arg head "$BRANCH_NAME" \
    --arg base "$REPO_BRANCH" \
    '{title: $title, body: $body, head: $head, base: $base}')

  API_RESPONSE=$(curl -sS -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO_SLUG}/pulls" \
    -d "$PR_JSON" 2>&1) || {
    error "REST API PR creation also failed: $API_RESPONSE"
    bead_comment "$BEAD_ID" "Agent pushed branch $BRANCH_NAME but failed to create PR via both gh CLI and REST API"
    exit "$EXIT_FAILURE"
  }

  PR_OUTPUT=$(echo "$API_RESPONSE" | jq -r '.html_url // empty')
  if [[ -z "$PR_OUTPUT" ]]; then
    API_MSG=$(echo "$API_RESPONSE" | jq -r '.message // "unknown error"')
    API_ERRORS=$(echo "$API_RESPONSE" | jq -r '.errors // [] | map(.message) | join(", ")')
    error "REST API PR creation failed: $API_MSG${API_ERRORS:+ ($API_ERRORS)}"
    bead_comment "$BEAD_ID" "Agent pushed branch $BRANCH_NAME but failed to create PR: $API_MSG"
    exit "$EXIT_FAILURE"
  fi
  log "PR created via REST API fallback"
}
PR_URL="$PR_OUTPUT"

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
  -t task -p 2 --parent "$BEAD_ID" --json 2>/dev/null) || true

if [[ -n "$REVIEW_BEAD" ]]; then
  # bd create --json may return an array or object; handle both
  REVIEW_ID=$(echo "$REVIEW_BEAD" | jq -r 'if type == "array" then .[0].id else .id end // empty' 2>/dev/null) || true
  if [[ -n "$REVIEW_ID" ]]; then
    log "Review bead created: $REVIEW_ID"
  else
    warn "Review bead created but could not extract ID (non-fatal)"
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
