#!/usr/bin/env bash
# lib.sh -- Shared library for beads-coder container scripts
#
# Source this file at the top of every script:
#   source "$(dirname "$0")/lib.sh"
#
# Provides: logging, exit codes, env validation, beads sync,
#           error reporting, and the EXIT trap.

set -euo pipefail

# ---------------------------------------------------------------------------
# Exit codes (meaningful, documented)
# ---------------------------------------------------------------------------
export EXIT_SUCCESS=0
export EXIT_FAILURE=1        # Recoverable failure (agent error, no changes, etc.)
export EXIT_CONFIG_ERROR=2   # Missing env vars, bad config
export EXIT_CLAIM_CONFLICT=3 # Bead already claimed by another agent

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
CURRENT_PHASE="${CURRENT_PHASE:-unknown}"
BEAD_ID="${BEAD_ID:-}"
BEADS_REMOTE="${BEADS_REMOTE:-}"
BEADS_SYNC_MODE="${BEADS_SYNC_MODE:-direct}"  # "direct" (SQL), "dolt" (clone+push), or "jsonl"
BEADS_JSONL_PATH="${BEADS_JSONL_PATH:-/beads-remote/beads.jsonl}"
BEADS_PREFIX="${BEADS_PREFIX:-bc}"
QUESTION_TIMEOUT="${QUESTION_TIMEOUT:-3600}"
REPO_BRANCH="${REPO_BRANCH:-main}"
BD_ACTOR="${BD_ACTOR:-beads-coder}"

# Track whether we already ran cleanup (prevent double-fire)
_CLEANUP_DONE=0

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()   { echo "[beads-coder:${CURRENT_PHASE}] $*" >&2; }
warn()  { echo "[beads-coder:${CURRENT_PHASE}] WARNING: $*" >&2; }
error() { echo "[beads-coder:${CURRENT_PHASE}] ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# Environment validation
# ---------------------------------------------------------------------------
# Usage: require_env VAR1 VAR2 ...
require_env() {
  local missing=()
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required environment variables: ${missing[*]}"
    exit "$EXIT_CONFIG_ERROR"
  fi
}

# Usage: require_any_env VAR1 VAR2 ...  (at least one must be set)
require_any_env() {
  for var in "$@"; do
    if [[ -n "${!var:-}" ]]; then
      return 0
    fi
  done
  error "At least one of these environment variables must be set: $*"
  exit "$EXIT_CONFIG_ERROR"
}

# ---------------------------------------------------------------------------
# Beads sync abstraction
# ---------------------------------------------------------------------------
# These functions abstract over dolt vs jsonl sync modes.
# They are best-effort: failures are logged but do not abort the script.

beads_sync_pull() {
  log "Pulling beads data (mode=${BEADS_SYNC_MODE})..."
  case "$BEADS_SYNC_MODE" in
    direct)
      # Direct SQL mode: bd is already connected to the server.
      # No pull needed -- reads go directly to the shared database.
      log "Direct SQL mode -- no pull needed."
      ;;
    dolt)
      if ! bd dolt pull 2>&1; then
        warn "bd dolt pull failed (non-fatal, continuing with local data)"
        return 1
      fi
      ;;
    jsonl)
      if [[ -f "$BEADS_JSONL_PATH" ]]; then
        if ! bd import "$BEADS_JSONL_PATH" 2>&1; then
          warn "bd import from $BEADS_JSONL_PATH failed"
          return 1
        fi
      else
        warn "JSONL file not found at $BEADS_JSONL_PATH"
        return 1
      fi
      ;;
    *)
      error "Unknown BEADS_SYNC_MODE: $BEADS_SYNC_MODE"
      return 1
      ;;
  esac
  log "Beads pull complete."
}

beads_sync_push() {
  log "Pushing beads data (mode=${BEADS_SYNC_MODE})..."
  case "$BEADS_SYNC_MODE" in
    direct)
      # Direct SQL mode: bd writes go directly to the server.
      # Commit the working set so changes are visible to other clients.
      bd dolt commit 2>&1 || true
      log "Direct SQL mode -- committed working set (no push needed)."
      ;;
    dolt)
      # Must commit pending working set changes before push
      bd dolt commit 2>&1 || true
      if ! bd dolt push 2>&1; then
        warn "bd dolt push failed (non-fatal)"
        return 1
      fi
      ;;
    jsonl)
      if ! bd export -o "$BEADS_JSONL_PATH" 2>&1; then
        warn "bd export to $BEADS_JSONL_PATH failed"
        return 1
      fi
      ;;
    *)
      error "Unknown BEADS_SYNC_MODE: $BEADS_SYNC_MODE"
      return 1
      ;;
  esac
  log "Beads push complete."
}

# ---------------------------------------------------------------------------
# Bead helpers
# ---------------------------------------------------------------------------

# Comment on the bead (best-effort, never aborts)
bead_comment() {
  local id="$1"
  local message="$2"
  bd comments add "$id" "$message" 2>/dev/null || warn "Failed to add comment to $id"
}

# Update bead status (best-effort)
bead_set_status() {
  local id="$1"
  local status="$2"
  bd update "$id" --status "$status" 2>/dev/null || warn "Failed to set $id status to $status"
}

# Read bead JSON (returns first element of the array)
bead_json() {
  local id="$1"
  bd show "$id" --json 2>/dev/null | jq '.[0]'
}

# ---------------------------------------------------------------------------
# EXIT trap -- ensures bead is always updated on failure
# ---------------------------------------------------------------------------
# Install with: install_exit_trap
# The trap captures the exit code and, on failure:
#   1. Comments on the bead with the error phase
#   2. Sets bead status to "open" (unblocking it for retry)
#   3. Pushes beads state (best-effort)

_exit_handler() {
  local exit_code=$?

  # Prevent double-fire
  if [[ "$_CLEANUP_DONE" -eq 1 ]]; then
    return
  fi
  _CLEANUP_DONE=1

  if [[ "$exit_code" -eq 0 ]]; then
    log "Exiting successfully."
  else
    error "Exiting with code $exit_code (phase: $CURRENT_PHASE)"

    # Best-effort: update bead with failure info
    # Guard: only attempt bd operations if the beads DB exists and is functional
    # Try from current dir first; fall back to /app where .beads/ always lives
    if [[ -n "$BEAD_ID" ]] && { bd show "$BEAD_ID" --json &>/dev/null || (cd /app && bd show "$BEAD_ID" --json) &>/dev/null; }; then
      local msg="Agent failed in phase '$CURRENT_PHASE' with exit code $exit_code"
      bead_comment "$BEAD_ID" "$msg"

      case "$exit_code" in
        "$EXIT_CLAIM_CONFLICT")
          # Don't change status -- another agent owns it
          log "Claim conflict; leaving bead status unchanged."
          ;;
        "$EXIT_CONFIG_ERROR")
          # Config error -- bead may not even be accessible
          bead_comment "$BEAD_ID" "Container configuration error. Check env vars." 2>/dev/null || true
          ;;
        *)
          # General failure -- revert to open so it can be retried
          bead_set_status "$BEAD_ID" "open"
          ;;
      esac

      # Best-effort sync
      beads_sync_push || true
    elif [[ -n "$BEAD_ID" ]]; then
      warn "Beads DB not initialized; skipping bead update on exit"
    fi
  fi
}

install_exit_trap() {
  trap _exit_handler EXIT
}

# ---------------------------------------------------------------------------
# Phase management
# ---------------------------------------------------------------------------
set_phase() {
  CURRENT_PHASE="$1"
  log "=== Phase: $CURRENT_PHASE ==="
}
