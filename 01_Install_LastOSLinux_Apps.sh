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

# Set Builder Flag so other tools know a build is in progress
echo "Builder Running" > /tmp/LastOSLinux-Builder

# Get the directory this script lives in (works when called from any location)
CurDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#cd LLStore
#./setup.sh
#cd $CurDir

# ============================================================
# Get Best Terminal (also stored for use by LLStore later)
# ============================================================
OSTERM=""
for t in gnome-terminal konsole x-terminal-emulator xterm xfce4-terminal; do
    if command -v "$t" > /dev/null 2>&1; then
        OSTERM=$t
        break
    fi
done

# ============================================================
# Seed APT cache from any local cache folders if they exist
# (Switched to 2nd method)
# ============================================================
[ -d "$CurDir/Cache" ] && sudo cp -rf "$CurDir/Cache/." /var/cache/apt/archives
[ -d "$CurDir/cache" ] && sudo cp -rf "$CurDir/cache/." /var/cache/apt/archives

# ============================================================
# Enable APT cache capture so downloads are saved and linked
# ============================================================

# Path to the repo manager script (two levels up in the repo folder)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/../../1-RepositoryLocalDebs/0-LastOS-Manage-Repo.sh"

# Run the repo manager if it exists
if [ -f "$TARGET_SCRIPT" ]; then
    bash "$TARGET_SCRIPT" -capture
    bash "$TARGET_SCRIPT" -link
else
    echo "Warning: Could not find $TARGET_SCRIPT — skipping repo manager."
fi

# Apply system updates first
sudo apt update && sudo apt upgrade -y
sudo apt autoremove -y

# ============================================================
# Copy Wine downloaded MSI's into place for both user and skel
# ============================================================

    mkdir -p "$HOME/.cache/wine"
    cp -r "$CurDir/wine/." "$HOME/.cache/wine"
    sudo mkdir -p /etc/skel/.cache/wine
    sudo cp -r "$CurDir/wine/." "/etc/skel/.cache/wine/"

# Copy Google Chrome installer to /tmp for use by LLStore
cp "$CurDir/google-chrome-stable_current_amd64.deb" /tmp/


# ============================================================
# Replace hardcoded path in the locations INI with the current
# script directory path so LLAppsInstalls entries resolve correctly
# ============================================================
sed "s!\/home/lastos/LastOSLinux-RC5/LLAppsInstalls!$CurDir/LLAppsInstalls!g" \
    "$CurDir/LLL_Store_Linux_Manual_Locations_Orig.ini" > "$CurDir/LLL_Store_Linux_Manual_Locations.ini"
[ -f "$CurDir/LLL_Store_Linux_Manual_Locations.ini" ] && \
    cp "$CurDir/LLL_Store_Linux_Manual_Locations.ini" /opt/LastOS/LLStore
[ -f "$CurDir/LLL_Settings.ini" ] && \
    cp "$CurDir/LLL_Settings.ini" /opt/LastOS/LLStore

# ============================================================
# Icons and Fonts — done first as they can crash other things
# if left until later
# ============================================================

# Install icons first (icon crashes block other installs)
/opt/LastOS/LLStore/llstore -i -q -KeepSudo -p "$CurDir/Icons_Preset.ini"

# Install fonts first too (font crashes block other installs)
/opt/LastOS/LLStore/llstore -i -q -KeepSudo -p "$CurDir/Fonts_Preset.ini"

# Install VLC and Java font dependencies
sudo apt -y install fonts-freefont-ttf fonts-dejavu-extra fonts-ipafont-gothic \
    fonts-ipafont-mincho fonts-wqy-microhei fonts-wqy-zenhei fonts-indic \
    libsdl-ttf2.0-0 libsdl2-ttf-2.0-0

# Microsoft Fonts (EULA bypassed via debconf pre-seed)
echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections
echo fonts-wine          msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections
sudo apt -y install ttf-mscorefonts-installer

# Rebuild font cache at the end — it's OK if this fails
# Note: there may be a bad font that needs tracking down and removing
fc-cache -f -v
#Not sure sudo is needed
sudo fc-cache -f -v

# Below two are too big to include out of the box — fonts above handle
# the crash prevention that jre and vlc would otherwise cause.
# They are included in the preset instead.
#sudo apt -y install default-jre
#sudo apt -y install vlc

# Turn NumLock on by default
sudo apt -y install numlockx
numlockx on

# I think this downloads a flatpak repo — moving it to the firstlogon.sh script
# FlatPaks - Integrated System Wide
#$OSTERM -e "flatpak install --system -y --noninteractive flathub it.mijorus.gearlever"

# Remove Firefox (replaced by Chrome)
sudo apt -y remove firefox firefox-locale-en

# Change default taskbar apps: switch from Firefox to Chrome and add LLStore
gsettings set org.cinnamon favorite-apps "['google-chrome.desktop', 'mintinstall.desktop', 'cinnamon-settings.desktop', 'llstore.desktop', 'org.gnome.Terminal.desktop', 'nemo.desktop']"

# Install all apps from the main LastOS preset
/opt/LastOS/LLStore/llstore -i -p "$CurDir/LastOSLinux_Preset.ini"
#> $HOME/Desktop/LLStore-Results.txt
#I removed -q (quit) from above after -i

# Signal that the sudo-elevated stage is done
echo "Done" > /tmp/LLSudoDone

# Apply the overlay settings on top of the defaults
[ -f "$CurDir/LLL_Settings-Overlay.ini" ] && \
    cp "$CurDir/LLL_Settings-Overlay.ini" /opt/LastOS/LLStore/LLL_Settings.ini

# Clean up any LLStore debug logs left on the desktop
[ -d "$HOME/Desktop/LLStore Debug-Logs" ] && \
    rm -rf "$HOME/Desktop/LLStore Debug-Logs"

# Panel to Center (instead of menu etc being far left)
#dconf write /org/cinnamon/enabled-applets "['panel1:center:0:menu@cinnamon.org:0', 'panel1:center:1:separator@cinnamon.org:1', 'panel1:center:2:grouped-window-list@cinnamon.org:2', 'panel1:right:0:systray@cinnamon.org:3', 'panel1:right:1:xapp-status@cinnamon.org:4', 'panel1:right:2:notifications@cinnamon.org:5', 'panel1:right:3:printers@cinnamon.org:6', 'panel1:right:4:removable-drives@cinnamon.org:7', 'panel1:right:5:keyboard@cinnamon.org:8', 'panel1:right:6:favorites@cinnamon.org:9', 'panel1:right:7:network@cinnamon.org:10', 'panel1:right:8:sound@cinnamon.org:11', 'panel1:right:9:power@cinnamon.org:12', 'panel1:right:10:calendar@cinnamon.org:13', 'panel1:right:11:cornerbar@cinnamon.org:14']"

# Make Root show files in compact view by default
sudo gsettings set org.nemo.preferences default-folder-viewer 'compact-view'

# Set show hidden files default for Root
sudo gsettings set org.nemo.preferences show-hidden-files true

# Install themes and apply distro-specific fixes
[ -f "$CurDir/Debian_Fixes.sh" ] && sudo bash "$CurDir/Debian_Fixes.sh"

# Setup Portable Eggs (AppImage method — alternative to deb install)
#chmod +x penguins-eggs-*.AppImage
#sudo cp -f penguins-eggs-*.AppImage /usr/local/bin/eggs
#sudo eggs setup
#sudo eggs setup --install

# Remove Builder Flag now that we're done
[ -f /tmp/LastOSLinux-Builder ] && rm -f /tmp/LastOSLinux-Builder
