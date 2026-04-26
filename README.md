# ipmi-fan-control

A vendor-agnostic fan speed controller for servers running **Proxmox VE** (or any Debian-based Linux), using `ipmitool` to manage fan speeds based on CPU temperature readings via in-band IPMI.

Vendor-specific raw IPMI commands are isolated into **profiles**, keeping the core logic hardware-independent. New hardware support can be added by contributing a profile file — no changes to the core script required.

---

## Supported Hardware

| Profile | Hardware | Status |
|---|---|---|
| `dell-idrac7` | PowerEdge R520, R620, R720, R820 | ✅ Tested |
| `dell-idrac6` | PowerEdge R510, R610, R710, R810 | ⚠️ Untested |
| `dell-idrac9` | PowerEdge R640, R740, R840, R940 | ⚠️ Untested |
| `supermicro`  | X9/X10/X11 motherboard series    | ⚠️ Untested |

> Untested profiles are included as a starting point for community verification. If you've tested one, please open an issue or PR to update its status.

---

## Requirements

- Proxmox VE or any Debian-based Linux
- Server with IPMI/BMC support (iDRAC, iLO, etc.)
- `ipmitool` v1.8.19+ (installed automatically if missing)
- Root access

---

## Quick Start

```bash
git clone https://github.com/N0t4R0b0t/ipmi-service.git
cd ipmi-service
sudo bash setup.sh
```

The installer will:
1. List available profiles and prompt you to select one
2. Install `ipmitool` if not present
3. Load and persist the required IPMI kernel modules
4. Deploy the script, config, profiles, and systemd units
5. Run once immediately to verify everything works

To uninstall (also restores vendor auto fan control):

```bash
sudo bash setup.sh --uninstall
```

---

## Configuration

Installed to `/etc/fan-control.conf`. Changes take effect on the next poll — no restart needed.

```bash
nano /etc/fan-control.conf
```

### Settings

| Setting | Default | Description |
|---|---|---|
| `PROFILE` | `dell-idrac7` | Vendor profile to use |
| `TEMP_CRITICAL` | `75` | °C at which vendor auto control is restored |
| `FALLBACK_ON_READ_ERROR` | `true` | Fall back to auto control if sensors fail |
| `DEFAULT_SPEED` | `20` | Fan % when below all thresholds |
| `POLL_INTERVAL` | `2min` | How often the timer fires |
| `BOOT_DELAY` | `30s` | Delay after boot before first run |
| `LOGFILE` | `/var/log/fan-control.log` | Log file path |
| `LOG_MAX_KB` | `1024` | Log size in KB before rotation |

### Temperature tiers

Tiers are evaluated from hottest to coolest — first match wins. Add or remove tiers freely; they must be numbered sequentially from `1`.

```bash
TIER_1_TEMP=65
TIER_1_SPEED=50

TIER_2_TEMP=55
TIER_2_SPEED=40

TIER_3_TEMP=45
TIER_3_SPEED=30

DEFAULT_SPEED=20   # below all thresholds
```

---

## How It Works

### In-band IPMI — no credentials needed

The script communicates with the BMC through the kernel IPMI driver (`/dev/ipmi0`) on the local host. No IP address, username, or password is required.

Required modules (`ipmi_devintf`, `ipmi_si`) are loaded by the systemd service before each run and persisted in `/etc/modules`.

### Profile system

Each profile in `/etc/fan-control.d/profiles/` defines three shell functions:

```bash
cmd_disable_auto()   # disable vendor automatic fan control
cmd_enable_auto()    # restore vendor automatic fan control
cmd_set_speed() $1   # set fan speed to $1 percent
```

The core script calls these functions without knowing or caring about the underlying IPMI commands. Switching hardware means switching one line in `fan-control.conf`.

---

## Monitoring

```bash
# Live log
tail -f /var/log/fan-control.log

# systemd journal
journalctl -u fan-control.service -f

# Timer status
systemctl list-timers fan-control.timer

# Current fan RPMs
ipmitool sdr type Fan

# Current temperatures
ipmitool sdr type Temperature
```

### Example log output

```
2026-04-25 14:02:01 Loaded profile: Dell iDRAC7 (dell-idrac7.conf)
2026-04-25 14:02:01 Current max temp: 42°C
2026-04-25 14:02:01 Temp 42°C is below all thresholds
2026-04-25 14:02:01 Fan speed set to 20% (0x14)
2026-04-25 14:10:01 Loaded profile: Dell iDRAC7 (dell-idrac7.conf)
2026-04-25 14:10:01 Current max temp: 58°C
2026-04-25 14:10:01 Matched tier 2: temp 58°C >= 55°C
2026-04-25 14:10:01 Fan speed set to 40% (0x28)
2026-04-25 14:20:01 CRITICAL: Temp 76°C >= 75°C — enabling vendor auto control
2026-04-25 14:20:01 Vendor auto fan control enabled (profile: Dell iDRAC7)
```

---

## Adding a New Profile

Create a file in `profiles/` named `<vendor>.conf`:

```bash
# =============================================================================
# Vendor Profile: My Server
# Compatible hardware: Model X, Model Y
# Status: UNTESTED
# =============================================================================

PROFILE_NAME="My Server BMC"
PROFILE_IPMITOOL_INTERFACE="open"

cmd_disable_auto() {
    ipmitool raw 0xXX 0xXX 0xXX 0xXX
}

cmd_enable_auto() {
    ipmitool raw 0xXX 0xXX 0xXX 0xXX
}

# $1 = speed percentage (integer)
cmd_set_speed() {
    local hex
    hex=$(percent_to_hex "$1")   # percent_to_hex is provided by the core script
    ipmitool raw 0xXX 0xXX "$hex"
}
```

Then set `PROFILE=<vendor>` in `/etc/fan-control.conf`. If it works, please open a PR to share it!

---

## File Layout

```
ipmi-service/
├── profiles/
│   ├── dell-idrac6.conf
│   ├── dell-idrac7.conf      ← tested
│   ├── dell-idrac9.conf
│   └── supermicro.conf
├── fan-control.conf          # user configuration
├── fan-control.sh            # core script
├── fan-control.service       # systemd service
├── fan-control.timer         # systemd timer
├── setup.sh                  # installer / uninstaller
└── README.md
```

After install:

```
/usr/local/bin/fan-control.sh
/etc/fan-control.conf
/etc/fan-control.d/profiles/
/etc/systemd/system/fan-control.service
/etc/systemd/system/fan-control.timer
/var/log/fan-control.log
```

---

## Safety

- Temperature at or above `TEMP_CRITICAL` immediately restores vendor auto control
- Sensor read failure restores vendor auto control (configurable)
- Restore auto control manually at any time with your profile's `cmd_enable_auto`, or for Dell:
  ```bash
  ipmitool raw 0x30 0x30 0x01 0x01
  ```

---

## Contributing

Contributions are welcome — especially tested profiles for new hardware. Please include:
- Hardware model and iDRAC/BMC version
- The raw IPMI commands you verified work
- Whether fan speed is confirmed via `ipmitool sdr type Fan`

---

## License

MIT
