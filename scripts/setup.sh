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

# BEADS_PROJECT_ID is required for direct SQL mode (the default)
if [[ "${BEADS_SYNC_MODE:-direct}" == "direct" ]]; then
  require_env BEADS_PROJECT_ID
  log "Using direct SQL mode (server: ${BEADS_SERVER_HOST:-beads-server}:${BEADS_SERVER_PORT:-3306})"
elif [[ "$BEADS_SYNC_MODE" == "dolt" ]]; then
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
# When GITHUB_TOKEN env var is set, gh uses it automatically.
# Calling 'gh auth login --with-token' would fail because gh sees the env var
# as an active auth method. Instead, verify the token works.
if gh auth status 2>&1; then
  log "GitHub CLI authenticated via GITHUB_TOKEN env var."
else
  # Fall back to explicit login (e.g. if GITHUB_TOKEN is unset but passed another way)
  echo "$GITHUB_TOKEN" | gh auth login --with-token 2>&1 || {
    error "GitHub CLI auth failed"
    exit "$EXIT_CONFIG_ERROR"
  }
fi

# Configure git to use HTTPS with token (for clone/push)
git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"

# ---------------------------------------------------------------------------
# 3. Initialize beads -- connect directly to beads-server via SQL
# ---------------------------------------------------------------------------
# Instead of running `bd init` (which overwrites the project_id in the shared
# database, breaking other clients), we manually create the minimal .beads/
# configuration that tells bd how to connect to the existing server.
#
# Required env vars:
#   BEADS_PROJECT_ID  - The host's project ID (must match the server's DB)
#   BEADS_SERVER_HOST - SQL server hostname (default: beads-server)
#   BEADS_SERVER_PORT - SQL server port (default: 3306)

BEADS_SERVER_HOST="${BEADS_SERVER_HOST:-beads-server}"
BEADS_SERVER_PORT="${BEADS_SERVER_PORT:-3306}"
BEADS_PROJECT_ID="${BEADS_PROJECT_ID:-}"

if [[ -z "$BEADS_PROJECT_ID" ]]; then
  error "BEADS_PROJECT_ID must be set (the host's project ID from .beads/metadata.json)"
  exit "$EXIT_CONFIG_ERROR"
fi

log "Configuring beads client (server=${BEADS_SERVER_HOST}:${BEADS_SERVER_PORT}, project=${BEADS_PROJECT_ID})..."

# Create minimal .beads directory with metadata pointing to the remote server.
# This avoids bd init entirely -- no database writes, no project ID overwrites.
mkdir -p /app/.beads

cat > /app/.beads/metadata.json <<METAEOF
{
  "database": "dolt",
  "backend": "dolt",
  "dolt_mode": "server",
  "dolt_database": "${BEADS_PREFIX}",
  "project_id": "${BEADS_PROJECT_ID}",
  "dolt_server_host": "${BEADS_SERVER_HOST}",
  "dolt_server_port": ${BEADS_SERVER_PORT},
  "dolt_server_user": "root",
  "issue_prefix": "${BEADS_PREFIX}"
}
METAEOF

# bd also reads the server port from this file
echo -n "$BEADS_SERVER_PORT" > /app/.beads/dolt-server.port

log "Beads config written to /app/.beads/metadata.json"

# bd discovers .beads/ by walking up from CWD -- run verify from /app
cd /app
if bd show "$BEAD_ID" --json &>/dev/null; then
  log "Connected to beads-server. Bead $BEAD_ID is accessible."
else
  error "Cannot connect to beads-server or bead $BEAD_ID not found."
  error "Check BEADS_PROJECT_ID, BEADS_SERVER_HOST, BEADS_SERVER_PORT."
  # Show what bd says for debugging
  bd show "$BEAD_ID" --json 2>&1 || true
  exit "$EXIT_FAILURE"
fi

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

# Symlink .beads into workspace so bd can discover it from /workspace.
# bd finds its config by walking up from CWD looking for .beads/ -- but
# /workspace is not a child of /app, so without this symlink bd commands
# fail after cd /workspace.
if [[ ! -e "$WORKSPACE/.beads" ]]; then
  ln -s /app/.beads "$WORKSPACE/.beads"
  log "Symlinked $WORKSPACE/.beads -> /app/.beads"
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
# 6. Claim the bead
# ---------------------------------------------------------------------------
# Set status to in_progress and assign to this actor.
# We don't use --claim (which fails if already assigned) because the
# launch script may have already touched the bead during validation.
log "Claiming bead $BEAD_ID for ${BD_ACTOR}..."
bd update "$BEAD_ID" --status in_progress --assignee "${BD_ACTOR}" --json 2>&1 || {
  warn "Failed to update bead status/assignee (non-fatal, continuing)"
}
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
