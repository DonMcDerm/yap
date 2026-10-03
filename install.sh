#!/usr/bin/env bash
# Install yap: the client into ~/.local/bin, the whisper daemon into ~/.local/share/yap,
# and a systemd --user unit that keeps the model resident.
#
#   ./install.sh                 venv + CUDA wheels (if an NVIDIA GPU is present) + the service
#   ./install.sh --cpu           skip the CUDA wheels (CPU int8 inference)
#   ./install.sh --no-service    install files and the venv only
#
# Your Hyprland config is never touched: the bind lines are printed at the end.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDIR="${YAP_BIN_DIR:-$HOME/.local/bin}"
DATADIR="${YAP_DATA_DIR:-$HOME/.local/share/yap}"
VENV="$DATADIR/venv"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
MODEL="${YAP_MODEL:-small.en}"

CPU_ONLY=0
NO_SERVICE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cpu)        CPU_ONLY=1 ;;
    --no-service) NO_SERVICE=1 ;;
    -h|--help)    sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

# ── venv: faster-whisper plus the pinned av ────────────────────────────────────────
if [ ! -x "$VENV/bin/python" ]; then
  say "creating venv: $VENV"
  python3 -m venv "$VENV"
fi
PY="$VENV/bin/python"
"$PY" -m pip install --quiet --upgrade pip
# av is pinned below 19 on purpose: faster-whisper 1.2.1 calls av.open(..., metadata_errors=...),
# which av 19 removed. The failure mode is an empty transcript, not an error message.
say "installing faster-whisper==1.2.1 + av==18.1.0"
"$PY" -m pip install --quiet "faster-whisper==1.2.1" "av==18.1.0"

if [ "$CPU_ONLY" = 0 ] && command -v nvidia-smi >/dev/null 2>&1; then
  say "NVIDIA GPU detected — adding the cublas/cudnn/nvrtc wheels so ctranslate2 can use CUDA"
  "$PY" -m pip install --quiet nvidia-cublas-cu12 nvidia-cudnn-cu12 nvidia-cuda-nvrtc-cu12
fi
PYVER="$("$PY" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

# ── files (an existing install is backed up, never clobbered) ──────────────────────
mkdir -p "$BINDIR" "$DATADIR"
if [ -e "$BINDIR/yap" ]; then
  BACKUP="$BINDIR/yap.bak.$(date +%s)"
  cp -a "$BINDIR/yap" "$BACKUP"
  say "existing client backed up: $BACKUP"
fi
install -m 0755 "$REPO/bin/yap" "$BINDIR/yap"
install -m 0644 "$REPO/src/sttd.py" "$DATADIR/sttd.py"
say "installed $BINDIR/yap and $DATADIR/sttd.py"

# ── service ───────────────────────────────────────────────────────────────────────
if [ "$NO_SERVICE" = 0 ]; then
  mkdir -p "$UNIT_DIR"
  sed -e "s|@VENV@|$VENV|g" -e "s|@DATADIR@|$DATADIR|g" \
      -e "s|@PYVER@|$PYVER|g" -e "s|@MODEL@|$MODEL|g" \
      "$REPO/systemd/yap-sttd.service.in" >"$UNIT_DIR/yap-sttd.service"
  # Decoder vocabulary (see src/sttd.py). Written as a FILE, never inlined into the unit:
  # systemd needs quotes around an Environment value containing spaces, and quoting adds escape
  # rules of its own. The daemon reads ~/.config/yap/prompt.txt when YAP_PROMPT is unset.
  if [ -n "${YAP_PROMPT:-}" ]; then
    CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/yap"
    mkdir -p "$CFG_DIR"
    printf '%s\n' "$YAP_PROMPT" >"$CFG_DIR/prompt.txt"
    say "decoder vocabulary: $CFG_DIR/prompt.txt"
  fi
  systemctl --user daemon-reload
  systemctl --user enable --now yap-sttd.service
  say "yap-sttd.service enabled (model: $MODEL)"
  say "daemon log: $HOME/.cache/yap/sttd.log   (look for 'listening on … (cuda/float32)')"
fi

cat <<EOF

Add these to ~/.config/hypr/bindings.lua (see examples/hyprland.lua):

  o.bind("SUPER + H", "Dictate (yap)", "$BINDIR/yap")
  o.bind("SUPER + SHIFT + H", "Insert last transcript (yap)", "$BINDIR/yap --last")

then:  hyprctl reload && hyprctl configerrors
       $BINDIR/yap --check
EOF
