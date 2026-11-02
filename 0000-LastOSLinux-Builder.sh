#!/bin/bash
# =============================================================================
#  LastOS LINUX BUILDER
# =============================================================================
#  One script that prepares the capture VM and builds the LastOS Linux ISO.
#  You type your sudo password ONCE - everything after that is hands-off.
#
#  Run it as your NORMAL user (not with sudo). Several steps must run as you
#  (gsettings, ~/.cache/wine, LLStore) while others need root; the script asks
#  for sudo once up front and uses it only where it is needed.
#
#  STAGES (run in this order; `all` = every one of them)
#    update    System updates FIRST. If a new kernel (or other reboot-needing
#              update) was installed, reboot and carry on automatically.
#    prepare   Download the latest Google Chrome .deb (used by the LLStore app)
#    store     Install / set up LLStore itself              (was 00_Install_LLStore)
#    apps      Updates, fonts, themes, presets, LLStore apps (was 01 / 02_AIO)
#    eggs      Install penguins-eggs (deb or AppImage)       (was 02_Install-Eggs)
#    iso       Clean up the system and build the ISO         (was 03_Build_ISO*)
#    resume    Continue a crashed / interrupted LLStore job  (was zzResume_Crashed)
#    repo      Open the repository cache manager menu
#
#    setup     = update + prepare + store + apps + eggs   (everything EXCEPT the ISO)
#    all       = setup + iso
#
#  USAGE
#    ./LastOSLinux-Builder.sh                 Menu (also what a double-click gives)
#    ./LastOSLinux-Builder.sh all             Full build, no questions
#    ./LastOSLinux-Builder.sh --aio all       Full build of the AIO (Wine) edition
#    ./LastOSLinux-Builder.sh apps eggs       Just those stages, in that order
#
#  OPTIONS
#    --standard | --aio     Edition. Picks the app preset AND the ISO recipe.
#                           (standard = LastOSLinux_Preset.ini + Build.ISO)
#                           (aio      = Linux_WINE-Preset-ForAIOBuilder.ini
#                                       + Build.ISO.With.Wine)
#    --preset FILE          Override the app preset (file in this folder)
#    --eggs auto|deb|appimage   How to install eggs. auto = deb if present,
#                           else AppImage.
#    --repo DIR             Repository cache folder (default: see below)
#    --manual-reboot        If a reboot is needed, stop and tell me instead of
#                           rebooting + resuming automatically.
#    --resume               Continue after a reboot (the script adds this itself).
#    -h, --help             Show this help
#
#  SUDO: you type the password once; the sudo timer is then kept alive until
#  the script ends. The script also starts LLStore's own sudo listener
#  (LL_Store/Tools/LLStore_Sudo.sh) as root itself, so LLStore finds it already
#  running and never opens its own password prompt (its sudo_script.sh would
#  try pkexec first, which ignores our sudo timer). The listener is restarted
#  if an LLStore run shuts it down, and stopped when this script ends. By
#  default a terminal window shows what it does, live; set
#  NO_LISTENER_TERMINAL=1 (or True) in SETTINGS below to run it hidden instead.
#  NOTHING is ever added to the system's sudo configuration, so nothing
#  sudo-related can be captured into the ISO by penguins-eggs.
#
#  REBOOTS: penguins-eggs builds the ISO's boot files from the RUNNING kernel,
#  so the running kernel must be the newest installed one. The script checks
#  right after the updates (stage `update`) and again before `eggs` and `iso`.
#  When a reboot is needed it saves where it was, reboots straight after a 15 s
#  countdown (Ctrl-C cancels), and re-opens itself in a terminal when you log
#  back in. You type the sudo password once more after the reboot - sudo does
#  not survive a reboot, and it must not.
#
#  EXPECTED LAYOUT  (this folder = "the builder folder")
#    LL_Store/                  LLStore to install              (stage: store)
#    LLAppsInstalls/            LLApp .tar files, incl. Clean.Build + Build.ISO
#    wine/                      Wine Mono/Gecko MSIs to pre-seed
#    DebianFixes/, Debian_Fixes.sh     Debian-only extras (optional)
#    penguins-eggs*amd64.deb  or  penguins-eggs-*-x86_64.AppImage
#    nodesource_setup.sh        NodeSource repo setup (deb method only)
#    ../../1-RepositoryLocalDebs/   offline .deb cache (see 000-LastOS-Manage-Repo.sh)
#
#  Every run is logged to  Logs/LastOSLinux-Build-<date>.log  in this folder.
# =============================================================================

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# -----------------------------------------------------------------------------
#  SETTINGS  (the only place you should need to edit)
# -----------------------------------------------------------------------------
LLSTORE_HOME="/opt/LastOS/LLStore"
LLSTORE_BIN="$LLSTORE_HOME/llstore"
# Where the LLStore sudo listener (LLStore_Sudo.sh, runs as root) shows itself:
#   0 (default)    = opens a TERMINAL WINDOW showing what it does, live, so you can watch
#   1 or True      = do NOT open a window; it runs hidden and its output only goes to the log file
NO_LISTENER_TERMINAL=0

LLSTORE_GROUP="lastos-users"         # group created by 'llstore -setup'; made active in THIS session without a re-login (see llstore_run)

CHROME_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
CHROME_DEB="google-chrome-stable_current_amd64.deb"

ICON_THEME="Windows-10-master"       # forced at ISO time (instead of the theme's own)
FAVORITE_APPS="['google-chrome.desktop', 'mintinstall.desktop', 'cinnamon-settings.desktop', 'llstore.desktop', 'org.gnome.Terminal.desktop', 'nemo.desktop']"

PRESET_STANDARD="LastOSLinux_Preset.ini"
PRESET_AIO="Linux_WINE-Preset-ForAIOBuilder.ini"
ISO_GLOB_STANDARD="LastOSLinux.Build.ISO_*_x64+x86_LLApp.tar"
ISO_GLOB_AIO="LastOSLinux.Build.ISO.With.Wine_*_x64+x86_LLApp.tar"
CLEAN_GLOB="LastOSLinux.Clean.Build_*_x64+x86_LLApp.tar"

BUILDER_FLAG="/tmp/LastOSLinux-Builder"    # "a build is running" marker other tools read
SUDO_DONE_FLAG="/tmp/LLSudoDone"           # "sudo-elevated stage finished" marker for LLStore
LLSTORE_SECURE="$HOME/.llstore_secure"     # LLStore's sudo hand-over folder (LLSudoHandShake / LLScript_Sudo.sh / LLSudoDone live here)
LEGACY_SUDOERS="/etc/sudoers.d/zz-lastos-builder"   # made by an early test version of this script; removed if found
REBOOT_COUNTDOWN=15                                  # seconds to cancel an automatic reboot
STATE_DIR="$HOME/.config/lastos-builder"             # where "continue after reboot" is remembered
STATE_FILE="$STATE_DIR/resume.conf"
RESUME_LAUNCHER="$STATE_DIR/resume.sh"
RESUME_DESKTOP="$HOME/.config/autostart/lastos-builder-resume.desktop"

# -----------------------------------------------------------------------------
#  DEFAULTS  (changed by the command-line options)
# -----------------------------------------------------------------------------
EDITION="standard"
PRESET_OVERRIDE=""
EGGS_METHOD="auto"
AUTO_RESUME=1
RESUME=0
JUST_REBOOTED=0
REBOOT_AFTER=0
REST_FROM=()
REST_AFTER=()
REPO_DIR=""
STAGES=()
RELAUNCHED=0
WARNINGS=()
KEEPALIVE_PID=""
LISTENER_PID=""
LISTENER_DIR=""
LOG_FILE=""
OS_ID=""

# -----------------------------------------------------------------------------
#  PRETTY OUTPUT
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
    C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else
    C_B=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_0=""
fi

step() { printf '\n%s==> %s%s\n' "$C_C$C_B" "$*" "$C_0"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s%s%s\n' "$C_G" "$*" "$C_0"; }
warn() { printf '    %sWARNING: %s%s\n' "$C_Y" "$*" "$C_0"; WARNINGS+=("$*"); }
err()  { printf '    %sERROR: %s%s\n' "$C_R" "$*" "$C_0" >&2; }
die()  { err "$*"; exit 1; }

# Run a command; if it fails, warn and carry on (the build should not stop for
# things like a font cache refresh). Failures are listed again at the very end.
try() { "$@" || { warn "Failed (continuing): $*"; return 1; }; }

# Print the documentation block at the top of this file
usage() { awk '/^# =+$/ { n++; next } n==1 || n==2 { sub(/^# ?/, ""); print } n>=3 { exit }' "$SCRIPT_PATH"; }

# -----------------------------------------------------------------------------
#  ARGUMENTS
# -----------------------------------------------------------------------------
ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --in-terminal)          RELAUNCHED=1 ;;   # added by our own relaunch
        --standard)             EDITION="standard" ;;
        --aio)                  EDITION="aio" ;;
        --preset)               PRESET_OVERRIDE="${2:-}"; shift || true ;;
        --eggs)                 EGGS_METHOD="${2:-auto}"; shift || true ;;
        --repo)                 REPO_DIR="${2:-}"; shift || true ;;
        --manual-reboot)        AUTO_RESUME=0 ;;
        --resume)               RESUME=1 ;;
        -h|--help)              usage; exit 0 ;;
        update|prepare|store|apps|eggs|iso|resume|repo) STAGES+=("$1") ;;
        setup)                  STAGES+=(update prepare store apps eggs) ;;
        all)                    STAGES+=(update prepare store apps eggs iso) ;;
        *)                      echo "Unknown option or stage: $1"; usage; exit 1 ;;
    esac
    shift
done

case "$EGGS_METHOD" in auto|deb|appimage) ;; *) die "--eggs must be auto, deb or appimage" ;; esac

set_edition_vars() {
    case "$EDITION" in
        aio)      PRESET="${PRESET_OVERRIDE:-$PRESET_AIO}";      ISO_GLOB="$ISO_GLOB_AIO" ;;
        *)        PRESET="${PRESET_OVERRIDE:-$PRESET_STANDARD}"; ISO_GLOB="$ISO_GLOB_STANDARD" ;;
    esac
}
set_edition_vars

# -----------------------------------------------------------------------------
#  TERMINAL DETECTION
#  Double-clicked from a file manager? Re-open ourselves inside a terminal so
#  there is somewhere to type the sudo password and read the output.
# -----------------------------------------------------------------------------
if [ ! -t 0 ] && [ "$RELAUNCHED" -eq 0 ]; then
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
        gnome-terminal)               exec gnome-terminal -- bash "$SCRIPT_PATH" --in-terminal "${ORIG_ARGS[@]}" ;;
        xfce4-terminal|mate-terminal) exec "$TERMINAL" -x bash "$SCRIPT_PATH" --in-terminal "${ORIG_ARGS[@]}" ;;
        *)                            exec "$TERMINAL" -e bash "$SCRIPT_PATH" --in-terminal "${ORIG_ARGS[@]}" ;;
    esac
fi

if [ "$EUID" -eq 0 ]; then
    echo "Please run this as your normal user, NOT with sudo."
    echo "It asks for your password once itself and uses sudo only where needed."
    [ "$RELAUNCHED" -eq 1 ] && read -rp "Press Enter to close..." _
    exit 1
fi

# -----------------------------------------------------------------------------
#  SUDO - ask ONCE, then stay authenticated for the whole build
# -----------------------------------------------------------------------------
sudo_begin() {
    step "Administrator access (you will only be asked once)"
    sudo -v || die "Authentication failed."

    # An early test version of this script could leave a passwordless-sudo rule
    # behind. It must never exist in an ISO, so remove it if it is there.
    if [ -f "$LEGACY_SUDOERS" ]; then
        sudo rm -f "$LEGACY_SUDOERS" && ok "Removed a leftover passwordless-sudo rule."
    fi

    # Keep-alive: refresh the sudo timer every 40 s until this script exits.
    ( while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 40; done ) &
    KEEPALIVE_PID=$!
    ok "sudo will be kept alive for the whole build."

    start_sudo_listener
}

# -----------------------------------------------------------------------------
#  LLStore SUDO LISTENER - run it ourselves so LLStore never asks for a password
#  LLStore elevates by dropping a script in $LLSTORE_SECURE and waiting for a
#  root listener (LLStore_Sudo.sh) to run it. If none answers its handshake it
#  opens a new terminal and runs sudo_script.sh, which tries pkexec FIRST - a
#  separate password prompt our sudo timer cannot satisfy. So: start the very
#  same listener here, already root, using the sudo session we already have.
#  A supervisor restarts it whenever an LLStore run (one started without
#  -KeepSudo) tells it to quit, and stops it for good when this script ends.
# -----------------------------------------------------------------------------
llstore_sudo_script() {
    local c
    for c in "$SCRIPT_DIR/LL_Store/Tools/LLStore_Sudo.sh" "$LLSTORE_HOME/Tools/LLStore_Sudo.sh"; do
        [ -f "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

stages_need_llstore() {
    local s
    for s in "${STAGES[@]}"; do
        case "$s" in store|apps|iso|resume) return 0 ;; esac
    done
    return 1
}

# Open a new terminal window that shows the listener's output live (tail -f; it ends by itself when the listener
# does). Closing the window changes nothing - the listener runs in the builder's session. Same terminal order and
# per-terminal syntax LLStore itself uses. Returns 1 if there is no terminal emulator.
#   $1 = pid of the listener pipeline   $2 = its output file   $3 = folder for the little launcher script
open_listener_window() {
    local pid="$1" log="$2" dir="$3" launcher t qp ql
    launcher="$dir/show-listener.sh"
    printf -v qp '%q' "$pid"; printf -v ql '%q' "$log"
    cat > "$launcher" <<VIEW
#!/bin/bash
printf '\033]0;LLStore sudo listener (LastOS builder)\007'
echo "LLStore sudo listener - output of LLStore's root (sudo) scripts, live."
echo "Closing this window changes nothing; it ends by itself when the builder finishes."
echo
exec tail -n +1 -f --pid=$qp $ql
VIEW
    for t in ptyxis gnome-terminal konsole xfce4-terminal mate-terminal lxterminal qterminal tilix terminator \
             alacritty kitty foot x-terminal-emulator xterm; do
        command -v "$t" >/dev/null 2>&1 || continue
        case "$t" in
            gnome-terminal)                       nohup "$t" --wait -- bash "$launcher" </dev/null >/dev/null 2>&1 & ;;
            ptyxis|mate-terminal|tilix|alacritty) nohup "$t" -- bash "$launcher" </dev/null >/dev/null 2>&1 & ;;
            terminator)                           nohup "$t" -x bash "$launcher" </dev/null >/dev/null 2>&1 & ;;
            xfce4-terminal|lxterminal|qterminal)  nohup "$t" -e "bash '$launcher'" </dev/null >/dev/null 2>&1 & ;;
            kitty|foot)                           nohup "$t" bash "$launcher" </dev/null >/dev/null 2>&1 & ;;
            *)                                    nohup "$t" -e bash "$launcher" </dev/null >/dev/null 2>&1 & ;;
        esac
        return 0
    done
    return 1
}

start_sudo_listener() {
    stages_need_llstore || return 0
    local script; script="$(llstore_sudo_script)" || { warn "LLStore_Sudo.sh not found - LLStore may ask for the password itself."; return 0; }
    step "LLStore sudo listener (so LLStore does not ask for the password)"

    # The hand-over folder must belong to YOU (LLStore writes into it) - never root.
    if [ -d "$LLSTORE_SECURE" ] && [ ! -O "$LLSTORE_SECURE" ]; then
        sudo chown -R "$USER": "$LLSTORE_SECURE" || warn "Could not take back ownership of $LLSTORE_SECURE"
    fi
    mkdir -p "$LLSTORE_SECURE" && chmod 700 "$LLSTORE_SECURE"

    # A listener left behind by an earlier run / a crashed LLStore would double-run scripts
    sudo -n pkill -f '[L]LStore_Sudo\.sh' 2>/dev/null && sleep 0.5
    rm -f "$LLSTORE_SECURE/LLSudoDone" "$LLSTORE_SECURE/LLSudo" "$LLSTORE_SECURE/LLBuilderStop"

    # LLStore writes LLSudoDone (= "listener, quit") whenever one of its runs ends without -KeepSudo - e.g. '-setup',
    # which relaunches itself and straight away needs the listener again. Restarting takes longer than LLStore waits
    # for its handshake (0.6 s), so it would open its own password prompt. So run a COPY of the listener that ignores
    # LLSudoDone and only quits on our own flag file (LLBuilderStop). The original in LL_Store/Tools is not touched.
    # (Same file name, in its own folder, so stop_sudo_listener's pgrep/pkill still match it.)
    LISTENER_DIR="$(mktemp -d /tmp/llstore_listener.XXXXXX)"
    sed 's/while \[ ! -f "\$DONE_FLAG" \]/while [ ! -f "$BASE_DIR\/LLBuilderStop" ]/' "$script" > "$LISTENER_DIR/LLStore_Sudo.sh"
    if grep -q LLBuilderStop "$LISTENER_DIR/LLStore_Sudo.sh"; then
        script="$LISTENER_DIR/LLStore_Sudo.sh"
    else
        warn "LLStore_Sudo.sh has changed - using it as is (LLStore may still ask for the password after some runs)."
        rm -f "$LISTENER_DIR/LLStore_Sudo.sh"
    fi

    # Show the listener's output in a terminal window? (default yes - see NO_LISTENER_TERMINAL in SETTINGS)
    # The listener itself must stay in THIS session: sudo's cached password belongs to the terminal it was typed in,
    # so a listener started inside a new window would ask for the password again. The window is just a live view.
    local visible=1 listenlog="$LISTENER_DIR/listener.log"
    case "${NO_LISTENER_TERMINAL,,}" in 1|true|yes|on) visible=0 ;; esac
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || visible=0          # no desktop session -> nowhere to open a window
    : > "$listenlog"

    # Supervisor: (re)start the root listener; if THIS script dies without cleaning up, tell the listener to quit.
    # (/proc test, not kill -0: the sudo process is root's, so a plain user cannot signal it.)
    (
        while kill -0 "$$" 2>/dev/null; do
            # -E + HOME/USER/LOGNAME: the elevated scripts must see YOU (Wine paths, setup_lastos_group.sh, ...), not root.
            # (sudo itself also sets SUDO_USER, which setup_lastos_group.sh uses to pick the user to add to the group.)
            { { sudo -n -E env HOME="$HOME" USER="$USER" LOGNAME="$USER" bash "$script" \
                  || sudo -n env HOME="$HOME" USER="$USER" LOGNAME="$USER" bash "$script"; } 2>&1 \
              | if [ "$visible" -eq 1 ]; then tee -a "$listenlog" >> "${LOG_FILE:-/dev/null}"; else cat >> "${LOG_FILE:-/dev/null}"; fi; } &
            lp=$!
            if [ "$visible" -eq 1 ]; then
                open_listener_window "$lp" "$listenlog" "$LISTENER_DIR" \
                    || { visible=0; echo "[builder] No terminal found for the listener window - it keeps running hidden (output in this log)." >> "${LOG_FILE:-/dev/null}"; }
            fi
            while kill -0 "$$" 2>/dev/null && [ -d "/proc/$lp" ]; do sleep 0.2; done
            kill -0 "$$" 2>/dev/null || { echo Unlock > "$LLSTORE_SECURE/LLBuilderStop"; echo Unlock > "$LLSTORE_SECURE/LLSudoDone"; break; }
            sleep 0.2
        done
    ) &
    LISTENER_PID=$!

    # Same handshake LLStore does: the listener deletes this file once it is up
    local i
    echo HandShake > "$LLSTORE_SECURE/LLSudoHandShake"
    for ((i = 0; i < 100; i++)); do
        [ -f "$LLSTORE_SECURE/LLSudoHandShake" ] || break
        sleep 0.1
    done
    if [ -f "$LLSTORE_SECURE/LLSudoHandShake" ]; then
        rm -f "$LLSTORE_SECURE/LLSudoHandShake"
        warn "LLStore sudo listener did not answer - LLStore may ask for the password itself. See the log."
    else
        if [ "$visible" -eq 1 ]; then ok "Listener running as root (output shown in a terminal window) - LLStore will use it without prompting."
        else ok "Listener running as root (hidden, output in the log) - LLStore will use it without prompting."; fi
    fi
}

stop_sudo_listener() {
    [ -n "$LISTENER_PID" ] || return 0
    kill "$LISTENER_PID" 2>/dev/null; LISTENER_PID=""      # stop restarting it
    echo Unlock > "$LLSTORE_SECURE/LLBuilderStop" 2>/dev/null   # ask it to quit
    echo Unlock > "$LLSTORE_SECURE/LLSudoDone" 2>/dev/null       # (and the original listener, if the copy could not be made)
    local i
    for ((i = 0; i < 30; i++)); do pgrep -f '[L]LStore_Sudo\.sh' >/dev/null 2>&1 || break; sleep 0.1; done
    sudo -n pkill -f '[L]LStore_Sudo\.sh' 2>/dev/null       # still there? make sure
    rm -f "$LLSTORE_SECURE/LLSudoDone" "$LLSTORE_SECURE/LLSudoHandShake" "$LLSTORE_SECURE/LLBuilderStop"
    [ -z "$LISTENER_DIR" ] || rm -rf "$LISTENER_DIR"; LISTENER_DIR=""
}

# Runs on EVERY way out: normal finish, error, Ctrl-C, kill, closed window.
cleanup() {
    local rc=$?
    trap '' PIPE                     # a dead log pipe must not kill us half-way through
    rm -f "$BUILDER_FLAG"
    print_summary "$rc"
    stop_sudo_listener               # nothing may keep running as root after the build
    local reboot_failed=0
    if [ "$REBOOT_AFTER" -eq 1 ]; then
        sync; sleep 2                # let the log writer finish before the machine goes down
        do_reboot || reboot_failed=1 # sudo is still alive here (keep-alive is stopped below)
    fi
    [ -n "$KEEPALIVE_PID" ] && kill "$KEEPALIVE_PID" 2>/dev/null
    # Keep the window open when we finished normally OR when the reboot did not happen
    if [ "$RELAUNCHED" -eq 1 ] && { [ "$REBOOT_AFTER" -eq 0 ] || [ "$reboot_failed" -eq 1 ]; }; then
        read -rp "Press Enter to close this window..." _ 2>/dev/null </dev/tty
    fi
    exit "$rc"
}

# Reboot right now (the 15 s Ctrl-C countdown already happened). Tries three ways
# and SHOWS any error - the old version scheduled "shutdown -r +1" with its errors
# hidden, then closed the window, so a failure was invisible.
do_reboot() {
    local c
    for c in "systemctl reboot" "reboot" "shutdown -r now"; do
        # shellcheck disable=SC2086
        if sudo -n $c; then
            sleep 30                 # the system should go down inside this wait
            break
        fi
    done
    err "The automatic reboot did not start. Please reboot manually - the build continues by itself after you log in."
    return 1
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

print_summary() {
    local rc="$1"
    echo
    echo "============================================================"
    if [ "$REBOOT_AFTER" -eq 1 ]; then
        printf '%s  REBOOTING NOW - the build continues automatically after you log in.%s\n' "$C_Y$C_B" "$C_0"
    elif [ "$rc" -eq 0 ] && [ "${#STAGES[@]}" -gt 0 ]; then
        printf '%s  FINISHED: %s%s\n' "$C_G$C_B" "${STAGES[*]}" "$C_0"
    elif [ "$rc" -ne 0 ]; then
        printf '%s  STOPPED (exit code %s)%s\n' "$C_R$C_B" "$rc" "$C_0"
    fi
    if [ "${#WARNINGS[@]}" -gt 0 ]; then
        printf '%s  %d warning(s) to look at:%s\n' "$C_Y" "${#WARNINGS[@]}" "$C_0"
        printf '    - %s\n' "${WARNINGS[@]}"
    fi
    [ -n "$LOG_FILE" ] && echo "  Log: $LOG_FILE"
    echo "============================================================"
}

# -----------------------------------------------------------------------------
#  LOGGING  (screen + file, colour codes stripped from the file)
# -----------------------------------------------------------------------------
start_logging() {
    local dir="$SCRIPT_DIR/Logs"
    mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ] || dir="$HOME"
    LOG_FILE="$dir/LastOSLinux-Build-$(date +%Y%m%d-%H%M%S).log"
    # The logger ignores Ctrl-C/kill so it stays alive to record the clean-up messages.
    exec > >(trap '' INT TERM HUP; exec tee >(sed -u 's/\x1b\[[0-9;]*[A-Za-z]//g' >> "$LOG_FILE")) 2>&1
}

# -----------------------------------------------------------------------------
#  HELPERS
# -----------------------------------------------------------------------------

# Non-interactive apt-get: no prompts, keeps your existing config files, waits
# for the dpkg lock (Mint's updater likes to grab it), retries flaky downloads.
apt_get() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 "$@"
}

# Install a list of packages, skipping any this distro doesn't have, instead
# of letting one unknown name abort the whole list.
apt_install_available() {
    local p avail=()
    for p in "$@"; do
        if apt-cache show "$p" >/dev/null 2>&1; then avail+=("$p"); else warn "Package not available here, skipped: $p"; fi
    done
    [ "${#avail[@]}" -gt 0 ] || return 0
    apt_get install "${avail[@]}"
}

pkg_installed() { dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'; }

# Newest file matching a glob (version-sorted, so v10 beats v9). Prints nothing if none.
newest_match() { compgen -G "$1" | sort -V | tail -n 1; }

# Distro ID (debian, linuxmint, ubuntu ...) without leaking os-release variables into this shell.
# shellcheck source=/dev/null
os_id() { ( . /etc/os-release 2>/dev/null; echo "${ID:-unknown}" ); }

# Make a directory under /opt the way its parent has it (owner/group/mode).
ensure_dir() {
    [ -d "$1" ] && return 0
    sudo mkdir -p "$1" && sudo chown --reference="$(dirname "$1")" "$1" &&
        sudo chmod --reference="$(dirname "$1")" "$1"
}

# Copy a file into a directory (optionally renaming it). Tries as you first,
# falls back to sudo and then gives the copy the folder's owner/group so
# LLStore (running as you, in the LLStore group) can still edit it later.
put_file() {
    local src="$1" destdir="$2" name="${3:-$(basename "$1")}"
    cp -f "$src" "$destdir/$name" 2>/dev/null && return 0
    sudo cp -f "$src" "$destdir/$name" || return 1
    sudo chown --reference="$destdir" "$destdir/$name" 2>/dev/null
    sudo chmod 664 "$destdir/$name"
}

# gsettings helpers. They silently skip a key that doesn't exist on this
# system (e.g. MATE schemas on a Cinnamon-only install) instead of printing errors.
gs_key_exists() { gsettings list-keys "$1" 2>/dev/null | grep -qxF "$2"; }

gset() {                     # as the current user
    gs_key_exists "$1" "$2" || return 0
    gsettings set "$1" "$2" "$3" 2>/dev/null || warn "gsettings set $1 $2 failed"
}

gset_root() {                # as root - root has no desktop session, so give it a private one
    gs_key_exists "$1" "$2" || return 0
    if command -v dbus-run-session >/dev/null 2>&1; then
        sudo -H dbus-run-session -- gsettings set "$1" "$2" "$3" 2>/dev/null
    else
        sudo -H gsettings set "$1" "$2" "$3" 2>/dev/null
    fi || warn "root gsettings set $1 $2 failed"
}

# Locate the repo folder and manager script, and call the manager as root.
resolve_repo() {
    if [ -z "$REPO_DIR" ]; then
        local c; c="$(readlink -f "$SCRIPT_DIR/../../1-RepositoryLocalDebs" 2>/dev/null)"
        [ -d "$c" ] && REPO_DIR="$c"
    fi
}

find_repo_manager() {
    local c
    for c in "$SCRIPT_DIR/000-LastOS-Manage-Repo.sh" "$SCRIPT_DIR/0-LastOS-Manage-Repo.sh" \
             "${REPO_DIR:+$REPO_DIR/0-LastOS-Manage-Repo.sh}"; do
        [ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

repo_manager() {             # repo_manager <manager args...>
    local mgr; mgr="$(find_repo_manager)" || { warn "Repo manager script not found - offline cache skipped."; return 1; }
    resolve_repo
    local args=(); [ -n "$REPO_DIR" ] && args+=(--repo "$REPO_DIR")
    sudo bash "$mgr" "${args[@]}" "$@"
}

# 'llstore -setup' can hand over to a detached copy of itself (sg lastos-users ..., needed the first time, when the
# lastos-users group is created) and exit at once while the real install carries on in the background. Wait for that
# instead of racing it (it used to stop here with "LLStore is not installed" while the install was still running).
wait_llstore_setup() {
    local i quiet=0 shown=0
    for ((i = 0; i < 900; i++)); do                                   # up to 15 minutes
        if pgrep -f 'llstore[^ ]* -setup' >/dev/null 2>&1; then
            quiet=0
            [ "$shown" -eq 0 ] && { info "LLStore setup is still running in the background - waiting for it to finish..."; shown=1; }
        else
            quiet=$((quiet + 1))
            [ "$quiet" -ge 4 ] && [ -x "$LLSTORE_BIN" ] && return 0     # nothing running for 4 s and it is installed
            [ "$quiet" -ge 20 ] && return 0                              # nothing ever started - need_llstore reports it
        fi
        sleep 1
    done
    warn "Gave up waiting for LLStore setup after 15 minutes."
}

need_llstore() {
    [ -x "$LLSTORE_BIN" ] || die "LLStore is not installed at $LLSTORE_BIN - run the 'store' stage first."
}

# 'llstore -setup' creates the LLStore group, but a group added to you NOW is not
# active in this login session until you log out and in (or start a new shell
# with that group). So: make sure you are a member, then run every LLStore call
# through 'sg', which starts it with the group already applied. No re-run, no
# re-login. Does nothing if the group doesn't exist (e.g. an older LLStore).
ensure_llstore_group() {
    getent group "$LLSTORE_GROUP" >/dev/null 2>&1 || { info "Group '$LLSTORE_GROUP' not present - nothing to apply."; return 0; }
    if id -nG "$USER" | tr ' ' '\n' | grep -qxF "$LLSTORE_GROUP"; then
        info "You are already a member of '$LLSTORE_GROUP'."
    else
        sudo usermod -aG "$LLSTORE_GROUP" "$USER" && ok "Added $USER to '$LLSTORE_GROUP'." \
            || warn "Could not add $USER to '$LLSTORE_GROUP'."
    fi
}

shell_quote() { local s; for s in "$@"; do printf "'%s' " "${s//\'/\'\\\'\'}"; done; }   # POSIX-safe quoting for sg -c

# Run LLStore with the LLStore group active in THIS session (see above)
llstore_run() {
    if getent group "$LLSTORE_GROUP" >/dev/null 2>&1 \
       && id -nG "$USER" | tr ' ' '\n' | grep -qxF "$LLSTORE_GROUP" \
       && ! id -nG | tr ' ' '\n' | grep -qxF "$LLSTORE_GROUP" \
       && command -v sg >/dev/null 2>&1; then
        sg "$LLSTORE_GROUP" -c "exec $(shell_quote "$LLSTORE_BIN" "$@")"
    else
        "$LLSTORE_BIN" "$@"
    fi
}

# Install an LLStore preset list quietly (-i install, -p preset, -q quit when done)
llstore_preset() { llstore_run -i -p -q -KeepSudo "$1"; }

# =============================================================================
#  KERNEL / REBOOT HANDLING
#  penguins-eggs builds the ISO's boot files from the RUNNING kernel. If an
#  update installed a newer kernel and we have not rebooted, the ISO won't boot.
# =============================================================================
running_kernel() { uname -r; }
newest_kernel()  { find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -n 1; }
kernel_is_stale() { local n; n="$(newest_kernel)"; [ -n "$n" ] && [ "$n" != "$(running_kernel)" ]; }

# This run's options plus the given stages, ready to paste on a command line
resume_command() {
    local flags=""
    [ "$EDITION" = "aio" ] && flags+=" --aio"
    [ -n "$PRESET_OVERRIDE" ] && flags+=" --preset $(printf '%q' "$PRESET_OVERRIDE")"
    [ "$EGGS_METHOD" != "auto" ] && flags+=" --eggs $EGGS_METHOD"
    [ -n "$REPO_DIR" ] && flags+=" --repo $(printf '%q' "$REPO_DIR")"
    printf '%q%s %s' "$SCRIPT_PATH" "$flags" "$*"
}

# Remember what is left to do and arrange for it to start by itself at login.
# Written to your home folder (not the USB); removed again the moment it runs.
save_resume_state() {
    mkdir -p "$STATE_DIR" "$(dirname "$RESUME_DESKTOP")"
    {
        printf 'R_STAGES=(%s)\n' "$(printf '%q ' "$@")"
        printf 'R_EDITION=%q\nR_PRESET=%q\nR_EGGS=%q\nR_REPO=%q\n' "$EDITION" "$PRESET_OVERRIDE" "$EGGS_METHOD" "$REPO_DIR"
    } > "$STATE_FILE"

    # The builder may live on a USB that mounts a moment after login - wait for it.
    cat > "$RESUME_LAUNCHER" <<LAUNCHER
#!/bin/bash
# Started at login by the LastOS builder to continue after a reboot.
for _ in \$(seq 1 120); do [ -f "$SCRIPT_PATH" ] && break; sleep 2; done
if [ ! -f "$SCRIPT_PATH" ]; then
    command -v notify-send >/dev/null && notify-send "LastOS builder" "Could not find $SCRIPT_PATH - run it with --resume"
    exit 1
fi
exec bash "$SCRIPT_PATH" --resume
LAUNCHER
    chmod +x "$RESUME_LAUNCHER"
    cat > "$RESUME_DESKTOP" <<AUTOSTART
[Desktop Entry]
Type=Application
Name=LastOS builder (continue after reboot)
Exec=bash "$RESUME_LAUNCHER"
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=8
AUTOSTART
}

clear_resume_state() { rm -f "$STATE_FILE" "$RESUME_LAUNCHER" "$RESUME_DESKTOP"; rmdir "$STATE_DIR" 2>/dev/null; }

# Called by --resume: load the saved stage list and options
load_resume_state() {
    [ -f "$STATE_FILE" ] || die "Nothing to resume (no saved state in $STATE_DIR)."
    # shellcheck source=/dev/null
    . "$STATE_FILE"
    STAGES=("${R_STAGES[@]}"); EDITION="$R_EDITION"; PRESET_OVERRIDE="$R_PRESET"
    EGGS_METHOD="$R_EGGS"; REPO_DIR="$R_REPO"
    clear_resume_state          # first thing: it must never trigger twice
    JUST_REBOOTED=1
}

# Reboot now and carry on with "$@" afterwards (or just explain, with --manual-reboot).
reboot_and_resume() {
    local why="$1"; shift
    step "A reboot is needed: $why"
    if [ "$#" -eq 0 ]; then
        warn "Reboot before building the ISO ($why)."; return 0
    fi
    if [ "$AUTO_RESUME" -eq 0 ]; then
        info "Please reboot, then continue with:"
        info "  $(resume_command "$@")"
        exit 0
    fi
    info "Still to do afterwards: $*"
    info "The build continues by itself when you log in again."
    local i
    for ((i = REBOOT_COUNTDOWN; i > 0; i--)); do
        printf '\r    Rebooting in %2d s - press Ctrl-C to cancel ' "$i"; sleep 1
    done
    echo
    # Only now (a Ctrl-C above must leave nothing behind):
    save_resume_state "$@"
    repo_manager -unlink || true       # capture mode OFF, so the fail-safe prompt and a not-yet-mounted USB can't upset the boot
    REBOOT_AFTER=1
    exit 0
}

# mode "any"    : newer kernel OR any update flagged as needing a reboot
# mode "kernel" : newer kernel only (what actually breaks the ISO)
# Remaining args: the stages to run after the reboot.
reboot_check() {
    local mode="$1"; shift
    local why=""
    if kernel_is_stale; then
        why="kernel $(newest_kernel) is installed but $(running_kernel) is running"
    elif [ "$mode" = "any" ] && [ -f /var/run/reboot-required ]; then
        why="updates were installed that need a reboot"
    else
        JUST_REBOOTED=0; return 0
    fi
    if [ "$JUST_REBOOTED" -eq 1 ]; then
        # We already rebooted once for this and it did not help (e.g. GRUB boots an older entry)
        JUST_REBOOTED=0
        warn "Still not on the newest kernel after rebooting: $why"
        local yn; read -rp "    Continue anyway? [y/N] " yn
        [[ "$yn" =~ ^[Yy]$ ]] || die "Stopped. Boot the newest kernel from the GRUB menu and run again."
        return 0
    fi
    reboot_and_resume "$why" "$@"
}

# Update the system (quick when there is nothing to do)
system_update() {
    try apt_get update
    try apt_get --with-new-pkgs upgrade
    try apt_get autoremove
}

# =============================================================================
#  STAGE: update  -  updates FIRST, so a new kernel is running before we build
# =============================================================================
stage_update() {
    step "System updates (first, so any new kernel is running before the build)"
    repo_manager -capture --no-update || true     # kernel debs get cached on the USB too
    system_update
    reboot_check any "${REST_AFTER[@]}"
}

# =============================================================================
#  STAGE: prepare  -  download the newest Google Chrome installer
#  (The LLStore "google chrome" app installs from a copy in /tmp - see 'apps'.)
# =============================================================================
# True if the Chrome .deb in this folder is valid AND matches the server's copy
# (same size, and not older than the server's Last-Modified when it gives one).
# Any doubt (offline, no size header) returns false, so the download is tried.
chrome_is_current() {
    local f="$SCRIPT_DIR/$CHROME_DEB" hdr rsize rmod rts lts
    [ -s "$f" ] && dpkg-deb --info "$f" >/dev/null 2>&1 || return 1
    hdr="$(wget --spider -S --timeout=20 --tries=2 "$CHROME_URL" 2>&1)" || return 1
    rsize="$(printf '%s\n' "$hdr" | tr -d '\r' | awk 'tolower($1)=="content-length:" {v=$2} END {print v}')"
    [ -n "$rsize" ] && [ "$rsize" = "$(stat -c %s "$f")" ] || return 1
    rmod="$(printf '%s\n' "$hdr" | tr -d '\r' | sed -n 's/^ *[Ll]ast-[Mm]odified: *//p' | tail -n 1)"
    if [ -n "$rmod" ]; then
        rts="$(date -d "$rmod" +%s 2>/dev/null)" || return 1
        lts="$(stat -c %Y "$f")"
        [ $((lts + 5)) -ge "$rts" ] || return 1      # 5 s slack for USB filesystem timestamp rounding
    fi
    return 0
}

stage_prepare() {
    step "Download the latest Google Chrome installer"
    command -v wget >/dev/null 2>&1 || apt_get install wget || die "wget is needed and could not be installed."

    # Already the latest? Compare the server's size/date with our copy first.
    # (wget -N alone re-downloads whenever Google's reply has no Last-Modified.)
    if chrome_is_current; then
        ok "Chrome installer is already the latest - not downloading again."
        return 0
    fi

    # -N: only download if the server copy is newer than the one we already have
    if wget -q --show-progress -N -P "$SCRIPT_DIR" "$CHROME_URL"; then
        if dpkg-deb --info "$SCRIPT_DIR/$CHROME_DEB" >/dev/null 2>&1; then
            ok "Chrome installer is ready: $CHROME_DEB"
        else
            warn "$CHROME_DEB looks corrupt - delete it and run 'prepare' again."
        fi
    elif [ -f "$SCRIPT_DIR/$CHROME_DEB" ]; then
        warn "Chrome download failed - using the copy already in the folder."
    else
        warn "Chrome download failed and there is no local copy."
    fi
}

# =============================================================================
#  STAGE: store  -  install and set up LLStore
# =============================================================================
stage_store() {
    step "Install LLStore"
    local ll="$SCRIPT_DIR/LL_Store/llstore"
    [ -f "$ll" ] || die "LLStore not found: $ll"
    [ -x "$ll" ] || chmod +x "$ll" 2>/dev/null

    # NOTE: no -KeepSudo here. The LLStore being replaced may be an old one
    # that does not know the lastos-users group yet.
    env GDK_BACKEND=x11 "$ll" -setup || warn "LLStore -setup returned an error."
    wait_llstore_setup
    need_llstore
    ensure_llstore_group     # new group applies to the rest of this run - no second run or re-login needed
}

# =============================================================================
#  STAGE: apps  -  updates, fonts, themes and every app in the preset
# =============================================================================
stage_apps() {
    need_llstore
    local preset_file="$SCRIPT_DIR/$PRESET"
    [ -f "$preset_file" ] || die "Preset not found: $preset_file"

    step "Starting app install (edition: $EDITION, preset: $PRESET)"
    echo "Builder Running" > "$BUILDER_FLAG"     # so other tools know a build is in progress
    rm -f "$SUDO_DONE_FLAG"                      # a stale marker from an earlier run would mislead LLStore

    # --- Offline package cache ------------------------------------------------
    step "Switch the package cache to capture mode"
    # Existing debs on the USB are reused; anything new is saved there.
    repo_manager -capture --no-update || true

    # --- System updates -------------------------------------------------------
    step "System updates (quick if the 'update' stage already did them)"
    system_update

    # --- Wine downloads (Mono/Gecko MSIs) for you AND for every new user ------
    step "Pre-seed Wine downloads"
    if [ -d "$SCRIPT_DIR/wine" ]; then
        mkdir -p "$HOME/.cache/wine" && cp -r "$SCRIPT_DIR/wine/." "$HOME/.cache/wine/"
        sudo mkdir -p /etc/skel/.cache/wine
        sudo cp -r "$SCRIPT_DIR/wine/." /etc/skel/.cache/wine/
        sudo chmod -R a+rX /etc/skel/.cache/wine
        ok "Wine MSIs copied to your cache and /etc/skel."
    else
        warn "No wine/ folder next to the script - Wine will download Mono/Gecko itself."
    fi

    # --- Chrome installer for the LLStore Chrome app --------------------------
    if [ -f "$SCRIPT_DIR/$CHROME_DEB" ]; then
        cp -f "$SCRIPT_DIR/$CHROME_DEB" /tmp/
    else
        warn "$CHROME_DEB not found - run the 'prepare' stage first or Chrome will be skipped."
    fi

    # --- LLStore settings & app locations -------------------------------------
    step "Configure LLStore"
    # Tell LLStore where the LLApp installers are. Generated fresh every run, so
    # no hard-coded path (the old sed on an '_Orig.ini' file is no longer needed).
    local tmpd; tmpd="$(mktemp -d)"
    printf '%s\n' "$SCRIPT_DIR/LLAppsInstalls" > "$tmpd/LLL_Store_Linux_Manual_Locations.ini"
    put_file "$tmpd/LLL_Store_Linux_Manual_Locations.ini" "$LLSTORE_HOME" || warn "Could not write the LLStore locations file."
    rm -rf "$tmpd"
    if [ -f "$SCRIPT_DIR/LLL_Settings.ini" ]; then
        put_file "$SCRIPT_DIR/LLL_Settings.ini" "$LLSTORE_HOME" || warn "Could not copy LLL_Settings.ini."
    fi

    # --- Icons and fonts FIRST - if left until later they can crash other installs
    step "Icons and fonts (installed first on purpose)"
    try llstore_preset "$SCRIPT_DIR/Icons_Preset.ini"
    try llstore_preset "$SCRIPT_DIR/Fonts_Preset.ini"

    step "Extra fonts (VLC / Java need these) and Microsoft core fonts"
    apt_install_available fonts-freefont-ttf fonts-dejavu-extra fonts-ipafont-gothic \
        fonts-ipafont-mincho fonts-wqy-microhei fonts-wqy-zenhei fonts-indic \
        libsdl-ttf2.0-0 libsdl2-ttf-2.0-0
    # Accept the MS fonts EULA in advance so the install never stops to ask
    echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | sudo debconf-set-selections
    try apt_install_available ttf-mscorefonts-installer
    # Rebuild font caches (user, then system). Harmless if it fails - a bad font
    # file may need tracking down.
    fc-cache -f >/dev/null 2>&1 || true
    sudo fc-cache -f >/dev/null 2>&1 || true
    # default-jre and vlc are too big to ship here - they are in the preset; the fonts above stop them crashing.

    # --- Desktop tweaks -------------------------------------------------------
    step "Desktop tweaks"
    try apt_install_available numlockx
    numlockx on 2>/dev/null || true                          # NumLock on by default

    local fx=() p
    for p in firefox firefox-esr firefox-locale-en; do pkg_installed "$p" && fx+=("$p"); done
    if [ "${#fx[@]}" -gt 0 ]; then
        info "Removing Firefox (replaced by Chrome): ${fx[*]}"
        try apt_get remove "${fx[@]}"
    fi

    # Taskbar: Chrome instead of Firefox, plus LLStore
    gset org.cinnamon favorite-apps "$FAVORITE_APPS"
    # (Optional - centre the panel: set /org/cinnamon/enabled-applets with dconf, see the old 01 script.)

    # --- THE BIG ONE: every app in the preset ---------------------------------
    step "Installing all apps from $PRESET"
    try llstore_preset "$preset_file"

    echo "Done" > "$SUDO_DONE_FLAG"                  # tells LLStore the sudo-elevated stage is over

    # --- After-install settings ------------------------------------------------
    step "Finishing touches"
    # Overlay: the settings LLStore should use on the finished system
    if [ -f "$SCRIPT_DIR/LLL_Settings-Overlay.ini" ]; then
        put_file "$SCRIPT_DIR/LLL_Settings-Overlay.ini" "$LLSTORE_HOME" "LLL_Settings.ini" || warn "Could not apply the settings overlay."
    fi
    rm -rf "$HOME/Desktop/LLStore Debug-Logs"        # LLStore debug logs left on the desktop

    # Root's file manager: compact view + show hidden files
    gset_root org.nemo.preferences default-folder-viewer "'compact-view'"
    gset_root org.nemo.preferences show-hidden-files true

    # Distro-specific themes/fixes (Debian). Runs from this folder so relative paths work.
    if [ -f "$SCRIPT_DIR/Debian_Fixes.sh" ]; then
        info "Applying Debian_Fixes.sh"
        ( cd "$SCRIPT_DIR" && sudo bash ./Debian_Fixes.sh ) || warn "Debian_Fixes.sh reported an error."
    fi

    rm -f "$BUILDER_FLAG"
}

# =============================================================================
#  STAGE: eggs  -  install penguins-eggs (the ISO maker)
# =============================================================================
stage_eggs() {
    # An app or update installed since 'update' may have brought another kernel
    reboot_check kernel "${REST_FROM[@]}"
    step "Install penguins-eggs"

    # Fixes the error at the end of the Calamares installer
    try apt_install_available language-selector-common

    local deb appimage method="$EGGS_METHOD"
    deb="$(newest_match "$SCRIPT_DIR/penguins-eggs*amd64.deb")"
    appimage="$(newest_match "$SCRIPT_DIR/penguins-eggs-*-x86_64.AppImage")"

    # The .deb is preferred: the copy installed via the LLStore preset failed
    # with mkisofs (the package was missing its isolinux dependencies).
    if [ "$method" = "auto" ]; then
        if   [ -n "$deb" ];      then method="deb"
        elif [ -n "$appimage" ]; then method="appimage"
        else warn "No penguins-eggs .deb or AppImage found in $SCRIPT_DIR - eggs not installed."; return 0
        fi
    fi

    case "$method" in
        deb)
            [ -n "$deb" ] || { warn "No penguins-eggs*amd64.deb in $SCRIPT_DIR"; return 0; }
            info "Using $(basename "$deb")"

            # eggs needs a current Node.js: use NodeSource unless the right major version is already here
            local want have
            want="$(grep -oP '^NODE_VERSION="\K[0-9]+' "$SCRIPT_DIR/nodesource_setup.sh" 2>/dev/null)"
            have="$(node -v 2>/dev/null | sed 's/^v//; s/\..*//')"
            if [ -f "$SCRIPT_DIR/nodesource_setup.sh" ] && [ "$have" != "$want" ]; then
                try sudo bash "$SCRIPT_DIR/nodesource_setup.sh"
            fi
            try apt_get install nodejs

            # apt resolves the deb's dependencies in one go (replaces dpkg -i + --fix-broken).
            # --reinstall so a rebuilt .deb with the same version number still gets installed.
            # Copied to /tmp first: apt can't read some USB mounts as its sandbox user.
            local tmpd; tmpd="$(mktemp -d)"
            cp "$deb" "$tmpd/"
            apt_get install --reinstall "$tmpd/$(basename "$deb")" || warn "penguins-eggs deb install failed."
            rm -rf "$tmpd"
            ;;
        appimage)
            [ -n "$appimage" ] || { warn "No penguins-eggs-*-x86_64.AppImage in $SCRIPT_DIR"; return 0; }
            info "Using $(basename "$appimage")"
            # AppImages need FUSE 2 (the package name differs between releases)
            local fuse
            for fuse in libfuse2t64 libfuse2; do
                if apt-cache show "$fuse" >/dev/null 2>&1; then try apt_get install "$fuse"; break; fi
            done
            sudo cp -f "$appimage" /usr/local/bin/eggs && sudo chmod 755 /usr/local/bin/eggs
            yes | sudo eggs setup install || warn "'eggs setup install' reported an error."
            ;;
    esac
    if command -v eggs >/dev/null 2>&1; then ok "eggs is installed: $(command -v eggs)"; else warn "eggs not found on PATH after install."; fi
}

# =============================================================================
#  STAGE: iso  -  clean up the system, then build the ISO through LLStore
# =============================================================================
stage_iso() {
    need_llstore
    reboot_check kernel "${REST_FROM[@]}"
    step "Prepare the system for capture"

    # Offline cache: capture OFF, link the debs read-only so 'apt clean' can
    # only remove the links, never the real files on the USB.
    repo_manager -link-ro || true

    # The Mint updater must not wake up mid-build
    pkill -f mintUpdate 2>/dev/null; pkill -f mintreport-tray 2>/dev/null

    # Hidden files OFF - clean view for the captured OS
    gset org.nemo.preferences show-hidden-files false

    # Use the Windows 10 icons rather than the theme's own (every desktop flavour, you and root)
    local schema
    for schema in org.cinnamon.desktop.interface org.gnome.desktop.interface org.mate.interface; do
        gset      "$schema" icon-theme "$ICON_THEME"
        gset_root "$schema" icon-theme "$ICON_THEME"
    done

    # Distro-specific tasks
    OS_ID="$(os_id)"
    info "OS ID: $OS_ID"
    case "$OS_ID" in
        debian)
            # Gamers Runtimes package goes into the Windows apps folder on Debian builds
            local src="$SCRIPT_DIR/DebianFixes/LastOS.Gamers.Runtimes.Lite_v23.04_x64+x86_ssApp.apz"
            if [ -f "$src" ]; then
                if ensure_dir /opt/LastOS/WindowsApps && put_file "$src" /opt/LastOS/WindowsApps; then
                    ok "Gamers Runtimes package copied."
                else
                    warn "Could not copy the Gamers Runtimes package."
                fi
            else
                warn "Debian fix file not found: $src"
            fi
            ;;
        *) info "Not Debian - Debian-only steps skipped." ;;
    esac

    # --- Clean up, then build ------------------------------------------------
    local apps="$SCRIPT_DIR/LLAppsInstalls" clean_tar build_tar
    step "Clean-up (LLStore)"
    clean_tar="$(newest_match "$apps/$CLEAN_GLOB")"
    if [ -n "$clean_tar" ]; then
        info "Running $(basename "$clean_tar")"
        llstore_run -KeepSudo -i -q "$clean_tar" || warn "Clean-up job returned an error."
    else
        warn "Clean Build LLApp not found in $apps ($CLEAN_GLOB)"
    fi

    step "Build the ISO (LLStore) - edition: $EDITION"
    build_tar="$(newest_match "$apps/$ISO_GLOB")"
    [ -n "$build_tar" ] || die "Build ISO LLApp not found in $apps ($ISO_GLOB)"
    info "Running $(basename "$build_tar")"
    # (Original scripts passed -KeepSudo to the clean-up but not to this one; kept as it was.)
    llstore_run -i -q "$build_tar" || warn "Build job returned an error."

    # If eggs/the compressor were launched in their own window and LLStore came
    # back early, wait here - exiting would stop the sudo keep-alive under them.
    if pgrep -f 'eggs (produce|kill)|mksquashfs|xorriso|mkisofs' >/dev/null 2>&1; then
        step "ISO still being written - waiting for it to finish (Ctrl-C to stop waiting)"
        while pgrep -f 'eggs (produce|kill)|mksquashfs|xorriso|mkisofs' >/dev/null 2>&1; do sleep 5; done
    fi

    command -v nemo >/dev/null 2>&1 && { nohup nemo "$HOME" >/dev/null 2>&1 & }
}

# =============================================================================
#  STAGE: resume / repo
# =============================================================================
stage_resume() { need_llstore; step "Resume the interrupted LLStore job"; llstore_run -continue; }

stage_repo() {
    local mgr; mgr="$(find_repo_manager)" || die "Repo manager script not found."
    resolve_repo
    local args=(); [ -n "$REPO_DIR" ] && args+=(--repo "$REPO_DIR")
    bash "$mgr" "${args[@]}"
}

# =============================================================================
#  MENU  (when no stages were given on the command line)
# =============================================================================
menu() {
    local choice
    while true; do
        clear
        set_edition_vars
        echo "================================================================"
        echo "                    LastOS LINUX BUILDER"
        echo "================================================================"
        echo " Edition : $EDITION    (preset: $PRESET)"
        echo " Folder  : $SCRIPT_DIR"
        echo "----------------------------------------------------------------"
        echo "  1) FULL BUILD   - prepare the system AND build the ISO"
        echo "  2) PREPARE ONLY - everything except the final ISO build"
        echo "  3) BUILD ISO    - clean-up + ISO build only"
        echo "  4) RESUME       - continue a crashed / interrupted LLStore job"
        echo "  5) REPO MANAGER - offline package cache menu"
        echo "  6) EDITION      - switch Standard <-> AIO (Wine)"
        echo "  0) Exit"
        echo "----------------------------------------------------------------"
        read -rp " Select an option [0-6]: " choice
        case "$choice" in
            1) STAGES=(update prepare store apps eggs iso); return 0 ;;
            2) STAGES=(update prepare store apps eggs);     return 0 ;;
            3) STAGES=(iso);                         return 0 ;;
            4) STAGES=(resume);                      return 0 ;;
            5) STAGES=(repo);                        return 0 ;;
            6) if [ "$EDITION" = "standard" ]; then EDITION="aio"; else EDITION="standard"; fi ;;
            0|q|Q) trap - EXIT; exit 0 ;;
            *) echo "Invalid choice."; sleep 1 ;;
        esac
    done
}

# =============================================================================
#  MAIN
# =============================================================================
if [ "$RESUME" -eq 1 ]; then load_resume_state; fi
[ "${#STAGES[@]}" -eq 0 ] && menu
set_edition_vars
start_logging

echo "LastOS Linux Builder - $(date)"
echo "Stages: ${STAGES[*]}   Edition: $EDITION   Folder: $SCRIPT_DIR"
[ "$JUST_REBOOTED" -eq 1 ] && echo "(Continuing after a reboot - running kernel: $(running_kernel))"

# The repo manager menu does its own sudo handling; everything else needs it up front
if [ "${#STAGES[@]}" -eq 1 ] && [ "${STAGES[0]}" = "repo" ]; then
    stage_repo; exit 0
fi

sudo_begin
resolve_repo

# REST_FROM / REST_AFTER tell a stage what is left, so it can resume there after a reboot
for i in "${!STAGES[@]}"; do
    REST_FROM=("${STAGES[@]:i}")
    REST_AFTER=("${STAGES[@]:i+1}")
    "stage_${STAGES[$i]}"
done
