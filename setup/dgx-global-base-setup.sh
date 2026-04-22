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
# uv (installed early so we can use it for the Safety Harness venv below)
# -----------------------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
  echo "=== Installing uv (astral.sh) ==="
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # shellcheck disable=SC1091
  . "$HOME/.local/bin/env" 2>/dev/null || export PATH="$HOME/.local/bin:$PATH"
else
  echo "=== uv already installed ==="
fi

# -----------------------------------------------------------------------------
# Safety Harness (dedicated uv-managed venv, idempotent)
#
# The harness is installed into its OWN virtualenv at ~/.dgx-harness/venv so it
# can't collide with other toolkits in this repo (label-studio, data-prep-toolkit,
# unsloth, etc.) that pin conflicting versions of numpy/openai/pyarrow. This
# honours the "NO global pip installs" policy at the top of this file and lets
# harness track modern NeMo Guardrails / spaCy / langchain without dragging
# the data and eval toolchains backwards.
# -----------------------------------------------------------------------------
HARNESS_DIR="$(cd "$(dirname "$0")/.." && pwd)/harness"
HARNESS_VENV="$HOME/.dgx-harness/venv"
if [ -f "$HARNESS_DIR/pyproject.toml" ]; then
  if [ ! -x "$HARNESS_VENV/bin/python" ]; then
    echo "=== Creating dedicated Safety Harness venv at $HARNESS_VENV ==="
    mkdir -p "$(dirname "$HARNESS_VENV")"
    uv venv --python 3.11 "$HARNESS_VENV"
  else
    echo "=== Safety Harness venv already present at $HARNESS_VENV ==="
  fi

  echo "=== Installing Safety Harness into $HARNESS_VENV (editable) ==="
  VIRTUAL_ENV="$HARNESS_VENV" uv pip install -e "$HARNESS_DIR[test]" --quiet

  echo "=== Downloading spaCy NER model (en_core_web_lg) into harness venv ==="
  VIRTUAL_ENV="$HARNESS_VENV" "$HARNESS_VENV/bin/python" -m spacy download en_core_web_lg --quiet 2>/dev/null || true

  echo "=== Installing Kaggle CLI (user-level) ==="
  uv tool install --force kaggle
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

# -----------------------------------------------------------------------------
# sparkrun (user-level, idempotent)
#
# sparkrun is vendored as a git submodule at vendor/sparkrun. If this tree
# was cloned without --recurse-submodules, auto-init it here so downstream
# steps (mode picker, aliases) don't fail.
# -----------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKRUN_SUBMODULE="$REPO_ROOT/vendor/sparkrun"

if [ ! -f "$SPARKRUN_SUBMODULE/pyproject.toml" ]; then
  if [ -d "$REPO_ROOT/.git" ] || [ -f "$REPO_ROOT/.git" ]; then
    echo "=== vendor/sparkrun not initialised — running: git submodule update --init --recursive ==="
    git -C "$REPO_ROOT" submodule update --init --recursive
  else
    echo "!!! vendor/sparkrun missing and $REPO_ROOT is not a git worktree." >&2
    echo "!!! Re-clone with:  git clone --recurse-submodules https://github.com/dr-robert-li/dgx-toolbox" >&2
  fi
fi

if [ -f "$SPARKRUN_SUBMODULE/pyproject.toml" ]; then
  echo "=== Installing sparkrun from vendor/sparkrun (editable) ==="
  uv tool install --force --editable "$SPARKRUN_SUBMODULE"

  # `source ~/.bashrc` from a non-interactive script is unreliable (bash
  # short-circuits most interactive init), so the PATH update written to
  # ~/.bashrc earlier isn't guaranteed to be in effect here. Explicitly
  # surface uv's tool bin dir so downstream steps in this same script
  # run (mode picker → dgx-mode.sh → `command -v sparkrun`) can see it.
  UV_TOOL_BIN="$(uv tool dir --bin 2>/dev/null || echo "$HOME/.local/bin")"
  case ":$PATH:" in
    *":$UV_TOOL_BIN:"*) ;;
    *) export PATH="$UV_TOOL_BIN:$PATH" ;;
  esac

  if ! command -v sparkrun >/dev/null 2>&1; then
    echo "!!! sparkrun installed but not on PATH (looked in $UV_TOOL_BIN)" >&2
  fi
else
  echo "!!! vendor/sparkrun still missing after submodule init attempt — skipping sparkrun install." >&2
fi

# -----------------------------------------------------------------------------
# Bash aliases (non-destructive merge)
#
# Writes dgx-toolbox aliases between stamped markers inside ~/.bash_aliases.
# Anything outside the markers is preserved, so users can keep their own
# aliases in the same file. On first install, if ~/.bash_aliases already
# exists without our markers, we back it up once to ~/.bash_aliases.pre-dgx-toolbox
# before merging.
# -----------------------------------------------------------------------------
ALIASES_SRC="$(cd "$(dirname "$0")/.." && pwd)/example.bash_aliases"
if [ -f "$ALIASES_SRC" ]; then
  TARGET="$HOME/.bash_aliases"
  MARK_START="# >>> dgx-toolbox >>>"
  MARK_END="# <<< dgx-toolbox <<<"

  # One-time backup of a pre-existing unmanaged file.
  if [ -f "$TARGET" ] \
     && ! grep -qF "$MARK_START" "$TARGET" \
     && [ ! -f "$TARGET.pre-dgx-toolbox" ]; then
    cp "$TARGET" "$TARGET.pre-dgx-toolbox"
    echo "=== Backed up existing $TARGET to $TARGET.pre-dgx-toolbox ==="
  fi

  # Rewrite the file: everything outside the markers from the existing file,
  # followed by a fresh managed block. Safe to run repeatedly.
  TMP="$(mktemp)"
  {
    if [ -f "$TARGET" ]; then
      awk -v start="$MARK_START" -v end="$MARK_END" '
        $0 == start { inblock=1; next }
        inblock && $0 == end { inblock=0; next }
        !inblock { print }
      ' "$TARGET"
    fi
    echo "$MARK_START"
    echo "# Managed by dgx-toolbox/setup/dgx-global-base-setup.sh."
    echo "# Do NOT edit between these markers — changes here are overwritten"
    echo "# on every setup run. Put your own aliases outside the markers."
    cat "$ALIASES_SRC"
    echo "$MARK_END"
  } > "$TMP"
  mv "$TMP" "$TARGET"
  echo "=== Bash aliases merged into $TARGET (non-destructive) ==="
fi

# -----------------------------------------------------------------------------
# First-time mode picker (single-node vs cluster)
# -----------------------------------------------------------------------------
PICKER="$(cd "$(dirname "$0")" && pwd)/dgx-mode-picker.sh"
if [ -x "$PICKER" ]; then
  echo "=== Running mode picker ==="
  "$PICKER" || echo "Mode picker skipped/failed — run 'dgx-mode' later to configure."
fi

echo ""
echo "=== Base global setup complete ==="
echo ""
echo "Next steps:"
echo "  1. source ~/.bashrc"
echo "  2. (Optional) Configure Kaggle API for dataset downloads:"
echo "     mkdir -p ~/.kaggle && chmod 700 ~/.kaggle"
echo "     echo '{\"username\":\"YOUR_USERNAME\",\"key\":\"KGAT_your_key\"}' > ~/.kaggle/kaggle.json"
echo "     chmod 600 ~/.kaggle/kaggle.json"
echo "     Both username and key required — get from https://www.kaggle.com/settings → API"
echo ""
