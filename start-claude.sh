#!/bin/bash
# Wrapper script to start Claude with proper terminal settings

sync_host_ssh() {
    local host_ssh="/host-ssh"
    local target_ssh="/home/node/.ssh"
    local file
    local base

    if [ ! -d "$host_ssh" ]; then
        return
    fi

    mkdir -p "$target_ssh"
    chmod 700 "$target_ssh"
    shopt -s nullglob dotglob

    for file in "$host_ssh"/*; do
        base="$(basename "$file")"
        case "$base" in
            .|..|known_hosts|known_hosts.old)
                continue
                ;;
        esac
        if [ -d "$file" ]; then
            cp -a "$file" "$target_ssh/"
            chmod 700 "$target_ssh/$base" 2>/dev/null || true
            continue
        fi

        if [ -f "$file" ] || [ -L "$file" ]; then
            cp -a "$file" "$target_ssh/"
            chmod 600 "$target_ssh/$base" 2>/dev/null || true
        fi
    done

    shopt -u nullglob dotglob

    if [ -f "$host_ssh/known_hosts" ]; then
        touch "$target_ssh/known_hosts"
        awk '!seen[$0]++' "$target_ssh/known_hosts" "$host_ssh/known_hosts" > "$target_ssh/known_hosts.tmp"
        mv "$target_ssh/known_hosts.tmp" "$target_ssh/known_hosts"
    fi

    chmod 600 "$target_ssh"/known_hosts 2>/dev/null || true
}

sync_host_gitconfig() {
    local src="/host-gitconfig"

    if [ -d "$src" ]; then
        # Docker created an empty directory because the file didn't exist on the host
        rm -rf "$src" 2>/dev/null || true
        echo "⚠️  WARNING: ~/.gitconfig not found on host — git identity is not set."
        echo "   Run on your host machine, then restart:"
        echo "     git config --global user.name  'Your Name'"
        echo "     git config --global user.email 'you@example.com'"
        echo ""
        return
    fi

    if [ -f "$src" ]; then
        cp "$src" /home/node/.gitconfig
        # Remove all credential helpers from the copied config. The container
        # cannot use host-side helpers (e.g. git-credential-manager) because
        # those binaries do not exist here. Authentication is handled via
        # GIT_ASKPASS instead (configured by setup_git_credentials below).
        git config --file /home/node/.gitconfig --remove-section credential 2>/dev/null || true
    fi
}

setup_git_credentials() {
    # The host ~/.gitconfig may reference git-credential-manager or another
    # helper that does not exist inside the container. Clear it so git does
    # not error out.
    git config --global credential.helper ""

    # Configure a single GIT_ASKPASS script that dispatches by host when one
    # or both of GH_TOKEN / AZURE_FEED_PAT are set.
    # GIT_ASKPASS is called by git with the prompt string as $1 and must print
    # the secret to stdout.
    # GitHub remotes use "x-access-token" as a fixed username in the URL so
    # git only calls this script for the password.
    # Azure DevOps remotes also embed the username in the URL.
    if [ -n "${GH_TOKEN:-}" ] || [ -n "${AZURE_FEED_PAT:-}" ]; then
        local askpass="/tmp/git-askpass"
        cat > "$askpass" << 'ASKPASS_EOF'
#!/bin/sh
case "$1" in
    *github.com*)
        echo "$GH_TOKEN"
        ;;
    *dev.azure.com*|*visualstudio.com*)
        echo "$AZURE_FEED_PAT"
        ;;
esac
ASKPASS_EOF
        chmod +x "$askpass"
        export GIT_ASKPASS="$askpass"
        [ -n "${GH_TOKEN:-}" ]        && echo "GitHub token authentication configured (GIT_ASKPASS)"
        [ -n "${AZURE_FEED_PAT:-}" ]  && echo "Azure DevOps PAT authentication configured (GIT_ASKPASS)"
    fi
}

sync_host_claude_auth() {
    local host_claude="/host-claude"
    local source_credentials="$host_claude/.credentials.json"
    local target_claude="/home/node/.claude"

    if [ ! -f "$source_credentials" ]; then
        return
    fi

    mkdir -p "$target_claude"
    install -m 600 "$source_credentials" "$target_claude/.credentials.json"
}

sync_host_claude_settings() {
    local host_claude="/host-claude"
    local source_settings="$host_claude/settings.json"
    local target_claude="/home/node/.claude"

    if [ ! -f "$source_settings" ]; then
        return
    fi

    mkdir -p "$target_claude"
    install -m 644 "$source_settings" "$target_claude/settings.json"
}

ensure_superpowers_plugin() {
    local settings="/home/node/.claude/settings.json"

    mkdir -p "/home/node/.claude"

    if [ ! -f "$settings" ]; then
        echo '{"enabledPlugins":{"superpowers@claude-plugins-official":true}}' > "$settings"
        return
    fi

    local updated
    updated=$(jq '.enabledPlugins["superpowers@claude-plugins-official"] = true' "$settings")
    echo "$updated" > "$settings"
}

extract_worktree_name() {
    local gitdir_path="$1"
    local normalized_path="${gitdir_path//\\//}"
    basename "$normalized_path"
}

# Fix Docker socket permissions if mounted
if [ -S /var/run/docker.sock ]; then
    DOCKER_SOCKET_GID=$(stat -c '%g' /var/run/docker.sock)
    CURRENT_DOCKER_GID=$(getent group docker | cut -d: -f3)

    if [ "$DOCKER_SOCKET_GID" != "$CURRENT_DOCKER_GID" ]; then
        echo "Fixing Docker group ID mismatch..."
        echo "  Docker socket GID: $DOCKER_SOCKET_GID"
        echo "  Container docker group GID: $CURRENT_DOCKER_GID"

        # Remove existing docker group and recreate with correct GID
        sudo groupdel docker 2>/dev/null || true
        sudo groupadd -g "$DOCKER_SOCKET_GID" docker
        sudo usermod -aG docker node

        echo "  Fixed: Docker group now has GID $DOCKER_SOCKET_GID"
    fi
fi

sync_host_ssh
sync_host_claude_auth
sync_host_gitconfig
setup_git_credentials
sync_host_claude_settings
ensure_superpowers_plugin

# Fix git worktree paths when running inside Docker
# Git worktrees use a .git file (not directory) containing a gitdir pointer to
# the main repo's .git/worktrees/<name> directory. When mounted from a Windows
# host, this path doesn't exist in the container. We fix this by setting GIT_DIR
# and GIT_WORK_TREE to point to the mounted parent repo instead.
if [ -f /workspace/.git ]; then
    GITDIR_LINE=$(cat /workspace/.git)
    GITDIR_PATH="${GITDIR_LINE#gitdir: }"

    # Detect Windows paths (D:/... or D:\...) or non-existent Linux paths
    if [[ "$GITDIR_PATH" =~ ^[A-Za-z]:[/\\] ]] || [ ! -d "$GITDIR_PATH" ]; then
        WORKTREE_NAME=$(extract_worktree_name "$GITDIR_PATH")
        PARENT_WORKTREE_DIR="/git-parent-repo/.git/worktrees/$WORKTREE_NAME"

        if [ -d "$PARENT_WORKTREE_DIR" ]; then
            # Copy the worktree admin dir so we can fix the reverse pointer
            # without mutating the mounted host repository metadata.
            CONTAINER_WORKTREE_DIR=$(mktemp -d /tmp/git-worktree-XXXXXX)
            cp -a "$PARENT_WORKTREE_DIR/." "$CONTAINER_WORKTREE_DIR/"

            GITDIR_FILE="$CONTAINER_WORKTREE_DIR/gitdir"
            if [ -f "$GITDIR_FILE" ]; then
                echo "/workspace/.git" > "$GITDIR_FILE"
            fi

            COMMONDIR_FILE="$CONTAINER_WORKTREE_DIR/commondir"
            if [ -f "$COMMONDIR_FILE" ]; then
                echo "/git-parent-repo/.git" > "$COMMONDIR_FILE"
            fi

            export GIT_DIR="$CONTAINER_WORKTREE_DIR"
            export GIT_WORK_TREE="/workspace"
            echo "Git worktree detected: $WORKTREE_NAME -> $CONTAINER_WORKTREE_DIR"
        else
            echo "WARNING: Git worktree detected but parent repo not accessible."
            echo "  Set GIT_PARENT_REPO=<path-to-main-repo> in your .env file"
            echo "  Example: GIT_PARENT_REPO=D:/doc/git/ventsight"
            echo "  The .git file references: $GITDIR_PATH"
        fi
    fi
fi

# Initialize firewall
sudo /usr/local/bin/init-firewall.sh

# Warn if Claude OAuth credentials are expired so the user knows to re-login
# on the host before starting a new session. Skipped when using an API key.
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    CREDS="/home/node/.claude/.credentials.json"
    if [ ! -f "$CREDS" ]; then
        echo ""
        echo "⚠️  No Claude credentials found — you will need to /login."
        echo "   Tip: run 'claude' on your host first to authenticate persistently,"
        echo "   then restart claude-safe."
        echo ""
    else
        EXPIRES_AT=$(jq -r '.claudeAiOauth.expiresAt // empty' "$CREDS" 2>/dev/null)
        if [ -n "$EXPIRES_AT" ] && [ "$EXPIRES_AT" != "null" ]; then
            NOW_MS=$(( $(date +%s) * 1000 ))
            if [ "$EXPIRES_AT" -lt "$NOW_MS" ]; then
                echo ""
                echo "╔══════════════════════════════════════════════════════════════╗"
                echo "║  ⚠️  Claude credentials have EXPIRED                          ║"
                echo "║  Run 'claude' on your host and use /login to refresh them,   ║"
                echo "║  then restart claude-safe.                                   ║"
                echo "╚══════════════════════════════════════════════════════════════╝"
                echo ""
            fi
        fi
    fi
fi

# Change to the designated working directory.
# In multi-repo mode claude-safe.sh sets CLAUDE_WORKING_DIR to the first repo;
# in single-repo mode /workspace is the repo, so we fall back to that.
cd "${CLAUDE_WORKING_DIR:-/workspace}"

# Set up browser opener via Unix socket relay when available.
# The wrapper sends the OAuth URL to the host, then holds the connection open.
# The host starts a TCP proxy for the OAuth callback, opens the browser, and
# when Firefox delivers the callback the host sends the request path back here.
# The container makes the final GET to its own 127.0.0.1:<port> and returns
# the HTTP response to the host, which forwards it to Firefox.
# This avoids docker exec and requires no docker group membership on the host.
if [ -n "${CLAUDE_BROWSER_SOCKET:-}" ] && [ -S "${CLAUDE_BROWSER_SOCKET}" ]; then
    cat > /tmp/browser-open.sh << 'BROWSER_WRAPPER_EOF'
#!/bin/sh
python3 - "$1" << 'PYEOF'
import socket, sys, os, re, urllib.request, urllib.parse, urllib.error, http.client

url = sys.argv[1]
# Read socket path from environment — not from the heredoc literal, since the
# outer heredoc is single-quoted and $CLAUDE_BROWSER_SOCKET is not expanded.
sock_path = os.environ.get('CLAUDE_BROWSER_SOCKET', '')
if not sock_path:
    sys.exit(1)

def extract_port(u):
    try:
        p = urllib.parse.urlparse(u)
        qs = urllib.parse.parse_qs(p.query)
        for ruri in qs.get('redirect_uri', []):
            rp = urllib.parse.urlparse(ruri)
            if rp.scheme == 'http' and rp.hostname == 'localhost' and rp.port:
                return rp.port
    except Exception:
        pass
    return None

port = extract_port(url)

s = socket.socket(socket.AF_UNIX)
s.connect(sock_path)
# Send URL terminated by newline so host knows when to stop reading.
s.sendall((url + '\n').encode())

if not port:
    s.close()
    sys.exit(0)

# Wait for the host to send back the callback path (e.g. /callback?code=...).
s.settimeout(300)
path_data = b''
while b'\n' not in path_data and len(path_data) < 4096:
    chunk = s.recv(256)
    if not chunk:
        break
    path_data += chunk

callback_path = path_data.decode('utf-8', errors='ignore').strip()
# Only relay /callback paths and bare /
if not callback_path or not re.match(r'^(/callback(\?|$)|/$)', callback_path):
    s.close()
    sys.exit(0)

# Make the request to the container's own loopback OAuth server.
# Use a no-redirect handler so we capture the raw response (including 302)
# and forward it to the host — Firefox handles redirect following itself.
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

opener = urllib.request.build_opener(NoRedirect)
try:
    # Use 'localhost' not '127.0.0.1': Node.js binds to ::1 (IPv6) when given
    # 'localhost', so connecting via 127.0.0.1 (IPv4) gets ECONNREFUSED.
    resp = opener.open(
        f'http://localhost:{port}{callback_path}',
        timeout=15
    )
    status = resp.status
    headers = resp.headers
    body = resp.read()
except urllib.error.HTTPError as e:
    # HTTPError is raised for 3xx when NoRedirect returns None — capture it.
    status = e.code
    headers = e.headers
    body = e.read()
except Exception as e:
    s.sendall(f'HTTP/1.0 502 Bad Gateway\r\n\r\n{e}'.encode())
    s.close()
    sys.exit(1)

raw = f'HTTP/1.0 {status} OK\r\n'.encode()
for k, v in headers.items():
    if k.lower() not in ('transfer-encoding', 'connection'):
        raw += f'{k}: {v}\r\n'.encode()
raw += b'\r\n' + body
s.sendall(raw)
s.close()
PYEOF
BROWSER_WRAPPER_EOF
    chmod 0700 /tmp/browser-open.sh
    export BROWSER=/tmp/browser-open.sh
    echo "Browser auto-open enabled — /login will open your browser."
fi

# Start Claude Code
exec claude --dangerously-skip-permissions
