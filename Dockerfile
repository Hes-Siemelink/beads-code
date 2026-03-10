# Dockerfile for beads-coder: ephemeral containerized coding agent
#
# Builds a container with all tools needed to:
#   1. Sync beads via Dolt remote
#   2. Clone a GitHub repo
#   3. Run OpenCode headlessly with the opencode-beads plugin
#   4. Create a PR with the results
#
# Usage:
#   docker build -t beads-coder .
#   docker run -e BEAD_ID=bc-xxx -e REPO_URL=... -e GITHUB_TOKEN=... \
#              -e BEADS_REMOTE=... -e ANTHROPIC_API_KEY=... beads-coder

# ---------------------------------------------------------------------------
# Stage 1: Install bd (beads CLI) from GitHub release
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS bd-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG BD_VERSION=0.59.0
ARG TARGETARCH

RUN ARCH="${TARGETARCH:-amd64}" && \
    curl -fsSL "https://github.com/steveyegge/beads/releases/download/v${BD_VERSION}/beads_${BD_VERSION}_linux_${ARCH}.tar.gz" \
    | tar xz -C /usr/local/bin bd && \
    chmod +x /usr/local/bin/bd

# ---------------------------------------------------------------------------
# Stage 1b: Install dolt binary
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS dolt-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG DOLT_VERSION=1.83.4
ARG TARGETARCH

RUN ARCH="${TARGETARCH:-amd64}" && \
    curl -fsSL "https://github.com/dolthub/dolt/releases/download/v${DOLT_VERSION}/dolt-linux-${ARCH}.tar.gz" \
    | tar xz -C /tmp && \
    cp -f /tmp/dolt-linux-${ARCH}/bin/dolt /usr/local/bin/dolt && \
    chmod +x /usr/local/bin/dolt && \
    rm -rf /tmp/dolt-linux-${ARCH}

# ---------------------------------------------------------------------------
# Stage 2: Main image
# ---------------------------------------------------------------------------
FROM node:22-slim

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    openssh-client \
    gettext-base \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install OpenCode globally
RUN npm install -g opencode-ai@latest

# Install AI SDK provider for custom/local models (Docker Model Runner, Ollama, etc.)
RUN npm install -g @ai-sdk/openai-compatible@latest

# Install opencode-beads plugin (pre-cache so it's available at runtime)
RUN npm install -g opencode-beads@latest

# Copy bd binary from builder stage
COPY --from=bd-builder /usr/local/bin/bd /usr/local/bin/bd

# Copy dolt binary from builder stage (required by bd for local database)
COPY --from=dolt-builder /usr/local/bin/dolt /usr/local/bin/dolt

# ---------------------------------------------------------------------------
# Application files
# ---------------------------------------------------------------------------
WORKDIR /app

# Copy scripts and configuration
COPY entrypoint.sh /app/entrypoint.sh
COPY scripts/ /app/scripts/
COPY container-AGENTS.md /app/container-AGENTS.md
COPY container-opencode.json /app/opencode.json

# Make scripts executable
RUN chmod +x /app/entrypoint.sh /app/scripts/*.sh

# ---------------------------------------------------------------------------
# Runtime configuration
# ---------------------------------------------------------------------------

# Create workspace directory
RUN mkdir -p /workspace

# Set git config to avoid warnings
RUN git config --system init.defaultBranch main

# Environment variable documentation (not set -- must be provided at runtime)
# Required:
#   BEAD_ID              - Bead ID to work on
#   REPO_URL             - GitHub repo to clone
#   GITHUB_TOKEN         - For git + gh CLI auth
#   BEADS_PROJECT_ID     - Host's beads project ID (from .beads/metadata.json)
#   ANTHROPIC_API_KEY or OPENAI_API_KEY - LLM provider key (not needed for Docker Model Runner)
#
# Optional:
#   BEADS_SERVER_HOST    - Beads SQL server hostname (default: beads-server)
#   BEADS_SERVER_PORT    - Beads SQL server port (default: 3306)
#   MODEL                - Model identifier (default: provider default)
#   QUESTION_TIMEOUT     - Seconds to wait for answers (default: 3600)
#   REPO_BRANCH          - Base branch (default: main)
#   BD_ACTOR             - Actor name for audit trail (default: beads-coder)
#   BEADS_SYNC_MODE      - Sync mode: "direct" (default), "dolt", or "jsonl"
#   BEADS_PREFIX         - Beads prefix (default: bc)
#   MAX_QUESTION_ROUNDS  - Max Q&A rounds (default: 5)

WORKDIR /workspace

ENTRYPOINT ["/app/entrypoint.sh"]
