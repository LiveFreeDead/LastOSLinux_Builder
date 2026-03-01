#!/bin/bash

# ============================================================
# 1. TERMINAL DETECTION
# If not running inside a terminal, find one and re-launch.
# Tries terminals in order of preference across all major DEs.
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
        # Last resort: try to show a graphical error message
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
# 2. ROOT ELEVATION
# Re-executes this script as root via sudo.
# Once running as root all internal commands run without sudo.
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo "This script requires administrative privileges."
    if ! sudo -v; then
        echo "Authentication failed. Press Enter to exit."
        read -r
        exit 1
    fi
    exec sudo "$0" "$@"
fi

# ============================================================
# 3. PATH DETECTION
# ============================================================
USB_PATH=$(dirname "$(readlink -f "$0")")
_CANDIDATE_PATH=$(readlink -f "$USB_PATH/../../1-RepositoryLocalDebs")
if [ -d "$_CANDIDATE_PATH" ]; then
    USB_PATH="$_CANDIDATE_PATH"
fi
unset _CANDIDATE_PATH
CONF_FILE="/etc/apt/apt.conf.d/99persist-to-usb"
LOCAL_CACHE="/var/cache/apt/archives"

# Get the real user's home dir even when running as root via sudo
if [ -n "$SUDO_USER" ]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_HOME=$HOME
fi

# ============================================================
# 4. FUNCTIONS
# ============================================================

header() {
    clear
    FREE_SPACE=$(df -h "$USB_PATH" 2>/dev/null | awk 'NR==2 {print $4}')
    echo "==============================================="
    echo "      0-LastOS REPOSITORY MANAGER (exFAT)      "
    echo "==============================================="
    echo " USB Location: $USB_PATH"
    echo " USB Free:     $FREE_SPACE"
    if [ -f "$CONF_FILE" ]; then
        echo " STATUS:      CAPTURE MODE ACTIVE (USB Cache)"
    else
        echo " STATUS:      STANDARD/LINK MODE"
    fi
    echo "-----------------------------------------------"
}

create_failsafe() {
    echo "Creating Emergency Fail-Safe autostart..."
    mkdir -p "$REAL_HOME/.config/autostart" "$REAL_HOME/.local/bin"

    local FAILSAFE_SCRIPT="$REAL_HOME/.local/bin/lastos-failsafe.sh"
    local AUTOSTART_FILE="$REAL_HOME/.config/autostart/lastos-failsafe.desktop"

    # Write the fail-safe cleanup script that runs at next login
    cat <<EOF > "$FAILSAFE_SCRIPT"
#!/bin/bash
until [ -n "\$DISPLAY" ] && [ -n "\$XAUTHORITY" ]; do
    sleep 1
done
sleep 2
if pkexec sh -c "rm -f $CONF_FILE && find $LOCAL_CACHE -type l -delete"; then
    rm -f "$AUTOSTART_FILE"
    rm -f "$FAILSAFE_SCRIPT"
fi
EOF
    chmod +x "$FAILSAFE_SCRIPT"

    # Write the autostart .desktop entry to trigger the fail-safe at login
    cat <<EOF > "$AUTOSTART_FILE"
[Desktop Entry]
Type=Application
Name=LastOS Fail-Safe
Exec=$FAILSAFE_SCRIPT
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

    # Restore ownership to the real user (not root)
    if [ -n "$SUDO_USER" ]; then
        chown "$SUDO_USER:$SUDO_USER" "$FAILSAFE_SCRIPT" "$AUTOSTART_FILE"
    fi
}

do_capture() {
    do_unlink  # Clean state first
    create_failsafe
    echo "Preparing USB for capture..."
    mkdir -p "$USB_PATH/partial"
    echo "Redirecting APT downloads to USB..."
    {
        echo "Dir::Cache::Archives \"$USB_PATH/\";"
        echo "Binary::apt::APT::Keep-Downloaded-Packages \"true\";"
        echo "APT::Keep-Downloaded-Packages \"true\";"
        echo "APT::Sandbox::User \"root\";"
    } > "$CONF_FILE"
    #apt update
    echo "Done. All downloads will stay on this USB."
}

# Link Read-Only: USB .deb files are linked but NOT set as the apt cache dir,
# so 'apt clean' will only remove the symlinks, leaving USB files untouched.
do_link_ro() {
    do_unlink  # Ensure no existing config or links interfere
    #create_failsafe
    echo "Creating Read-Only Symbolic Links..."
    # We do NOT create the $CONF_FILE here.
    # This keeps the USB protected from 'apt clean'.
    ln -s "$USB_PATH"/*.deb "$LOCAL_CACHE/" 2>/dev/null
    apt update
    echo "Links created. 'apt clean' will only delete the links, not your USB files."
}

do_link() {
    #do_unlink  # Don't stop a capture if done separate
    #create_failsafe
    echo "Linking .deb files from USB to system cache..."
    ln -s "$USB_PATH"/*.deb "$LOCAL_CACHE/" 2>/dev/null
    apt update
    echo "Links created. System will now use USB files."
}

do_prune() {
    echo "Scanning for old package versions on USB..."
    # Make sure the USB path exists before trying to cd into it
    if [ ! -d "$USB_PATH" ]; then
        echo "Error: USB path not found: $USB_PATH"
        return 1
    fi
    cd "$USB_PATH" || return 1
    ls ./*.deb 2>/dev/null | cut -d'_' -f1 | sort -u | while read -r pkg; do
        count=$(ls "${pkg}"_*.deb 2>/dev/null | wc -l)
        if [ "$count" -gt 1 ]; then
            echo "Found $count versions of $pkg..."
            # Sort versions and collect all but the newest
            old_files=$(ls "${pkg}"_*.deb | sort -V | head -n -1)
            for file in $old_files; do
                echo "  Deleting older version: $file"
                [ -f "$file" ] && rm "$file"
            done
        fi
    done
    echo "Pruning complete."
}

do_unlink() {
    echo "Unlinking and cleaning up system settings..."
    # Remove the apt redirect config if present
    [ -f "$CONF_FILE" ] && rm -f "$CONF_FILE"
    # Remove fail-safe files if they exist
    [ -f "$REAL_HOME/.local/bin/lastos-failsafe.sh" ]              && rm -f "$REAL_HOME/.local/bin/lastos-failsafe.sh"
    [ -f "$REAL_HOME/.config/autostart/lastos-failsafe.desktop" ]  && rm -f "$REAL_HOME/.config/autostart/lastos-failsafe.desktop"
    echo "Removing symlinks from $LOCAL_CACHE..."
    [ -d "$LOCAL_CACHE" ] && find "$LOCAL_CACHE" -type l -delete
    # Remove APT temp folders left on USB
    [ -d "$USB_PATH/partial" ] && rm -rf "$USB_PATH/partial"
    [ -f "$USB_PATH/lock" ]    && rm -f  "$USB_PATH/lock"
    # Ensure the USB is fully accessible
    chmod -R 777 "$USB_PATH" 2>/dev/null
}

# ============================================================
# 5. ARGUMENT HANDLING (non-interactive / scripted use)
# ============================================================
if [ -n "$1" ]; then
    case $1 in
        -capture) do_capture ;;
        -link)    do_link    ;;
        -link-ro) do_link_ro ;;
        -prune)   do_prune   ;;
        -unlink)  do_unlink  ;;
        *) echo "Usage: $0 {-capture|-link|-link-ro|-prune|-unlink}" ;;
    esac
    exit 0
fi

# ============================================================
# 6. INTERACTIVE MENU
# ============================================================
while true; do
    header
    echo " 1) CAPTURE: Save all new downloads to USB"
    echo " 2) LINK:    Use existing USB files (Standard)"
    echo " 3) LINK RO: Use USB files (Protected from 'apt clean')"
    echo " 4) PRUNE:   Delete old versions from USB"
    echo " 5) UNLINK:  Reset system & Wipe USB Temp files"
    echo " 6) EXIT"
    echo "-----------------------------------------------"
    read -rp " Select an option [1-6]: " choice

    case $choice in
        1) do_capture ; echo ""; read -rp "Press Enter to return..." ;;
        2) do_link    ; echo ""; read -rp "Press Enter to return..." ;;
        3) do_link_ro ; echo ""; read -rp "Press Enter to return..." ;;
        4) do_prune   ; echo ""; read -rp "Press Enter to return..." ;;
        5) do_unlink  ; echo ""; read -rp "Press Enter to return..." ;;
        6) exit 0 ;;
        *) echo "Invalid choice." ; sleep 1 ;;
    esac
done
