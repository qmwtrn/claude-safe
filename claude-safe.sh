#!/bin/bash
set -euo pipefail

# Run Claude Code safely in a sandboxed Docker container
# with network restrictions and skip-permissions enabled
#
# Author: Daniel Krähenbühl - Hamilton Medical AG

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Use current directory if no project path is provided
if [ $# -ge 1 ]; then
    PROJECT_DIR="$1"
elif [ -z "${PROJECT_DIR:-}" ] && [ -f "$SCRIPT_DIR/.env" ]; then
    PROJECT_DIR=$(grep -E '^PROJECT_DIR=' "$SCRIPT_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
fi
PROJECT_DIR="${PROJECT_DIR:-.}"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# Choose Docker Compose (v1 or v2)
COMPOSE_CMD=()
if command -v docker-compose &> /dev/null; then
    COMPOSE_CMD=(docker-compose)
elif docker compose version &> /dev/null; then
    COMPOSE_CMD=(docker compose)
else
    echo "❌ Error: Docker Compose is not installed"
    echo "   Please install Docker Compose from: https://docs.docker.com/compose/install/"
    exit 1
fi

# Helper: convert Windows drive-letter paths (D:/... or D:\...) to WSL format (/mnt/d/...)
win_to_wsl_path() {
    local p="$1"
    if [[ "$p" =~ ^([A-Za-z]):[/\\] ]]; then
        local drive
        drive=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
        p="/mnt/$drive${p:2}"
        p="${p//\\//}"
    fi
    echo "$p"
}

# Convert Windows paths to WSL format
if [[ "$PROJECT_DIR" =~ ^[/\\][/\\] ]]; then
    # UNC paths (\\server\share or //server/share)
    unc_path="${PROJECT_DIR//\\//}"
    # Extract server and share components
    unc_path="${unc_path#//}"
    server="${unc_path%%/*}"
    rest="${unc_path#*/}"
    if [[ "$server" == "wsl$" || "$server" == "wsl.localhost" ]]; then
        # \\wsl$\distro\path or \\wsl.localhost\distro\path → extract the path after distro
        if [[ "$rest" == */* ]]; then
            PROJECT_DIR="/${rest#*/}"
        else
            PROJECT_DIR="/"
        fi
    else
        echo "❌ Error: UNC network paths (\\\\$server\\...) cannot be directly used in WSL"
        echo "   Mount the share first: sudo mount -t drvfs '${PROJECT_DIR}' /mnt/share"
        echo "   Then use: $0 /mnt/share"
        exit 1
    fi
else
    PROJECT_DIR=$(win_to_wsl_path "$PROJECT_DIR")
fi

# Check if project directory exists
if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ Error: Directory not found: $PROJECT_DIR"
    exit 1
fi

# Convert to absolute path
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Check if .env file exists, create empty one if not
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Creating .env file..."
    echo "# Leave empty to use web-based login" > "$SCRIPT_DIR/.env"
    echo "ANTHROPIC_API_KEY=" >> "$SCRIPT_DIR/.env"
fi

# Export PROJECT_DIR for docker-compose
export PROJECT_DIR

# Ensure ~/.ssh and ~/.claude exist so Docker bind mounts don't create root-owned dirs
mkdir -p -m 700 ~/.ssh
mkdir -p ~/.claude

# Read GIT_PARENT_REPO from .env if not already in environment
if [ -z "${GIT_PARENT_REPO:-}" ] && [ -f "$SCRIPT_DIR/.env" ]; then
    GIT_PARENT_REPO=$(grep -E '^GIT_PARENT_REPO=' "$SCRIPT_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
fi

# Auto-detect git worktrees if GIT_PARENT_REPO not set
if [ -z "${GIT_PARENT_REPO:-}" ] && [ -f "$PROJECT_DIR/.git" ]; then
    gitdir_content=$(cat "$PROJECT_DIR/.git")
    gitdir_path="${gitdir_content#gitdir: }"
    # Normalize backslashes to forward slashes for pattern matching
    gitdir_normalized="${gitdir_path//\\//}"
    if [[ "$gitdir_normalized" == */.git/worktrees/* ]]; then
        GIT_PARENT_REPO="${gitdir_normalized%%/.git/worktrees/*}"
        echo "🔗 Git worktree detected, parent repo: $GIT_PARENT_REPO"
    fi
fi

# Default GIT_PARENT_REPO to PROJECT_DIR so wrapper and direct compose usage behave the same
GIT_PARENT_REPO="${GIT_PARENT_REPO:-$PROJECT_DIR}"
GIT_PARENT_REPO=$(win_to_wsl_path "$GIT_PARENT_REPO")
export GIT_PARENT_REPO
if [ "$GIT_PARENT_REPO" != "$PROJECT_DIR" ]; then
    echo "📂 Parent repo mount: $GIT_PARENT_REPO"
fi

echo "🐳 Starting Claude Code..."
echo "📁 Project: $PROJECT_DIR"
echo "⚡ Running with --dangerously-skip-permissions"
echo ""

# Run the container with Claude Code automatically starting
# Build the list of compose files: always the base, plus override if present
COMPOSE_FILES=(-f "$COMPOSE_FILE")
OVERRIDE_FILE="$SCRIPT_DIR/docker-compose.override.yml"
if [ -f "$OVERRIDE_FILE" ]; then
    COMPOSE_FILES+=(-f "$OVERRIDE_FILE")
fi

"${COMPOSE_CMD[@]}" "${COMPOSE_FILES[@]}" run --rm claude-code

# Cleanup
echo ""
echo "✅ Claude Code session ended"
