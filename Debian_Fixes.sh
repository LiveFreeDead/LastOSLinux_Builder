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
# FUNCTIONS
# ============================================================

# Universal install function — picks the right package manager for the distro
inst() {
    APT_CMD=$(type -P apt    2>/dev/null)
    DNF_CMD=$(type -P dnf    2>/dev/null)
    EMERGE_CMD=$(type -P emerge 2>/dev/null)
    EOPKG_CMD=$(type -P eopkg  2>/dev/null)
    APK_CMD=$(type -P apk    2>/dev/null)
    PACMAN_CMD=$(type -P pacman 2>/dev/null)
    PAMAC_CMD=$(type -P pamac  2>/dev/null)
    ZYPPER_CMD=$(type -P zypper 2>/dev/null)
    YUM_CMD=$(type -P yum    2>/dev/null)

    if   [ -n "$PAMAC_CMD"  ]; then sudo "$PAMAC_CMD"  install --no-confirm "$@"
    elif [ -n "$DNF_CMD"    ]; then sudo "$DNF_CMD"    -y install           "$@"
    elif [ -n "$APT_CMD"    ]; then sudo "$APT_CMD"    -y install           "$@"
    elif [ -n "$EMERGE_CMD" ]; then sudo "$EMERGE_CMD"                      "$@"
    elif [ -n "$EOPKG_CMD"  ]; then sudo "$EOPKG_CMD"  -y install           "$@"
    elif [ -n "$APK_CMD"    ]; then sudo "$APK_CMD"    add install          "$@"
    elif [ -n "$PACMAN_CMD" ]; then yes | sudo "$PACMAN_CMD" -Syu           "$@"   # -Syu gets dependencies too
    elif [ -n "$ZYPPER_CMD" ]; then sudo "$ZYPPER_CMD" --non-interactive install "$@"
    elif [ -n "$YUM_CMD"    ]; then sudo "$YUM_CMD"    -y install           "$@"
    else echo "Error: No supported package manager found — cannot install: $*"
    fi
}

# ============================================================
# TERMINAL AND PACKAGE MANAGER DETECTION
# ============================================================

# Get Best Terminal For LLStore (in order)
OSTERM=""
for t in gnome-terminal konsole x-terminal-emulator xterm xfce4-terminal; do
    if command -v "$t" > /dev/null 2>&1; then
        OSTERM=$t
        break
    fi
done

# Detect the active package manager and store it for use below
PM=""
APT_CMD=$(type -P apt    2>/dev/null)
DNF_CMD=$(type -P dnf    2>/dev/null)
EMERGE_CMD=$(type -P emerge 2>/dev/null)
EOPKG_CMD=$(type -P eopkg  2>/dev/null)
APK_CMD=$(type -P apk    2>/dev/null)
PACMAN_CMD=$(type -P pacman 2>/dev/null)
PAMAC_CMD=$(type -P pamac  2>/dev/null)
ZYPPER_CMD=$(type -P zypper 2>/dev/null)
YUM_CMD=$(type -P yum    2>/dev/null)

if   [ -n "$PAMAC_CMD"  ]; then PM=pamac;  echo "Package Manager: pamac"
elif [ -n "$DNF_CMD"    ]; then PM=dnf;    echo "Package Manager: dnf"
elif [ -n "$APT_CMD"    ]; then PM=apt;    echo "Package Manager: apt"
elif [ -n "$EMERGE_CMD" ]; then PM=emerge; echo "Package Manager: emerge"
elif [ -n "$EOPKG_CMD"  ]; then PM=eopkg;  echo "Package Manager: eopkg"
elif [ -n "$APK_CMD"    ]; then PM=apk;    echo "Package Manager: apk"
elif [ -n "$PACMAN_CMD" ]; then PM=pacman; echo "Package Manager: pacman"
elif [ -n "$ZYPPER_CMD" ]; then PM=zypper; echo "Package Manager: zypper"
elif [ -n "$YUM_CMD"    ]; then PM=yum;    echo "Package Manager: yum"
else echo "Unknown Package Manager. Script section skipped"
fi

echo "Terminal Used:        $OSTERM"
echo "Desktop Environment:  $XDG_SESSION_DESKTOP"

# ============================================================
# DISTRO-SPECIFIC TASKS
# Use these sections to add repos, PPAs, or update commands.
# ============================================================
. /etc/os-release
echo "OS ID: $ID"

case $ID in
    linuxmint|ubuntu)
        ;;

    debian|pop)
        # Add Linux Mint repo for theme/icon packages on Debian and Pop!_OS
        echo "deb [trusted=yes] http://packages.linuxmint.com debian main" | \
            sudo tee /etc/apt/sources.list.d/linuxmint.list
        sudo apt update
        ;;

    fedora|nobara)
        ;;

    opensuse-tumbleweed)
        ;;

    arch|endeavouros)
        ;;

    biglinux)
        ;;

    solus)
        ;;

    *)
        echo "Unknown Distribution. Script section skipped"
        ;;
esac

# ============================================================
# DESKTOP ENVIRONMENT-SPECIFIC TASKS
# ============================================================
case $XDG_SESSION_DESKTOP in
    cinnamon)       ;;
    gnome|ubuntu)   ;;
    kde|KDE)        ;;
    lxde)           ;;
    mate)           ;;
    unity)          ;;
    xfce)           ;;
    cosmic|pop)     ;;
    budgie-desktop) ;;
    LXQt)           ;;
    *)
        echo "Unknown Desktop Environment. Script section skipped"
        ;;
esac

# ============================================================
# INSTALL APPS
# Uses the inst() function above to support many distros.
# Add package names after 'inst' to install them.
# inst appname1 appname2 etc
# ============================================================

# FlatPak Install Package System Wide
# (User mode flatpaks should be done from a non-sudo LLScript)
# Uncomment and add "org.name.thing" to install a Flatpak:
#$OSTERM -e "flatpak install --system -y --noninteractive flathub "

# ----- Add Your Code Here -----

inst mint-themes
inst mint-l-icons
inst mint-x-icons
inst mint-y-icons
inst yaru-theme-icon
inst yaru-theme-gtk
