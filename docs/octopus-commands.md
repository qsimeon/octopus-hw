# Octopus CLI — Complete Command Reference

Every `octopus` command explained in plain English.

---

## `octopus run`
**What it does**: Runs the full 5-stage hardware discovery pipeline from scratch.

The pipeline takes ~20-30 min on Mac, ~25-45 min on Pi (varies by model — Sonnet 4.6 is fastest, GLM-5.1 free tier is slowest). It:
1. Probes the OS for all connected hardware
2. Identifies what each device is (arm, camera, GPIO, etc.)
3. Generates MCP tool schemas
4. Writes a FastMCP server (server.py) with real hardware I/O code
5. Deploys the server on port 7777

```bash
octopus run
```

Use `--resume` to skip already-completed stages:
```bash
octopus run --resume
```

---

## `octopus status`
**What it does**: Shows everything that's running, including URLs.

```
Octopus v4.5 (demo mode)

  Server:  RUNNING (PID 12345, port 7777)
           Local:  http://192.168.1.100:7777/mcp
           LAN:    http://192.168.1.100:7777/mcp
  Tunnel:  https://random-words.trycloudflare.com/mcp  ← use this for remote clients
  Daemon:  RUNNING (PID 12346)
  Tools:   16
  Perceive: ok (3 frames)

  Dir:     /home/qsimeon/octopus
```

**The URL you want to share with agents**: the Tunnel URL (if running).

---

## `octopus start`
**What it does**: Starts the deployed MCP server (after pipeline has run).

```bash
octopus start
```

Use this if the server crashed. Does NOT re-run the pipeline.

---

## `octopus stop`
**What it does**: Stops the server, daemon, and any Inspector dashboard.

```bash
octopus stop
```

---

## `octopus expose`
**What it does**: Creates a public HTTPS URL using Cloudflare Tunnel.

This is how you make the Pi's MCP server reachable from the internet.

```bash
octopus expose
```

Outputs:
```
✅ Tunnel live: https://random-words.trycloudflare.com
   Claude Desktop Connectors: https://random-words.trycloudflare.com/mcp
   OpenClaw MCP config: { "url": "https://random-words.trycloudflare.com/mcp", "transport": "streamable-http" }
   Railway OCTOPUS_MCP_URL: https://random-words.trycloudflare.com/mcp
```

**Returns the terminal** — runs in background. URL changes every restart.
**To stop the tunnel**: `octopus expose-stop` (or `kill $(cat /tmp/octopus_tunnel.pid)`).

### Wiring Claude Desktop to the tunnel (manual, one-time)

Claude Desktop reads its MCP server list from `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `~/.config/Claude/claude_desktop_config.json` (Linux). Edit it to add Octopus:

```json
{
  "mcpServers": {
    "octopus-pi": {
      "command": "npx",
      "args": ["mcp-remote", "https://YOUR-TUNNEL.trycloudflare.com/mcp"]
    }
  }
}
```

Replace `YOUR-TUNNEL.trycloudflare.com` with whatever URL `octopus expose` printed. Restart Claude Desktop. Tools should appear under the connector menu within ~30 s. (If you already have other entries under `mcpServers`, just add `octopus-pi` alongside them — don't replace the whole object.)

---

## `octopus expose-stop`
**What it does**: Kills the Cloudflare quick-tunnel started by `octopus expose`.

```bash
octopus expose-stop
```

Uses `/tmp/octopus_tunnel.pid` if present; otherwise falls back to `pkill -f
'cloudflared tunnel'`. The MCP server keeps running — only the public URL goes
away. Run `octopus expose` again to get a fresh tunnel URL. (Remember to
update Railway's `OCTOPUS_MCP_URL` env var if anything depends on the bridge.)

---

## `octopus dashboard [url]`
**What it does**: Opens MCP Inspector in your browser — a GUI to browse and test tools.

```bash
octopus dashboard                                           # local server
octopus dashboard https://random-words.trycloudflare.com/mcp  # remote Pi
```

**Returns the terminal** — Inspector runs in background.
**To stop**: `octopus dashboard-stop` (or `kill $(cat /tmp/octopus_inspector.pid)`).

---

## `octopus dashboard-stop`
**What it does**: Kills the MCP Inspector process tree.

```bash
octopus dashboard-stop
```

Use this when you want to launch a new Inspector pointed at a different MCP URL,
or when you just don't need it running anymore. Matches on
`@modelcontextprotocol/inspector` and `mcp-inspector` process names.

---

## `octopus pause`
**What it does**: Stops the daemon (watch/heal loop) but keeps the MCP server running.

Use this to stop burning API tokens while keeping the server up for clients to connect.

```bash
octopus pause
```

---

## `octopus resume`
**What it does**: Restarts the daemon after a pause. Also restarts it if it crashed.

```bash
octopus resume
```

---

## `octopus reprobe`
**What it does**: Re-discovers hardware after a re-plug and patches the **live** server in place — without regenerating it from scratch.

Tiny problem: you yanked the arm USB cable and plugged it back in, and now the live server is calling `/dev/ttyACM0` but the OS re-enumerated the arm onto `/dev/ttyACM1`. Every tool call returns `[Errno 2] No such file or directory`.

Tiny fix: `octopus reprobe` re-runs **probe + identify** to pick up the new wiring, then re-runs the **perceive + arm** privileged steps to patch the running server. The daemon also does this automatically when it sees a `device_moved_error` — `octopus reprobe` is the manual button for when the daemon is paused.

```bash
octopus reprobe
```

Does NOT regenerate `serve/server.py` or `deploy/connection.json` from scratch — the existing tools are still correct, just the device paths are stale.

---

## `octopus chat`
**What it does**: Opens an interactive agent session with full Octopus context.

The agent knows: what hardware is connected, current logs, server URL. It has full read/write/bash access and can call MCP tools.

```bash
octopus chat
octopus chat "move joint 1 to 90 degrees"  # with initial prompt
```

---

## `octopus logs`
**What it does**: Tails the live orchestrator log.

```bash
octopus logs
```

Press Ctrl+C to stop following.

---

## `octopus perceive`
**What it does**: Manually captures a frame from the perception camera.

```bash
octopus perceive
```

Saves to `_generated/perceive/frames/manual_TIMESTAMP.png` and opens it.

---

## `octopus validate`
**What it does**: Checks that the generated server.py is valid Python syntax.

```bash
octopus validate
```

---

## `octopus uninstall`
**What it does**: Stops everything, removes `_generated/`, removes CLI symlink.

```bash
octopus uninstall
# Then to also remove the repo:
rm -rf ~/octopus
```

---

## Common Workflows

### Fresh start on Pi
```bash
ssh qsimeon@100.116.87.36
export OPENROUTER_API_KEY=sk-or-...
curl -fsSL https://raw.githubusercontent.com/qsimeon/octopus-hw/main/install.sh | bash
```

### Get public URL and check status
```bash
octopus expose    # starts tunnel, prints URL, returns terminal
octopus status    # shows Server, Tunnel URL, Daemon, Tools
```

### Server crashed — restart everything
```bash
octopus start     # restart server
octopus resume    # restart daemon
octopus status    # verify both running
```

### Quick arm test (bypass MCP)
```bash
cd ~/octopus
uv run python3 -c "
from scservo_sdk import PortHandler, PacketHandler
p=PortHandler('/dev/ttyACM0'); p.openPort(); p.setBaudRate(1000000)
ph=PacketHandler(0); ph.write2ByteTxRx(p,1,42,int(90/180*4095))
print('Motor 1 → 90°: OK'); p.closePort()
"
```

### SCP latest camera frame to Mac
```bash
scp qsimeon@100.116.87.36:~/octopus/_generated/perceive/frames/capture_latest.png ~/Downloads/
open ~/Downloads/capture_latest.png
```
