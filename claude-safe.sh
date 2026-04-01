#!/bin/bash
set -euo pipefail

# Run Claude Code safely in a sandboxed Docker container
# with network restrictions and skip-permissions enabled
#
# Author: Daniel Krähenbühl - Hamilton Medical AG

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

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

# Helper: normalize a single path — handles UNC, Windows drive letters, and resolves to absolute
normalize_path() {
    local p="$1"
    if [[ "$p" =~ ^[/\\][/\\] ]]; then
        local unc="${p//\\//}"
        unc="${unc#//}"
        local server="${unc%%/*}"
        local rest="${unc#*/}"
        if [[ "$server" == "wsl$" || "$server" == "wsl.localhost" ]]; then
            p="${rest#*/}"
            p="/${p}"
        else
            echo "❌ Error: UNC network paths (\\\\$server\\...) cannot be directly used in WSL" >&2
            echo "   Mount the share first: sudo mount -t drvfs '$1' /mnt/share" >&2
            return 1
        fi
    else
        p=$(win_to_wsl_path "$p")
    fi
    if [ ! -d "$p" ]; then
        echo "❌ Error: Directory not found: $p" >&2
        return 1
    fi
    echo "$(cd "$p" && pwd)"
}

# Show usage information
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [PATH...]

Run Claude Code in a sandboxed Docker container with network restrictions
and --dangerously-skip-permissions enabled.

Arguments:
  PATH                  One or more project directories to mount.
                        Multiple paths are mounted as named subdirectories
                        under /workspace/<basename>. The first path becomes
                        the working directory.
                        Default: PROJECT_DIR from .env, or current directory.

Options:
  -h, --help            Show this help message and exit.
  --no-browser          Do not grant the container access to the host X11
                        display. Use this when running headless or when you
                        do not want the container to be able to open windows
                        on your desktop. By default, the X11 socket is shared
                        so that /login inside the container can open your
                        browser automatically. DISPLAY defaults to :0 when
                        not set in the environment.

Environment variables (set in .env or shell):
  ANTHROPIC_API_KEY     API key for Claude. Leave empty to use web-based login.
  PROJECT_DIR           Default project directory (overridden by PATH argument).
  GIT_PARENT_REPO       Path to the parent git repository (auto-detected for
                        worktrees, otherwise defaults to the primary PATH).

Examples:
  $(basename "$0")                        # use current directory
  $(basename "$0") /path/to/repo          # single repo
  $(basename "$0") /repo/a /repo/b        # multiple repos
  $(basename "$0") --no-browser /path/to/repo   # skip X11 display sharing
EOF
}

# Collect raw paths from arguments, .env, or default to current directory
NO_BROWSER=false
RAW_PATHS=()
if [ $# -ge 1 ]; then
    for _arg in "$@"; do
        case "$_arg" in
            -h|--help) usage; exit 0 ;;
            --no-browser) NO_BROWSER=true ;;
            *) RAW_PATHS+=("$_arg") ;;
        esac
    done
fi
if [ "${#RAW_PATHS[@]}" -eq 0 ] && [ -z "${PROJECT_DIR:-}" ] && [ -f "$SCRIPT_DIR/.env" ]; then
    _env_dir=$(grep -E '^PROJECT_DIR=' "$SCRIPT_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    [ -n "$_env_dir" ] && RAW_PATHS+=("$_env_dir")
fi
[ "${#RAW_PATHS[@]}" -eq 0 ] && RAW_PATHS+=(".")

# Resolve all paths
RESOLVED_PATHS=()
for _raw in "${RAW_PATHS[@]}"; do
    _resolved=$(normalize_path "$_raw") || exit 1
    RESOLVED_PATHS+=("$_resolved")
done

# Check if .env file exists, create empty one if not
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Creating .env file..."
    echo "# Leave empty to use web-based login" > "$SCRIPT_DIR/.env"
    echo "ANTHROPIC_API_KEY=" >> "$SCRIPT_DIR/.env"
fi

# Ensure ~/.ssh and ~/.claude exist so Docker bind mounts don't create root-owned dirs
mkdir -p -m 700 ~/.ssh
mkdir -p ~/.claude

# Single repo: existing behavior — mount at /workspace
# Multiple repos: create an empty temp dir for /workspace, mount each repo as a named subdir
EXTRA_VOLUME_FLAGS=()
TEMP_WORKSPACE=""
if [ "${#RESOLVED_PATHS[@]}" -eq 1 ]; then
    export PROJECT_DIR="${RESOLVED_PATHS[0]}"
else
    TEMP_WORKSPACE=$(mktemp -d)
    export PROJECT_DIR="$TEMP_WORKSPACE"
    for _path in "${RESOLVED_PATHS[@]}"; do
        _name=$(basename "$_path")
        EXTRA_VOLUME_FLAGS+=(-v "$_path:/workspace/$_name")
    done
    export CLAUDE_WORKING_DIR="/workspace/$(basename "${RESOLVED_PATHS[0]}")"
fi

# Read GIT_PARENT_REPO from .env if not already in environment
if [ -z "${GIT_PARENT_REPO:-}" ] && [ -f "$SCRIPT_DIR/.env" ]; then
    GIT_PARENT_REPO=$(grep -E '^GIT_PARENT_REPO=' "$SCRIPT_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
fi

# Auto-detect git worktrees from the primary repo
_primary="${RESOLVED_PATHS[0]}"
if [ -z "${GIT_PARENT_REPO:-}" ] && [ -f "$_primary/.git" ]; then
    gitdir_content=$(cat "$_primary/.git")
    gitdir_path="${gitdir_content#gitdir: }"
    gitdir_normalized="${gitdir_path//\\//}"
    if [[ "$gitdir_normalized" == */.git/worktrees/* ]]; then
        GIT_PARENT_REPO="${gitdir_normalized%%/.git/worktrees/*}"
        echo "🔗 Git worktree detected, parent repo: $GIT_PARENT_REPO"
    fi
fi

GIT_PARENT_REPO="${GIT_PARENT_REPO:-$_primary}"
GIT_PARENT_REPO=$(win_to_wsl_path "$GIT_PARENT_REPO")
export GIT_PARENT_REPO
if [ "$GIT_PARENT_REPO" != "$_primary" ]; then
    echo "📂 Parent repo mount: $GIT_PARENT_REPO"
fi

echo "🐳 Starting Claude Code..."
if [ "${#RESOLVED_PATHS[@]}" -eq 1 ]; then
    echo "📁 Project: ${RESOLVED_PATHS[0]}"
else
    echo "📁 Repos:"
    for _path in "${RESOLVED_PATHS[@]}"; do
        echo "   /workspace/$(basename "$_path")  ←  $_path"
    done
    echo "   Starting in: /workspace/$(basename "${RESOLVED_PATHS[0]}")"
fi
echo "⚡ Running with --dangerously-skip-permissions"
echo ""

# Run the container with Claude Code automatically starting
# Build the list of compose files: always the base, plus override if present
COMPOSE_FILES=(-f "$COMPOSE_FILE")
OVERRIDE_FILE="$SCRIPT_DIR/docker-compose.override.yml"
if [ -f "$OVERRIDE_FILE" ]; then
    COMPOSE_FILES+=(-f "$OVERRIDE_FILE")
fi

# Grant container access to host X11 display so /login can open the browser.
# When DISPLAY is unset and --no-browser is not given, default to :0.
X11_VOLUME_FLAGS=()
DISPLAY_FLAGS=()
if [ "$NO_BROWSER" = false ]; then
    : "${DISPLAY:=:0}"
    xhost +local:docker > /dev/null 2>&1 \
        && X11_VOLUME_FLAGS=(-v /tmp/.X11-unix:/tmp/.X11-unix) \
        && DISPLAY_FLAGS=(-e DISPLAY="$DISPLAY") \
        && echo "X11 display sharing enabled ($DISPLAY) — /login will open your browser."
fi

"${COMPOSE_CMD[@]}" "${COMPOSE_FILES[@]}" run --rm "${EXTRA_VOLUME_FLAGS[@]}" "${X11_VOLUME_FLAGS[@]}" "${DISPLAY_FLAGS[@]}" claude-code

# Cleanup
[ -n "$TEMP_WORKSPACE" ] && rm -rf "$TEMP_WORKSPACE"
echo ""
echo "✅ Claude Code session ended"
