# IDENTIFY — Device Capability Identification

## Objective

Read the probe output from the previous stage and determine what each discovered device can do. Annotate every device with its capabilities, a confidence score, and a category.

## What to do

1. Read the probe JSON (path provided by the orchestrator).
2. For each device, figure out what it is and what it can do.
3. Write the annotated results as JSON to the output path specified by the orchestrator.

Use whatever strategies make sense to identify devices:
- **Descriptor/driver matching** — if the probe data includes a driver name or descriptor string, that's often enough.
- **VID:PID lookup** — for USB devices, search the vendor/product ID pair. The chip ID names the *adapter*, not the product.
- **Web search (use this aggressively)** — you have web search tools (`pi-web-access`). Whenever a chip/descriptor is ambiguous, search the *combination* of clues (chip + workstation context), not just the chip alone.
- **Educated guessing** — common I2C addresses, GPIO descriptions, and device names can narrow things down. Lower confidence when guessing.

**Principle**: identify the *product* the chip belongs to, not just the chip. "USB-serial adapter" is almost never the right answer — it's a bus for *something specific*.

**Evidence-only**: do not emit capabilities for hardware the probe didn't actually surface. The pipeline is hardware-agnostic by design — if no robotic arm was discovered, no arm tools should appear in the output. Resist the urge to "be helpful" by hallucinating devices.

## Output format

Write a JSON object:

```json
{
  "stage": "identify",
  "timestamp": "2026-03-16T12:00:01Z",
  "host": "raspberrypi",
  "devices": [
    {
      "path": "device-id-from-probe",
      "bus": "i2c",
      "identified_as": "BME280",
      "category": "sensor",
      "capabilities": ["read_temperature", "read_humidity", "read_barometric_pressure"],
      "confidence": 0.95,
      "identification_method": "descriptor_driver",
      "notes": "Driver bme280 loaded; address 0x76 is default."
    }
  ]
}
```

### Fields

- `stage`: always `"identify"`
- `devices[]`: one entry per probe device — never drop a device
- `category`: one of `sensor`, `actuator`, `bidirectional`, `infrastructure`, `unknown`
- `capabilities`: concrete actions like `read_temperature`, `set_angle`, `capture_image`, `set_color`
- `confidence`: 0.0–1.0 (higher = more certain)
- `identification_method`: how you identified it (e.g., `descriptor_driver`, `vid_pid_lookup`, `web_search`, `heuristic`)

## Filtering

Only include devices that an AI agent could meaningfully control or read from via MCP tools. **Drop** pure infrastructure devices that have no actionable capabilities — USB host controllers, Thunderbolt buses, memory modules, internal SSDs, virtual network adapters, serial port profile entries, and duplicate bus entries. These just add noise.

**Always keep these high-value device types** — never filter them out:

- **Cameras** (USB webcams, CSI cameras, FaceTime cameras) — capabilities: `capture_image`, `capture_video_frame`.

- **USB-serial adapters** (CH340, CH9102, CP2102, FTDI, Arduino CDC, etc.) are rarely the product themselves — they're buses for something specific. Web-search the workstation context (chip VID:PID + descriptor strings + manufacturer) to identify the *attached product*. Emit capability names that reflect that product (e.g. `arm_set_joint_angle`), not the chip. **Never default to `send_serial_command` / `serial_write` / `raw_bytes_write`** — those leak protocol internals and defeat the point of MCP tools. If you cannot determine what's behind a USB-serial adapter from probe evidence + a quick web search, set `identified_as: "Unknown USB-serial device"` and `category: "unknown"`. Do not invent.

- **Paired Bluetooth peripherals** — only include them when there is a real software path to drive them. Probe surfaces paired devices, but a vendor-specific capability (custom noise-cancelling, vendor app features, etc.) usually requires a proprietary SDK the OS does not ship. Emit a tool only when (a) an OS-provided API can drive the device (system audio routing, standard HID input, A2DP playback), or (b) a standard profile fully covers the capability. Otherwise leave the device as `category: "infrastructure"` or drop it.

- **Network-reachable peers** (mDNS services, LAN neighbors from `arp -a`, WiFi SSIDs in range) — record them in the probe JSON for observability, but **do not promote them to `category: "actuator"` / `"sensor"` here** unless this machine has concrete credentials and a working library to actually control them. Use `category: "infrastructure"` (or drop them) so the INTERFACE stage knows not to generate MCP tools for them. Being visible on the network is not the same as being controllable by this install.

### Controllable-only rule (load-bearing)

A tool that always returns `NotImplementedError` is worse than no tool — it pollutes the discovery surface, wastes agent turns, and undermines trust. Before emitting a capability:

1. Is there a concrete library on this machine (or installable via `pip install`) that drives this exact device?
2. Or is there a standard OS API (CoreVideo, V4L2, GPIO, ALSA, AVFoundation, etc.) that gives real I/O?

If **neither**, do NOT emit a capability. Set `category: "infrastructure"` and move on.

### Privileged-hardware identification (deep demo support)

A handful of devices are part of Octopus's *demo* rig and get curated identification rules. These rules only fire when the probe genuinely surfaced the matching evidence — never as a default.

- **SO-ARM101 / SO-ARM100 robotic arm**: a USB-serial device whose chip is **CH340 (VID 1a86:7523)** or **CH343 (VID 1a86:55d3)** AND whose descriptor or surrounding probe context names Feetech, STS3215, LeRobot, SO-ARM100, or SO-ARM101. When that pattern matches, identify as `SO-ARM101` (or `SO-ARM100` for the 4-DoF version) with `category: "actuator"` and capabilities `arm_set_joint_angle`, `arm_get_joint_angle`, `arm_home`, `arm_set_all_joints`. The privileged step `protocol/privileged/arm.md` runs after the pipeline and verifies/patches these tools using `scservo_sdk`. **If the chip is present but no Feetech/SO-ARM evidence is anywhere in probe output, do NOT emit arm tools** — a bare CH340 could be anything (Arduino, generic USB-serial cable, a different product). Identify as `category: "unknown"`.

- **Camera rail controller**: a USB-serial device whose product string contains "Arduino" or "MKRZero". Identify as a rail controller with capabilities `rail_move_x`, `rail_move_y`, `rail_home`; the privileged step `protocol/privileged/perceive.md` generates the actual tools.

Focus on devices a user would actually want an AI to interact with: sensors, cameras, microphones, speakers, displays, actuators, Bluetooth peripherals with a known software path, Wi-Fi (scanning networks), etc.

Keep the output list to roughly **5-15 devices** even if the probe found more. Fewer devices with well-defined capabilities is better than an exhaustive list.

## Constraints

- Describe what devices can DO (capabilities), not just input/output classification.
- Use snake_case for capability names: `read_temperature`, `set_pwm_duty`, `capture_image`.
- If you can't identify a device, set `identified_as` to `"Unknown"`, `category` to `"unknown"`, and `confidence` to `0.0`.
- List only 2-5 core capabilities per device. Don't enumerate every possible sub-function.
