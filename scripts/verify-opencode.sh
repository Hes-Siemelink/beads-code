#!/usr/bin/env bash
# verify-opencode.sh -- Verify OpenCode configuration for container use
#
# This script validates that OpenCode and the opencode-beads plugin
# are correctly configured for headless operation inside the container.
# Run this during container build or as a smoke test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

set_phase "verify-opencode"

ERRORS=0

# ---------------------------------------------------------------------------
# 1. Check opencode binary is available
# ---------------------------------------------------------------------------
log "Checking opencode binary..."
if command -v opencode &>/dev/null; then
  OPENCODE_VERSION=$(opencode --version 2>/dev/null || echo "unknown")
  log "opencode found: $OPENCODE_VERSION"
else
  error "opencode not found in PATH"
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# 2. Check opencode.json exists and has the plugin
# ---------------------------------------------------------------------------
log "Checking opencode.json..."
OPENCODE_CONFIG="/app/opencode.json"

if [[ -f "$OPENCODE_CONFIG" ]]; then
  # Verify it's valid JSON
  if ! jq empty "$OPENCODE_CONFIG" 2>/dev/null; then
    error "opencode.json is not valid JSON"
    ERRORS=$((ERRORS + 1))
  else
    log "opencode.json is valid JSON"
    # Check for permission: allow (required for headless/non-interactive use)
    HAS_PERMS=$(jq -r '.permission // "unset"' "$OPENCODE_CONFIG" 2>/dev/null)
    if [[ "$HAS_PERMS" == "allow" ]]; then
      log "permission: allow (headless-ready)"
    else
      warn "permission is '$HAS_PERMS' -- consider 'allow' for headless use"
    fi
  fi
else
  error "opencode.json not found at $OPENCODE_CONFIG"
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# 3. Check bd CLI is available
# ---------------------------------------------------------------------------
log "Checking bd binary..."
if command -v bd &>/dev/null; then
  BD_VERSION=$(bd --version 2>/dev/null || echo "unknown")
  log "bd found: $BD_VERSION"
else
  error "bd not found in PATH"
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# 4. Check gh CLI is available
# ---------------------------------------------------------------------------
log "Checking gh binary..."
if command -v gh &>/dev/null; then
  GH_VERSION=$(gh --version 2>/dev/null | head -1 || echo "unknown")
  log "gh found: $GH_VERSION"
else
  error "gh not found in PATH"
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# 5. Check required system tools
# ---------------------------------------------------------------------------
for tool in git jq curl envsubst; do
  if command -v "$tool" &>/dev/null; then
    log "$tool found"
  else
    error "$tool not found in PATH"
    ERRORS=$((ERRORS + 1))
  fi
done

# ---------------------------------------------------------------------------
# 6. Verify LLM API key availability (at runtime only)
# ---------------------------------------------------------------------------
if [[ "${VERIFY_RUNTIME:-0}" == "1" ]]; then
  log "Checking LLM API keys (runtime check)..."
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    log "ANTHROPIC_API_KEY is set"
  elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
    log "OPENAI_API_KEY is set"
  else
    error "No LLM API key found (need ANTHROPIC_API_KEY or OPENAI_API_KEY)"
    ERRORS=$((ERRORS + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
if [[ "$ERRORS" -eq 0 ]]; then
  log "All checks passed"
  exit 0
else
  error "$ERRORS check(s) failed"
  exit 1
fi
