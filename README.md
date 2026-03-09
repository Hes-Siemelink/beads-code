# beads-coder

An ephemeral Docker container that takes a [beads](https://github.com/steveyegge/beads) issue ID, clones a GitHub repo, uses [OpenCode](https://opencode.ai) in headless mode to implement the story, and delivers a pull request.

One command in, one PR out.

## Quick start

### Build

```bash
docker build -t beads-coder .
```

### Run

```bash
docker run --rm \
  -e BEAD_ID=bc-42 \
  -e REPO_URL=https://github.com/your-org/your-repo \
  -e GITHUB_TOKEN=ghp_xxxxxxxxxxxx \
  -e BEADS_REMOTE=file:///beads-remote \
  -e ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxx \
  beads-coder
```

The container will:

1. Initialize a beads database and sync from the remote
2. Clone the repo, create a `beads/bc-42` branch
3. Atomically claim the bead (prevents race conditions with other agents)
4. Run OpenCode headlessly to implement the story
5. If blocked, create a question bead, poll for an answer, and resume
6. Commit, push, and create a PR linked back to the bead
7. Exit

## Environment variables

### Required

| Variable | Description |
|---|---|
| `BEAD_ID` | Bead ID to work on (e.g. `bc-42`) |
| `REPO_URL` | GitHub repo URL to clone |
| `GITHUB_TOKEN` | GitHub personal access token (needs repo + PR permissions) |
| `BEADS_REMOTE` | Dolt remote URL for beads sync (see [Sync modes](#sync-modes)) |
| `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` | At least one LLM provider key |

### Optional

| Variable | Default | Description |
|---|---|---|
| `MODEL` | provider default | Model identifier (e.g. `claude-sonnet-4-20250514`) |
| `REPO_BRANCH` | `main` | Base branch to create the feature branch from |
| `QUESTION_TIMEOUT` | `3600` | Seconds to wait for answers to question beads |
| `MAX_QUESTION_ROUNDS` | `5` | Maximum question/answer round-trips |
| `BD_ACTOR` | `beads-coder` | Actor name for git commits and audit trail |
| `BEADS_SYNC_MODE` | `dolt` | Sync mode: `dolt` or `jsonl` |
| `BEADS_PREFIX` | `bc` | Beads ID prefix |
| `BEADS_JSONL_PATH` | `/beads-remote/beads.jsonl` | JSONL file path (only for `jsonl` mode) |

## How it works

### Phases

The container runs four phases in sequence:

```
Setup  -->  Code  -->  Question loop  -->  Deliver
```

**Setup** (`scripts/setup.sh`): Validates env vars, configures git/gh auth, initializes the beads database, pulls bead data from the remote, clones the repo, creates a feature branch, and atomically claims the bead.

**Code** (`scripts/run-agent.sh`): Reads the bead description, composes a structured prompt, and runs `opencode run` headlessly with the opencode-beads plugin. The agent receives project-specific instructions via an injected `AGENTS.md`.

**Question loop** (integrated in `run-agent.sh`): If the agent is blocked and needs human input, it creates a question bead (child of the work bead), writes its ID to `/tmp/needs-answer`, and exits. The script detects this, syncs the question upstream, and polls every 30 seconds for an answer. Once answered (or timed out), it resumes the agent.

**Deliver** (`scripts/deliver.sh`): Stages changes (excluding injected `AGENTS.md`), commits with a conventional commit message referencing the bead, pushes the branch, creates a PR via `gh`, updates the bead with the PR link, and creates a review-request child bead.

### Error handling

Every failure updates the bead so work items never get stuck in limbo:

- **Missing env vars**: Exit code 2, clear error message
- **Bead already claimed**: Exit code 3, bead status unchanged
- **Clone/push/PR failure**: Exit code 1, bead commented with error details, status reverted to `open`
- **Agent crash**: Exit code 1, bead commented with phase and error
- **Sync failures**: Logged but non-fatal (best-effort)

An EXIT trap ensures the bead is always updated, even on unexpected failures.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success -- PR created |
| `1` | Recoverable failure (agent error, no changes, push failed) |
| `2` | Configuration error (missing env vars, bad config) |
| `3` | Claim conflict (bead already taken by another agent) |

## Sync modes

The container communicates bead state (claims, questions, status updates) via a Dolt remote.

### Dolt remote (default)

Set `BEADS_REMOTE` to any Dolt remote URL:

```bash
# File-based (simplest for local testing)
-e BEADS_REMOTE=file:///beads-remote

# DoltHub
-e BEADS_REMOTE=your-org/your-beads-db
-e DOLT_REMOTE_USER=your-user
-e DOLT_REMOTE_PASSWORD=your-token
```

For file-based remotes, mount a shared volume:

```bash
docker run --rm \
  -v /path/to/beads-remote:/beads-remote \
  -e BEADS_REMOTE=file:///beads-remote \
  ...
  beads-coder
```

### JSONL fallback

For environments where Dolt remotes are impractical:

```bash
docker run --rm \
  -v /path/to/shared:/beads-remote \
  -e BEADS_SYNC_MODE=jsonl \
  -e BEADS_JSONL_PATH=/beads-remote/beads.jsonl \
  ...
  beads-coder
```

The host exports beads to JSONL before launch, the container imports on startup and exports before exit.

## Question protocol

When the agent needs human input:

1. Agent creates a question bead as a child of the work bead
2. Agent writes the question bead ID to `/tmp/needs-answer` and exits
3. Container syncs the question upstream and polls for an answer every 30s
4. Human (or another agent) adds a comment to the question bead
5. Container detects the answer, resumes the agent with the answer as context

If no answer arrives within `QUESTION_TIMEOUT` seconds, the agent is resumed and told to proceed with its best judgment.

## Project structure

```
beads-coder/
  Dockerfile              # Multi-stage build (1.5 GB image)
  entrypoint.sh           # Orchestrates phases: setup -> code -> deliver
  container-AGENTS.md     # Template injected into the workspace for the agent
  container-opencode.json # OpenCode config with opencode-beads plugin
  scripts/
    lib.sh                # Shared: logging, exit codes, env validation, sync, EXIT trap
    setup.sh              # Phase 1: init beads, clone repo, claim bead
    run-agent.sh          # Phase 2+3: run OpenCode, handle question loop
    deliver.sh            # Phase 4: commit, push, create PR
    verify-opencode.sh    # Smoke test for the container toolchain
```

## Bundled tools

The container image includes:

- **bd** (beads CLI) -- issue tracking
- **opencode** -- AI coding agent (headless mode)
- **opencode-beads** -- plugin for beads integration
- **gh** -- GitHub CLI for PR creation
- **git**, **jq**, **curl**, **envsubst**
