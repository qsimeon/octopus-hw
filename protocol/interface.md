# INTERFACE — MCP Tool Schema Generation

## Objective

Read the identify output from the previous stage and generate MCP-compliant tool schemas — one tool per device capability.

## What to do

1. Read the identify JSON (path provided by the orchestrator).
2. For each device capability, create a tool definition with a name, description, input schema, and implementation hints.
3. Write the result as a JSON array to the output path specified by the orchestrator.

**Respect the identify stage output exactly.** The capability names in `identify/output.json`
are the *contract* with the SERVE stage — do not invent lower-level alternatives. For example,
if identify labels a device as `SO-ARM101` with capabilities `arm_set_joint_angle`,
`arm_get_joint_angle`, `arm_home`, `arm_set_all_joints`, produce exactly those four tools.
Never substitute something like `send_serial_command` or `ch340_write_bytes` — those are
generic fallbacks that bypass the identified device's proper library.

## Output format

Write a JSON array of tool definitions:

```json
[
  {
    "name": "dht22_read_temperature",
    "description": "Read the current temperature from the DHT22 sensor on GPIO4.",
    "device_id": "sim-temp-001",
    "capabilities": ["read_temperature"],
    "input_schema": {
      "type": "object",
      "properties": {
        "unit": {"type": "string", "enum": ["celsius", "fahrenheit"], "default": "celsius"}
      },
      "required": []
    },
    "implementation_hints": {
      "interface": "GPIO",
      "pin": 4,
      "library": "adafruit-circuitpython-dht",
      "notes": "Requires gpio group permissions."
    }
  }
]
```

### Naming + parameters

- Tool names: `{device_type_lowercase}_{capability}`, snake_case.
- Design sensible parameters per capability (`unit` for reads, `angle`/`steps`/`r,g,b` for writes, etc.).
- For unfamiliar capabilities, use an empty `properties` object and note constraints in `implementation_hints`.
- Privileged demo devices have dedicated specs that may overwrite these tools — see `protocol/privileged/arm.md` for robotic arms, `protocol/privileged/perceive.md` for the perception camera + rail.

### Implementation hints

Include enough for SERVE to generate working code: `interface` (GPIO/I2C/SPI/USB/etc.), `pin`/`address`, `library` (preferring SDKs over raw bytes — e.g. `scservo_sdk` for Feetech, `gpiozero` for GPIO), and any constraints (baudrate, timing, lock requirements).

## Preferences

A tool that can't succeed is worse than no tool — it wastes an agent's turn and surfaces a confusing error. Trust the identify stage's filtering: if a device made it through identify with `category: "actuator"` / `"sensor"` and concrete capabilities, generate tools. If it's `category: "infrastructure"` or has no `capabilities`, skip it. Don't second-guess identify's category, and don't re-promote network neighbors / WiFi SSIDs / unpaired Bluetooth scans into tools — identify already filtered those.

If forced to choose between breadth (more tools) and depth (fewer, better-thought tools), pick depth.

## Constraints

- One tool per capability. A device with N capabilities produces N tools.
- All `input_schema` must be valid JSON Schema.
- If the identify output is empty, write `[]`.
- Target is roughly **20–30 tools** for a typical Pi or laptop — enough to cover the real hardware without ballooning into network-neighbor noise.
