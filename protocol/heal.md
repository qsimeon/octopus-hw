# HEAL — Automatic Server Repair

## Objective

Given a health report from the WATCH stage, diagnose and fix server issues.

## What to do

1. Read the watch report (path provided by the orchestrator).
2. Read the server file at `_generated/serve/server.py`.
3. For each error in the report:
   - `import_error` / "not installed" — install the missing package using `pip install` or `uv pip install`.
   - `runtime_error` in a tool — read the traceback, rewrite the broken tool function.
   - `syntax_error` — fix the syntax in server.py.
   - `server_down` / server not running — restart using `bash _generated/deploy/start.sh`.
   - **`device_moved_error`** — the log shows `[Errno 2] No such file or directory: '/dev/ttyACM*'`, repeated `[TxRxResult] no status packet` storms after a previously-quiet bus, or `serial.serialutil.SerialException: device disconnected`. The device is still physically present but moved to a different `/dev/ttyACM*` (the OS re-enumerated after a re-plug, USB bus reset, or arm power-cycle). Do NOT rewrite the tool — the code is correct, the path is stale. Set the heal-report `status` to `device_moved_error`. The orchestrator's daemon detects this status and triggers `run_reprobe()` on the next cycle, which re-runs probe + identify (refreshing `_generated/{probe,identify}/output.json` with the new device path) and re-runs the perceive + arm privileged steps to patch the live server in place. Users can also invoke this manually via `octopus reprobe`.
4. If you modified `server.py`, restart the server.
5. Write a heal report to the output path.

## Output format

The orchestrator's daemon parses this file. **Schema is fixed.**

```json
{
  "status": "healed" | "partial" | "failed" | "device_moved_error",
  "actions_taken": [
    {
      "error": "<short description of the original problem>",
      "action": "<what was done to fix it>",
      "result": "ok" | "failed"
    }
  ],
  "server_restarted": true
}
```

Required keys: `status`, `actions_taken` (may be empty list), `server_restarted` (boolean). The orchestrator branches on `status`:
- `healed` / `partial` → continue normal daemon loop
- `failed` → log + retry next cycle
- `device_moved_error` → trigger `run_reprobe()` immediately, skip the next sleep

**Status values:** `healed` (all errors fixed), `partial` (some fixed, some remain), `failed` (could not fix), `device_moved_error` (re-discovery needed; daemon will trigger reprobe).

## Constraints

- Never delete tools. Only fix or improve them.
- Back up server.py before modifying: `cp server.py server.py.bak`
- Test syntax after any edit: `python -c "import py_compile; py_compile.compile('_generated/serve/server.py', doraise=True)"`
- If you can't fix an error, leave it and report `"partial"`.
- Use the same launcher script to restart: `bash _generated/deploy/start.sh`
