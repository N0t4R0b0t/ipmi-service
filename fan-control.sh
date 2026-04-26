#!/bin/bash
# =============================================================================
# IPMI Fan Speed Controller
# Vendor-agnostic core — behaviour is defined by the loaded profile.
# Configuration: /etc/fan-control.conf
# Profiles:      /etc/fan-control.d/profiles/
# =============================================================================

set -euo pipefail

CONFIG_FILE="/etc/fan-control.conf"
PROFILES_DIR="/etc/fan-control.d/profiles"
IPMITOOL="/usr/bin/ipmitool"

# --- Load config --------------------------------------------------------------

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found at $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# --- Logging ------------------------------------------------------------------

log() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') $1"

    if [ -f "$LOGFILE" ]; then
        local size_kb
        size_kb=$(du -k "$LOGFILE" | cut -f1)
        if [ "$size_kb" -ge "${LOG_MAX_KB:-1024}" ]; then
            mv "$LOGFILE" "${LOGFILE}.1"
        fi
    fi

    echo "$msg" >> "$LOGFILE"
}

# --- Helpers ------------------------------------------------------------------

percent_to_hex() {
    printf '0x%02x' "$1"
}

get_max_temp() {
    $IPMITOOL sdr type Temperature 2>/dev/null \
        | grep -v "disabled\|ns\|na" \
        | awk -F'|' '{print $5}' \
        | grep -oP '\d+' \
        | sort -n \
        | tail -1
}

set_fan_speed() {
    local speed_pct=$1
    local speed_hex
    speed_hex=$(percent_to_hex "$speed_pct")

    cmd_disable_auto
    cmd_set_speed "$speed_pct"
    log "Fan speed set to ${speed_pct}% (${speed_hex})"
}

enable_auto_control() {
    cmd_enable_auto
    log "Vendor auto fan control enabled (profile: ${PROFILE_NAME:-unknown})"
}

# --- Load vendor profile ------------------------------------------------------

PROFILE_FILE="${PROFILES_DIR}/${PROFILE:-dell-idrac7}.conf"

if [ ! -f "$PROFILE_FILE" ]; then
    log "ERROR: Profile not found: $PROFILE_FILE"
    echo "ERROR: Profile not found: $PROFILE_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_FILE"
log "Loaded profile: ${PROFILE_NAME} (${PROFILE}.conf)"

# Verify required functions are defined
for fn in cmd_disable_auto cmd_enable_auto cmd_set_speed; do
    if ! declare -f "$fn" > /dev/null; then
        log "ERROR: Profile '${PROFILE}' is missing required function: ${fn}"
        exit 1
    fi
done

# --- Pre-flight checks --------------------------------------------------------

if [ ! -e /dev/ipmi0 ]; then
    log "ERROR: /dev/ipmi0 not found. Are ipmi_devintf and ipmi_si modules loaded?"
    echo "ERROR: /dev/ipmi0 not found." >&2
    exit 1
fi

# --- Main logic ---------------------------------------------------------------

TEMP=$(get_max_temp)

if [ -z "$TEMP" ]; then
    log "ERROR: Could not read temperature sensors."
    if [ "${FALLBACK_ON_READ_ERROR:-true}" = "true" ]; then
        log "Enabling vendor auto control as safety fallback."
        enable_auto_control
    fi
    exit 1
fi

log "Current max temp: ${TEMP}°C"

# Safety ceiling
if [ "$TEMP" -ge "${TEMP_CRITICAL:-75}" ]; then
    log "CRITICAL: Temp ${TEMP}°C >= ${TEMP_CRITICAL}°C — enabling vendor auto control"
    enable_auto_control
    exit 0
fi

# Evaluate tiers
applied=false
n=1
while true; do
    tier_temp_var="TIER_${n}_TEMP"
    tier_speed_var="TIER_${n}_SPEED"

    [ -z "${!tier_temp_var+x}" ] || [ -z "${!tier_speed_var+x}" ] && break

    tier_temp="${!tier_temp_var}"
    tier_speed="${!tier_speed_var}"

    if [ "$TEMP" -ge "$tier_temp" ]; then
        log "Matched tier ${n}: temp ${TEMP}°C >= ${tier_temp}°C"
        set_fan_speed "$tier_speed"
        applied=true
        break
    fi

    ((n++))
done

if [ "$applied" = false ]; then
    log "Temp ${TEMP}°C is below all thresholds"
    set_fan_speed "${DEFAULT_SPEED:-20}"
fi
