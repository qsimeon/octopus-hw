# PROBE — Hardware Enumeration

## Objective

Discover every hardware interface and device visible to the operating system on this machine. Write the results as structured JSON.

## What to do

1. Detect the current platform.
2. Use whatever platform-appropriate tools are available to enumerate hardware — USB, serial, GPIO, I2C, SPI, Bluetooth, audio, storage, display.
3. Write the result as a single JSON object to the output path specified by the orchestrator.

Use only OS tools already present (no `sudo`, no installs). Check availability before calling — record what's missing in `scan_methods`, continue.

### Reach beyond the wires

The OS-level hardware list is the starting point. Also gather **context** the machine can see on its connectable surfaces, so identify has clues to work with. These are not all controllable devices — passing WiFi SSIDs and LAN neighbors are context, not actuators. Record them, but don't pretend you can drive a printer that happens to be in range.

Categories to attempt (skip cleanly when the tool isn't there):

- **Serial / UART devices** — capture VID/PID, baud-rate hints, manufacturer strings. Robotic arms and microcontrollers live here.
- **Bluetooth devices** — paired and visible.
- **mDNS / Bonjour services** on the LAN — printers, IoT hubs, etc.
- **WiFi networks** in range.
- **LAN hosts** — cheap ARP neighbor list. No deep nmap scans.

**Time-box every scan.** The whole stage must complete in well under 10 minutes. If any single scan can't return quickly, skip it and note `"status": "timeout"` in `scan_methods`. The goal is breadth, not exhaustive coverage.

## Output format

Write a JSON object with this structure:

```json
{
  "platform": "Linux",
  "hostname": "raspberrypi",
  "timestamp": "2026-03-16T12:00:00Z",
  "scan_methods": [
    {"tool": "lsusb", "status": "ok"},
    {"tool": "gpiodetect", "status": "not_found"}
  ],
  "devices": [
    {
      "id": "unique-identifier",
      "name": "Human-readable name",
      "interface": "USB",
      "raw_descriptor": "original tool output for this device"
    }
  ]
}
```

Required fields: `platform`, `hostname`, `timestamp`, `scan_methods`, `devices`. Each device needs at least `id`, `name`, `interface`, `raw_descriptor`. Include `vendor_id` and `product_id` if available.

## Constraints

- Enumerate everything the OS reports — do not filter or classify devices.
- Include all USB devices, even common peripherals like webcams, serial adapters, and audio interfaces. The identify stage will determine which are relevant for hardware control. Do not skip cameras or serial ports — they may be robotic arm controllers or perception cameras.
- Never use `sudo`. Never prompt for input.
- If a tool is missing or fails, note it in `scan_methods` and continue.
- The `devices` array may be empty if nothing is found.
