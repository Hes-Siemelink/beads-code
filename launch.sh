#!/usr/bin/env bash
# launch.sh -- Host-side script to dispatch a bead to a beads-coder container
#
# Prerequisites:
#   1. beads-server running (cd beads-server && docker compose up -d)
#   2. Host bd configured with "origin" remote pointing to beads-server
#   3. Initial push done (bd dolt push --force on first use)
#
# Usage:
#   ./launch.sh <bead-id> <repo-url> [options]
#
# Examples:
#   ./launch.sh bc-42 https://github.com/your-org/your-repo
#   ./launch.sh bc-42 https://github.com/your-org/your-repo --model claude-sonnet-4-20250514
#   ./launch.sh bc-42 https://github.com/your-org/your-repo --dry-run

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
# Default: container-to-container via Docker network (beads-server is the container name)
BEADS_REMOTE_URL="${BEADS_REMOTE_URL:-http://beads-server:50051/bc}"
IMAGE="beads-coder"
MODEL="${MODEL:-}"
BRANCH="${REPO_BRANCH:-main}"
QUESTION_TIMEOUT="${QUESTION_TIMEOUT:-3600}"
BD_ACTOR="${BD_ACTOR:-beads-coder}"
SYNC_MODE="dolt"
DRY_RUN=0

BEAD_ID=""
REPO_URL=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()   { echo "[launch] $*" >&2; }
warn()  { echo "[launch] WARNING: $*" >&2; }
error() { echo "[launch] ERROR: $*" >&2; }
die()   { error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: ./launch.sh <bead-id> <repo-url> [options]

Dispatches a bead to a beads-coder container.

Prerequisites:
  1. Start the beads server:   cd beads-server && docker compose up -d
  2. Configure the remote:     bd dolt remote add origin http://localhost:50051/bc
  3. Initial seed (first time): bd dolt commit && bd dolt push --force

Arguments:
  <bead-id>       Bead ID to work on (e.g. bc-42)
  <repo-url>      GitHub repo URL to clone

Options:
  --remote <url>        Beads remote URL for container (default: http://beads-server:50051/bc)
  --image <name>        Docker image name (default: beads-coder)
  --model <model>       LLM model identifier
  --branch <branch>     Base branch (default: main)
  --timeout <seconds>   Question timeout (default: 3600)
  --actor <name>        Actor name for audit trail (default: beads-coder)
  --network <name>      Docker network to join (default: beads-server_default)
  --dry-run             Print the docker run command without executing
  -h, --help            Show this help message

Environment variables (auto-detected):
  GITHUB_TOKEN          GitHub personal access token (required)
  ANTHROPIC_API_KEY     Anthropic API key (at least one LLM key required)
  OPENAI_API_KEY        OpenAI API key (at least one LLM key required)
  BEADS_REMOTE_URL      Override remote URL for container (default: http://beads-server:50051/bc)

Workflow:
  1. Pushes the host's beads DB to the beads-server
  2. Runs the beads-coder container on the same Docker network
  3. Container pulls beads, implements story, pushes results
  4. Host pulls bead updates back from the server
  5. Prints a summary: bead status, PR URL, any questions

Examples:
  # Basic usage
  ./launch.sh bc-42 https://github.com/your-org/your-repo

  # With a specific model
  ./launch.sh bc-42 https://github.com/your-org/your-repo --model claude-sonnet-4-20250514

  # Dry run to see the docker command
  ./launch.sh bc-42 https://github.com/your-org/your-repo --dry-run
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
DOCKER_NETWORK="beads-server_default"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      --remote)
        BEADS_REMOTE_URL="$2"; shift 2
        ;;
      --image)
        IMAGE="$2"; shift 2
        ;;
      --model)
        MODEL="$2"; shift 2
        ;;
      --branch)
        BRANCH="$2"; shift 2
        ;;
      --timeout)
        QUESTION_TIMEOUT="$2"; shift 2
        ;;
      --actor)
        BD_ACTOR="$2"; shift 2
        ;;
      --network)
        DOCKER_NETWORK="$2"; shift 2
        ;;
      --dry-run)
        DRY_RUN=1; shift
        ;;
      -*)
        die "Unknown option: $1 (use --help for usage)"
        ;;
      *)
        # Positional args: bead-id, then repo-url
        if [[ -z "$BEAD_ID" ]]; then
          BEAD_ID="$1"
        elif [[ -z "$REPO_URL" ]]; then
          REPO_URL="$1"
        else
          die "Unexpected argument: $1 (use --help for usage)"
        fi
        shift
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
validate() {
  # Required positional args
  [[ -n "$BEAD_ID" ]]  || die "Missing required argument: <bead-id>"
  [[ -n "$REPO_URL" ]] || die "Missing required argument: <repo-url>"

  # Required env vars
  [[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN must be set"

  # At least one LLM key
  if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" ]]; then
    die "At least one of ANTHROPIC_API_KEY or OPENAI_API_KEY must be set"
  fi

  # Docker available
  command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"

  # bd available
  command -v bd >/dev/null 2>&1 || die "bd (beads CLI) is not installed or not in PATH"

  # Check beads-server is reachable (remotesapi returns 400 on GET /, but connection succeeds)
  if ! curl -so /dev/null --connect-timeout 2 "http://localhost:50051/" 2>/dev/null; then
    warn "Could not reach beads-server at http://localhost:50051 -- is it running?"
    warn "Start it with: cd beads-server && docker compose up -d"
  fi

  # Verify the bead exists locally
  local bead_json
  bead_json=$(bd show "$BEAD_ID" --json 2>/dev/null | jq '.[0]' 2>/dev/null) || true
  if [[ -z "$bead_json" || "$bead_json" == "null" ]]; then
    die "Bead $BEAD_ID not found in local beads database"
  fi

  local bead_status
  bead_status=$(echo "$bead_json" | jq -r '.status')
  if [[ "$bead_status" != "open" && "$bead_status" != "in_progress" ]]; then
    die "Bead $BEAD_ID has status '$bead_status' -- must be 'open' or 'in_progress'"
  fi

  log "Bead verified: $BEAD_ID ($(echo "$bead_json" | jq -r '.title'))"
}

# ---------------------------------------------------------------------------
# Push beads to server
# ---------------------------------------------------------------------------
push_beads() {
  log "Pushing beads to server..."
  bd dolt commit 2>&1 || true    # may say "nothing to commit"
  DOLT_REMOTE_PASSWORD="" bd dolt push 2>&1 || {
    die "Failed to push beads to server. Is 'origin' remote configured? Try: bd dolt remote add origin http://localhost:50051/bc"
  }
  log "Beads pushed successfully."
}

# ---------------------------------------------------------------------------
# Build docker run command
# ---------------------------------------------------------------------------
build_docker_cmd() {
  # The container connects to beads-server via Docker networking.
  # Use the container name (beads-server) as the hostname when on the same network,
  # or host.docker.internal when not on the beads-server network.
  local cmd=(
    docker run --rm
    --network "$DOCKER_NETWORK"
    -e "BEAD_ID=$BEAD_ID"
    -e "REPO_URL=$REPO_URL"
    -e "GITHUB_TOKEN=$GITHUB_TOKEN"
    -e "BEADS_REMOTE=$BEADS_REMOTE_URL"
    -e "DOLT_REMOTE_PASSWORD="
    -e "REPO_BRANCH=$BRANCH"
    -e "QUESTION_TIMEOUT=$QUESTION_TIMEOUT"
    -e "BD_ACTOR=$BD_ACTOR"
    -e "BEADS_SYNC_MODE=$SYNC_MODE"
  )

  # Pass through LLM API keys
  [[ -n "${ANTHROPIC_API_KEY:-}" ]]  && cmd+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
  [[ -n "${OPENAI_API_KEY:-}" ]]     && cmd+=(-e "OPENAI_API_KEY=$OPENAI_API_KEY")

  # Optional: model
  [[ -n "$MODEL" ]] && cmd+=(-e "MODEL=$MODEL")

  # Image name
  cmd+=("$IMAGE")

  echo "${cmd[@]}"
}

# ---------------------------------------------------------------------------
# Pull results back from server
# ---------------------------------------------------------------------------
pull_results() {
  log "Pulling bead updates from server..."
  DOLT_REMOTE_PASSWORD="" bd dolt pull 2>&1 || {
    warn "Failed to pull beads from server (results may be stale)"
    return 1
  }
  log "Beads pulled successfully."
}

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
print_summary() {
  log "============================================"
  log "  beads-coder run complete"
  log "============================================"

  # Read bead state after pull
  local bead_json
  bead_json=$(bd show "$BEAD_ID" --json 2>/dev/null | jq '.[0]' 2>/dev/null) || true

  if [[ -n "$bead_json" && "$bead_json" != "null" ]]; then
    local status title
    status=$(echo "$bead_json" | jq -r '.status')
    title=$(echo "$bead_json" | jq -r '.title')

    log "Bead:   $BEAD_ID"
    log "Title:  $title"
    log "Status: $status"

    # Check for PR reference in notes
    local notes
    notes=$(echo "$bead_json" | jq -r '.notes // empty')
    if [[ -n "$notes" ]]; then
      # Use grep -E for portability (works on macOS and Linux)
      local pr_url
      pr_url=$(echo "$notes" | grep -oE 'https://github\.com/[^[:space:])]+/pull/[0-9]+' | head -1) || true
      if [[ -n "$pr_url" ]]; then
        log "PR:     $pr_url"
      fi
    fi
  else
    warn "Could not read bead $BEAD_ID after pull"
  fi

  # Check for question beads (children with "question" in title)
  local children
  children=$(bd list --parent "$BEAD_ID" --json 2>/dev/null) || true
  if [[ -n "$children" && "$children" != "[]" && "$children" != "null" ]]; then
    local question_count
    question_count=$(echo "$children" | jq '[.[] | select(.title | test("question|blocked|clarif"; "i"))] | length' 2>/dev/null) || question_count=0
    if [[ "$question_count" -gt 0 ]]; then
      log ""
      log "Questions ($question_count):"
      echo "$children" | jq -r '.[] | select(.title | test("question|blocked|clarif"; "i")) | "  \(.id): \(.title) [\(.status)]"' 2>/dev/null || true
    fi
  fi

  log "============================================"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate

  push_beads

  local docker_cmd
  docker_cmd=$(build_docker_cmd)

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry run -- docker command:"
    echo ""
    echo "$docker_cmd"
    echo ""
    exit 0
  fi

  log "Launching container..."
  log "Image:   $IMAGE"
  log "Bead:    $BEAD_ID"
  log "Repo:    $REPO_URL"
  log "Remote:  $BEADS_REMOTE_URL"
  log "Network: $DOCKER_NETWORK"
  log ""

  # Run the container (output streams directly to terminal)
  local exit_code=0
  eval "$docker_cmd" || exit_code=$?

  log ""
  if [[ "$exit_code" -eq 0 ]]; then
    log "Container exited successfully (code 0)"
  else
    warn "Container exited with code $exit_code"
  fi

  # Always try to pull results back, even on failure
  pull_results || true
  print_summary

  exit "$exit_code"
}

main "$@"
