#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# DGX Spark Global Base Setup (Idempotent & Safe)
# - System-wide: core build tools, Python, etc. via apt
# - User-level: Miniconda + pyenv + pyenv-virtualenv
# - NO global pip installs
# =============================================================================

echo "=== Updating system packages ==="
sudo apt-get update -y
sudo apt-get upgrade -y

echo "=== Core build tools & libraries (system-wide via apt) ==="
sudo apt-get install -y \
  build-essential \
  pkg-config \
  git \
  curl wget \
  ca-certificates \
  libssl-dev \
  zlib1g-dev \
  libbz2-dev \
  libreadline-dev \
  libsqlite3-dev \
  llvm \
  libncursesw5-dev \
  xz-utils \
  tk-dev \
  libxml2-dev \
  libxmlsec1-dev \
  libffi-dev \
  liblzma-dev

echo "=== System Python via apt (no pip here) ==="
sudo apt-get install -y python3 python3-venv python3-dev python3-full

# -----------------------------------------------------------------------------
# Miniconda (user-level, idempotent)
# -----------------------------------------------------------------------------
MINICONDA_DIR="$HOME/miniconda3"
if [ -d "$MINICONDA_DIR" ]; then
  echo "=== Miniconda already installed at $MINICONDA_DIR, skipping install ==="
else
  echo "=== Installing Miniconda (aarch64) for current user ==="
  cd /tmp
  curl -fsSLO https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh
  bash Miniconda3-latest-Linux-aarch64.sh -b -p "$MINICONDA_DIR"
  rm Miniconda3-latest-Linux-aarch64.sh
fi

# Ensure conda init line is present in .bashrc
if ! grep -q "conda init bash" "$HOME/.bashrc" 2>/dev/null; then
  echo "=== Initializing conda in .bashrc (bash) ==="
  "$MINICONDA_DIR/bin/conda" init bash || true
else
  echo "=== conda already initialized in .bashrc ==="
fi

# shellcheck disable=SC1090
source "$HOME/.bashrc" || true

# -----------------------------------------------------------------------------
# Ensure ~/.local/bin on PATH (idempotent)
# -----------------------------------------------------------------------------
if ! echo ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
  echo "=== Adding ~/.local/bin to PATH in .bashrc ==="
  {
    echo ''
    echo '# Ensure local bin is on PATH'
    echo 'case ":$PATH:" in'
    echo '  *":$HOME/.local/bin:"*) ;;'
    echo '  *) export PATH="$HOME/.local/bin:$PATH" ;;'
    echo 'esac'
  } >> "$HOME/.bashrc"
  export PATH="$HOME/.local/bin:$PATH"
else
  echo "=== ~/.local/bin already on PATH ==="
fi

# -----------------------------------------------------------------------------
# pyenv + pyenv-virtualenv (user-level, idempotent)
# -----------------------------------------------------------------------------
if [ -d "$HOME/.pyenv" ]; then
  echo "=== pyenv already installed at $HOME/.pyenv, skipping install ==="
else
  echo "=== Installing pyenv + pyenv-virtualenv ==="
  curl https://pyenv.run | bash
fi

# Ensure pyenv block exists in .bashrc
if ! grep -q "pyenv virtualenv-init" "$HOME/.bashrc" 2>/dev/null; then
  echo "=== Adding pyenv setup to .bashrc ==="
  {
    echo ''
    echo '# pyenv setup'
    echo 'export PYENV_ROOT="$HOME/.pyenv"'
    echo 'export PATH="$PYENV_ROOT/bin:$PATH"'
    echo 'if command -v pyenv >/dev/null 2>&1; then'
    echo '  eval "$(pyenv init -)"'
    echo '  eval "$(pyenv virtualenv-init -)"'
    echo 'fi'
  } >> "$HOME/.bashrc"
else
  echo "=== pyenv setup already present in .bashrc ==="
fi

# shellcheck disable=SC1090
source "$HOME/.bashrc" || true

# -----------------------------------------------------------------------------
# Safety Harness (user-level, idempotent)
# -----------------------------------------------------------------------------
HARNESS_DIR="$(cd "$(dirname "$0")/.." && pwd)/harness"
if [ -f "$HARNESS_DIR/pyproject.toml" ]; then
  echo "=== Installing Safety Harness (pip install -e) ==="
  pip install -e "$HARNESS_DIR[test]" --quiet
  echo "=== Downloading spaCy NER model (en_core_web_lg) ==="
  python -m spacy download en_core_web_lg --quiet 2>/dev/null || true
else
  echo "=== Safety Harness not found at $HARNESS_DIR, skipping ==="
fi

# Ensure HARNESS_API_KEY is in .bashrc (idempotent)
if ! grep -q "HARNESS_API_KEY" "$HOME/.bashrc" 2>/dev/null; then
  echo "=== Adding HARNESS_API_KEY to .bashrc ==="
  echo 'export HARNESS_API_KEY="sk-devteam-test"' >> "$HOME/.bashrc"
else
  echo "=== HARNESS_API_KEY already set in .bashrc ==="
fi

# Copy bash aliases if not already present
ALIASES_SRC="$(cd "$(dirname "$0")/.." && pwd)/example.bash_aliases"
if [ -f "$ALIASES_SRC" ]; then
  cp "$ALIASES_SRC" "$HOME/.bash_aliases"
  echo "=== Bash aliases updated from example.bash_aliases ==="
fi

echo "=== Base global setup complete (idempotent, no global pip). ==="
echo "Open a new shell or 'source ~/.bashrc' to use conda/pyenv."
