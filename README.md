# beads-coder

An ephemeral Docker container that takes a [beads](https://github.com/steveyegge/beads) issue ID, clones a GitHub repo, uses [OpenCode](https://opencode.ai) in headless mode to implement the story, and delivers a pull request.

One command in, one PR out.

## Quick start

### 1. Start the beads server

The beads server is a Dolt database that acts as the central hub for beads sync between the host and coding containers.

```bash
cd beads-server
docker compose up -d
```

This starts a Dolt SQL server with the remotesapi enabled on port 50051.

### 2. Configure your host to sync with the server

```bash
# Add the server as a remote (one-time setup)
bd dolt remote add origin http://localhost:50051/bc

# Push your beads to the server (first push needs --force)
bd dolt commit
bd dolt push --force
```

Subsequent pushes won't need `--force`:

```bash
bd dolt commit && bd dolt push
```

### 3. Build the coding container

```bash
docker build -t beads-coder .
```

### 4. Launch a coding job

```bash
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx
export ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxx

./launch.sh bc-42 https://github.com/your-org/your-repo
```

The launch script will:

1. Push the latest beads to the server
2. Start a beads-coder container on the same Docker network
3. Wait for it to finish
4. Pull results back from the server
5. Print a summary with bead status, PR URL, and any questions

Use `--dry-run` to see the Docker command without running it:

```bash
./launch.sh bc-42 https://github.com/your-org/your-repo --dry-run
```

## Architecture

```
  ┌─────────┐         ┌──────────────┐         ┌─────────────┐
  │  Host    │  push   │ beads-server │  pull   │ beads-coder │
  │  (bd)    │ ──────> │ (Dolt + API) │ <────── │ (container) │
  │         │ <────── │  port 50051  │ ──────> │             │
  │         │  pull   │              │  push   │             │
  └─────────┘         └──────────────┘         └─────────────┘
                              │
                        Docker network
                     (beads-server_default)
```

The beads-server runs Dolt's remotesapi, which provides a native push/pull protocol over HTTP. Both the host and coding containers sync through this server -- no volume mounts needed.

### Phases

The coding container runs four phases in sequence:

```
Setup  -->  Code  -->  Question loop  -->  Deliver
```

**Setup** (`scripts/setup.sh`): Validates env vars, configures git/gh auth, initializes the beads database, pulls bead data from the server, clones the repo, creates a feature branch, and atomically claims the bead.

**Code** (`scripts/run-agent.sh`): Reads the bead description, composes a structured prompt, and runs `opencode run` headlessly with the opencode-beads plugin. The agent receives project-specific instructions via an injected `AGENTS.md`.

**Question loop** (integrated in `run-agent.sh`): If the agent is blocked and needs human input, it creates a question bead (child of the work bead), writes its ID to `/tmp/needs-answer`, and exits. The script detects this, syncs the question upstream, and polls every 30 seconds for an answer. Once answered (or timed out), it resumes the agent.

**Deliver** (`scripts/deliver.sh`): Stages changes (excluding injected `AGENTS.md`), commits with a conventional commit message referencing the bead, pushes the branch, creates a PR via `gh`, updates the bead with the PR link, and creates a review-request child bead.

## Beads server

The `beads-server/` directory contains a Docker Compose setup for the central Dolt server.

### What it does

- Runs `dolt sql-server` with the remotesapi enabled (port 50051)
- Auto-initializes the `bc` database on first run
- Grants `CLONE_ADMIN` to `root@%` so clients can push/pull
- Persists data in a Docker volume (`beads-data`)

### Configuration

| Environment variable | Default | Description |
|---|---|---|
| `BEADS_DB_NAME` | `bc` | Database name (must match your beads prefix) |
| `BEADS_SQL_PORT` | `3307` | Host port for SQL access (debugging) |
| `BEADS_REMOTE_PORT` | `50051` | Host port for remotesapi (push/pull) |

### Management

```bash
# Start
cd beads-server && docker compose up -d

# View logs
docker compose logs -f

# Stop (keeps data)
docker compose down

# Stop and delete all data
docker compose down -v
```

## Launch script

`launch.sh` is the host-side entry point for dispatching work.

### Options

| Option | Default | Description |
|---|---|---|
| `--remote <url>` | `http://beads-server:50051/bc` | Beads remote URL for container |
| `--image <name>` | `beads-coder` | Docker image name |
| `--model <model>` | provider default | LLM model identifier |
| `--branch <branch>` | `main` | Base branch |
| `--timeout <seconds>` | `3600` | Question timeout |
| `--actor <name>` | `beads-coder` | Actor name for audit trail |
| `--network <name>` | `beads-server_default` | Docker network to join |
| `--dry-run` | | Print docker command without executing |

### Environment variables

| Variable | Required | Description |
|---|---|---|
| `GITHUB_TOKEN` | Yes | GitHub personal access token |
| `ANTHROPIC_API_KEY` | At least one | Anthropic API key |
| `OPENAI_API_KEY` | At least one | OpenAI API key |
| `BEADS_REMOTE_URL` | No | Override remote URL for container |

## Container environment variables

### Required

| Variable | Description |
|---|---|
| `BEAD_ID` | Bead ID to work on (e.g. `bc-42`) |
| `REPO_URL` | GitHub repo URL to clone |
| `GITHUB_TOKEN` | GitHub personal access token (needs repo + PR permissions) |
| `BEADS_REMOTE` | Dolt remote URL for beads sync |
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
| `DOLT_REMOTE_PASSWORD` | | Password for Dolt remote auth (empty for beads-server) |

## Error handling

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

### Beads server (recommended)

The beads-server provides a Dolt remotesapi over HTTP. Both the host and containers push/pull to it.

```bash
# Host pushes to server
bd dolt remote add origin http://localhost:50051/bc
bd dolt push

# Container connects via Docker network
BEADS_REMOTE=http://beads-server:50051/bc
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
  launch.sh               # Host-side: push beads, run container, pull results
  container-AGENTS.md     # Template injected into the workspace for the agent
  container-opencode.json # OpenCode config with opencode-beads plugin
  scripts/
    lib.sh                # Shared: logging, exit codes, env validation, sync, EXIT trap
    setup.sh              # Phase 1: init beads, clone repo, claim bead
    run-agent.sh          # Phase 2+3: run OpenCode, handle question loop
    deliver.sh            # Phase 4: commit, push, create PR
    verify-opencode.sh    # Smoke test for the container toolchain
  beads-server/
    Dockerfile            # Dolt SQL server with remotesapi
    docker-compose.yml    # One-command server setup
    config.yaml           # Dolt server configuration
    init-db.sh            # First-run database + permissions setup
    entrypoint.sh         # Init then start server
```

## Bundled tools

The coding container image includes:

- **bd** (beads CLI) -- issue tracking
- **opencode** -- AI coding agent (headless mode)
- **opencode-beads** -- plugin for beads integration
- **gh** -- GitHub CLI for PR creation
- **git**, **jq**, **curl**, **envsubst**
