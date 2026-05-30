# DEPLOY — Install Dependencies, Start Server, Generate Client Configs

## Objective

The SERVE stage generated a FastMCP server. Now make it usable: install its dependencies, verify it works, start it over the network, and generate config files so AI clients can connect.

## What to do

1. Read the generated server file (path provided by the orchestrator).
2. Parse its imports and install any missing Python packages. Use `pip install` or `uv pip install`. If a package fails to install, note it and continue — the server uses library guards (`HAS_*` flags) so missing packages degrade individual tools rather than crashing the server.
3. Test syntax: `python -c "import py_compile; py_compile.compile('<server_path>', doraise=True)"`.
4. Find an available port starting from 7777. Check if a port is in use with `lsof -i :PORT` (macOS) or `ss -tlnp | grep :PORT` (Linux). Try 7777, 7778, 7779, etc. until one is free. Use that port in all output files.

**CRITICAL ORDER — write all output files BEFORE starting the server:**

5. **Write `connection.json`** to the output path specified by the orchestrator.
6. **Write client config files** to `_generated/deploy/clients/`.
7. **Write a launcher script** to `_generated/deploy/start.sh` that starts the server as a background process.
8. **Execute the launcher script** as the VERY LAST thing you do.

The server runs forever — if you start it before writing the output files, you will hang and never finish. Write everything first, start the server last.

### Launcher script (`_generated/deploy/start.sh`)

The script must:
- read the chosen port from `connection.json` (fall back to 7777)
- kill anything currently bound to that port (portable: `lsof` on Mac, `fuser` on Linux)
- launch `<PROJECT_DIR>/.venv/bin/fastmcp run <PROJECT_DIR>/_generated/serve/server.py --transport http --host 0.0.0.0 --port <PORT>` as a `nohup` background process — the **venv-pinned `fastmcp`, never the system one**. The system `fastmcp` (if any) runs against system Python, which doesn't have `scservo_sdk` / `gpiozero` / `opencv-python` installed, so every hardware tool fails with a silent `ModuleNotFoundError` at first invocation
- write the PID to `_generated/deploy/server.pid` and stdout to `_generated/deploy/server.log`
- export `PATH="$HOME/.local/bin:$PATH"` so `uv` is found (nohup drops PATH on some systems)

## Output format

Write a JSON object to the output path:

```json
{
  "status": "ok",
  "url": "http://0.0.0.0:7777/mcp",
  "port": 7777,
  "transport": "http",
  "deps_installed": ["opencv-python", "gpiozero"],
  "deps_failed": [],
  "tool_count": 30,
  "start_command": "bash _generated/deploy/start.sh",
  "client_configs": {
    "claude_desktop": "_generated/deploy/clients/claude_desktop.json",
    "generic": "_generated/deploy/clients/generic.json"
  }
}
```

Also write these client config files:

### Claude Desktop config (`_generated/deploy/clients/claude_desktop.json`)

Generate TWO connection options. Claude Desktop on the same machine uses STDIO; remote clients use HTTP (StreamableHTTP).

```json
{
  "mcpServers_STDIO_same_machine": {
    "octopus": {
      "command": "<PROJECT_DIR>/.venv/bin/python",
      "args": ["<PROJECT_DIR>/_generated/serve/server.py"]
    }
  },
  "mcpServers_HTTP_any_client": {
    "octopus": {
      "url": "http://<HOST_IP>:<PORT>/mcp"
    }
  },
  "instructions": "Copy ONE of the above into your claude_desktop_config.json under 'mcpServers'. Use STDIO if Claude Desktop is on this machine. Use HTTP for remote connections or other MCP clients."
}
```

Replace `<PROJECT_DIR>` with the actual project directory (use `pwd`). Replace `<HOST_IP>` with the machine's IP. Replace `<PORT>` with the chosen port.

### OpenClaw config (`_generated/deploy/clients/openclaw.json`)

OpenClaw requires an explicit `transport` field. Without it, the client defaults to SSE and fails (see openclaw/openclaw#55087).

```json
{
  "mcp": {
    "servers": {
      "octopus": {
        "url": "http://<HOST_IP>:<PORT>/mcp",
        "transport": "streamable-http"
      }
    }
  }
}
```

Replace `<HOST_IP>` and `<PORT>` with the actual values. This config can be pasted into OpenClaw's MCP settings.

### Generic MCP client config (`_generated/deploy/clients/generic.json`)

```json
{
  "server_url": "http://localhost:7777/mcp",
  "transport": "streamable-http",
  "name": "octopus-hardware"
}
```

## Constraints

- **Write output files BEFORE starting the server.** The server blocks forever.
- Use port 7777 by default. If taken, try 8001, 8002.
- Write the PID so the server can be stopped later with `kill $(cat _generated/deploy/server.pid)`.
- If the server fails to start, set `"status": "error"` in the output and include the error message.
- Create the `_generated/deploy/clients/` directory if it doesn't exist.
