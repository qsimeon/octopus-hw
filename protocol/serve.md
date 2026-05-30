# SERVE — FastMCP Server Generation

## Objective

Read the interface output from the previous stage and generate a complete, runnable FastMCP server that performs real hardware I/O for each tool.

## What to do

1. Read the interface JSON (path provided by the orchestrator).
2. Generate a single Python file that creates a FastMCP server with one `@mcp.tool()` function per tool definition.
3. Write the file to the output path specified by the orchestrator.

**Do not run the server.** Just write the file.

## DNS-rebinding protection (must be disabled for tunneled servers)

The generated server is exposed via a Cloudflare quick-tunnel (`octopus expose`),
so the public Host header reaching FastMCP is `*.trycloudflare.com` — NOT the
local `localhost` / bind IP. The underlying `mcp.server.fastmcp.FastMCP` enables
DNS-rebinding protection by default (when its INTERNAL `host` setting defaults
to `127.0.0.1`, which it does), and rejects every non-allowlisted Host header
with HTTP 421 / "Invalid Host header". This silently breaks every public
client (Railway bridge, Claude Desktop, OpenClaw, the docs site).

**Always instantiate FastMCP with DNS-rebinding protection disabled:**

```python
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

mcp = FastMCP(
    "Octopus Hardware Server",
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)
```

We don't need DNS-rebinding protection because:
- The tunnel itself is the public attack surface (and cloudflare handles its own validation)
- The local server only binds to `0.0.0.0:7777` on the Pi's LAN, behind tunnel auth
- Honest hosts come from cloudflared with rotating wildcards we can't enumerate ahead of time
- Defense-in-depth would require populating `allowed_hosts` per tunnel restart, which is hostile to the deploy-once flow

## Concurrency safety for shared-bus hardware

Any hardware on a single shared bus (serial / I²C / RS-485 / SPI) is a
**single-writer resource**. FastMCP handles requests in worker threads; daemon
workers add more threads. Without a lock, interleaved TX bytes corrupt frames
("no status packet", "checksum mismatch" under load only).

**Rules — these are absolute, not suggestions:**

- **Use a `threading.Lock()` per shared bus.** Hold the lock across the entire
  read+write transaction (not just the write). Reads need it too — half-duplex.
- **Use the manufacturer baudrate, exactly.** STS3215 = 1,000,000 bps. Lowering
  the baudrate to "mitigate flake" makes broadcasts return `COMM_SUCCESS`
  while motors never move (the framing becomes unrecognizable; no per-motor
  ack means the SDK can't tell). The only time to change baudrate is if the
  user has already reconfigured the device's baudrate register.
- **STS3215 servos: individual `write2ByteTxRx` per servo, never SYNC WRITE.**
  The firmware on this rig does not properly support SYNC WRITE — only one
  servo moves when commanded that way. Loop joint IDs, write each one,
  inside the lock.

This is a control problem, not a "model calls replace conditionals" violation
(#5 caveat). Bus arbitration must live in code; no prompt prevents thread races.

## Guidelines

- **Library choice:** Use appropriate libraries for the platform. For example, on Raspberry Pi: `gpiozero` for GPIO, `adafruit-circuitpython-dht` for DHT sensors, `smbus2` for I2C, `opencv-python` for cameras, `feetech-servo-sdk` for Feetech STS3215 bus servos.
- **Pin numbering:** Use BCM numbering (not BOARD/physical) when working with GPIO.
- **State management:** Initialize hardware objects once at module level, not inside every tool call (avoids resource leaks). For serial devices, open the port once and reuse.
- **Library guards:** Use `HAS_*` boolean flags from try/except imports. If a library is missing, **raise RuntimeError** (not return an error JSON) so MCP reports it as a real error: `if not HAS_CV2: raise RuntimeError("opencv-python not installed — run: uv add opencv-python")`.
- **Error handling:** Wrap hardware I/O in try/except. Raise exceptions for missing dependencies; return `{"error": str(e)}` only for runtime I/O failures that are expected (e.g. camera temporarily unavailable).
- **Return format:** Return JSON strings. Reads: `{"value": ..., "unit": ...}`. Writes: `{"status": "ok", ...}`.
- **Parameters:** Derive function parameters from `input_schema.properties`. Use Python type hints.

### Camera tools

Camera tools return `{"status": "ok", "image_base64": <b64>, "format": <ext>, "saved_to": <path>, "resolution": [w, h]}` and **also write the frame to disk** at `_generated/perceive/frames/capture_latest.<ext>` (fixed filename — overwrite, don't accumulate; the daemon and SCP both rely on this path).

**Camera resource discipline (single-shot, NOT singleton).** `cv2.VideoCapture(idx)` holds the underlying `/dev/video*` file descriptor open. If your handler caches a long-lived `VideoCapture` instance (the obvious singleton optimization), every concurrent caller gets `Device or resource busy` until the cache is invalidated. The daemon's perceive heartbeat captures every 5 minutes, so any concurrent client call (Claude Desktop, the live-site buttons, manual tool invocation) collides.

The required pattern: open → flush buffer → grab one frame → **`cap.release()` immediately** → return. Use a process-wide `threading.Lock()` (`CAM_LOCK`) so concurrent in-process calls serialize cleanly. Example shape (the agent generates real code; this is the contract):

```python
CAM_LOCK = threading.Lock()

def _capture(idx: int, w: int, h: int):
    with CAM_LOCK:
        cap = cv2.VideoCapture(idx)
        if not cap.isOpened():
            return None
        try:
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, w)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, h)
            for _ in range(5): cap.read()  # flush stale frames
            ret, frame = cap.read()
            return frame if ret else None
        finally:
            cap.release()  # ALWAYS release — never cache the handle
```

Do NOT use the `_get_camera()` singleton pattern that re-uses a global `_cv2_cap`; it leaks `/dev/video0` to subsequent callers and causes the "Camera not available" cascade after the first hiccup. The lock + release-per-call pattern costs ~50–80 ms of camera-warmup overhead but is robust.

### Serial / bus-protocol devices

For any device whose interface is a framed serial/bus protocol (robotic arms, servo
buses, 3D-printer controllers, stepper drivers, etc.), **use the device's proper
SDK** — never raw pyserial bytes. A tool named `send_serial_command` is almost always
a sign that the SERVE stage skipped research. Web-search the device's Python SDK and
use it.

If a device was flagged as a privileged framework device (robotic arm → see
`protocol/privileged/arm.md`, camera → see `protocol/privileged/perceive.md`), that spec's dedicated
step will run after SERVE and will correct any arm/camera tools if needed. You do
not need to be perfect here for those devices — but do your best with whatever web
search reveals, and use the proper SDK when you can identify it.

## Constraints

- The file must be valid Python 3.10+.
- Each tool function must be independently safe — one broken sensor must not crash other tools.
- Do not import from the `octopus` package. The server is self-contained.
- If the interface input is empty, generate a minimal server with zero tools.
- Use stdio transport (the default for `mcp.run()`).
- Keep the server under 500 lines. Each tool function should be 10-20 lines. Don't over-engineer — simple implementations that work are better than elaborate ones that don't fit.

## Observability — required, not optional

Wrap every `@mcp.tool()` so each call and its result (ok / error) is appended to `_generated/octopus.log`. The daemon tails this file to detect failures and trigger heal cycles; without it the self-healing loop is blind. Implementation is up to you (a decorator that wraps `mcp.tool`, or a logging FileHandler attached to a tool-call logger) — what matters is that every call leaves a line and every error is distinguishable from a success.

**Critical rule for the wrapper itself:** when you write a decorator that wraps the tool function, you MUST preserve the wrapped function's signature so FastMCP can introspect it for JSON Schema generation. Use `functools.update_wrapper` (or `@functools.wraps`), not just `wrapper.__name__ = func.__name__`:

```python
import functools

def tool_wrapper(func):
    def wrapper(*args, **kwargs):
        try:
            result = func(*args, **kwargs)
            log.info(f"{func.__name__}: OK")
            return result
        except Exception as e:
            log.error(f"{func.__name__}: ERROR: {e}")
            raise
    functools.update_wrapper(wrapper, func)   # ← REQUIRED, not optional
    return wrapper
```

Without `functools.update_wrapper`, FastMCP sees only the bare `wrapper(*args, **kwargs)` signature, generates a broken `{"type": "string"}` schema for every parameter, and every tool call fails with a Pydantic validation error. The bug is silent at server startup and only surfaces when an MCP client tries to invoke a tool.
