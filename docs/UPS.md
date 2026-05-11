# UPS — CyberPower CP850PFCLCD

Uninterruptible Power Supply setup using NUT (Network UPS Tools). Monitors the UPS over USB and triggers a graceful shutdown when battery reaches critical level, protecting PostgreSQL and filesystems from corruption.

## Hardware

- **Model:** CyberPower CP850PFCLCD PFC Sinewave
- **Capacity:** 850VA / 510W
- **Connection:** USB (Type-B on UPS to Type-A on server)
- **NUT driver:** `usbhid-ups`

## How It Works

1. NUT's `upsd` daemon communicates with the UPS over USB using the `usbhid-ups` driver
2. `upsmon` polls the UPS status every 5 seconds (every 2 seconds when on battery)
3. When the UPS reports battery is critically low, `upsmon` triggers `shutdown -h +0`
4. systemd stops all services in dependency order — containers, then PostgreSQL, then filesystems

This means a power outage plays out like:

```
Power loss → UPS switches to battery → server stays running
  → battery drains to critical → NUT triggers graceful shutdown
  → power returns → server boots (if BIOS set to restore on AC)
  → systemd starts all services automatically
```

## Initial Setup

### 1. Enable the module

The UPS module is imported but disabled by default. Enable it in `configuration.nix`:

```nix
services.ups.enable = true;
```

Without this, the module is a no-op — no NUT services, no secrets required, no errors.

### 2. Connect USB

Plug a USB cable from the UPS (Type-B port on the back) to the server.

### 3. Add the upsmon secret

NUT uses an internal password for daemon communication. Pick any random string:

```bash
sops secrets/secrets.yaml
```

Add:

```yaml
ups:
    upsmon-password: your-random-password-here
```

### 3. BIOS — Restore on AC Power Loss

Enter BIOS/UEFI (usually Del or F2 at boot) and find the power recovery setting:

- Look for **"Restore on AC Power Loss"**, **"After Power Failure"**, or **"AC Recovery"**
- Set it to **Power On**

This ensures the server boots automatically when power returns after a full shutdown.

### 5. Deploy

```bash
sudo nixos-rebuild switch --flake .#server
```

### 6. Verify

Check that the server sees the UPS on USB:

```bash
lsusb | grep -i cyber
```

You should see something like `Bus 001 Device 003: ID 0764:0501 Cyber Power System, Inc. CP1500 AVR UPS`.

Query the UPS status:

```bash
sudo upsc cyberpower
```

This prints battery charge, runtime, input voltage, load percentage, etc. Key fields:

| Field | Meaning |
|---|---|
| `battery.charge` | Current battery percentage |
| `battery.runtime` | Estimated seconds of runtime remaining |
| `ups.status` | `OL` = online (on AC), `OB` = on battery, `LB` = low battery |
| `input.voltage` | AC voltage from the wall |
| `ups.load` | Percentage of UPS capacity in use |

## Configuration

The NUT config lives in `modules/ups.nix`. Key settings in `upsmon`:

| Setting | Value | Purpose |
|---|---|---|
| `POLLFREQ` | 5 | Seconds between status polls (normal) |
| `POLLFREQALERT` | 2 | Seconds between status polls (on battery) |
| `DEADTIME` | 15 | Seconds before a non-responding UPS is declared dead |
| `FINALDELAY` | 5 | Seconds between "shutdown now" and actual halt |

NUT decides when to shut down based on the UPS reporting low battery (`LB` status), which the UPS itself determines based on remaining runtime. The CP850PFCLCD defaults to triggering low battery at around 2 minutes of estimated runtime remaining. This can be adjusted in the UPS front panel settings if needed.

## Useful Commands

```bash
# Full UPS status dump
sudo upsc cyberpower

# Just battery charge
sudo upsc cyberpower battery.charge

# Just runtime remaining (seconds)
sudo upsc cyberpower battery.runtime

# Check if NUT services are running
systemctl status nut-driver.service
systemctl status nut-server.service
systemctl status nut-monitor.service

# View NUT logs
journalctl -u nut-monitor.service -f
```

## Troubleshooting

### UPS not detected

```bash
lsusb | grep -i cyber
```

If nothing shows up:
- Check the USB cable is connected on both ends
- Try a different USB port on the server
- Try a different USB cable

If it shows up in `lsusb` but `upsc` fails:
- Check udev rules applied: `udevadm trigger`
- Restart the driver: `sudo systemctl restart nut-driver.service`
- Check driver logs: `journalctl -u nut-driver.service`

### Permission denied

The udev rule in `modules/ups.nix` grants the `nut` group access to CyberPower USB devices (vendor ID `0764`). If you get permission errors:

```bash
# Verify the udev rule is active
udevadm test /sys/bus/usb/devices/<device-path> 2>&1 | grep -i mode

# Reapply udev rules without rebooting
sudo udevadm control --reload-rules && sudo udevadm trigger
```

### NUT shuts down too early or too late

The shutdown trigger is based on the UPS reporting low battery, not a specific percentage. The CP850PFCLCD determines this based on estimated runtime. You can adjust the low battery threshold via the UPS front panel LCD:
1. Hold the display button to enter settings
2. Navigate to the low battery runtime setting
3. Adjust the threshold (default is ~2 minutes)
