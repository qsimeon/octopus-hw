# ARM — Robotic Arm Framework Step (Privileged)

## Objective

The general pipeline has discovered hardware and generated MCP tools. If any of that
hardware is a **robotic arm** (the demo privileges the SO-ARM100 / SO-ARM101 with
Feetech STS3215 bus servos), verify that the `arm_*` tools in `_generated/serve/server.py`
are correct — and if not, rewrite them using the proper SDK.

## Plug-and-play (validated 2026-05-02)

The SO-ARM101 is **plug-and-play**: USB-serial CH343 chip, Feetech STS3215 over
Dynamixel-compatible at 1,000,000 bps, all servos pingable + movable from a from-scratch
Python script. **No vendor toolchain required** — `lerobot.calibrate`, the LeRobot CLI,
or any other vendor software is **not** a prerequisite. If the agent generates correct
tool code, the arm responds.

## Bus rules — individual writes only

**Do NOT use SYNC WRITE / GroupSyncWrite (instruction 0x83) for multi-servo moves.**
The STS3215 firmware on this rig does not properly support SYNC WRITE — only one servo
moves when commanded that way. Use **individual `write2ByteTxRx` per servo** instead;
loop the joints and write each one sequentially. Slightly slower but reliable.

## Servo allocation (demo rig)

In the current demo rig **servo #1 (base rotation) is intentionally disabled** — the
original servo #3 was physically broken; teammates swapped it with servo #1 and
re-programmed IDs, so the broken motor now sits at ID 1 where missing motion is least
visible during a demo. **Tool implementations should treat joint 1 as a no-op** (still
expose the tool, but skip the actual write and return a marker like
`{"status": "skipped", "reason": "joint 1 disabled in demo rig"}`). Multi-joint pose
helpers should iterate IDs 2–6 only.

This is the arm analogue of `perceive.md` for the camera: a conditional post-pipeline
step that provides curated context for a specific privileged device so any supported
model produces correct tools.

This step is **conditional** — if the pipeline did not discover an arm, it exits cleanly
and does nothing.

## What to do

1. Read `_generated/identify/output.json`. Look for any device whose
   `identified_as` names a robotic arm (e.g. `"SO-ARM101"`, `"SO-ARM100"`)
   OR whose `category` is `"actuator"` with arm-flavored capabilities
   (`set_joint_angle`, `arm_*`, etc.).

   If no arm was identified, write `{"status": "no_arm", "reason": "no robotic arm in identify output"}`
   to the output path and exit cleanly.

2. Read `_generated/serve/server.py`. Check whether it already has well-formed arm tools:
   - Tools named `arm_*` (or the equivalent namespace the pipeline chose)
   - Uses `scservo_sdk` (imported from the `feetech-servo-sdk` pip package)
   - Opens the correct serial port (usually `/dev/ttyACM0` on Pi, varies on Mac)
   - Uses `PacketHandler(0)` — protocol version 0 is required for SCS / Feetech servos
   - **Enables torque at module init** — `write1ByteTxRx(port, mid, 40, 1)` for motor IDs 1-6. This is non-negotiable: without it, every position command succeeds on the wire and does nothing physically. If the current server.py is missing the torque-enable loop, that alone is reason to rewrite.

3. **Verify physical motion, not just server acks.** `status: ok` from `arm_set_joint_angle` only proves a packet was accepted — it does NOT prove the servo physically moved. You MUST do a before/after position read:
   a. `before_raw = arm_get_joint_angle(2)` — current raw position of joint 2
   b. Pick a target far from `before_raw` (e.g. if before ≈ 2048, target raw ≈ 1500 or 2500).
      Convert to degrees and call `arm_set_joint_angle(joint=2, angle=<deg>, speed=500)`.
   c. Wait ~2 seconds for the servo to slew.
   d. `after_raw = arm_get_joint_angle(2)` — current raw position again.
   e. If `|after_raw - before_raw| < 50` (negligible motion for a commanded large move),
      **the servo is not responding**. The most common cause is missing torque-enable.
      Rewrite server.py to add the torque-enable loop, restart the server, and repeat
      the verification.
   f. If the servo does move, record the before/after/target numbers in the output
      notes so the user can see proof.

4. If the arm tools look correct AND the physical-motion check passed, write
   `{"status": "ok", "arm_tools": [...], "notes": "verified motion: joint 2 moved from <before> to <after> raw (commanded <target>)"}`.
   Otherwise, rewrite the arm section as described, restart the server via
   `bash ~/octopus/_generated/deploy/start.sh` (after killing the old server),
   and re-run the verification. Do not claim "ok" without a successful motion check.

5. If the arm tools are missing, stubbed, or wrong (e.g. raw pyserial bytes, `ch340_*`
   tool names, `send_serial_command`, tools that return `"not implemented"`),
   **rewrite that portion of `server.py`** using the SDK. Keep the rest of the file
   intact (do not touch camera tools, GPIO tools, etc.).

   When rewriting, you have full freedom on tool naming and structure. The facts you
   need are:

### SO-ARM101 / SO-ARM100 facts

- **Hardware**: 6× Feetech STS3215 bus servos daisy-chained on a single serial bus
  (SO-ARM101 is 6-DoF; SO-ARM100 is 4-DoF — same protocol, fewer motors).
- **Serial bus**: USB-serial adapter (CH340 or CH343) at **1,000,000 bps — exactly**.
  This is the manufacturer's factory-set baudrate for STS3215 servos. **Do not lower
  it as a workaround for transient comm errors.** Lowering the baudrate makes every
  read return "no status packet" while broadcast writes silently appear to succeed
  at the SDK layer (the motors never actually move). If the bus is flaky, fix it with
  a thread lock and **individual per-servo writes**, not by changing speed. Use the
  device path the probe/identify stages reported.
- **Library**: `feetech-servo-sdk` (pip package) imports as `scservo_sdk` (Python module).
  `from scservo_sdk import PacketHandler, PortHandler, COMM_SUCCESS`.
- **Protocol version**: 0 (SCS). `PacketHandler(0)` — **the argument is required**.
  Without it you get `PacketHandler.__init__() missing 1 required positional argument`.
- **Position range**: 0–4095 (12-bit magnetic encoder). Center ≈ 2048.
- **Motor IDs** (flashed to each physical servo — do not reassign) map to LeRobot's
  canonical joint names. **Always use these names in tool parameters and output** so
  the agent and user speak the same language as the LeRobot ecosystem:

  | ID | LeRobot name   | Physical joint     |
  |----|----------------|--------------------|
  | 1  | `shoulder_pan` | Base rotation (yaw) |
  | 2  | `shoulder_lift`| Shoulder (pitch)   |
  | 3  | `elbow_flex`   | Elbow              |
  | 4  | `wrist_flex`   | Wrist pitch        |
  | 5  | `wrist_roll`   | Wrist roll         |
  | 6  | `gripper`      | Gripper open/close |

- **Reading position**: `read2ByteTxRx(port, motor_id, ADDR_PRESENT_POSITION)`.
- **Writing position**: `write2ByteTxRx(port, motor_id, ADDR_GOAL_POSITION, raw)`.
- **Register addresses** (STS3215 memory map):
  - `ADDR_TORQUE_ENABLE    = 40`  (1 byte, must be 1 for servo to act on commands)
  - `ADDR_STS_GOAL_ACC     = 41`  (1 byte, 0–254 ramp; default 30 for smooth motion. Without setting it, the servo defaults to maximum acceleration and slams to full speed instantly — movements look jerky and abrupt.)
  - `ADDR_GOAL_POSITION    = 42`  (2 bytes, target position)
  - `ADDR_GOAL_SPEED       = 46`  (2 bytes, 0–32767; smaller is slower)
  - `ADDR_PRESENT_POSITION = 56`  (2 bytes, current position)
  - `ADDR_PRESENT_LOAD     = 60`  (2 bytes, instantaneous load)
  - `ADDR_PRESENT_VOLTAGE  = 62`  (1 byte ×0.1 V)
  - `ADDR_PRESENT_TEMP     = 63`  (1 byte, °C — spec ceiling 40 °C, hard fault ~70 °C)
- **CRITICAL: enable torque at module init.** STS3215 servos silently ignore
  `write2ByteTxRx(GOAL_POSITION)` when torque is disabled — the bus returns
  `result=0` (success) but the physical servo holds position. Right after
  opening the port and instantiating `PacketHandler(0)`, loop motor IDs 1-6 and
  call `packet.write1ByteTxRx(port, mid, ADDR_TORQUE_ENABLE, 1)` for each.
  Without this, every position command silently no-ops.
- **Authoritative reference**: lerobot SO100m wiki
  <https://wiki.seeedstudio.com/lerobot_so100m/>.

### Degrees ↔ raw: use calibration, don't hard-code ranges

The canonical LeRobot setup stores a per-robot calibration file mapping raw 0-4095
to each joint's physical range. **Read this file before inventing your own
`_JOINT_LIMITS` table** — hand-tuned tables drift from the physical arm and
produce bizarre mappings (commanding 45° → servo ends up at 105°).

- **Path**: `~/.cache/huggingface/lerobot/calibration/robots/<robot-id>.json`
  (varies per installation — glob for `*.json` under `calibration/robots/`).
- **Schema**: per-joint `{"min": <raw>, "mid": <raw>, "max": <raw>}`.
- **Conversion**: `angle_deg = (raw - mid) / (max - min) * 240.0`  (LeRobot
  normalizes to a ±120° half-range around mid).
- **If the calibration file is missing**, note it in output and emit tools that
  operate in **raw units only** (e.g. `arm_set_joint_raw(joint, raw_0_4095)`).
  Do not invent degrees-to-raw math from thin air. The user runs
  `lerobot-calibrate --robot.type=so101_follower --robot.port=/dev/ttyACM0
  --robot.id=<name>` once to generate the file.

### Joint-2 thermal management

`shoulder_lift` (joint 2) holds the arm against gravity at full torque draw — STS3215 datasheet recommends 0–40 °C, but joint 2 runs 60–70 °C under sustained load (within absolute spec, above recommended). LeRobot has no gravity compensation. Rules:

- **`arm_home()` parks in a gravity-neutral pose, not all-centered-at-2048.** Fold `elbow_flex` so the forearm's CoM sits over joint 2's rotation axis (≈1200 raw, but consult calibration). A straight arm at home puts joint 2 under peak holding load.
- **`arm_rest()` disables torque on joints 2 and 3 for ~30 s** (write 0 to `ADDR_TORQUE_ENABLE` for those IDs, sleep, write 1 back). Daemon-callable cooldown.
- **At 55 °C: trigger `arm_rest()` automatically.** Don't block other joints — return `{"status": "queued", "thermal_rest_active": true, "available_joints": [...], "retry_after_seconds": N}` for joint-2 calls during rest; calls to non-thermal joints proceed.
- **Don't loop-command joint 2 to the same position.** Re-issuing the same goal under load is what cooks the motor.

Python gotcha: if `arm_rest()` reads a module-level mutable (`_rest_start_time`, `_arm_busy`) it also writes, declare `global` at the top of the function — generators have repeatedly hit `UnboundLocalError` here.

### USB topology rules

**Do NOT route the USB camera through a hub** (LeRobot FAQ — shared hub causes
silent VIDIOC timeouts). Specifically:

- **Arm and camera must be on separate USB controllers.** On a Pi 4, the arm
  goes on one of the two USB 2.0 root ports and any UVC camera on a USB 3.0
  root port (the blue ones). Shared hub → intermittent camera failures and
  arm reinit storms.
- If two cameras must coexist, only one can be UVC-class on a given hub.

### Tool wrapper must hide transient USB flaps

`cdc_acm` drops `/dev/ttyACM0` every 10-15 min on the Pi. The current server
surfaces `{"error": "Arm not connected", "transient": true}` on the call that
catches the drop; users see a scary error even though the next call works.

- Every arm tool wrapper must **internally retry once** after a `transient:true`
  failure before returning to the caller. Retry delay: 800-1200 ms (typical
  reconnect time). Only surface the error if the retry also fails.
- The flag goes in the response *if and only if* both attempts failed, so
  callers can still distinguish "USB is genuinely stuck" from "one-shot flap."

### Minimum set of arm tools to produce

Name them consistently (`arm_*` is the convention in the existing codebase).
**Parameters should accept either the motor ID (1-6) or the LeRobot joint name**
(`shoulder_pan`, `shoulder_lift`, …, `gripper`) — don't force the user to
remember "2 = shoulder_lift".

- `arm_set_joint_angle(joint: int | str, angle: float, speed: int = 500, acc: int = 30)` — set one joint by ID or name. Set `ADDR_STS_GOAL_ACC` *before* `ADDR_GOAL_SPEED` *before* `ADDR_GOAL_POSITION`; the order matters because the servo applies the latest values when it sees the position write. `acc=30` is the smooth-motion default; `acc=0` uses maximum acceleration (jerky).
- `arm_get_joint_angle(joint: int | str)` — read one joint's current angle
- `arm_home()` — move to the **gravity-neutral rest pose** defined above, not raw 2048
- `arm_rest()` — torque-off joints 2 and 3 briefly to cool joint 2 (see thermal rules)
- `arm_set_all_joints(angles: dict | list[float])` — loop joint IDs, individual `write2ByteTxRx` per servo (NOT `GroupSyncWrite` — see §Bus rules)
- `arm_read_status(joint: int | str = None)` — when `joint` is omitted, return per-joint
  diag for all 6. Having a no-arg default makes it useful from dashboards and
  avoids pydantic's "missing required argument" rejection.

Each tool should:
- Be gated by an `if not HAS_FEETECH: raise RuntimeError(...)` check (the library may
  be missing on non-robotics platforms)
- **Open the serial port LAZILY** — not at `import` time. Use a module-level
  cache variable and a getter (`_get_arm()`) that opens the port on the first
  tool call and reuses it on every subsequent call. Opening at import-time
  breaks `fastmcp list` and other tooling that imports server.py without
  intending to talk to hardware, AND it deadlocks with the already-running
  server (only one process can hold `/dev/ttyACM0`). Lazy-init is the only
  correct pattern.
- Not open / close the port per call — once `_get_arm()` opens it, reuse
- **Internally retry once** on `transient:true` before returning (see wrapper rule)
- **Accept the LeRobot joint name** as a string alias for the motor ID

### Tool return shapes (load-bearing — clients depend on these)

The Join39 REST bridge and the docs-site demo buttons parse these responses
key-by-key. **The schema is fixed, the keys must be present, the types must
match** — even when extending tools, don't drop or rename these keys:

`arm_set_joint_angle(joint, angle, speed=300)` → success:
```json
{"status": "ok", "joint": 2, "joint_name": "shoulder_lift",
 "raw_before": 2048, "raw_after": 1500, "raw_target": 1500,
 "deg": -45.0, "speed": 300}
```

`arm_get_joint_angle(joint)` → success:
```json
{"status": "ok", "joint": 2, "joint_name": "shoulder_lift",
 "raw": 1500, "deg": -45.0, "temperature_c": 38, "load": 120}
```

`arm_home(speed=300)` / `arm_rest()` → success:
```json
{"status": "ok", "pose": "home" | "rest",
 "joints": {"1": 2048, "2": 1200, ...}, "duration_ms": 1850}
```

`arm_set_all_joints(angles)` → success:
```json
{"status": "ok", "joints_set": {"shoulder_pan": 0, "shoulder_lift": -45, ...},
 "skipped": ["shoulder_pan"]}
```

`arm_read_status(joint=None)` → success (no-arg = all 6 joints):
```json
{"status": "ok",
 "joints": [
   {"joint": 1, "joint_name": "shoulder_pan", "raw": 2048, "deg": 0.0,
    "temperature_c": 35, "load": 0, "torque_enabled": true,
    "voltage_v": 7.4, "disabled": false}
 ]}
```

For a **disabled joint** (e.g. servo #1 on the demo rig — see "Servo
allocation" above) ANY of the above tools returns `{"status": "skipped",
"reason": "joint 1 disabled in demo rig", "joint": 1, "joint_name":
"shoulder_pan"}` instead of acting on it. **Do not return a bare error**
for a disabled joint — clients distinguish skipped from real errors.

For a **transient bus error** (e.g. `/dev/ttyACM0` flap mid-call), return
`{"status": "error", "error": "...", "transient": true, "joint": <int>}`.
The wrapper rule above retries once on `transient:true` before bubbling
the error to the caller.

For a **non-transient error**, return `{"status": "error", "error": "...",
"transient": false}` (or omit the `transient` key — clients treat absence
as `false`).

### Port reconciliation (lazy-open + self-healing handler cache)

The lazy-open rule above (`_get_arm()` opens the port on first call, caches it for
reuse) is necessary but not sufficient. The cache must **reconcile its state on
every call** — otherwise a single failed open at startup leaves `port_handler =
None` permanently, and every subsequent tool call returns "Arm port not open
(transient)" forever even after the USB has long since recovered. We have shipped
this exact bug. Don't ship it again.

The fix is a small state machine inside `_get_arm()` paired with a
"clear-cache-on-transient" rule in every tool wrapper. Together they make the
arm tools self-healing without needing the daemon to restart the server.

`_get_arm()` reconciliation rules:
1. If a cached `port_handler` exists AND `port_handler.is_open` is truthy, return it.
2. Otherwise, attempt to open the port (`PortHandler(device_port)`, `setBaudRate(1_000_000)`,
   `openPort()`). On success: re-enable torque on motor IDs 2–6
   (`write1ByteTxRx(handler, mid, 40, 1)` — joint 1 is disabled in the demo rig and
   gets skipped per "Servo allocation"), cache the new handler, and return it.
3. On any exception during step 2 (SerialException, OSError "device or resource busy",
   `[TxRxResult] no status packet`, etc.): clear the cache (`port_handler = None`)
   and return `None`. The caller raises a `transient:true` error and the next call
   retries open from scratch.

Tool wrapper reconciliation rule (every `arm_*` tool):
- Wrap the actual SDK call in a `try/except`. On **any** exception consistent with
  a bus drop (`serial.SerialException`, `OSError`, `Exception` whose `str()` contains
  `"no status packet"` or `"device disconnected"`), set the module-level
  `port_handler = None` BEFORE returning. The next call will re-enter `_get_arm()`,
  hit branch 2, and reopen.

Pseudocode sketch:

```python
_port_handler = None  # module-level cache

def _get_arm():
    global _port_handler
    if _port_handler is not None and getattr(_port_handler, "is_open", False):
        return _port_handler
    try:
        ph = PortHandler(DEVICE_PORT)
        ph.openPort()
        ph.setBaudRate(1_000_000)
        for mid in (2, 3, 4, 5, 6):  # joint 1 disabled in demo rig
            packet.write1ByteTxRx(ph, mid, ADDR_TORQUE_ENABLE, 1)
        _port_handler = ph
        return _port_handler
    except Exception:
        _port_handler = None
        return None

def arm_get_joint_angle(joint):
    global _port_handler
    ph = _get_arm()
    if ph is None:
        return {"status": "error", "transient": True, "error": "port not open"}
    try:
        raw, comm, err = packet.read2ByteTxRx(ph, mid, ADDR_PRESENT_POSITION)
        if comm != COMM_SUCCESS:
            _port_handler = None  # force reopen next call
            return {"status": "error", "transient": True, "error": "no status packet"}
        return {"status": "ok", "joint": mid, "raw": raw, ...}
    except Exception as e:
        _port_handler = None  # force reopen next call
        return {"status": "error", "transient": True, "error": str(e)}
```

This is **local-retry first**. The watch.md/heal.md `device_moved_error` pathway
is the **second line of defense**: if a tool's wrapper retry-once still
fails three cycles in a row, the daemon classifies it as `device_moved_error` and
triggers a full `run_reprobe()` to refresh `_generated/{probe,identify}/output.json`
with the new device path. The two layers compose — most flaps clear in <2 s via
local-retry, and only true re-enumerations escalate to reprobe.

6. After rewriting, write the output JSON to the orchestrator-specified path. Example:

```json
{
  "status": "patched",
  "arm_tools": ["arm_set_joint_angle", "arm_get_joint_angle", "arm_home", "arm_set_all_joints"],
  "device_port": "/dev/ttyACM0",
  "notes": "serve stage produced ch340_send_serial_command tools; rewrote using scservo_sdk"
}
```

7. **Do not restart the server gratuitously at the end of this step.** Step 4's
   restart was for the in-flight verification cycle; once the rewrite is verified,
   leave `server.py` edited. The daemon's heal loop will pick up future changes,
   or the user can run `octopus start`.

8. **Working files go in `_generated/arm/`, not the project root.** Any verification
   scripts you write while patching (sanity probes, motion tests, single-shot scratch
   files) must be created inside `_generated/arm/` and deleted after use, OR kept there
   permanently. **Never write `test_*.py`, `motion_*.py`, etc. at the project root** —
   those leak into the user's clone and pollute every fresh install. The `tests/` dir
   is for the official pytest suite only; you don't add to it.

## Output format

```json
{
  "status": "ok" | "no_arm" | "patched" | "error",
  "arm_tools": ["arm_set_joint_angle", ...],
  "device_port": "/dev/ttyACM0",
  "notes": "string description of what happened"
}
```

## Constraints

- Do **not** re-run device discovery — the pipeline already did that. Trust identify.
- Do **not** touch tools unrelated to the arm (camera, GPIO, Bluetooth, etc.).
- Do **not** install pip packages from this step. The deploy stage handles deps.
  If `scservo_sdk` is missing, note it in the output and let the daemon's heal loop
  catch up.
- Web-search is allowed and encouraged if anything here is unclear. The lerobot wiki
  above is the authoritative reference.
- Keep the rewrite minimal — patch just the arm tools; don't refactor the whole file.
- If the arm is already correctly wired, say so and exit. Don't rewrite for fun.
