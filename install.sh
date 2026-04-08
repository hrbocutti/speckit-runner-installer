#!/usr/bin/env bash
set -euo pipefail

# speckit-runner installer
# Usage: curl -fsSL https://raw.githubusercontent.com/hrbocutti/speckit-runner-installer/main/install.sh | bash

REPO="hrbocutti/speckit-runner"
INSTALL_DIR="${SPECKIT_HOME:-$HOME/.speckit-runner}"
VENV_DIR="$INSTALL_DIR/.venv"
BIN_LINK="/usr/local/bin/speckit-runner"
REQUIRED_PYTHON="3.10"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { printf "${CYAN}[speckit]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[speckit]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[speckit]${NC} %s\n" "$*"; }
fail()    { printf "${RED}[speckit]${NC} %s\n" "$*"; exit 1; }

# --- Find suitable Python (>= 3.10) ---

find_python() {
  # 1. Check if pyenv has a suitable version
  if command -v pyenv >/dev/null 2>&1; then
    for ver in $(pyenv versions --bare 2>/dev/null | sort -rV); do
      local major minor
      major=$(echo "$ver" | cut -d. -f1)
      minor=$(echo "$ver" | cut -d. -f2)
      if [ "$major" -eq 3 ] && [ "$minor" -ge 10 ]; then
        PYTHON="$(pyenv prefix "$ver")/bin/python3"
        if [ -x "$PYTHON" ]; then
          info "Using pyenv Python $ver"
          return 0
        fi
      fi
    done
  fi

  # 2. Check system python3
  if command -v python3 >/dev/null 2>&1; then
    local ver
    ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    if [ "$major" -eq 3 ] && [ "$minor" -ge 10 ]; then
      PYTHON="python3"
      info "Using system Python $ver"
      return 0
    fi
  fi

  # 3. Check versioned binaries (python3.12, python3.11, python3.10)
  for v in 12 11 10; do
    if command -v "python3.$v" >/dev/null 2>&1; then
      PYTHON="python3.$v"
      info "Using $(command -v python3.$v) (3.$v)"
      return 0
    fi
  done

  return 1
}

# --- Pre-flight checks ---

command -v git     >/dev/null 2>&1 || fail "git is required but not installed."
command -v gh      >/dev/null 2>&1 || fail "gh CLI is required but not installed. See: https://cli.github.com"
command -v claude  >/dev/null 2>&1 || fail "Claude CLI is required but not installed. See: https://docs.anthropic.com/en/docs/claude-code/overview"

if ! find_python; then
  echo ""
  fail "Python 3.10+ is required but not found.

  Install options:
    brew install python@3.12
    pyenv install 3.12

  After installing, re-run this script."
fi

# Check gh authentication
gh auth status >/dev/null 2>&1 || fail "gh CLI not authenticated. Run: gh auth login"

# Check Claude CLI health (auth, model, config)
info "Checking Claude CLI..."
claude --version >/dev/null 2>&1 || fail "Claude CLI not working. Run 'claude doctor' to diagnose."
info "Claude CLI: $(claude --version 2>/dev/null)"

info "Installing speckit-runner..."

# --- Clone or update (via gh for private repo access) ---

if [ -d "$INSTALL_DIR" ]; then
  info "Updating existing installation..."
  git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || {
    warn "Pull failed, re-cloning..."
    rm -rf "$INSTALL_DIR"
    gh repo clone "$REPO" "$INSTALL_DIR" -- --depth 1
  }
else
  info "Cloning speckit-runner (private repo via gh)..."
  gh repo clone "$REPO" "$INSTALL_DIR" -- --depth 1
fi

# --- Create venv and install Python package ---

info "Creating virtual environment with $($PYTHON --version)..."
$PYTHON -m venv "$VENV_DIR"
VENV_PIP="$VENV_DIR/bin/pip"
VENV_PYTHON="$VENV_DIR/bin/python"

info "Installing Python dependencies..."
"$VENV_PIP" install --quiet --upgrade pip 2>/dev/null || true
"$VENV_PIP" install --quiet -e "$INSTALL_DIR[mcp]"

# --- Symlink ---

VENV_BIN="$VENV_DIR/bin/speckit-runner"
if [ -f "$VENV_BIN" ]; then
  info "Creating symlink at $BIN_LINK (may require sudo)..."
  sudo ln -sf "$VENV_BIN" "$BIN_LINK" 2>/dev/null || {
    warn "Could not create symlink. Add to PATH manually:"
    warn "  export PATH=\"$VENV_DIR/bin:\$PATH\""
  }
fi

# --- Configure MCP for Claude Code ---

SPECKIT_BIN="$VENV_BIN"
if command -v speckit-runner >/dev/null 2>&1; then
  SPECKIT_BIN="$(command -v speckit-runner)"
fi

CLAUDE_MCP="$HOME/.claude/.mcp.json"
mkdir -p "$HOME/.claude"

if [ -f "$CLAUDE_MCP" ]; then
  # Add speckit server if not already present
  if ! grep -q '"speckit"' "$CLAUDE_MCP" 2>/dev/null; then
    # Insert into existing mcpServers object
    $PYTHON -c "import json; f=open('$CLAUDE_MCP'); cfg=json.load(f); f.close(); cfg.setdefault('mcpServers',{})['speckit']={'command':'$SPECKIT_BIN','args':[]}; f=open('$CLAUDE_MCP','w'); json.dump(cfg,f,indent=2); f.close()" \
      && info "MCP server added to Claude Code config"
  else
    info "MCP server already configured in Claude Code"
  fi
else
  printf '{\n  "mcpServers": {\n    "speckit": {\n      "command": "%s",\n      "args": []\n    }\n  }\n}\n' "$SPECKIT_BIN" > "$CLAUDE_MCP"
  info "MCP server configured for Claude Code (~/.claude/.mcp.json)"
fi

# --- Verify ---

echo ""
if command -v speckit-runner >/dev/null 2>&1; then
  success "speckit-runner installed successfully!"
  info "Version: $(speckit-runner --version 2>/dev/null || echo 'unknown')"
else
  success "speckit-runner installed at $INSTALL_DIR"
  warn "Binary not on PATH. Run:"
  warn "  export PATH=\"$VENV_DIR/bin:\$PATH\""
  warn "Add the line above to your ~/.zshrc or ~/.bashrc to persist."
fi

echo ""
info "All prerequisites verified: git, gh, python 3.10+, claude"
info "Usage: speckit-runner run \"https://github.com/owner/repo/issues/42\""
info "Help:  speckit-runner --help"
