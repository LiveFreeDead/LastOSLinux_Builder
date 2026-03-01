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
# Added Penguins Eggs back to preset, should work now excludes is disabled.
# Nope put back due to needing the deb as the one I made isn't working with mkisofs.
# Yep was lack of isolinux depends etc in the penguins eggs package.
# Nope still dodgy.
# ============================================================

MAINDIR=$PWD

# Run the NodeSource setup script if it's present
[ -f "$MAINDIR/nodesource_setup.sh" ] && sudo bash "$MAINDIR/nodesource_setup.sh"

sudo apt -y install nodejs
sudo apt install -y --fix-broken

# Install the penguins-eggs .deb — find it dynamically so the version doesn't matter
EGGS_DEB=$(ls "$MAINDIR"/penguins-eggs*amd64.deb 2>/dev/null | head -n 1)
if [ -z "$EGGS_DEB" ]; then
    echo "Warning: No penguins-eggs .deb found in $MAINDIR — skipping deb install."
else
    sudo dpkg -i "$EGGS_DEB"
fi

sudo apt install -y --fix-broken

# This fixes the error at the end of Calamares
sudo apt -y install language-selector-common

# Manual jobs to fix Calamares theme and grub.
# May not be needed as grub updates require eggs to do the heavy lifting
# to detect the kernel version.
#sudo mkdir -p /usr/lib/penguins-eggs
#[ -d "$MAINDIR/CalamaresTheme" ] && sudo cp -rf "$MAINDIR/CalamaresTheme/"* /usr/lib/penguins-eggs/
