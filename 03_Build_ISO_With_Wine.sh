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

MAINDIR=$PWD

# Disable write-through cache mode so the USB won't be wiped by apt clean
[ -f "$MAINDIR/0-LastOS-Manage-Repo.sh" ] && bash "$MAINDIR/0-LastOS-Manage-Repo.sh" -link-ro

# Kill Mint Updater so it doesn't trigger mid-build
killall mintUpdate      2>/dev/null
killall mintreport-tray 2>/dev/null

# Set hide hidden files default (clean view for the captured OS)
gsettings set org.nemo.preferences show-hidden-files false

# Make it use Win 10 Icons not the theme ones
gsettings set org.cinnamon.desktop.interface icon-theme "Windows-10-master"
sudo gsettings set org.cinnamon.desktop.interface icon-theme "Windows-10-master"
gsettings set org.gnome.desktop.interface   icon-theme "Windows-10-master"
sudo gsettings set org.gnome.desktop.interface   icon-theme "Windows-10-master"
gsettings set org.mate.interface            icon-theme "Windows-10-master"
sudo gsettings set org.mate.interface            icon-theme "Windows-10-master"

# ============================================================
# Distro-specific tasks
# ============================================================
. /etc/os-release
echo "OS ID: $ID"

case $ID in
    debian)
        # Copy Gamers Runtimes package into the Windows apps folder for Debian builds
        SRC="$MAINDIR/DebianFixes/LastOS.Gamers.Runtimes.Lite_v23.04_x64+x86_ssApp.apz"
        if [ -f "$SRC" ]; then
            mkdir -p /opt/LastOS/WindowsApps
            cp "$SRC" /opt/LastOS/WindowsApps/
        else
            echo "Warning: Debian fix file not found: $SRC"
        fi
        ;;
    *)
        echo "Not Debian, skipped"
        ;;
esac

# Below is not required as language-selector-common is installed in the eggs setup script.
# Manual jobs to fix Calamares Errors.
#sudo cp -f "$MAINDIR/aaJobs-Manual/"*.sh /usr/lib/penguins-eggs/conf/distros/noble/calamares/libexec

# ============================================================
# Run clean-up and build (Wine ISO variant) via LLStore
# ============================================================

echo "Running Clean up from $MAINDIR/LLAppsInstalls/"
CLEAN_TAR=$(ls "$MAINDIR/LLAppsInstalls/"LastOSLinux.Clean.Build_*_x64+x86_LLApp.tar 2>/dev/null | head -n 1)
if [ -n "$CLEAN_TAR" ]; then
    /opt/LastOS/LLStore/llstore -i -q "$CLEAN_TAR"
else
    echo "Warning: Clean build LLApp tar not found in $MAINDIR/LLAppsInstalls/"
fi

echo "Running Build from $MAINDIR/LLAppsInstalls/"
BUILD_TAR=$(ls "$MAINDIR/LLAppsInstalls/"LastOSLinux.Build.ISO.With.Wine_*_x64+x86_LLApp.tar 2>/dev/null | head -n 1)
if [ -n "$BUILD_TAR" ]; then
    /opt/LastOS/LLStore/llstore -i -q "$BUILD_TAR"
else
    echo "Warning: Build ISO With Wine LLApp tar not found in $MAINDIR/LLAppsInstalls/"
fi

# Open the home folder in Nemo once the build kicks off
nemo "$HOME" &
