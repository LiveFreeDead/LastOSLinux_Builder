#!/bin/bash
# setup_lastos_system.sh
# Comprehensive system-wide setup for LastOS LLStore
# Works in both live sessions and installed systems
# Ensures all users (current and future) have access to /LastOS/LLStore

set -e

LLSTORE_PATH="/LastOS/LLStore"
GROUP_NAME="lastos-users"
INSTALL_MARKER="/etc/lastos-configured"

echo "=========================================="
echo "LastOS System Configuration"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root"
    echo "Usage: sudo $0"
    exit 1
fi

# Function to check if live session
is_live_session() {
    grep -q "boot=live\|boot=casper" /proc/cmdline 2>/dev/null || \
    [ -d "/run/live" ] || [ -d "/lib/live" ] || \
    mount | grep -q "overlay on / "
}

# ──────────────────────────────────────────────────────────────────────────
# Step 1: Create lastos-users group
# ──────────────────────────────────────────────────────────────────────────

echo "→ Creating lastos-users group..."
if ! getent group "$GROUP_NAME" &>/dev/null; then
    groupadd -r "$GROUP_NAME"
    echo "  ✓ Group created"
else
    echo "  ✓ Group already exists"
fi

# ──────────────────────────────────────────────────────────────────────────
# Step 2: Add current non-root users to the group
# ──────────────────────────────────────────────────────────────────────────

echo ""
echo "→ Adding existing users to $GROUP_NAME..."

# Get list of real users (UID >= 1000, excluding nobody)
for user in $(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd); do
    if ! groups "$user" | grep -q "$GROUP_NAME"; then
        usermod -a -G "$GROUP_NAME" "$user"
        echo "  ✓ Added $user"
    else
        echo "  - $user already in group"
    fi
done

# ──────────────────────────────────────────────────────────────────────────
# Step 3: Configure /etc/adduser.conf (Debian/Ubuntu)
# ──────────────────────────────────────────────────────────────────────────

echo ""
echo "→ Configuring adduser.conf..."

if [ -f /etc/adduser.conf ]; then
    # Remove any existing EXTRA_GROUPS entries for lastos-users
    sed -i '/EXTRA_GROUPS=.*lastos-users/d' /etc/adduser.conf
    
    # Check if EXTRA_GROUPS exists and is not commented
    if grep -q "^EXTRA_GROUPS=" /etc/adduser.conf; then
        # Append to existing EXTRA_GROUPS
        sed -i 's/^\(EXTRA_GROUPS="\([^"]*\)"\)/EXTRA_GROUPS="\2 lastos-users"/' /etc/adduser.conf
        # Clean up double spaces
        sed -i 's/EXTRA_GROUPS="  */EXTRA_GROUPS="/' /etc/adduser.conf
        sed -i 's/  *"/"/g' /etc/adduser.conf
    else
        # Create new EXTRA_GROUPS entry
        echo "" >> /etc/adduser.conf
        echo "# LastOS: Add new users to lastos-users group automatically" >> /etc/adduser.conf
        echo 'EXTRA_GROUPS="lastos-users"' >> /etc/adduser.conf
    fi
    
    # Ensure ADD_EXTRA_GROUPS is enabled
    sed -i 's/^#*ADD_EXTRA_GROUPS=.*/ADD_EXTRA_GROUPS=1/' /etc/adduser.conf
    
    # If ADD_EXTRA_GROUPS doesn't exist, add it
    if ! grep -q "^ADD_EXTRA_GROUPS=" /etc/adduser.conf; then
        echo "ADD_EXTRA_GROUPS=1" >> /etc/adduser.conf
    fi
    
    echo "  ✓ adduser.conf configured"
else
    echo "  - adduser.conf not found (not a Debian-based system)"
fi

# ──────────────────────────────────────────────────────────────────────────
# Step 4: Configure /etc/default/useradd (Red Hat/Fedora/Generic)
# ──────────────────────────────────────────────────────────────────────────

echo ""
echo "→ Configuring useradd defaults..."

if [ -f /etc/default/useradd ]; then
    # Remove existing GROUP entries
    sed -i '/^GROUP=.*lastos-users/d' /etc/default/useradd
    
    # Check if GROUPS line exists
    if grep -q "^GROUPS=" /etc/default/useradd; then
        # Append to existing GROUPS
        sed -i "s/^\(GROUPS=\)\(.*\)/\1\2,lastos-users/" /etc/default/useradd
        # Clean up double commas
        sed -i 's/,,*/,/g' /etc/default/useradd
        sed -i 's/^GROUPS=,/GROUPS=/' /etc/default/useradd
    else
        # Create new GROUPS entry
        echo "" >> /etc/default/useradd
        echo "# LastOS: Add new users to lastos-users group automatically" >> /etc/default/useradd
        echo "GROUPS=lastos-users" >> /etc/default/useradd
    fi
    
    echo "  ✓ useradd defaults configured"
else
    echo "  - /etc/default/useradd not found"
fi

# ──────────────────────────────────────────────────────────────────────────
# Step 5: Create /etc/skel additions for new users
# ──────────────────────────────────────────────────────────────────────────

echo ""
echo "→ Setting up /etc/skel for new users..."

# Create profile.d script for automatic group addition
cat > /etc/profile.d/lastos-groups.sh << 'PROFILE_EOF'
# LastOS: Ensure user is in lastos-users group
# This runs on every login and adds user if needed

if [ -n "$BASH_VERSION" ] || [ -n "$ZSH_VERSION" ]; then
    # Only run once per session
    if [ ! -f "$HOME/.lastos-group-checked" ]; then
        if ! groups | grep -q "lastos-users" 2>/dev/null; then
            # Not in group, try to add (requires sudo)
            if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
                sudo usermod -a -G lastos-users "$USER" 2>/dev/null
                # Mark as checked
                touch "$HOME/.lastos-group-checked" 2>/dev/null
                
                # Notify user
                if command -v notify-send &>/dev/null; then
                    notify-send "LastOS" "You've been added to lastos-users group. Please log out and back in." -u low 2>/dev/null &
                fi
            fi
        else
            # Already in group, mark as checked
            touch "$HOME/.lastos-group-checked" 2>/dev/null
        fi
    fi
fi
PROFILE_EOF

chmod +x /etc/profile.d/lastos-groups.sh
echo "  ✓ Login script created"

# ──────────────────────────────────────────────────────────────────────────
# Step 6: Create systemd service for first-boot user setup
# ──────────────────────────────────────────────────────────────────────────

echo ""
echo "→ Creating first-boot service..."

cat > /etc/systemd/system/lastos-setup.service << 'SYSTEMD_EOF'
[Unit]
Description=LastOS User Group Setup
After=multi-user.target
ConditionPathExists=!/etc/lastos-users-configured

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lastos-add-users.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

# Create the actual script that runs on first boot
cat > /usr/local/sbin/lastos-add-users.sh << 'ADDUSERS_EOF'
#!/bin/bash
# Add all existing users to lastos-users group on first boot

GROUP_NAME="lastos-users"

# Create group if needed
if ! getent group "$GROUP_NAME" &>/dev/null; then
    groupadd -r "$GROUP_NAME"
fi

# Add all real users
for user in $(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd); do
    if ! groups "$user" | grep -q "$GROUP_NAME"; then
        usermod -a -G "$GROUP_NAME" "$user"
    fi
done

# Mark as configured
touch /etc/lastos-users-configured

exit 0
ADDUSERS_EOF

chmod +x /usr/local/sbin/lastos-add-users.sh

# Enable the service if systemd is available
if command -v systemctl &>/dev/null; then
    systemctl daemon-reload
    systemctl enable lastos-setup.service 2>/dev/null
    echo "  ✓ Systemd service enabled"
else
    echo "  - Systemd not available, service not enabled"
fi

# ──────────────────────────────────────────────────────────────────────────
# Step 7: Setup /LastOS/LLStore permissions
# ──────────────────────────────────────────────────────────────────────────

echo ""
echo "→ Configuring /LastOS/LLStore permissions..."

if [ -d "$LLSTORE_PATH" ]; then
    # Set group ownership
    chgrp -R "$GROUP_NAME" "$LLSTORE_PATH"
    
    # Set permissions: rwxrwsr-x (2775) with SGID bit
    # SGID ensures new files inherit the group
    chmod -R 2775 "$LLSTORE_PATH"
    
    # Set SGID on directory
    find "$LLSTORE_PATH" -type d -exec chmod g+s {} \;
    
    # Ensure files are readable/executable by group
    find "$LLSTORE_PATH" -type f -exec chmod g+rw {} \;
    
    echo "  ✓ Permissions set (2775 with SGID)"
else
    echo "  - $LLSTORE_PATH not found (will be set during LLStore install)"
fi

# ──────────────────────────────────────────────────────────────────────────
# Step 8: Handle live sessions differently
# ──────────────────────────────────────────────────────────────────────────

if is_live_session; then
    echo ""
    echo "→ Live session detected"
    
    if [ -d "$LLSTORE_PATH" ]; then
        # In live session, use 777 for immediate access
        chmod -R 777 "$LLSTORE_PATH"
        echo "  ✓ Applied 777 permissions for live session"
    fi
    
    # Don't mark as permanently configured in live session
    rm -f "$INSTALL_MARKER"
else
    # Mark system as configured
    touch "$INSTALL_MARKER"
    echo ""
    echo "→ System marked as configured"
fi

# ──────────────────────────────────────────────────────────────────────────
# Step 9: Create helper command for manual group activation
# ──────────────────────────────────────────────────────────────────────────

echo ""
echo "→ Creating helper commands..."

cat > /usr/local/bin/lastos-fix-groups << 'HELPER_EOF'
#!/bin/bash
# Helper script to manually fix group membership

if [ "$EUID" -eq 0 ]; then
    # Running as root, add all users
    for user in $(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd); do
        usermod -a -G lastos-users "$user" 2>/dev/null
    done
    echo "All users added to lastos-users group"
else
    # Running as user, add self with sudo
    sudo usermod -a -G lastos-users "$USER"
    echo "You've been added to lastos-users group."
    echo "Run 'newgrp lastos-users' to activate without logout"
fi
HELPER_EOF

chmod +x /usr/local/bin/lastos-fix-groups
echo "  ✓ Helper command created: lastos-fix-groups"

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "Configuration Complete!"
echo "=========================================="
echo ""
echo "What was configured:"
echo "  • Created '$GROUP_NAME' group"
echo "  • Added existing users to group"
echo "  • Configured adduser/useradd for new users"
echo "  • Created login script (/etc/profile.d/lastos-groups.sh)"
echo "  • Setup first-boot service (lastos-setup.service)"
echo "  • Set /LastOS/LLStore permissions (if exists)"
echo ""

if is_live_session; then
    echo "Live Session Notes:"
    echo "  • /LastOS/LLStore uses 777 permissions"
    echo "  • After installation, run this script again"
    echo "  • Or LLStore installer will run it automatically"
else
    echo "Next Steps:"
    echo "  • Current users need to log out and back in"
    echo "  • Or run: newgrp lastos-users"
    echo "  • New users will automatically be in the group"
    echo "  • Helper command available: lastos-fix-groups"
fi

echo ""
echo "=========================================="

exit 0
