#!/usr/bin/env bash
# Build, install, and (re)start the nanocharger daemon.
# Safe to re-run: existing config is preserved, missing pieces are bootstrapped.
#
# Build is run as the current user; everything else uses sudo.
#
# Filesystem layout follows FHS:
#   binary  -> /usr/local/bin/nanocharger          (locally installed software)
#   config  -> /etc/nanocharger/schedule.json
#   state   -> /var/lib/nanocharger/state.json
#   service -> /etc/systemd/system/nanocharger.service

set -euo pipefail

BIN_DEST=/usr/local/bin/nanocharger
CONFIG_DIR=/etc/nanocharger
CONFIG_FILE="${CONFIG_DIR}/schedule.json"
STATE_DIR=/var/lib/nanocharger
SERVICE_NAME=nanocharger.service
SERVICE_DEST="/etc/systemd/system/${SERVICE_NAME}"
SERVICE_USER=nanocharger

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLE_CONFIG="${REPO_DIR}/schedule.sample.json"
SERVICE_SRC="${REPO_DIR}/Packaging/nanocharger.service"

bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }

if [[ "$(uname -s)" != "Linux" ]]; then
    red "This installer targets Linux (Raspberry Pi OS). Refusing to run on $(uname -s)."
    exit 1
fi
if ! command -v sudo >/dev/null; then
    red "'sudo' is required."
    exit 1
fi
if ! command -v systemctl >/dev/null; then
    red "'systemctl' is required (systemd-based init expected)."
    exit 1
fi
if ! command -v swift >/dev/null; then
    red "'swift' toolchain not found. Install Swift before running this script."
    exit 1
fi
if [[ ! -f "$SERVICE_SRC" ]]; then
    red "Missing $SERVICE_SRC; run this script from a clean checkout of the repo."
    exit 1
fi

# 1) Build as the current user.
green "==> Building release binary"
cd "$REPO_DIR"
swift build -c release

BUILT_BINARY="$REPO_DIR/.build/release/nanocharger"
if [[ ! -x "$BUILT_BINARY" ]]; then
    red "Build did not produce $BUILT_BINARY"
    exit 1
fi

# 2) Stop the daemon if it's currently running.
if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "$SERVICE_NAME"; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        green "==> Stopping running daemon"
        sudo systemctl stop "$SERVICE_NAME"
    fi
fi

# 3) Ensure system user.
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    green "==> Creating system user '$SERVICE_USER'"
    sudo useradd --system --home-dir "$STATE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi

# 4) Install binary.
green "==> Installing binary -> $BIN_DEST"
sudo install -m 0755 "$BUILT_BINARY" "$BIN_DEST"

# 5) Ensure /etc and /var directories with correct ownership.
sudo install -d -m 0755 "$CONFIG_DIR"
sudo install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$STATE_DIR"

# 6) Place config if missing; preserve any existing config.
config_was_created=false
if [[ ! -f "$CONFIG_FILE" ]]; then
    if [[ -f "$SAMPLE_CONFIG" ]]; then
        green "==> Installing default config -> $CONFIG_FILE"
        sudo install -m 0644 "$SAMPLE_CONFIG" "$CONFIG_FILE"
        config_was_created=true
    else
        yellow "Sample config $SAMPLE_CONFIG missing; skipping default-config install."
        yellow "You will need to write $CONFIG_FILE manually before the daemon will manage anything."
    fi
else
    green "==> Existing $CONFIG_FILE preserved"
fi

# 7) Install systemd unit and reload.
green "==> Installing systemd unit -> $SERVICE_DEST"
sudo install -m 0644 "$SERVICE_SRC" "$SERVICE_DEST"
sudo systemctl daemon-reload

# 8) If the config was just created, give the user a chance to edit before the daemon starts.
if [[ "$config_was_created" == "true" ]]; then
    echo
    yellow "A default config has been installed at $CONFIG_FILE."
    yellow "It contains placeholder hub/port ids that probably won't match your hardware."
    yellow "Discover real ids in another terminal with:  nanocharger ui   (or:  uhubctl)"
    echo
    read -rp "Edit $CONFIG_FILE now with nano before starting the daemon? [Y/n] " answer
    answer=${answer:-Y}
    if [[ "$answer" =~ ^[Yy] ]]; then
        sudo nano "$CONFIG_FILE"
    else
        yellow "Skipped editing. The daemon will start with the placeholder config and warn about unknown ports."
    fi
fi

# 9) Enable + (re)start.
green "==> Enabling and (re)starting $SERVICE_NAME"
sudo systemctl enable "$SERVICE_NAME" >/dev/null
sudo systemctl restart "$SERVICE_NAME"

sleep 1
echo
bold "Service status:"
sudo systemctl status "$SERVICE_NAME" --no-pager -l | sed -n '1,15p' || true

echo
green "Install complete."
echo "Follow logs with:    journalctl -u $SERVICE_NAME -f"
echo "Edit schedule with:  sudo nano $CONFIG_FILE  &&  sudo systemctl restart $SERVICE_NAME"
