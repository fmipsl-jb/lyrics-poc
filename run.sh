#!/usr/bin/env bash
#
# run.sh - one-command setup + launch for the Lyrics app.
#
# This script is designed to work on a FRESH Mac. It will, as needed:
#   1. Install Homebrew (if missing).
#   2. Install/upgrade a modern Python (3.12) with Tk 8.6 bindings + ffmpeg.
#   3. Create/refresh a Python virtual environment and install app deps.
#   4. Launch the Lyrics app.
#
# It is safe to run repeatedly: already-installed prerequisites are upgraded,
# not reinstalled. Re-running keeps everything current.
#
# Override the Python interpreter (skip auto-provisioning) with:
#   PYTHON=/path/to/python3 ./run.sh
#
# Linux note: this script auto-provisions via Homebrew (macOS-focused, per the
# PoC brief). On Linux, install python3 (with tkinter) + ffmpeg via your package
# manager and run:  PYTHON=python3 ./run.sh
#
# Robust error handling without `set -e`. `set -e` interacts badly with the many
# conditional checks and function calls in this provisioning script (a non-zero
# result from a legitimate test can abort the whole run). Instead we run without
# -e and explicitly abort (via `die`) only on genuinely fatal steps.
set -uo pipefail
cd "$(dirname "$0")"

# Python series we standardise on: modern, ships Tk 8.6 (via python-tk), and
# within Whisper's supported range (3.8–3.11 officially; 3.12 works in practice).
PY_SERIES="3.12"
BREW_PYTHON="python@${PY_SERIES}"
BREW_PYTHON_TK="python-tk@${PY_SERIES}"
BREW_FFMPEG="ffmpeg"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

OS="$(uname -s)"

# ---------------------------------------------------------------------------
# Step 0: If the caller pinned PYTHON, honour it and skip provisioning.
# ---------------------------------------------------------------------------
USER_PINNED_PYTHON="${PYTHON:-}"

# ---------------------------------------------------------------------------
# Step 1: Ensure Homebrew (macOS auto-provisioning path).
# ---------------------------------------------------------------------------
ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    return
  fi

  # Common install locations that might not be on PATH yet.
  for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$brew_bin" ]; then
      eval "$("$brew_bin" shellenv)"
      return
    fi
  done

  log "Homebrew not found. Installing Homebrew (you may be prompted for your password)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Load brew into this shell for Apple Silicon (/opt/homebrew) or Intel (/usr/local).
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  command -v brew >/dev/null 2>&1 || die "Homebrew installation did not complete. Please install it manually from https://brew.sh and re-run."
}

# Install a formula if missing, otherwise upgrade it (keeps things up to date).
brew_ensure() {
  local formula="$1"
  if brew list "$formula" >/dev/null 2>&1; then
    log "Upgrading $formula (if a newer version exists)..."
    brew upgrade "$formula" 2>/dev/null || true   # 'already newest' returns non-zero; ignore
  else
    log "Installing $formula..."
    brew install "$formula"
  fi
}

# ---------------------------------------------------------------------------
# Step 2: Provision Python (Tk 8.6) + ffmpeg via Homebrew.
# ---------------------------------------------------------------------------
provision_prerequisites() {
  ensure_homebrew

  log "Making sure Homebrew itself is current..."
  brew update >/dev/null 2>&1 || warn "brew update failed (offline?). Continuing with what's installed."

  brew_ensure "$BREW_PYTHON"
  brew_ensure "$BREW_PYTHON_TK"   # provides Tk 8.6 bindings so the GUI renders
  brew_ensure "$BREW_FFMPEG"      # Whisper needs ffmpeg to read audio
}

# ---------------------------------------------------------------------------
# Step 3: Choose a Python with a working Tk >= 8.6.
# ---------------------------------------------------------------------------
python_has_modern_tk() {
  "$1" -c 'import tkinter,sys; sys.exit(0 if tkinter.TkVersion>=8.6 else 1)' >/dev/null 2>&1
}

pick_python() {
  # 1. Respect an explicit override.
  if [ -n "$USER_PINNED_PYTHON" ]; then
    echo "$USER_PINNED_PYTHON"; return
  fi
  # 2. Prefer the Homebrew Python we just provisioned.
  local brew_prefix
  brew_prefix="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
  for candidate in \
    "$brew_prefix/bin/python${PY_SERIES}" \
    /opt/homebrew/bin/python${PY_SERIES} \
    /usr/local/bin/python${PY_SERIES} \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    python3; do
    if command -v "$candidate" >/dev/null 2>&1 && python_has_modern_tk "$candidate"; then
      echo "$candidate"; return
    fi
  done
  echo "python3"   # last resort
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$OS" = "Darwin" ] && [ -z "$USER_PINNED_PYTHON" ]; then
  provision_prerequisites
elif [ -z "$USER_PINNED_PYTHON" ]; then
  warn "Non-macOS system detected. Skipping auto-provisioning."
  warn "Ensure python3 (with tkinter/Tk>=8.6) and ffmpeg are installed."
fi

PY="$(pick_python)"
PY_TK="$("$PY" -c 'import tkinter; print(tkinter.TkVersion)' 2>/dev/null || echo 'none')"
log "Using Python: $PY (Tk $PY_TK)"

if [ "$PY_TK" = "none" ]; then
  warn "Selected Python has no Tk bindings; the GUI may not open. On macOS, run: brew install $BREW_PYTHON_TK"
fi

# Verify ffmpeg is reachable now (it should be after provisioning).
if command -v ffmpeg >/dev/null 2>&1; then
  :
else
  warn "ffmpeg is still not on PATH. Transcription will fail until it's installed."
  warn "  macOS:  brew install ffmpeg"
fi

# ---------------------------------------------------------------------------
# Step 4: Virtual environment + Python dependencies.
# ---------------------------------------------------------------------------

# Rebuild the venv if it's missing, was built against an old-Tk interpreter,
# or was created by a *different* base interpreter than the one we chose now.
# This keeps the environment deterministic across machines and upgrades.
#
# Note: these checks are written to be safe under `set -e` - we capture results
# into variables with `|| true` rather than letting a non-zero comparison abort.
needs_rebuild="no"
if [ -d ".venv" ]; then
  if [ ! -x ".venv/bin/python" ]; then
    needs_rebuild="yes"
  else
    venv_tk_ok="no"
    if python_has_modern_tk ".venv/bin/python"; then venv_tk_ok="yes"; fi

    chosen_base="$("$PY" -c 'import sys; print(sys.base_prefix)' 2>/dev/null || echo chosen)"
    venv_base="$(.venv/bin/python -c 'import sys; print(sys.base_prefix)' 2>/dev/null || echo venv)"

    if [ "$venv_tk_ok" != "yes" ]; then
      log "Existing .venv uses an old Tk; rebuilding it with $PY..."
      needs_rebuild="yes"
    elif [ "$chosen_base" != "$venv_base" ]; then
      log "Existing .venv was built with a different Python; rebuilding it with $PY..."
      needs_rebuild="yes"
    fi
  fi
fi

if [ "$needs_rebuild" = "yes" ]; then
  rm -rf .venv
fi

if [ ! -d ".venv" ]; then
  log "Creating virtual environment (.venv)..."
  if ! "$PY" -m venv .venv; then
    die "Failed to create the virtual environment with $PY."
  fi
fi

# shellcheck disable=SC1091
if ! source .venv/bin/activate; then
  die "Could not activate the virtual environment (.venv)."
fi

log "Installing/upgrading Python dependencies..."
pip install --upgrade pip >/dev/null
# openai-whisper's build imports pkg_resources, which setuptools>=81 removed.
# Pin setuptools below 81 and disable build isolation so the build succeeds.
pip install --upgrade "setuptools>=68,<81" wheel >/dev/null
if ! pip install --upgrade --no-build-isolation -r requirements.txt; then
  die "Failed to install Python dependencies. See the pip output above."
fi

log "Launching Lyrics..."
export TK_SILENCE_DEPRECATION=1   # silence the harmless macOS Tk notice

# Testing/CI hook: LYRICS_SETUP_ONLY=1 completes provisioning + venv setup and
# exits before opening the GUI. Normal users never set this.
if [ "${LYRICS_SETUP_ONLY:-0}" = "1" ]; then
  log "Setup complete (LYRICS_SETUP_ONLY=1); skipping GUI launch."
  exit 0
fi

python app.py
