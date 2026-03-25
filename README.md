# Claude Code Safe

Run [Claude Code](https://github.com/anthropics/claude-code) in a sandboxed Docker container with network restrictions and skip-permission mode.

## Why Use This?

- **Security**: Run Claude Code with dangerously-skip-permissions safely in an isolated container
- **Network Restrictions**: Firewall limits access to GitHub, npm, Anthropic API, and essential services only
- **Zero-Friction**: One command to run - Claude starts automatically with skip permissions
- **Easy Setup**: No API key required - login with your Claude.ai account
- **Persistent Config**: Authentication and history saved between sessions
- **Cross-Platform**: Works on Linux, macOS, and Windows (via WSL)

## Requirements

- Docker Engine 20.10+ (or Docker Desktop on Windows/macOS)
- Docker Compose 2.0+
- A Claude.ai account or Anthropic API key
- **Windows only**: WSL 2 with Docker Desktop WSL integration ([setup guide](#windows-setup))

## Quick Start

### 1. Clone and Setup

```bash
git clone https://github.com/DanielKraehenbuehl/claude-safe.git
cd claude-safe
./setup.sh
```

The setup script checks dependencies and builds the container (2-5 minutes first time, 5-30 seconds after).

### 2. Run on Your Project

```bash
# From project directory
cd /path/to/your/project
/path/to/claude-safe/claude-safe.sh

# Or specify path
./claude-safe.sh /path/to/your/project
```

Claude Code starts automatically with `--dangerously-skip-permissions` enabled.

### 3. First-Time Login

On first run, Claude shows an authentication URL. Copy it, open in your browser, login with your Claude.ai account, and authorize. Your authentication is saved for future sessions.

### 4. Create an Alias (Recommended)

Add to your shell config (`~/.bashrc`, `~/.zshrc`, etc.):

```bash
alias claude='/path/to/claude-safe/claude-safe.sh'
source ~/.bashrc  # or ~/.zshrc
```

Now run from any project:

```bash
cd ~/my-project
claude
```

This also enables VS Code and other tools to invoke the containerized Claude Code, giving you:
- Container isolation and security
- Network restrictions via firewall
- Consistent environment across projects
- No need to install Claude Code on your host

## Windows Setup

Claude Safe works on Windows via WSL (Windows Subsystem for Linux):

1. **Install WSL 2**:
   ```powershell
   # In PowerShell (as Administrator)
   wsl --install
   ```

2. **Install Docker Desktop for Windows**:
   - Download from [docker.com](https://www.docker.com/products/docker-desktop/)
   - Enable WSL 2 integration in Settings > Resources > WSL Integration

3. **Run setup from WSL terminal** (Ubuntu, Debian, etc.) following the Quick Start above

**Access Windows projects** via `/mnt/c/` paths:
```bash
cd /mnt/c/Users/YourName/Documents/my-project
~/claude-safe/claude-safe.sh
```

**Clipboard integration**: Built-in `copy` and `paste` commands work with Windows clipboard:
```bash
echo "text" | copy    # Copy to Windows clipboard
paste                 # Paste from Windows clipboard
```

**Known WSL issue**: You may see input echo twice (cosmetic only, doesn't affect functionality).

## How It Works

- Project directory automatically mounts at `/workspace` in the container
- Changes appear instantly on your host machine
- Authentication and history persist in Docker volumes (survive container restarts)
- Network firewall restricts outbound connections to approved domains
- Container runs as non-root user for additional security
- Each run creates a fresh container that auto-deletes on exit (type `exit` or Ctrl+D to stop)

## Using get-shit-done Workflows

The container includes the **get-shit-done (GSD)** framework for structured, spec-driven development.

### Why Use GSD?

- **Structured Planning**: Define requirements, create roadmaps, plan phases systematically
- **Quality Consistency**: Each task runs in a fresh context window
- **Atomic Commits**: Individual tasks produce separate git commits
- **Parallel Execution**: Run multiple agents concurrently
- **Session Persistence**: Project state persists across container restarts

### Quick Start Workflow

```bash
cd ~/my-new-app
claude

# Inside Claude Code:
/gsd:new-project         # Extract project vision through guided questions
/gsd:define-requirements # Scope features across versions (MVP, v2, v3)
/gsd:create-roadmap      # Structure development into phases
/gsd:plan-phase          # Generate atomic task plan
/gsd:execute-phase       # Execute tasks with parallel agents
/gsd:verify-work         # Verify requirements met
/gsd:complete-milestone  # Ship version and prepare next
```

**GSD maintains these files in your project:**
- `PROJECT.md` - Project vision and overview
- `REQUIREMENTS.md` - Versioned feature requirements
- `ROADMAP.md` - Phase structure and task mapping
- `STATE.md` - Current execution state

### Key Commands

**Project Setup:**
- `/gsd:new-project` - Extract project ideas through guided questioning
- `/gsd:research-project` - Investigate domain ecosystems and best practices
- `/gsd:define-requirements` - Scope features across versions
- `/gsd:create-roadmap` - Structure development phases
- `/gsd:map-codebase` - Analyze existing codebases

**Execution:**
- `/gsd:plan-phase` - Generate atomic task plans
- `/gsd:execute-phase` - Run parallel agents
- `/gsd:execute-plan` - Interactive single-plan execution
- `/gsd:verify-work` - Verify completed work
- `/gsd:complete-milestone` - Ship versions

**Session Management:**
- `/gsd:pause-work` - Save current state
- `/gsd:resume-work` - Resume from saved state

Type `/gsd:help` inside Claude Code for full command list.

### Learn More

- **GSD Repository**: https://github.com/glittercowboy/get-shit-done
- **Troubleshooting**: See [GSD troubleshooting](#get-shit-done-commands-not-found) below

## Advanced Usage

### Using an API Key

If you prefer API key authentication over web login:

```bash
cp .env.example .env
# Edit .env and add your API key
echo "ANTHROPIC_API_KEY=your-key-here" >> .env
./claude-safe.sh
```

### Persistent Environment Variables (Without Modifying Tracked Files)

To inject secrets or environment variables without touching `docker-compose.yml` (which is checked into git), create a `docker-compose.override.yml` file in the `claude-safe` directory:

```yaml
services:
  claude-code:
    environment:
      - MY_SECRET=value
      - DATABASE_URL=postgres://user:pass@host/db
```

Docker Compose automatically merges this file with `docker-compose.yml`. Since `docker-compose.override.yml` is listed in `.gitignore`, it is never committed or pushed.

Add any number of variables here. No rebuild required — changes take effect on the next `claude-safe.sh` run.

### Read-Only Project Mount

Edit `docker-compose.yml`:

```yaml
volumes:
  - ${PROJECT_DIR:-.}:/workspace:ro
```

### Resource Limits

Add to `docker-compose.yml`:

```yaml
deploy:
  resources:
    limits:
      cpus: '2'
      memory: 4G
```

### Direct Docker Compose

```bash
PROJECT_DIR=/path/to/project docker compose run --rm claude-code
```

For git worktrees, also set `GIT_PARENT_REPO` to the main repository:

```bash
PROJECT_DIR=/path/to/worktree \
GIT_PARENT_REPO=/path/to/main/repo \
docker compose run --rm claude-code
```

If you use `./claude-safe.sh`, `GIT_PARENT_REPO` is auto-detected for worktrees.

### VS Code Dev Container

For full VS Code development environment inside the container, copy the included `devcontainer.json` to `.devcontainer/` in your project, then use "Reopen in Container".

### Customize Allowed Domains

The firewall allows these domains by default:
- GitHub (api.github.com, github.com, raw.githubusercontent.com)
- npm (registry.npmjs.org)
- Anthropic (api.anthropic.com, sentry.io, statsig.anthropic.com)
- Microsoft (packages.microsoft.com, marketplace.visualstudio.com)
- Python (pypi.org, files.pythonhosted.org)

To add custom domains, edit `init-firewall.sh` around line 76:

```bash
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "your-custom-domain.com"; do
```

Then rebuild: `./setup.sh`

## Configuration

Copy `.env.example` to `.env` and customize (optional):

```bash
cp .env.example .env
```

**Available options:**

```bash
# Authentication (leave empty for web-based login, recommended)
ANTHROPIC_API_KEY=

# Optional: Your timezone (default: America/Los_Angeles)
TZ=America/New_York

# Optional: Claude Code version (default: latest)
CLAUDE_CODE_VERSION=latest

# Optional: Project directory (default: current directory)
PROJECT_DIR=/path/to/your/project

# Optional: GSD default model - sonnet, opus, or haiku (default: sonnet)
GSD_DEFAULT_MODEL=sonnet
```

## Container Lifecycle

**Image vs Container:**
- **Image** = Template built by `setup.sh`
- **Container** = Running instance created by `claude-safe.sh`

**When to run `./setup.sh`:**
- ✅ First time installation
- ✅ After `git pull` updates
- ✅ After modifying Dockerfile or firewall rules
- ❌ NOT needed before every run

**What persists between runs:**
- ✅ Authentication (Docker volume)
- ✅ Command history (Docker volume)
- ✅ Project files (mounted directory)
- ❌ Container itself (auto-deleted with `--rm` flag)

## Troubleshooting

### Code Colors/Syntax Highlighting Missing

Rebuild the container:

```bash
./setup.sh
```

### Copy-Paste Not Working

**WSL/Windows**: Use `Ctrl+Shift+C`/`Ctrl+Shift+V` in Windows Terminal, or use the built-in `copy`/`paste` commands

**macOS**: `Cmd+C`/`Cmd+V` with mouse selection

**Linux**: Mouse selection auto-copies, `Shift+Insert` to paste

**All platforms**: Share via files:
```bash
echo "output" > /workspace/result.txt  # Inside container
cat /path/to/project/result.txt        # On host
```

### Web Login Fails

Check port 38714 is exposed:

```bash
docker ps
# Should show: 0.0.0.0:38714->38714/tcp
```

### Need to Re-authenticate

```bash
docker-compose down -v
```

### Firewall Blocking Required Site

Test from inside container:

```bash
curl https://api.github.com  # Should work
curl https://google.com      # Should fail (blocked)
```

Add custom domains to `init-firewall.sh` and rebuild if needed.

### get-shit-done Commands Not Found

Verify installation:

```bash
ls -la ~/.claude/commands/gsd/
# Should show 27 command files
```

If missing, rebuild:

```bash
./setup.sh --force
```

Manual installation:

```bash
npx --yes get-shit-done-cc --global
```

Requires Claude Code v0.7.0+ with skill support.

### GSD State Not Persisting

Check volume exists:

```bash
docker volume ls  # Should show: claude-code-config
```

Verify project files:

```bash
ls /workspace/PROJECT.md
```

### GSD Agents Slow

Increase resources in `docker-compose.yml` (see [Resource Limits](#resource-limits)).

Check if agents need additional network domains in `init-firewall.sh`.

### Permission Errors

The container runs as `node` user with passwordless sudo for package managers:

```bash
sudo apt-get install dotnet-sdk-8.0
sudo pip3 install robotframework
sudo npm install -g typescript
```

For full root access:

```bash
docker-compose run --rm --user root claude-code
```

## What's Included

- **Node.js 20** with npm
- **Python 3.11** with pip3
- **Git** with GitHub CLI (`gh`)
- **Docker CLI** with BuildX and Compose plugins
- **Development tools**: zsh, fzf, vim, nano, jq, wget, curl
- **Network tools**: iptables, ipset for firewall
- **Claude Code** (latest version)
- **get-shit-done framework** with slash commands
- **pre-commit** for git hooks
- **Sudo access** to package managers

## Security Considerations

Even with Docker + firewall + skip permissions:

- ✅ Claude **can** modify/delete files in mounted project
- ✅ Claude **can** execute commands in the container
- ✅ Claude **can** consume resources (set limits if needed)
- ❌ Claude **cannot** access files outside mounted volumes
- ❌ Claude **cannot** install packages on your host
- ❌ Claude **cannot** access most internet sites (firewall restricted)

## Files in This Repo

```
.
├── setup.sh               # One-command setup script
├── claude-safe.sh         # Run Claude safely in container
├── setup-clipboard.sh     # Clipboard integration setup
├── docker-compose.yml     # Docker orchestration
├── Dockerfile             # Container image definition
├── init-firewall.sh       # Network firewall script
├── start-claude.sh        # Container entrypoint
├── devcontainer.json      # VS Code Dev Container config
├── .env.example           # Environment variables template
├── .gitignore             # Git ignore rules
├── LICENSE                # MIT License
├── CONTRIBUTORS.md        # Author and contributors
└── README.md              # This file
```

## Contributing

Issues and pull requests welcome! Please ensure:
- Scripts remain simple and portable
- Security features are preserved
- Documentation stays beginner-friendly

## Author

**Daniel Krähenbühl** - Hamilton Medical AG

## Credits

Built from the official Claude Code `.devcontainer` setup by Anthropic.
