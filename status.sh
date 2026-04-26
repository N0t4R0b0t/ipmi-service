#!/bin/bash
# IPMI Fan Control — Live Status

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

CONFIG_FILE="${CONFIG_FILE:-/etc/fan-control.conf}"
LOGFILE="/var/log/fan-control.log"
TEMP_CRITICAL=75

# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

IPMITOOL="${IPMITOOL:-/usr/bin/ipmitool}"

# ── helpers ───────────────────────────────────────────────────────────────────

bar() {
    local val=$1 max=$2 width=20
    local filled=$(( val * width / max ))
    [ "$filled" -gt "$width" ] && filled=$width
    local empty=$(( width - filled ))
    local b="" i
    for (( i=0; i<filled; i++ )); do b+="█"; done
    for (( i=0; i<empty;  i++ )); do b+="░"; done
    printf '%s' "$b"
}

temp_color() {
    local val=$1
    if   [ "$val" -ge "$TEMP_CRITICAL" ];                    then printf '%s' "$RED"
    elif [ "$val" -ge "$(( TEMP_CRITICAL * 75 / 100 ))" ];   then printf '%s' "$YELLOW"
    else                                                           printf '%s' "$GREEN"
    fi
}

section() {
    echo ""
    echo -e "  ${BOLD}$1${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────────${NC}"
}

ipmi_ok() {
    [ -e /dev/ipmi0 ] && command -v "$IPMITOOL" &>/dev/null
}

# ── header ────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}=================================================${NC}"
printf "${BOLD}${CYAN}  IPMI Fan Control — Status         %s ${NC}\n" "$(date '+%H:%M:%S')"
echo -e "${BOLD}${CYAN}=================================================${NC}"

# ── temperatures ──────────────────────────────────────────────────────────────

section "Temperatures"

if ! ipmi_ok; then
    echo -e "  ${YELLOW}IPMI not available — check /dev/ipmi0 and ipmitool${NC}"
else
    found=0
    while IFS='|' read -r name _id status _entity value; do
        status="$(echo "$status" | xargs)"
        value="$(echo "$value"   | xargs)"
        [[ "$status" =~ ^(ns|na)$ ]] && continue
        temp="$(echo "$value" | grep -oP '^\d+' || true)"
        [ -z "$temp" ] && continue
        color="$(temp_color "$temp")"
        b="$(bar "$temp" "$TEMP_CRITICAL")"
        printf "  %-22s ${color}%3d°C${NC}  ${color}%s${NC}\n" \
            "$(echo "$name" | xargs)" "$temp" "$b"
        (( found++ )) || true
    done < <("$IPMITOOL" sdr type Temperature 2>/dev/null)
    [ "$found" -eq 0 ] && echo -e "  ${DIM}No sensors reported${NC}"
fi

# ── fan speeds ────────────────────────────────────────────────────────────────

section "Fan Speeds"

last_pct=""
[ -f "$LOGFILE" ] && last_pct="$(grep 'Fan speed set to' "$LOGFILE" | tail -1 | grep -oP '\d+(?=%)' || true)"

if ! ipmi_ok; then
    echo -e "  ${YELLOW}IPMI not available${NC}"
else
    found=0
    while IFS='|' read -r name _id status _entity value; do
        status="$(echo "$status" | xargs)"
        value="$(echo "$value"   | xargs)"
        [[ "$status" =~ ^(ns|na)$ ]] && continue
        rpm="$(echo "$value" | grep -oP '^\d+' || true)"
        [ -z "$rpm" ] && continue
        printf "  %-22s %5d RPM\n" "$(echo "$name" | xargs)" "$rpm"
        (( found++ )) || true
    done < <("$IPMITOOL" sdr type Fan 2>/dev/null)
    [ "$found" -eq 0 ] && echo -e "  ${DIM}No fan sensors reported${NC}"
fi

if [ -n "$last_pct" ]; then
    echo ""
    b="$(bar "$last_pct" 100)"
    echo -e "  Control:  ${CYAN}${last_pct}%${NC}  ${CYAN}${b}${NC}"
fi

# ── control state ─────────────────────────────────────────────────────────────

section "Control State"

if [ -f "$LOGFILE" ]; then
    last_action="$(grep -E 'Fan speed set to|auto fan control' "$LOGFILE" | tail -1 | cut -c21- || true)"
    last_poll="$(grep 'Current max temp' "$LOGFILE" | tail -1 | cut -c1-19 || true)"
    [ -n "$last_action" ] && echo -e "  Last action:  ${CYAN}${last_action}${NC}"
    [ -n "$last_poll"   ] && echo -e "  Last poll:    ${DIM}${last_poll}${NC}"
else
    echo -e "  ${DIM}No log at $LOGFILE — service may not have run yet${NC}"
fi

timer_active=false
systemctl is-active fan-control.timer &>/dev/null && timer_active=true || true

if [ "$timer_active" = true ]; then
    next_run="$(systemctl list-timers fan-control.timer --no-legend 2>/dev/null | awk '{print $1, $2}' | head -1 | xargs || true)"
    echo -e "  Timer:        ${GREEN}active${NC}${next_run:+  (next run: $next_run)}"
else
    echo -e "  Timer:        ${YELLOW}inactive${NC}"
fi

echo ""
echo -e "${BOLD}${CYAN}=================================================${NC}"
echo ""
