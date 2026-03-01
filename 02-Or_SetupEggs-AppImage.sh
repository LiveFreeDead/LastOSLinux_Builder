#!/bin/bash

# ============================================================
# TERMINAL DETECTION
# If not running inside a terminal, find one and re-launch.
# ============================================================
find_terminal() {
    for CANDIDATE in gnome-terminal konsole xfce4-terminal mate-terminal lxterminal tilix alacritty xterm x-terminal-emulator; do
        if command -v "$CANDIDATE" > /dev/null 2>&1; then
            echo "$CANDIDATE"
            return 0
        fi
    done
    return 1
}

if [ ! -t 0 ]; then
    TERMINAL=$(find_terminal)
    if [ -z "$TERMINAL" ]; then
        command -v zenity > /dev/null 2>&1 && \
            zenity --error --text="No terminal emulator found. Please install xterm or another terminal."
        exit 1
    fi
    case "$TERMINAL" in
        gnome-terminal) exec gnome-terminal -- bash "$0" "$@" ;;
        konsole)        exec konsole        -e bash "$0" "$@" ;;
        xfce4-terminal) exec xfce4-terminal -x bash "$0" "$@" ;;
        mate-terminal)  exec mate-terminal  -x bash "$0" "$@" ;;
        *)              exec "$TERMINAL"    -e bash "$0" "$@" ;;
    esac
fi

# ============================================================
# SUDO KEEPALIVE
# Authenticate once and keep sudo alive for the whole script.
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo "Some operations require elevated privileges. Please authenticate:"
    sudo -v || { echo "Authentication failed. Press Enter to exit."; read -r; exit 1; }
    # Refresh the sudo timestamp every 50 seconds until this script exits
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
fi

# ============================================================
# MAIN
# ============================================================

CurDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# This fixes the error at the end of Calamares
sudo apt -y install language-selector-common

# Find the eggs AppImage and make it executable
EGGS_APPIMAGE=$(ls "$CurDir"/penguins-eggs-*-x86_64.AppImage 2>/dev/null | head -n 1)
if [ -z "$EGGS_APPIMAGE" ]; then
    echo "Warning: No penguins-eggs AppImage found in $CurDir — skipping eggs setup."
else
    chmod +x "$EGGS_APPIMAGE"
    sudo cp -f "$EGGS_APPIMAGE" /usr/local/bin/eggs
    #sudo eggs setup
    yes | sudo eggs setup install
fi
