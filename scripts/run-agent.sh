#!/usr/bin/env bash
# run-agent.sh -- Phase 2+3: Invoke OpenCode to implement the story, handle question loop
#
# Phase 2: Compose prompt from bead data, run opencode headlessly
# Phase 3: Detect question beads, poll for answers, resume agent
#
# The question flow:
#   1. OpenCode (via AGENTS.md instructions) creates a question bead and
#      writes its ID to /tmp/needs-answer, then exits cleanly.
#   2. This script detects /tmp/needs-answer, syncs the question upstream,
#      and polls for an answer (comment on the question bead).
#   3. Once answered, it resumes OpenCode with the answer as context.
#   4. On timeout, it resumes telling the agent to proceed with best judgment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

set_phase "code"
install_exit_trap

WORKSPACE="/workspace"
MODEL="${MODEL:-}"
OPENCODE_LOG="/tmp/opencode-output.log"
NEEDS_ANSWER_FILE="/tmp/needs-answer"
MAX_QUESTION_ROUNDS="${MAX_QUESTION_ROUNDS:-5}"
OPENCODE_TIMEOUT="${OPENCODE_TIMEOUT:-1800}"   # 30 minutes default

# ---------------------------------------------------------------------------
# 1. Read bead data
# ---------------------------------------------------------------------------
log "Reading bead data..."
if [[ ! -f /tmp/bead.json ]]; then
  error "Bead data not found at /tmp/bead.json -- did setup.sh run?"
  exit "$EXIT_FAILURE"
fi

BEAD_TITLE=$(cat /tmp/bead-title.txt 2>/dev/null || jq -r '.title' /tmp/bead.json)
BEAD_DESCRIPTION=$(cat /tmp/bead-description.txt 2>/dev/null || jq -r '.description' /tmp/bead.json)
BEAD_DESIGN=$(jq -r '.design // empty' /tmp/bead.json)
BEAD_NOTES=$(jq -r '.notes // empty' /tmp/bead.json)

log "Working on: $BEAD_TITLE"

# ---------------------------------------------------------------------------
# 2. Compose the prompt
# ---------------------------------------------------------------------------
log "Composing prompt..."

PROMPT="You are working on bead ${BEAD_ID}: ${BEAD_TITLE}

## Story

${BEAD_DESCRIPTION}"

if [[ -n "$BEAD_DESIGN" ]]; then
  PROMPT="${PROMPT}

## Design Notes

${BEAD_DESIGN}"
fi

if [[ -n "$BEAD_NOTES" ]]; then
  PROMPT="${PROMPT}

## Additional Notes

${BEAD_NOTES}"
fi

PROMPT="${PROMPT}

## Instructions

1. Read the AGENTS.md file in this workspace for project-specific guidance.
2. Implement the changes described in the story above.
3. Run any available tests to verify your work.
4. If you are blocked and need human input, follow the question protocol in AGENTS.md.
5. Do NOT commit or push -- the orchestrator handles that.
6. When done, simply exit."

log "Prompt composed (${#PROMPT} chars)"

# ---------------------------------------------------------------------------
# 3. Build opencode command
# ---------------------------------------------------------------------------
build_opencode_cmd() {
  local prompt="$1"
  local extra_args=("${@:2}")

  local cmd=(opencode run "$prompt" --dir "$WORKSPACE")

  if [[ -n "$MODEL" ]]; then
    cmd+=(-m "$MODEL")
  fi

  # Add any extra args (e.g., --continue, --session)
  cmd+=("${extra_args[@]}")

  echo "${cmd[@]}"
}

# ---------------------------------------------------------------------------
# 4. Run OpenCode (Phase 2)
# ---------------------------------------------------------------------------
run_opencode() {
  local prompt="$1"
  shift
  local extra_args=("$@")

  # Clear any previous needs-answer signal
  rm -f "$NEEDS_ANSWER_FILE"

  # Prevent interactive prompts and network calls that could hang in a container
  export OPENCODE_DISABLE_AUTOUPDATE=1
  export OPENCODE_DISABLE_LSP_DOWNLOAD=1
  export OPENCODE_DISABLE_PRUNE=1
  # Point OpenCode to our config file (it won't find it via --dir /workspace)
  export OPENCODE_CONFIG="/app/opencode.json"

  log "Invoking OpenCode..."

  local cmd=(opencode run "$prompt" --dir "$WORKSPACE" --print-logs)
  if [[ -n "$MODEL" ]]; then
    cmd+=(-m "$MODEL")
  fi
  cmd+=("${extra_args[@]}")

  log "Command: ${cmd[*]}"
  log "Timeout: ${OPENCODE_TIMEOUT}s"

  # Run opencode with a timeout. Write output to log file and stream to stderr.
  # IMPORTANT: We avoid `timeout ... | tee` because tee keeps the pipe open
  # after timeout kills the process, causing the pipeline to hang. Instead we
  # redirect directly to the log file and tail it in the background for live output.
  local exit_code=0
  : > "$OPENCODE_LOG"  # truncate log file
  tail -f "$OPENCODE_LOG" &
  local tail_pid=$!
  timeout --signal=TERM --kill-after=30 "$OPENCODE_TIMEOUT" \
    "${cmd[@]}" >> "$OPENCODE_LOG" 2>&1 || exit_code=$?
  sleep 1
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true

  if [[ "$exit_code" -eq 124 ]]; then
    warn "OpenCode timed out after ${OPENCODE_TIMEOUT}s"
    bead_comment "$BEAD_ID" "OpenCode timed out after ${OPENCODE_TIMEOUT}s during phase $CURRENT_PHASE"
  fi

  # Post-run diagnostics
  log "OpenCode exited with code $exit_code"
  if [[ -f "$OPENCODE_LOG" ]]; then
    local log_lines
    log_lines=$(wc -l < "$OPENCODE_LOG" 2>/dev/null || echo 0)
    log "OpenCode log: $log_lines lines written to $OPENCODE_LOG"
    if [[ "$exit_code" -ne 0 ]]; then
      log "--- Last 20 lines of OpenCode output ---"
      tail -20 "$OPENCODE_LOG" >&2 || true
      log "--- End of OpenCode output ---"
    fi
  fi
  # Show workspace changes so far
  local ws_changes
  ws_changes=$(cd "$WORKSPACE" && git diff --stat HEAD 2>/dev/null || true)
  local ws_untracked
  ws_untracked=$(cd "$WORKSPACE" && git ls-files --others --exclude-standard 2>/dev/null || true)
  if [[ -n "$ws_changes" || -n "$ws_untracked" ]]; then
    log "Workspace changes after OpenCode run:"
    [[ -n "$ws_changes" ]]   && log "$ws_changes"
    [[ -n "$ws_untracked" ]] && log "Untracked: $ws_untracked"
  else
    log "No workspace changes detected after OpenCode run."
  fi

  return "$exit_code"
}

# ---------------------------------------------------------------------------
# 5. Question polling loop (Phase 3)
# ---------------------------------------------------------------------------
poll_for_answer() {
  local question_bead_id="$1"
  local timeout="${QUESTION_TIMEOUT:-3600}"
  local poll_interval=30
  local elapsed=0

  log "Polling for answer to question bead $question_bead_id (timeout: ${timeout}s)..."

  # Push the question upstream first
  beads_sync_push || warn "Failed to push question bead upstream"

  while [[ "$elapsed" -lt "$timeout" ]]; do
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))

    # Pull latest state
    beads_sync_pull || {
      warn "Sync pull failed during polling (attempt at ${elapsed}s)"
      continue
    }

    # Check for comments on the question bead (answers)
    local comments
    comments=$(bd comments list "$question_bead_id" --json 2>/dev/null || echo "[]")
    local comment_count
    comment_count=$(echo "$comments" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$comment_count" -gt 0 ]]; then
      # Get the latest comment as the answer
      local answer
      answer=$(echo "$comments" | jq -r '.[-1].content // .[-1].body // .[-1].text // empty' 2>/dev/null)

      if [[ -n "$answer" ]]; then
        log "Answer received for $question_bead_id after ${elapsed}s"
        echo "$answer"
        return 0
      fi
    fi

    # Also check if the question bead itself was updated/closed
    local q_status
    q_status=$(bd show "$question_bead_id" --json 2>/dev/null | jq -r '.[0].status // "open"')
    if [[ "$q_status" == "closed" ]]; then
      local q_notes
      q_notes=$(bd show "$question_bead_id" --json 2>/dev/null | jq -r '.[0].notes // empty')
      if [[ -n "$q_notes" ]]; then
        log "Question bead was closed with notes -- treating as answer"
        echo "$q_notes"
        return 0
      fi
    fi

    log "No answer yet for $question_bead_id (${elapsed}s / ${timeout}s)"
  done

  warn "Question timeout after ${timeout}s for $question_bead_id"
  return 1
}

# ---------------------------------------------------------------------------
# 6. Main loop: run agent, handle questions, resume
# ---------------------------------------------------------------------------
QUESTION_ROUND=0
SESSION_ID=""

# Initial run
run_opencode "$PROMPT" || {
  OC_EXIT=$?
  # Non-zero exit from opencode is not necessarily fatal --
  # check if it left a question signal
  if [[ ! -f "$NEEDS_ANSWER_FILE" ]]; then
    error "OpenCode failed (exit $OC_EXIT) without a question signal"
    bead_comment "$BEAD_ID" "OpenCode failed with exit code $OC_EXIT. Check container logs for details."
    exit "$EXIT_FAILURE"
  fi
}

# Question loop
while [[ -f "$NEEDS_ANSWER_FILE" ]]; do
  QUESTION_ROUND=$((QUESTION_ROUND + 1))

  if [[ "$QUESTION_ROUND" -gt "$MAX_QUESTION_ROUNDS" ]]; then
    warn "Max question rounds ($MAX_QUESTION_ROUNDS) exceeded"
    bead_comment "$BEAD_ID" "Agent reached max question rounds ($MAX_QUESTION_ROUNDS). Proceeding with best judgment."
    break
  fi

  set_phase "question-loop-$QUESTION_ROUND"

  QUESTION_BEAD_ID=$(cat "$NEEDS_ANSWER_FILE" | tr -d '[:space:]')
  rm -f "$NEEDS_ANSWER_FILE"
  log "Question detected: bead $QUESTION_BEAD_ID (round $QUESTION_ROUND)"

  # Poll for answer (poll_for_answer prints the answer text to stdout)
  ANSWER_TEXT=""
  if ANSWER_TEXT=$(poll_for_answer "$QUESTION_BEAD_ID"); then
    log "Resuming agent with answer..."
    RESUME_PROMPT="The answer to your question (bead $QUESTION_BEAD_ID) is:

${ANSWER_TEXT}

Please continue implementing bead ${BEAD_ID} based on this answer."
  else
    log "Question timed out -- telling agent to proceed with best judgment"
    RESUME_PROMPT="Your question (bead $QUESTION_BEAD_ID) was not answered within the timeout period.

Please proceed with your best judgment to implement bead ${BEAD_ID}. Document any assumptions you make as comments on the bead."

    bead_comment "$QUESTION_BEAD_ID" "Question timed out after ${QUESTION_TIMEOUT}s. Agent proceeding with best judgment."
  fi

  set_phase "code-resumed-$QUESTION_ROUND"

  # Resume opencode
  run_opencode "$RESUME_PROMPT" || {
    OC_EXIT=$?
    if [[ ! -f "$NEEDS_ANSWER_FILE" ]]; then
      error "OpenCode failed on resume (exit $OC_EXIT)"
      bead_comment "$BEAD_ID" "OpenCode failed on resume round $QUESTION_ROUND with exit code $OC_EXIT"
      exit "$EXIT_FAILURE"
    fi
  }
done

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
set_phase "code-complete"
log "Agent coding phase complete (${QUESTION_ROUND} question round(s))"
bead_comment "$BEAD_ID" "Agent completed coding phase with ${QUESTION_ROUND} question round(s)."
