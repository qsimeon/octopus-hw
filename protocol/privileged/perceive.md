# PERCEIVE — The perception subsystem (camera + rail)

## Objective

The pipeline has discovered hardware and generated MCP tools. Some of those tools capture images (webcams, USB cameras, CSI cameras). Your job has two halves:

1. **Camera selection** — pick which discovered camera tool is the "perception eye" (the one pointing at the Octopus body) and generate a thin capture utility that calls it.
2. **Camera rail** — if the rig also has a 2-axis stepper rail that moves the camera, expose `rail_*` MCP tools so the agent can change viewpoint between captures.

The perception subsystem is the **hardware face of the two-faces self-reference principle**: software has the watch/heal daemon that observes its own logs; hardware has this perception loop that observes the rest of the rig. Camera + rail together make perception *agentic* (the agent chooses its viewpoint), not just passive image capture.

This is NOT about detecting cameras from scratch. The pipeline already did that. You are selecting which discovered camera to use for self-perception, wiring up a capture script, and (if the rail is wired) exposing rail control tools.

## What to do

1. Read the interface output (`_generated/interface/output.json`) to find all tools whose name or description involves image capture, camera, webcam, snapshot, or photo.

2. Read the deploy output (`_generated/deploy/connection.json`) to get the MCP server URL and port.

3. **If multiple camera tools exist**: Write a `_generated/perceive/cameras.json` listing all candidates. The orchestrator parses this file — its **schema is fixed** (do not deviate, do not write a bare list at the top level):

   ```json
   {
     "cameras": [
       {
         "tool_name": "<MCP tool name as string>",
         "description": "<one-line description>",
         "device_id": "<bus-and-VID:PID identifier or empty string>",
         "device_type": "<USB | builtin | csi | ip | unknown>",
         "notes": "<free-text reasoning, optional>"
       }
     ]
   }
   ```

   `tool_name` is the **only required key per entry**; everything else is optional but preferred. The top-level wrapper object is mandatory — the orchestrator reads `cameras.json["cameras"]` and assumes it is a list of dicts each having `tool_name`.

   Then pick the best one for perception using these priorities (in order):
   - **Expected-camera hint**: if `octopus.toml` under `[perception]` sets `expected_camera = "..."`, strongly prefer a camera whose tool description matches (case-insensitive substring match on the camera name). The demo ships with `expected_camera = "Microsoft LifeCam Studio"` — prefer that camera if discovered.
   - Prefer USB cameras over built-in cameras (USB cameras are more likely to be the external perception eye).
   - Prefer cameras with "external", "USB", or "peripheral" in their description over "FaceTime", "built-in", or "integrated".
   - If you still can't decide, pick the first USB camera found.
   - **USB topology check**: from the LeRobot FAQ verbatim — *"If the program cannot read image data from the USB camera, ensure the USB camera is not connected through a hub."* If probe output shows an arm on `/dev/ttyACM*`, the selected camera should be on a DIFFERENT USB root controller than the arm. On a Pi 4, that means arm on a USB-2 port (black) and camera on a USB-3 port (blue). Shared-hub topology causes the camera to return `VIDIOC_S_FMT: Operation timed out` whenever the arm reinits — this is the #1 cause of "camera randomly drops" on this hardware. If you detect shared-hub topology, note it in `state_summary.txt` so the user knows to replug.
   - Write your choice and reasoning to `_generated/perceive/output.json`.
   - Note: the user can override this by editing `cameras.json` and re-running perceive.

4. **If exactly one camera tool exists**: Use it.

5. **If no camera tools exist**: Write `{"status": "no_camera", "reason": "No camera tools found in interface output"}` and exit cleanly.

6. Generate a capture script at `_generated/perceive/capture.py` that:
   - Calls the chosen camera MCP tool via HTTP (using `httpx` to POST to the MCP server)
   - Has a `capture_frame(output_path: str) -> dict` function
   - Can be run as CLI: `python capture.py --output /path/to/frame.png`
   - Decodes the base64 image from the tool response and writes it to disk
   - Returns JSON to stdout: `{"status": "ok", "path": "...", "timestamp": "...", "tool_name": "..."}`
   - Handles errors gracefully: `{"status": "error", "message": "..."}`

7. Test the capture by calling the script once, saving to `_generated/perceive/test_frame.png`. If the test fails (server not running, tool errors), report the error but still write the capture script — the daemon will retry later.

8. Write the output JSON to the orchestrator-specified output path.

## Output format

The orchestrator parses this file. **Schema is fixed.** Required key is `status`; the rest depend on status.

On success:
```json
{
  "status": "ok",
  "camera_tool": "<MCP tool name as string>",
  "server_url": "http://localhost:7777/mcp",
  "capture_script": "_generated/perceive/capture.py",
  "test_frame": "_generated/perceive/test_frame.png",
  "all_cameras": ["<tool_name1>", "<tool_name2>"],
  "selection_reason": "<one-line explanation>"
}
```

If no camera found:
```json
{ "status": "no_camera", "reason": "<one-line explanation>" }
```

If a hardware-side problem was detected (e.g. shared-USB-hub topology):
```json
{
  "status": "ok",
  "camera_tool": "<chosen_tool>",
  "warnings": ["shared USB hub with arm — replug onto separate roots"],
  "...other ok fields..."
}
```

Status values are `ok`, `no_camera`, or `error`. The orchestrator inspects `status` and `camera_tool` only — extra keys are tolerated; missing required keys cause the perceive step to be reported as failed.

## Camera rail (the perception actuator)

If the rig has a 2-axis stepper rail that moves the camera, expose `rail_*` MCP tools so the agent can change viewpoint. The rail is **not** for object manipulation — it is *perception actuation* (the camera *is* the proprioception, since the rail has no encoders).

### When this section runs

If `_generated/identify/output.json` indicates a camera-rail subsystem (search the discovered devices for an Arduino-compatible USB-serial controller hint that the user wired to the rail OR stepper-driver-on-Pi-GPIO patterns), proceed. Otherwise skip — the camera-only flow above is sufficient.

### Hardware (default: USB-serial Arduino)

The current demo rig drives the rail through an **Arduino MKRZero connected to the Pi over USB**. The Arduino runs a tiny line-protocol firmware that translates `MOVE_X N` / `MOVE_Y N` / `HOME` commands into STEP/DIR pulses on the A4988 driver pins. The Pi never touches GPIO directly — it just talks serial.

This is the default because (a) it survives Pi GPIO permission/conflict edge cases, (b) the Arduino's hardware timer makes the step-pulse cadence rock-steady regardless of what else the Pi is doing, and (c) it's the wiring topology our reference rig uses.

| Setting | Value                  |
|---------|------------------------|
| Port    | `/dev/ttyACM1`         |
| Baud    | 115200                 |
| Cmds    | `MOVE_X N`, `MOVE_Y N`, `HOME` (newline-terminated) |
| Reply   | `OK` or `ERR <msg>`    |

The agent should auto-detect the rail Arduino in identify output (look for `Arduino`, `MKRZero`, or `ATmega32U4` in product strings + a `/dev/ttyACM*` port that is NOT the arm). If detection is ambiguous, the user can pin the path in `octopus.toml`:

```toml
[perception]
rail_interface = "serial"   # default; "gpio" forces the override path below
rail_port = "/dev/ttyACM1"  # override if the Arduino enumerates elsewhere
```

### Override: direct Pi GPIO (legacy / no-Arduino rigs)

If the user sets `[perception].rail_interface = "gpio"` OR identify shows GPIO-direct stepper drivers with NO Arduino present, fall back to driving the rail straight from BCM pins via `gpiozero`. STEP/DIR pulses go straight to the driver IC (A4988 / DRV8825 / similar):

| Axis | Motor   | STEP pin (BCM) | DIR pin (BCM) | Step pulse delay |
|------|---------|----------------|---------------|------------------|
| X    | NEMA17  | 17             | 27            | 800 µs           |
| Y    | NEMA17  | 22             | 23            | 800 µs           |

`gpiozero.DigitalOutputDevice` turns each pin into a pulseable line. 800 µs half-period is the speed Yile's reference firmware tested at (~625 Hz step rate). Faster (≤400 µs) risks driver missed-steps depending on motor load and driver IC. The rail has no position feedback (open-loop steppers); track position in software regardless of which interface is chosen.

### MCP tools to expose

If `server.py` does not already expose these as `rail_*` tools, write them. Match the existing camera/arm tool style (FastMCP `@mcp.tool()` decorators, JSON-shaped return values, threading lock for shared resources).

**`rail_move_x(steps: int)`** — clamp `steps` to `[-2000, 2000]`, pulse STEP-X with DIR-X driving the chosen direction, return `{"status": "ok", "axis": "x", "steps": <clamped>, "position": {"x": <new>, "y": <unchanged>}}`. Increment the software position counter inside the lock.

**`rail_move_y(steps: int)`** — same shape, Y axis, increments y counter.

**`rail_get_position()`** — return `{"status": "ok", "position": {"x": <int>, "y": <int>}}` from the software counter.

**`rail_home()`** — drive both axes back to the software-recorded zero pose. Open-loop, so this only works if the position counter has been kept honest since startup. Return `{"status": "ok", "position": {"x": 0, "y": 0}}`.

### Reference scaffold (default — USB-serial Arduino)

The agent generates the actual tool wrappers; this scaffold is what the *bus access* should look like inside each tool (matches the rig's tested firmware):

```python
import serial, threading, json

_RAIL_PORT = "/dev/ttyACM1"        # override via [perception].rail_port if Arduino enumerates elsewhere
_rail_serial = serial.Serial(_RAIL_PORT, 115200, timeout=2.0)
_RAIL_LOCK = threading.Lock()      # serialize against thermal monitor / heal threads
_X_POS = 0
_Y_POS = 0

def _rail_cmd(command: str) -> str:
    """Send a newline-terminated command to the rail Arduino, return its reply."""
    _rail_serial.reset_input_buffer()
    _rail_serial.write((command + "\n").encode())
    return _rail_serial.readline().decode().strip()

@mcp.tool()
def rail_move_x(steps: int) -> str:
    """Move the X axis by `steps` (signed). Open-loop, no encoder feedback."""
    global _X_POS
    steps = max(-2000, min(2000, int(steps)))
    with _RAIL_LOCK:
        reply = _rail_cmd(f"MOVE_X {steps}")
        if not reply.startswith("OK"):
            return json.dumps({"status": "error", "reply": reply})
        _X_POS += steps
    return json.dumps({"status": "ok", "axis": "x", "steps": steps,
                       "position": {"x": _X_POS, "y": _Y_POS}})

# rail_move_y, rail_get_position, rail_home follow the same pattern,
# sending MOVE_Y / HOME commands respectively.
```

### Reference scaffold (override — direct GPIO)

If `[perception].rail_interface = "gpio"`, generate the direct-GPIO variant instead:

```python
from gpiozero import DigitalOutputDevice
import time, threading, json

# Pin assignments (match identify output if it differs from these defaults)
_X_STEP = DigitalOutputDevice(17); _X_DIR = DigitalOutputDevice(27)
_Y_STEP = DigitalOutputDevice(22); _Y_DIR = DigitalOutputDevice(23)
_RAIL_LOCK = threading.Lock()
_STEP_DELAY = 0.0008               # 800 us — tested-safe rate
_X_POS = 0
_Y_POS = 0

def _move_motor(step_pin, dir_pin, steps):
    if steps >= 0: dir_pin.on()
    else:          dir_pin.off()
    for _ in range(abs(steps)):
        step_pin.on();  time.sleep(_STEP_DELAY)
        step_pin.off(); time.sleep(_STEP_DELAY)

@mcp.tool()
def rail_move_x(steps: int) -> str:
    global _X_POS
    steps = max(-2000, min(2000, int(steps)))
    with _RAIL_LOCK:
        _move_motor(_X_STEP, _X_DIR, steps)
        _X_POS += steps
    return json.dumps({"status": "ok", "axis": "x", "steps": steps,
                       "position": {"x": _X_POS, "y": _Y_POS}})
```

### Safety constraints

- **Clamp every move**: `max_single_move_steps = 2000`. The agent should request smaller moves (a few hundred steps) for typical viewpoint shifts.
- **Cumulative position guard**: keep a software running tally per axis; reject moves that would drive the count outside `[-10000, 10000]` (about half the rail's mechanical range — adjust based on the actual rail).
- **Bus arbitration**: the `_RAIL_LOCK` is the same discipline as the arm bus and applies for the same reason — multiple FastMCP request threads + the watch/heal daemon must not race for the serial port (or GPIO, in the override path).
- **No continuous bursts**: the agent should not chain rail moves faster than the camera can capture.
- **Verify with the camera, not assumptions**: the rail has no encoder. After any non-trivial move, the agent should capture a frame and confirm the scene changed. This is principle #2 (hardware self-perception) doing its job — the rail is an actuator without proprioception, so the camera *is* the proprioception.

### Perception protocol (how the agent uses rail + camera together)

This is a usage pattern the agent should adopt, not a rule the spec enforces:

```
1. capture image
2. rail_move_x(N)  or  rail_move_y(N)
3. capture image
4. compare viewpoints (visual diff, occlusion check, object localization)
5. infer environment state
```

Common patterns the agent should consider:

- **Workspace scan**: `rail_move_x` → capture → `rail_move_y` → capture, build a multi-view picture before deciding on an action.
- **Occlusion handling**: if a target isn't visible in the current frame, move the rail before assuming the target is gone.
- **Arm verification**: after an `arm_*` command, optionally `rail_move_x(±200)` and capture again to confirm the resulting pose from a second viewpoint.

The Markov visual state extends per-viewpoint when rail tools are exposed: `state_summary.txt` should include `last_camera_position: {x: <int>, y: <int>}` so the agent doesn't have to re-derive viewpoint from scratch on every tick.

### Output: extending the perceive output JSON

The output JSON already documents the camera selection. If rail tools were generated/verified, also include them:

```json
{
  "status": "ok",
  "camera_tool": "lifecam_studio_capture_image",
  "rail_tools": ["rail_move_x", "rail_move_y", "rail_get_position", "rail_home"],
  "rail_pin_assignment": {"x_step": 17, "x_dir": 27, "y_step": 22, "y_dir": 23},
  "rail_step_delay_us": 800,
  "capture_script": "_generated/perceive/capture.py",
  "selection_reason": "..."
}
```

If no rail is detected, `rail_tools` is omitted and only the camera fields are present.

## Constraints

- Do NOT try to detect cameras directly (no OpenCV VideoCapture, no RTSP scanning). Use the MCP tools that already exist.
- The capture script calls the MCP server over HTTP — it does not import hardware libraries.
- Use `httpx` (already a project dependency) for HTTP calls to the MCP server.
- The capture script must work independently — the daemon and CLI call it as a subprocess.
- If the MCP server is not running when perceive runs, still write the capture script. It will work once the server starts.
- Write to `_generated/perceive/` directory (create it if needed).
