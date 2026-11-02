#!/bin/bash
# =============================================================================
#  LastOS REPOSITORY MANAGER
# =============================================================================
#  Keeps a USB (or any folder) full of .deb files so builds never download the
#  same package twice, and so an ISO build can be done with the cache linked in.
#
#  MODES
#    capture  APT downloads go straight to the repo folder (and anything already
#             there is reused). Use this while preparing the VM.
#    link     Symlink the repo's .debs into /var/cache/apt/archives.
#    link-ro  Same, but capture mode is switched OFF first, so 'apt clean' can
#             only delete the symlinks - never your USB files.
#    unlink   Switch capture off and remove every link and temp file.
#    prune    Delete older versions of a package (keeps the newest per arch).
#    verify   Delete zero-byte / corrupt .debs so they get fetched again.
#    status   Show current mode, repo location, sizes and link health.
#
#  USAGE (menu)      ./000-LastOS-Manage-Repo.sh
#  USAGE (scripted)  ./000-LastOS-Manage-Repo.sh [--repo DIR] [--no-update]
#                                                 [--dry-run] -capture|-link|
#                                                 -link-ro|-prune|-unlink|
#                                                 -verify|-status
#
#  REPO FOLDER: --repo DIR, otherwise ../../1-RepositoryLocalDebs relative to
#  this script if it exists, otherwise the folder this script lives in.
#  The same file can live in both places - it works out where it is.
# =============================================================================

SELF="$(readlink -f "$0")"
SELF_DIR="$(dirname "$SELF")"
ORIG_ARGS=("$@")

CONF_FILE="/etc/apt/apt.conf.d/99persist-to-usb"   # APT redirect (capture mode)
LOCAL_CACHE="/var/cache/apt/archives"              # where APT normally keeps debs
LEGACY_SUDOERS="/etc/sudoers.d/zz-lastos-builder"  # left by an early test version of the builder; never wanted

usage() {
    cat <<'USAGE'
Usage: 000-LastOS-Manage-Repo.sh [--repo DIR] [--no-update] [--dry-run] ACTION
  (no action)  open the interactive menu
  -capture     APT downloads go to the repo (existing debs are reused)
  -link        symlink repo debs into /var/cache/apt/archives
  -link-ro     capture off, then link (apt clean can't touch the repo)
  -unlink      capture off, remove links and temp files
  -prune       delete older versions (newest kept per package + architecture)
  -verify      delete empty / corrupt debs
  -status      show mode, sizes and link health
USAGE
}

# ============================================================
# 1. ARGUMENTS  (parsed first - no side effects)
# ============================================================
ACTION=""; REPO_ARG=""; DO_UPDATE=1; DRY_RUN=0
while [ $# -gt 0 ]; do
    arg="${1#--}"; arg="${arg#-}"          # accept -capture and --capture
    case "$arg" in
        capture|link|link-ro|prune|unlink|verify|status) ACTION="$arg" ;;
        repo)        REPO_ARG="${2:-}"; shift || true ;;
        no-update)   DO_UPDATE=0 ;;
        dry-run)     DRY_RUN=1 ;;
        h|help)      usage; exit 0 ;;
        *)           echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

# ============================================================
# 2. TERMINAL DETECTION  (menu mode only)
# Double-clicked from a file manager? Re-open inside a terminal.
# Scripted calls (-capture etc.) never need this.
# ============================================================
if [ -z "$ACTION" ] && [ ! -t 0 ]; then
    TERMINAL=""
    for c in gnome-terminal konsole xfce4-terminal mate-terminal lxterminal tilix alacritty xterm x-terminal-emulator; do
        command -v "$c" >/dev/null 2>&1 && { TERMINAL="$c"; break; }
    done
    if [ -z "$TERMINAL" ]; then
        command -v zenity >/dev/null 2>&1 &&
            zenity --error --text="No terminal emulator found. Please install xterm or another terminal."
        exit 1
    fi
    case "$TERMINAL" in
        gnome-terminal) exec gnome-terminal -- bash "$SELF" "${ORIG_ARGS[@]}" ;;
        xfce4-terminal|mate-terminal) exec "$TERMINAL" -x bash "$SELF" "${ORIG_ARGS[@]}" ;;
        *)              exec "$TERMINAL" -e bash "$SELF" "${ORIG_ARGS[@]}" ;;
    esac
fi

# ============================================================
# 3. ROOT ELEVATION
# Re-runs this script under sudo; everything below runs as root.
# (When the builder calls us it is already authenticated - no prompt.)
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo "This script requires administrative privileges."
    sudo -v || { echo "Authentication failed. Press Enter to exit."; read -r; exit 1; }
    exec sudo bash "$SELF" "${ORIG_ARGS[@]}"
fi

# ============================================================
# 4. PATHS
# ============================================================
if [ -n "$REPO_ARG" ]; then
    REPO_DIR="$(readlink -f "$REPO_ARG")"
elif [ -d "$SELF_DIR/../../1-RepositoryLocalDebs" ]; then
    REPO_DIR="$(readlink -f "$SELF_DIR/../../1-RepositoryLocalDebs")"
else
    REPO_DIR="$SELF_DIR"
fi

# Real (non-root) user, so the fail-safe lands in THEIR home, not /root
REAL_USER="${SUDO_USER:-}"
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
else
    REAL_USER=""; REAL_HOME="$HOME"
fi

FAILSAFE_SCRIPT="$REAL_HOME/.local/bin/lastos-failsafe.sh"
AUTOSTART_FILE="$REAL_HOME/.config/autostart/lastos-failsafe.desktop"

# ============================================================
# 5. HELPERS
# ============================================================
capture_active() { [ -f "$CONF_FILE" ]; }

repo_fstype() { findmnt -no FSTYPE -T "$REPO_DIR" 2>/dev/null; }

repo_deb_count() { find "$REPO_DIR" -maxdepth 1 -type f -name '*.deb' 2>/dev/null | wc -l; }

# Refuse to capture into a folder we cannot write to (would break every apt call)
check_repo_writable() {
    if [ ! -d "$REPO_DIR" ]; then
        echo "ERROR: Repo folder not found: $REPO_DIR (is the USB plugged in?)"; return 1
    fi
    if ! touch "$REPO_DIR/.write-test" 2>/dev/null; then
        echo "ERROR: Repo folder is not writable: $REPO_DIR"; return 1
    fi
    rm -f "$REPO_DIR/.write-test"
}

# Make the repo world-writable - but only on filesystems that have real
# permissions. exFAT/FAT/NTFS take their permissions from the mount options,
# so a recursive chmod there is slow and does nothing.
fix_repo_perms() {
    case "$(repo_fstype)" in
        exfat|vfat|msdos|ntfs|ntfs3|fuseblk|"") ;;
        *) chmod -R a+rwX "$REPO_DIR" 2>/dev/null ;;
    esac
}

# Symlink every non-empty .deb from the repo into the local APT cache.
# (find -exec handles any number of files; a plain glob can overflow.)
link_debs() {
    mkdir -p "$LOCAL_CACHE"
    find "$REPO_DIR" -maxdepth 1 -type f -name '*.deb' -size +0c \
        -exec ln -sf -t "$LOCAL_CACHE" {} +
}

unlink_debs() { [ -d "$LOCAL_CACHE" ] && find "$LOCAL_CACHE" -maxdepth 1 -type l -delete; }

apt_refresh() {
    if [ "$DO_UPDATE" -eq 1 ]; then apt-get update; fi
}

header() {
    clear
    local free; free="$(df -h "$REPO_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
    echo "==============================================="
    echo "        LastOS REPOSITORY MANAGER"
    echo "==============================================="
    echo " Repo:    $REPO_DIR"
    echo " Free:    ${free:-?}   Debs: $(repo_deb_count)   FS: $(repo_fstype)"
    if capture_active; then
        echo " STATUS:  CAPTURE MODE ACTIVE (downloads go to the repo)"
    else
        echo " STATUS:  STANDARD / LINK MODE"
    fi
    echo "-----------------------------------------------"
}

# ============================================================
# 6. ACTIONS
# ============================================================

# Fail-safe: if a build is abandoned in capture mode, the next login undoes it
# (capture left on + USB unplugged = every apt command fails).
create_failsafe() {
    [ -n "$REAL_USER" ] || return 0
    echo "Creating emergency fail-safe autostart..."
    mkdir -p "$REAL_HOME/.config/autostart" "$REAL_HOME/.local/bin"

    cat > "$FAILSAFE_SCRIPT" <<EOF
#!/bin/bash
# LastOS fail-safe - undoes capture mode at login if a build never finished.
# Wait (up to ~2 min) for a graphical session so pkexec can show its prompt.
for _ in \$(seq 1 120); do
    [ -n "\$DISPLAY" ] || [ -n "\$WAYLAND_DISPLAY" ] && break
    sleep 1
done
sleep 2
if pkexec sh -c 'rm -f "$CONF_FILE" "$LEGACY_SUDOERS"; find "$LOCAL_CACHE" -maxdepth 1 -type l -delete'; then
    rm -f "$AUTOSTART_FILE" "\$0"
fi
EOF
    chmod +x "$FAILSAFE_SCRIPT"

    cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=LastOS Fail-Safe
Exec=$FAILSAFE_SCRIPT
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    chown "$REAL_USER:" "$FAILSAFE_SCRIPT" "$AUTOSTART_FILE"
}

remove_failsafe() { rm -f "$FAILSAFE_SCRIPT" "$AUTOSTART_FILE"; }

do_unlink() {
    echo "Unlinking and cleaning up system settings..."
    rm -f "$CONF_FILE" "$LEGACY_SUDOERS"
    remove_failsafe
    echo "Removing symlinks from $LOCAL_CACHE..."
    unlink_debs
    # APT temp files left in the repo
    if [ -n "$REPO_DIR" ] && [ -d "$REPO_DIR" ]; then
        rm -rf "${REPO_DIR:?}/partial"
        rm -f  "${REPO_DIR:?}/lock"
        fix_repo_perms
    fi
}

do_capture() {
    do_unlink                      # always start from a clean state
    check_repo_writable || return 1
    echo "Redirecting APT downloads to $REPO_DIR ..."
    mkdir -p "$REPO_DIR/partial"
    {
        echo "Dir::Cache::Archives \"$REPO_DIR/\";"
        echo "Binary::apt::APT::Keep-Downloaded-Packages \"true\";"
        echo "APT::Keep-Downloaded-Packages \"true\";"
        # exFAT has no owners, so the unprivileged _apt user can't write there
        echo "APT::Sandbox::User \"root\";"
    } > "$CONF_FILE"
    # Belt and braces: if the redirect is ever lifted mid-build the existing
    # debs are still reachable through the local cache.
    link_debs
    create_failsafe
    echo "Done. Existing debs are reused and new downloads stay in the repo."
}

# Standard link: leaves capture mode alone (so a running capture continues).
do_link() {
    echo "Linking .deb files from the repo into the system cache..."
    link_debs
    apt_refresh
    echo "Links created ($(find "$LOCAL_CACHE" -maxdepth 1 -type l | wc -l))."
}

# Read-only link: capture is switched off first, so 'apt clean' only removes
# the symlinks and the real files on the USB are never touched.
do_link_ro() {
    do_unlink
    echo "Creating read-only symbolic links..."
    link_debs
    apt_refresh
    echo "Links created. 'apt clean' will only delete the links, not your repo files."
}

# Keep only the newest version of each package PER ARCHITECTURE.
# (The old version grouped by name only, so libc6 amd64 and libc6 i386 looked
#  like two versions of one package and one of them was deleted.)
do_prune() {
    echo "Scanning for old package versions in $REPO_DIR ..."
    [ -d "$REPO_DIR" ] || { echo "Error: repo folder not found: $REPO_DIR"; return 1; }

    local -A newest_ver=() newest_file=()
    local -a doomed=()
    local f base arch rest ver name key

    while IFS= read -r f; do
        base="${f%.deb}"                       # name_version_arch
        arch="${base##*_}"
        rest="${base%_*}"
        name="${rest%%_*}"
        ver="${rest#*_}"; ver="${ver//%3a/:}"  # APT stores the epoch colon as %3a
        key="$name|$arch"
        if [ -z "${newest_ver[$key]:-}" ]; then
            newest_ver[$key]="$ver"; newest_file[$key]="$f"
        elif dpkg --compare-versions "$ver" gt "${newest_ver[$key]}"; then
            doomed+=("${newest_file[$key]}")
            newest_ver[$key]="$ver"; newest_file[$key]="$f"
        else
            doomed+=("$f")
        fi
    done < <(cd "$REPO_DIR" && find . -maxdepth 1 -type f -name '*_*_*.deb' -printf '%f\n' | sort)

    if [ "${#doomed[@]}" -eq 0 ]; then echo "Nothing to prune."; return 0; fi

    local bytes=0 sz
    for f in "${doomed[@]}"; do
        sz="$(stat -c %s "$REPO_DIR/$f" 2>/dev/null || echo 0)"; bytes=$((bytes + sz))
        if [ "$DRY_RUN" -eq 1 ]; then echo "  Would delete: $f"
        else echo "  Deleting older version: $f"; rm -f "${REPO_DIR:?}/$f"; fi
    done
    local note=""; [ "$DRY_RUN" -eq 1 ] && note=" (dry run - nothing deleted)"
    echo "Pruning complete: ${#doomed[@]} file(s), $((bytes / 1048576)) MB${note}."
}

# A pulled USB or a killed download can leave empty / truncated debs. In capture
# mode APT re-fetches them, but in link-ro (offline) mode they break installs.
do_verify() {
    echo "Verifying .deb files in $REPO_DIR (this can take a while)..."
    local bad=0 total=0 f
    while IFS= read -r -d '' f; do
        total=$((total + 1))
        if [ ! -s "$f" ] || ! dpkg-deb --info "$f" >/dev/null 2>&1; then
            echo "  BAD: $(basename "$f")"; bad=$((bad + 1))
            [ "$DRY_RUN" -eq 1 ] || rm -f "$f"
        fi
    done < <(find "$REPO_DIR" -maxdepth 1 -type f -name '*.deb' -print0)
    echo "Checked $total file(s): $bad bad $([ "$DRY_RUN" -eq 1 ] && echo '(dry run)' || echo '(removed)')."
}

do_status() {
    local links dangling bytes
    links="$(find "$LOCAL_CACHE" -maxdepth 1 -type l 2>/dev/null | wc -l)"
    dangling="$(find "$LOCAL_CACHE" -maxdepth 1 -xtype l 2>/dev/null | wc -l)"
    bytes="$(find "$REPO_DIR" -maxdepth 1 -type f -name '*.deb' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%d", s/1048576}')"
    echo "Repo folder : $REPO_DIR  ($(repo_fstype))"
    echo "Debs in repo: $(repo_deb_count)  (${bytes:-0} MB)"
    echo "Mode        : $(capture_active && echo 'CAPTURE (APT writes to the repo)' || echo 'standard')"
    echo "Cache links : $links  (broken: $dangling)"
    [ "$dangling" -gt 0 ] && echo "              -> broken links mean the USB moved/unplugged; run -unlink then -link."
    [ -f "$FAILSAFE_SCRIPT" ] && echo "Fail-safe   : armed (will reset capture mode at next login)"
    return 0
}

# ============================================================
# 7. SCRIPTED MODE
# ============================================================
if [ -n "$ACTION" ]; then
    case "$ACTION" in
        capture) do_capture ;;
        link)    do_link ;;
        link-ro) do_link_ro ;;
        prune)   do_prune ;;
        unlink)  do_unlink ;;
        verify)  do_verify ;;
        status)  do_status ;;
    esac
    exit $?
fi

# ============================================================
# 8. INTERACTIVE MENU
# ============================================================
while true; do
    header
    echo " 1) CAPTURE : Save all new downloads to the repo"
    echo " 2) LINK    : Use existing repo files (standard)"
    echo " 3) LINK RO : Use repo files (protected from 'apt clean')"
    echo " 4) PRUNE   : Delete old versions (dry run first)"
    echo " 5) UNLINK  : Reset system & remove temp files"
    echo " 6) VERIFY  : Remove empty / corrupt debs"
    echo " 7) STATUS  : Show details"
    echo " 0) EXIT"
    echo "-----------------------------------------------"
    read -rp " Select an option [0-7]: " choice
    case "$choice" in
        1) do_capture ;;
        2) do_link ;;
        3) do_link_ro ;;
        4) DRY_RUN=1 do_prune
           read -rp "Delete these for real? [y/N] " yn
           [[ "$yn" =~ ^[Yy]$ ]] && DRY_RUN=0 do_prune ;;
        5) do_unlink ;;
        6) do_verify ;;
        7) do_status ;;
        0|q|Q) exit 0 ;;
        *) echo "Invalid choice."; sleep 1; continue ;;
    esac
    echo ""; read -rp "Press Enter to return..."
done
