#!/usr/bin/env bash
# setup.sh -- Phase 1: Environment setup, beads sync, repo clone, bead claim
#
# This script bootstraps the container environment:
#   1. Validates required environment variables
#   2. Configures git and GitHub CLI auth
#   3. Initializes beads DB and syncs from remote
#   4. Clones the target repo and creates a feature branch
#   5. Atomically claims the bead
#   6. Exports bead data for downstream phases
#   7. Injects AGENTS.md into the workspace

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

set_phase "setup"
install_exit_trap

# ---------------------------------------------------------------------------
# 1. Validate environment
# ---------------------------------------------------------------------------
log "Validating environment variables..."
require_env BEAD_ID REPO_URL GITHUB_TOKEN
require_any_env ANTHROPIC_API_KEY OPENAI_API_KEY

# BEADS_REMOTE is required for dolt mode
if [[ "$BEADS_SYNC_MODE" == "dolt" ]]; then
  require_env BEADS_REMOTE
fi

log "Environment OK. BEAD_ID=$BEAD_ID, REPO_URL=$REPO_URL, SYNC_MODE=$BEADS_SYNC_MODE"

# ---------------------------------------------------------------------------
# 2. Configure git identity and GitHub CLI
# ---------------------------------------------------------------------------
log "Configuring git identity..."
git config --global user.name "${BD_ACTOR:-beads-coder}"
git config --global user.email "${BD_ACTOR:-beads-coder}@beads.dev"

log "Configuring GitHub CLI auth..."
echo "$GITHUB_TOKEN" | gh auth login --with-token 2>&1 || {
  error "GitHub CLI auth failed"
  exit "$EXIT_CONFIG_ERROR"
}

# Configure git to use HTTPS with token (for clone/push)
git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"

# ---------------------------------------------------------------------------
# 3. Initialize beads and sync from remote
# ---------------------------------------------------------------------------
log "Initializing beads database..."
if [[ ! -d /app/.beads ]]; then
  # Fresh init -- container's own beads DB
  bd init --prefix "$BEADS_PREFIX" 2>&1 || {
    error "bd init failed"
    exit "$EXIT_FAILURE"
  }
fi

# Configure remote (dolt mode)
if [[ "$BEADS_SYNC_MODE" == "dolt" ]]; then
  log "Adding Dolt remote: $BEADS_REMOTE"
  bd dolt remote add origin "$BEADS_REMOTE" 2>&1 || {
    # Remote may already exist if re-running
    warn "bd dolt remote add failed (may already exist)"
  }
fi

# Pull bead data
beads_sync_pull || {
  error "Failed to pull beads data -- cannot proceed without the bead"
  exit "$EXIT_FAILURE"
}

# ---------------------------------------------------------------------------
# 4. Validate the bead exists and is workable
# ---------------------------------------------------------------------------
log "Reading bead $BEAD_ID..."
BEAD_JSON=$(bead_json "$BEAD_ID")

if [[ -z "$BEAD_JSON" || "$BEAD_JSON" == "null" ]]; then
  error "Bead $BEAD_ID not found"
  exit "$EXIT_FAILURE"
fi

BEAD_STATUS=$(echo "$BEAD_JSON" | jq -r '.status')
BEAD_TITLE=$(echo "$BEAD_JSON" | jq -r '.title')
log "Bead found: '$BEAD_TITLE' (status: $BEAD_STATUS)"

if [[ "$BEAD_STATUS" != "open" && "$BEAD_STATUS" != "in_progress" ]]; then
  error "Bead $BEAD_ID is in status '$BEAD_STATUS' -- not workable"
  exit "$EXIT_FAILURE"
fi

# ---------------------------------------------------------------------------
# 5. Clone repo and create feature branch
# ---------------------------------------------------------------------------
WORKSPACE="/workspace"
log "Cloning $REPO_URL into $WORKSPACE..."

if [[ -d "$WORKSPACE/.git" ]]; then
  warn "Workspace already contains a git repo -- using existing clone"
else
  git clone "$REPO_URL" "$WORKSPACE" 2>&1 || {
    error "Failed to clone $REPO_URL"
    bead_comment "$BEAD_ID" "Agent failed: could not clone repo $REPO_URL"
    exit "$EXIT_FAILURE"
  }
fi

BRANCH_NAME="beads/${BEAD_ID}"
log "Creating feature branch: $BRANCH_NAME"

cd "$WORKSPACE"
git checkout -b "$BRANCH_NAME" "origin/${REPO_BRANCH}" 2>&1 || {
  error "Failed to create branch $BRANCH_NAME from origin/$REPO_BRANCH"
  bead_comment "$BEAD_ID" "Agent failed: could not create branch from origin/$REPO_BRANCH"
  exit "$EXIT_FAILURE"
}

# ---------------------------------------------------------------------------
# 6. Claim the bead atomically
# ---------------------------------------------------------------------------
log "Claiming bead $BEAD_ID..."
if ! bd update "$BEAD_ID" --claim --json 2>&1; then
  error "Failed to claim bead $BEAD_ID -- it may already be claimed by another agent"
  exit "$EXIT_CLAIM_CONFLICT"
fi
log "Bead claimed successfully."

# ---------------------------------------------------------------------------
# 7. Export bead data for downstream phases
# ---------------------------------------------------------------------------
log "Exporting bead data to /tmp/bead.json..."
echo "$BEAD_JSON" > /tmp/bead.json

# Also extract key fields for easy consumption
echo "$BEAD_JSON" | jq -r '.title'       > /tmp/bead-title.txt
echo "$BEAD_JSON" | jq -r '.description' > /tmp/bead-description.txt

# ---------------------------------------------------------------------------
# 8. Inject AGENTS.md into workspace
# ---------------------------------------------------------------------------
log "Injecting AGENTS.md into workspace..."
AGENTS_TEMPLATE="/app/container-AGENTS.md"
AGENTS_TARGET="$WORKSPACE/AGENTS.md"

if [[ -f "$AGENTS_TEMPLATE" ]]; then
  # Substitute $BEAD_ID in the template
  RENDERED=$(BEAD_ID="$BEAD_ID" envsubst '$BEAD_ID' < "$AGENTS_TEMPLATE")

  if [[ -f "$AGENTS_TARGET" ]]; then
    # Append to existing AGENTS.md with a separator
    log "Existing AGENTS.md found -- appending container instructions"
    {
      echo ""
      echo "---"
      echo ""
      echo "$RENDERED"
    } >> "$AGENTS_TARGET"
  else
    echo "$RENDERED" > "$AGENTS_TARGET"
  fi
  log "AGENTS.md injected."
else
  warn "Container AGENTS.md template not found at $AGENTS_TEMPLATE"
fi

# ---------------------------------------------------------------------------
# 9. Sync bead status upstream
# ---------------------------------------------------------------------------
beads_sync_push || warn "Post-claim sync failed (non-fatal)"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "Setup complete. Workspace: $WORKSPACE, Branch: $BRANCH_NAME, Bead: $BEAD_ID"
log "Bead title: $BEAD_TITLE"
