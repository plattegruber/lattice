#!/usr/bin/env bash
set -euo pipefail

# Lattice — Claude Code session bootstrap
# Installs required tooling for Elixir/Phoenix development on Fly.io.
# Only runs in remote (web/headless) environments where tools aren't pre-installed.

LOG_PREFIX="[lattice:session-start]"
log() { echo "$LOG_PREFIX $*"; }

# Skip in local environments where the developer has tools installed
if [ -z "${CLAUDE_REMOTE:-}" ] && [ -z "${CODESPACES:-}" ] && [ -z "${GITPOD_WORKSPACE_ID:-}" ]; then
  log "Local environment detected — skipping bootstrap"
  exit 0
fi

log "Remote environment detected — installing tooling..."

# --- GitHub CLI (gh) ---
if ! command -v gh &>/dev/null; then
  log "Installing GitHub CLI..."
  GH_VERSION="2.74.0"
  GH_ARCHIVE="gh_${GH_VERSION}_linux_amd64.tar.gz"
  curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${GH_ARCHIVE}" -o "/tmp/${GH_ARCHIVE}"
  tar -xzf "/tmp/${GH_ARCHIVE}" -C /tmp
  cp "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh 2>/dev/null \
    || sudo cp "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh 2>/dev/null \
    || { mkdir -p "$HOME/.local/bin" && cp "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" "$HOME/.local/bin/gh" && export PATH="$HOME/.local/bin:$PATH"; }
  rm -rf "/tmp/${GH_ARCHIVE}" "/tmp/gh_${GH_VERSION}_linux_amd64"
  log "GitHub CLI $(gh --version | head -1) installed"
else
  log "GitHub CLI already installed: $(gh --version | head -1)"
fi

# --- Erlang/OTP + Elixir via asdf ---
install_asdf_and_languages() {
  if ! command -v asdf &>/dev/null; then
    log "Installing asdf version manager..."
    git clone https://github.com/asdf-vm/asdf.git "$HOME/.asdf" --branch v0.16.0 2>/dev/null || true
    # shellcheck disable=SC1091
    . "$HOME/.asdf/asdf.sh"
    export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"
  fi

  if ! asdf plugin list 2>/dev/null | grep -q erlang; then
    log "Adding asdf erlang plugin..."
    asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git
  fi

  if ! asdf plugin list 2>/dev/null | grep -q elixir; then
    log "Adding asdf elixir plugin..."
    asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git
  fi

  # Install versions from .tool-versions if present, otherwise use defaults
  local PROJECT_DIR
  PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  if [ -f "$PROJECT_DIR/.tool-versions" ]; then
    log "Installing languages from .tool-versions..."
    cd "$PROJECT_DIR"
    asdf install
  else
    # Defaults — update these as needed
    local ERLANG_VERSION="27.2.4"
    local ELIXIR_VERSION="1.18.3-otp-27"

    log "Installing Erlang/OTP $ERLANG_VERSION (this takes a few minutes)..."
    # Minimal Erlang build — skip docs, GUI, and optional deps
    export KERL_CONFIGURE_OPTIONS="--without-javac --without-wx --without-odbc --without-debugger --without-observer --without-et"
    asdf install erlang "$ERLANG_VERSION" || {
      log "WARNING: Erlang build failed — you may need build dependencies"
      log "Try: apt-get install -y build-essential autoconf libncurses-dev libssl-dev"
      return 1
    }
    asdf set --home erlang "$ERLANG_VERSION"

    log "Installing Elixir $ELIXIR_VERSION..."
    asdf install elixir "$ELIXIR_VERSION"
    asdf set --home elixir "$ELIXIR_VERSION"
  fi

  log "Erlang: $(erl -noshell -eval 'io:format(erlang:system_info(otp_release)), halt().' 2>/dev/null || echo 'pending')"
  log "Elixir: $(elixir --version 2>/dev/null | tail -1 || echo 'pending')"
}

# Check if Elixir is already available
if ! command -v elixir &>/dev/null; then
  # Check for build dependencies first
  if command -v apt-get &>/dev/null; then
    log "Installing Erlang/Elixir build dependencies..."
    (sudo apt-get update -qq && sudo apt-get install -y -qq \
      build-essential autoconf libncurses-dev libssl-dev libwxgtk-webview3.2-dev \
      unzip curl 2>&1) | tail -1
  fi
  install_asdf_and_languages
else
  log "Elixir already installed: $(elixir --version | tail -1)"
fi

# --- Fly CLI (flyctl) ---
if ! command -v flyctl &>/dev/null && ! command -v fly &>/dev/null; then
  log "Installing Fly CLI..."
  curl -fsSL https://fly.io/install.sh | sh 2>&1 | tail -3
  export FLYCTL_INSTALL="$HOME/.fly"
  export PATH="$FLYCTL_INSTALL/bin:$PATH"
  log "Fly CLI installed: $(flyctl version 2>/dev/null || echo 'installed')"
else
  log "Fly CLI already installed: $(flyctl version 2>/dev/null || fly version 2>/dev/null)"
fi

# --- Hex + Rebar (Elixir package managers) ---
if command -v mix &>/dev/null; then
  log "Installing Hex and Rebar..."
  mix local.hex --force --if-missing 2>/dev/null
  mix local.rebar --force --if-missing 2>/dev/null
  log "Hex and Rebar ready"
fi

# --- Project dependencies ---
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ -f "$PROJECT_DIR/mix.exs" ]; then
  log "Fetching project dependencies..."
  cd "$PROJECT_DIR"
  mix deps.get 2>&1 | tail -3
  log "Dependencies fetched"
fi

log "Session bootstrap complete"
