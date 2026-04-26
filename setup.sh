#!/bin/bash
# =============================================================================
# IPMI Fan Control — Installer
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Root check ---------------------------------------------------------------

[ "$EUID" -ne 0 ] && error "Please run as root: sudo bash setup.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_SCRIPT="/usr/local/bin/fan-control.sh"
INSTALL_CONFIG="/etc/fan-control.conf"
INSTALL_PROFILES_DIR="/etc/fan-control.d/profiles"
INSTALL_SERVICE="/etc/systemd/system/fan-control.service"
INSTALL_TIMER="/etc/systemd/system/fan-control.timer"

# --- Uninstall ----------------------------------------------------------------

if [[ "${1:-}" == "--uninstall" ]]; then
    info "Uninstalling IPMI Fan Control..."

    systemctl stop fan-control.timer 2>/dev/null || true
    systemctl disable fan-control.timer 2>/dev/null || true
    systemctl stop fan-control.service 2>/dev/null || true
    systemctl disable fan-control.service 2>/dev/null || true

    rm -f "$INSTALL_SCRIPT" "$INSTALL_SERVICE" "$INSTALL_TIMER"

    if command -v ipmitool &>/dev/null && [ -e /dev/ipmi0 ]; then
        # Source the active profile to restore auto control properly
        if [ -f "$INSTALL_CONFIG" ]; then
            # shellcheck source=/dev/null
            source "$INSTALL_CONFIG"
            PROFILE_FILE="${INSTALL_PROFILES_DIR}/${PROFILE:-dell-idrac7}.conf"
            if [ -f "$PROFILE_FILE" ]; then
                # shellcheck source=/dev/null
                source "$PROFILE_FILE"
                cmd_enable_auto 2>/dev/null && success "Vendor auto fan control restored."
            fi
        fi
    fi

    warn "Config kept at $INSTALL_CONFIG — remove manually if desired."
    warn "Profiles kept at $INSTALL_PROFILES_DIR — remove manually if desired."
    success "Uninstall complete."
    exit 0
fi

# --- Header -------------------------------------------------------------------

echo ""
echo -e "${BOLD}${CYAN}=================================================${NC}"
echo -e "${BOLD}${CYAN}  IPMI Fan Control — Installer                  ${NC}"
echo -e "${BOLD}${CYAN}=================================================${NC}"
echo ""

# --- Profile selection --------------------------------------------------------

AVAILABLE_PROFILES=()
TESTED_PROFILES=()
UNTESTED_PROFILES=()

for f in "$SCRIPT_DIR/profiles/"*.conf; do
    name=$(basename "$f" .conf)
    # Check if profile is marked as tested
    if grep -q "Status: TESTED" "$f" 2>/dev/null; then
        TESTED_PROFILES+=("$name")
    else
        UNTESTED_PROFILES+=("$name")
    fi
    AVAILABLE_PROFILES+=("$name")
done

echo -e "${BOLD}Available vendor profiles:${NC}"
echo ""
echo -e "  ${GREEN}Tested:${NC}"
for p in "${TESTED_PROFILES[@]}"; do
    echo "    $p"
done
echo -e "  ${YELLOW}Untested (community contributions welcome):${NC}"
for p in "${UNTESTED_PROFILES[@]}"; do
    echo "    $p"
done
echo ""

read -rp "Enter profile name [dell-idrac7]: " SELECTED_PROFILE
SELECTED_PROFILE="${SELECTED_PROFILE:-dell-idrac7}"

PROFILE_FILE="$SCRIPT_DIR/profiles/${SELECTED_PROFILE}.conf"
if [ ! -f "$PROFILE_FILE" ]; then
    error "Profile not found: profiles/${SELECTED_PROFILE}.conf"
fi

# Warn if untested
if grep -q "Status: UNTESTED" "$PROFILE_FILE" 2>/dev/null; then
    echo ""
    warn "Profile '${SELECTED_PROFILE}' is UNTESTED. Use at your own risk."
    warn "Please report your results at: https://github.com/N0t4R0b0t/ipmi-service/issues"
    read -rp "Continue anyway? [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && error "Aborted."
fi

success "Profile selected: ${SELECTED_PROFILE}"
echo ""

# --- ipmitool -----------------------------------------------------------------

info "Checking for ipmitool..."
if ! command -v ipmitool &>/dev/null; then
    info "ipmitool not found — installing..."
    apt-get update -qq
    apt-get install -y ipmitool
    success "ipmitool installed."
else
    IPMI_VER=$(ipmitool -V | awk '{print $3}')
    success "ipmitool found (version ${IPMI_VER})."
fi

# --- Kernel modules -----------------------------------------------------------

info "Loading IPMI kernel modules..."
modprobe ipmi_devintf || warn "Could not load ipmi_devintf."
modprobe ipmi_si      || warn "Could not load ipmi_si."

for mod in ipmi_devintf ipmi_si; do
    grep -qx "$mod" /etc/modules 2>/dev/null || echo "$mod" >> /etc/modules
done
success "IPMI modules loaded and persisted."

[ ! -e /dev/ipmi0 ] && error "/dev/ipmi0 not found. Check iDRAC/BMC is enabled in BIOS."
success "/dev/ipmi0 is available."

# --- Install config -----------------------------------------------------------

if [ -f "$INSTALL_CONFIG" ]; then
    warn "Config already exists at $INSTALL_CONFIG — preserving your settings."
    warn "To reset, delete $INSTALL_CONFIG and re-run setup."
    # Update the PROFILE line in existing config to match selection
    sed -i "s/^PROFILE=.*/PROFILE=${SELECTED_PROFILE}/" "$INSTALL_CONFIG"
    success "Updated PROFILE=${SELECTED_PROFILE} in existing config."
else
    cp "$SCRIPT_DIR/fan-control.conf" "$INSTALL_CONFIG"
    sed -i "s/^PROFILE=.*/PROFILE=${SELECTED_PROFILE}/" "$INSTALL_CONFIG"
    success "Config installed to $INSTALL_CONFIG."
fi

# --- Install profiles ---------------------------------------------------------

mkdir -p "$INSTALL_PROFILES_DIR"
cp "$SCRIPT_DIR/profiles/"*.conf "$INSTALL_PROFILES_DIR/"
success "Profiles installed to $INSTALL_PROFILES_DIR."

# --- Install script -----------------------------------------------------------

cp "$SCRIPT_DIR/fan-control.sh" "$INSTALL_SCRIPT"
chmod +x "$INSTALL_SCRIPT"
success "Script installed to $INSTALL_SCRIPT."

# --- Install systemd units ----------------------------------------------------

# shellcheck source=/dev/null
source "$INSTALL_CONFIG"

cp "$SCRIPT_DIR/fan-control.service" "$INSTALL_SERVICE"
sed \
    -e "s/__POLL_INTERVAL__/${POLL_INTERVAL:-2min}/g" \
    -e "s/__BOOT_DELAY__/${BOOT_DELAY:-30s}/g" \
    "$SCRIPT_DIR/fan-control.timer" > "$INSTALL_TIMER"

success "systemd units installed."

# --- Enable and start ---------------------------------------------------------

systemctl daemon-reload
systemctl enable fan-control.timer
systemctl start fan-control.timer
success "fan-control.timer enabled and started."

# --- First run ----------------------------------------------------------------

info "Running fan-control.sh to verify..."
if bash "$INSTALL_SCRIPT"; then
    success "First run completed successfully."
else
    warn "First run reported errors — check $INSTALL_CONFIG and ${LOGFILE:-/var/log/fan-control.log}."
fi

# --- Done ---------------------------------------------------------------------

echo ""
echo -e "${BOLD}${GREEN}=================================================${NC}"
echo -e "${BOLD}${GREEN}  Installation complete!                         ${NC}"
echo -e "${BOLD}${GREEN}=================================================${NC}"
echo ""
echo "  Profile:     ${SELECTED_PROFILE}"
echo "  Config:      $INSTALL_CONFIG"
echo "  Profiles:    $INSTALL_PROFILES_DIR"
echo "  Script:      $INSTALL_SCRIPT"
echo "  Log:         ${LOGFILE:-/var/log/fan-control.log}"
echo "  Poll every:  ${POLL_INTERVAL:-2min} (first run after ${BOOT_DELAY:-30s} on boot)"
echo ""
echo "  Useful commands:"
echo "    systemctl status fan-control.timer"
echo "    systemctl list-timers fan-control.timer"
echo "    journalctl -u fan-control.service -f"
echo "    tail -f ${LOGFILE:-/var/log/fan-control.log}"
echo "    bash setup.sh --uninstall"
echo ""
