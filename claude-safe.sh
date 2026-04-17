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

# Open host browser from the container via a Unix socket relay.
# AppArmor (docker-default profile) blocks D-Bus from the container, so
# xdg-open is called on the HOST side by a Python listener started here.
# The container sends URLs over a bind-mounted Unix socket. The listener
# validates the URL scheme before passing it to xdg-open.
# When DISPLAY is unset and --no-browser is not given, default to :0.
X11_VOLUME_FLAGS=()
BROWSER_SOCKET_FLAGS=()
DISPLAY_FLAGS=()
_listener_pid=""
_browser_socket=""
_listener_script=""

cleanup_browser() {
    [ -n "$_listener_pid" ] && kill "$_listener_pid" 2>/dev/null || true
    [ -n "$_browser_socket" ] && rm -f "$_browser_socket" 2>/dev/null || true
    [ -n "$_listener_script" ] && rm -f "$_listener_script" 2>/dev/null || true
}

if [ "$NO_BROWSER" = false ]; then
    : "${DISPLAY:=:0}"
    if xhost +local:docker > /dev/null 2>&1; then
        X11_VOLUME_FLAGS=(-v /tmp/.X11-unix:/tmp/.X11-unix)
        DISPLAY_FLAGS=(-e DISPLAY="$DISPLAY")
    fi

    _browser_socket=$(mktemp -u /tmp/claude-browser-XXXXXX.sock)
    _listener_script=$(mktemp /tmp/claude-browser-listener-XXXXXX.py)
    _sentinel="${_browser_socket}.ready"

    # Write the listener to a temp file to avoid HEREDOC-in-subshell PID issues.
    #
    # OAuth callback relay — no docker exec, no privilege escalation:
    #
    # When the container sends an OAuth authorization URL the wrapper holds
    # the Unix socket connection open. The host:
    #   1. Extracts the callback port from redirect_uri
    #   2. Starts a TCP proxy on localhost:<port>
    #   3. Calls xdg-open to open the browser
    #   4. When Firefox hits the proxy with /callback?code=..., the host sends
    #      that path back over the still-open Unix socket to the container
    #   5. The container makes the final GET to its own 127.0.0.1:<port><path>
    #      and writes the HTTP response back over the socket
    #   6. The host forwards that response to Firefox
    #
    # This avoids docker exec (requires docker group) and docker socket access.
    cat > "$_listener_script" << PYEOF
import socket, subprocess, os, sys, re, threading, urllib.parse

socket_path = "$_browser_socket"
sentinel_path = "$_sentinel"

if os.path.exists(socket_path):
    os.remove(socket_path)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(socket_path)
os.chmod(socket_path, 0o700)
sock.listen(5)

# Signal readiness to the shell by creating the sentinel file.
open(sentinel_path, 'w').close()

# Map oauth port -> open container socket connection.
# Protected by a lock because the proxy thread and the main accept loop
# access it concurrently.
import threading
pending = {}
pending_lock = threading.Lock()

def extract_oauth_port(url):
    """Extract callback port from redirect_uri parameter in OAuth URL."""
    try:
        parsed = urllib.parse.urlparse(url)
        params = urllib.parse.parse_qs(parsed.query)
        for ruri in params.get('redirect_uri', []):
            rp = urllib.parse.urlparse(ruri)
            if rp.scheme == 'http' and rp.hostname == 'localhost' and rp.port:
                return rp.port
    except Exception:
        pass
    return None

def start_oauth_proxy(port, container_conn):
    """
    Bind a TCP proxy on localhost:<port>. When Firefox delivers the callback
    request, extract the path and send it to the container over container_conn.
    Wait for the container to reply with the HTTP response, then forward it
    to Firefox. The container makes the actual request to its own loopback.
    """
    try:
        proxy = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        proxy.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        proxy.bind(('127.0.0.1', port))
        proxy.listen(5)
        proxy.settimeout(300)
    except OSError as e:
        sys.stderr.write(f"OAuth proxy: cannot bind port {port}: {e}\n")
        return

    def serve():
        try:
            while True:
                try:
                    browser_conn, _ = proxy.accept()
                except socket.timeout:
                    break
                except OSError:
                    break

                try:
                    browser_conn.settimeout(15)
                    raw = b''
                    while b'\r\n\r\n' not in raw and len(raw) < 8192:
                        chunk = browser_conn.recv(4096)
                        if not chunk:
                            break
                        raw += chunk
                    first_line = raw.split(b'\r\n')[0].decode('utf-8', errors='ignore')
                    m = re.match(r'\w+ (/[^\s]*)', first_line)
                    if not m:
                        browser_conn.sendall(b'HTTP/1.1 400 Bad Request\r\n\r\n')
                        browser_conn.close()
                        continue

                    path = m.group(1)
                    # Only relay /callback paths and bare /
                    if not re.match(r'^(/callback(\?|$)|/$)', path):
                        browser_conn.sendall(b'HTTP/1.1 403 Forbidden\r\n\r\n')
                        browser_conn.close()
                        continue

                    with pending_lock:
                        conn = pending.get(port)

                    if conn is None:
                        browser_conn.sendall(b'HTTP/1.1 503 Service Unavailable\r\n\r\nNo container connection')
                        browser_conn.close()
                        continue

                    try:
                        # Send path to container, delimited by newline.
                        conn.sendall((path + '\n').encode())
                        # Read HTTP response from container until it closes its end.
                        response = b''
                        conn.settimeout(15)
                        while True:
                            chunk = conn.recv(4096)
                            if not chunk:
                                break
                            response += chunk
                        browser_conn.sendall(response if response else
                            b'HTTP/1.1 502 Bad Gateway\r\n\r\nEmpty response from container')
                    except Exception:
                        browser_conn.sendall(b'HTTP/1.1 502 Bad Gateway\r\n\r\nRelay error')
                    finally:
                        browser_conn.close()
                        with pending_lock:
                            pending.pop(port, None)

                except Exception:
                    try:
                        browser_conn.close()
                    except Exception:
                        pass
        finally:
            proxy.close()

    threading.Thread(target=serve, daemon=True).start()

try:
    while True:
        conn, _ = sock.accept()
        try:
            # Read URL sent by the container browser wrapper (max 2048 bytes).
            data = b''
            while len(data) < 2048:
                chunk = conn.recv(256)
                if not chunk or b'\n' in chunk:
                    data += chunk
                    break
                data += chunk
            url = data.decode('utf-8', errors='ignore').strip()

            if not url.startswith('https://'):
                conn.close()
                continue

            port = extract_oauth_port(url)
            if port:
                with pending_lock:
                    pending[port] = conn
                start_oauth_proxy(port, conn)
                # conn is kept open — the proxy thread will close it after use.
            else:
                conn.close()

            subprocess.Popen(['xdg-open', url],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
        except Exception:
            try:
                conn.close()
            except Exception:
                pass
except Exception:
    pass
finally:
    sock.close()
    for p in (socket_path, sentinel_path):
        try:
            os.remove(p)
        except OSError:
            pass
PYEOF

    # Start the listener as a direct background job so $! is the real PID.
    python3 "$_listener_script" &
    _listener_pid=$!
    trap 'cleanup_browser' EXIT

    # Wait for the listener to bind before starting the container.
    _wait=0
    while [ ! -f "$_sentinel" ] && [ $_wait -lt 50 ]; do
        sleep 0.1
        _wait=$(( _wait + 1 ))
    done
    rm -f "$_sentinel"

    BROWSER_SOCKET_FLAGS=(-v "${_browser_socket}:${_browser_socket}" \
                          -e CLAUDE_BROWSER_SOCKET="${_browser_socket}")
fi

"${COMPOSE_CMD[@]}" "${COMPOSE_FILES[@]}" run --rm "${EXTRA_VOLUME_FLAGS[@]}" "${X11_VOLUME_FLAGS[@]}" "${BROWSER_SOCKET_FLAGS[@]}" "${DISPLAY_FLAGS[@]}" claude-code

# Cleanup
cleanup_browser
[ -n "$TEMP_WORKSPACE" ] && rm -rf "$TEMP_WORKSPACE"
echo ""
echo "Claude Code session ended"
