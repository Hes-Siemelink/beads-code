#!/usr/bin/env bash
# entrypoint.sh -- Main entrypoint for the beads-coder container
#
# Orchestrates the 5 phases:
#   1. Setup   (scripts/setup.sh)   -- init beads, clone repo, claim bead
#   2. Code    (scripts/run-agent.sh) -- invoke OpenCode, handle questions
#   3. Deliver (scripts/deliver.sh) -- commit, push, create PR
#   4. Exit    (handled by EXIT trap in lib.sh)
#
# Usage:
#   docker run -e BEAD_ID=bc-xxx -e REPO_URL=... -e GITHUB_TOKEN=... \
#              -e BEADS_REMOTE=... -e ANTHROPIC_API_KEY=... beads-coder

set -euo pipefail

# Resolve script directory (works whether running from /app or elsewhere)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Scripts may be in /app/scripts/ or relative to entrypoint
if [[ -d "$SCRIPT_DIR/scripts" ]]; then
  SCRIPTS="$SCRIPT_DIR/scripts"
elif [[ -d "/app/scripts" ]]; then
  SCRIPTS="/app/scripts"
else
  echo "ERROR: Cannot find scripts directory" >&2
  exit 2
fi

source "$SCRIPTS/lib.sh"

# ---------------------------------------------------------------------------
# Set defaults for optional env vars
# ---------------------------------------------------------------------------
export QUESTION_TIMEOUT="${QUESTION_TIMEOUT:-3600}"
export REPO_BRANCH="${REPO_BRANCH:-main}"
export MODEL="${MODEL:-}"
export BD_ACTOR="${BD_ACTOR:-beads-coder}"
export BEADS_SYNC_MODE="${BEADS_SYNC_MODE:-dolt}"
export BEADS_PREFIX="${BEADS_PREFIX:-bc}"
export MAX_QUESTION_ROUNDS="${MAX_QUESTION_ROUNDS:-5}"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
set_phase "init"
install_exit_trap

log "========================================"
log "  beads-coder container starting"
log "========================================"
log "BEAD_ID:        ${BEAD_ID:-<not set>}"
log "REPO_URL:       ${REPO_URL:-<not set>}"
log "REPO_BRANCH:    $REPO_BRANCH"
log "BEADS_REMOTE:   ${BEADS_REMOTE:-<not set>}"
log "BEADS_SYNC_MODE: $BEADS_SYNC_MODE"
log "MODEL:          ${MODEL:-<auto>}"
log "QUESTION_TIMEOUT: ${QUESTION_TIMEOUT}s"
log "BD_ACTOR:       $BD_ACTOR"
log "========================================"

# ---------------------------------------------------------------------------
# Phase 1: Setup
# ---------------------------------------------------------------------------
set_phase "setup"
log "Running setup..."
"$SCRIPTS/setup.sh"
log "Setup complete."

# ---------------------------------------------------------------------------
# Phase 2+3: Code + Question Loop
# ---------------------------------------------------------------------------
set_phase "code"
log "Running agent..."
"$SCRIPTS/run-agent.sh"
log "Agent complete."

# ---------------------------------------------------------------------------
# Phase 4: Deliver
# ---------------------------------------------------------------------------
set_phase "deliver"
log "Running delivery..."
"$SCRIPTS/deliver.sh"
log "Delivery complete."

# ---------------------------------------------------------------------------
# Phase 5: Exit (clean)
# ---------------------------------------------------------------------------
set_phase "exit"
log "========================================"
log "  beads-coder container finished"
log "========================================"
log "Bead $BEAD_ID has been processed."

exit 0
