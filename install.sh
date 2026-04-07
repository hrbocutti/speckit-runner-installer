#!/usr/bin/env bash
set -euo pipefail

# speckit-runner installer
# Usage: curl -fsSL https://raw.githubusercontent.com/hrbocutti/speckit-runner-installer/main/install.sh | bash

REPO="hrbocutti/speckit-runner"
INSTALL_DIR="${SPECKIT_HOME:-$HOME/.speckit-runner}"
BIN_LINK="/usr/local/bin/speckit-runner"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { printf "${CYAN}[speckit]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[speckit]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[speckit]${NC} %s\n" "$*"; }
fail()    { printf "${RED}[speckit]${NC} %s\n" "$*"; exit 1; }

# --- Pre-flight checks ---

command -v git     >/dev/null 2>&1 || fail "git is required but not installed."
command -v gh      >/dev/null 2>&1 || fail "gh CLI is required but not installed. See: https://cli.github.com"
command -v python3 >/dev/null 2>&1 || fail "python3 is required but not installed."
command -v claude  >/dev/null 2>&1 || fail "Claude CLI is required but not installed. See: https://docs.anthropic.com/en/docs/claude-code/overview"

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)
if [ "$PYTHON_MAJOR" -lt 3 ] || { [ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 9 ]; }; then
  fail "Python 3.9+ required, found $PYTHON_VERSION"
fi

# Check gh authentication
gh auth status >/dev/null 2>&1 || fail "gh CLI not authenticated. Run: gh auth login"

# Check Claude CLI health (auth, model, config)
info "Running Claude doctor..."
claude doctor 2>&1 || fail "Claude CLI check failed. Run 'claude doctor' to diagnose and fix issues."

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

# --- Install Python package ---

info "Installing Python dependencies..."
python3 -m pip install --quiet --upgrade pip 2>/dev/null || true
python3 -m pip install --quiet -e "$INSTALL_DIR"

# --- Symlink (if pip didn't put it on PATH) ---

if ! command -v speckit-runner >/dev/null 2>&1; then
  SCRIPTS_DIR=$(python3 -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>/dev/null)

  if [ -f "$SCRIPTS_DIR/speckit-runner" ]; then
    info "Creating symlink at $BIN_LINK (may require sudo)..."
    sudo ln -sf "$SCRIPTS_DIR/speckit-runner" "$BIN_LINK" 2>/dev/null || {
      warn "Could not create symlink. Add to PATH manually:"
      warn "  export PATH=\"$SCRIPTS_DIR:\$PATH\""
    }
  fi
fi

# --- Verify ---

echo ""
if command -v speckit-runner >/dev/null 2>&1; then
  success "speckit-runner installed successfully!"
  info "Version: $(speckit-runner --version 2>/dev/null || echo 'unknown')"
else
  success "speckit-runner installed at $INSTALL_DIR"
  warn "Binary not on PATH. Add this to your shell profile:"
  warn "  export PATH=\"\$(python3 -m site --user-base)/bin:\$PATH\""
fi

echo ""
info "All prerequisites verified: git, gh, python3, claude"
info "Usage: speckit-runner run \"https://github.com/owner/repo/issues/42\""
info "Help:  speckit-runner --help"
