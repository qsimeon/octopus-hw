# Octopus Protocol — Universal Agentic Hardware Control

## The Idea

Two ideas, both simple:

1. **The coding agent IS the software.** You don't ship code. You ship an agent that reads specs and writes platform-specific code at runtime. Like an OS is the runtime for apps, the coding agent is the runtime for prompts.

2. **Prompts ARE infrastructure.** Instead of scripts that break when the platform changes, you ship markdown specifications. The agent reads the spec, figures out how to implement it on *this* machine, runs it. Same spec → different code on Mac vs Pi vs Windows. The spec never rots because agents improve.

**Together:** `install.sh` drops a coding agent + a folder of markdown files on any machine. The agent reads the protocol, discovers your hardware, builds an MCP server. Any AI can now control your devices.

**Demonstrated:** `curl | bash` on a Raspberry Pi with a Seedstudio SO-ARM101 robotic arm and USB camera → ~16 MCP tools → `arm_set_joint_angle(2, 45)` → arm physically moves → `lifecam_studio_capture_image` → camera returns frame of the arm. Tool count varies (~15-30) depending on which hardware is connected. Install times: ~10-20 min on Pi with the Gemini 3 Flash default, ~25-45 min with premium models (Sonnet 4.6, Opus 4.7), ~20-30 min on Mac. The pipeline enforces a 10-minute hard budget per stage (3 attempts × ~3.33 min) to bound retries.

## How It Works

```
install.sh
  └─→ installs pi-coding-agent (the runtime)
  └─→ drops protocol/ folder (the specs)
  └─→ runs orchestrator
        │
        ▼  General pipeline (runs for any hardware)
  ┌────────┐   ┌──────────┐   ┌───────────┐   ┌────────┐   ┌────────┐
  │ PROBE  │─→ │ IDENTIFY │─→ │ INTERFACE │─→ │ SERVE  │─→ │ DEPLOY │
  │"what's │   │"what can │   │"make MCP  │   │"write  │   │"make   │
  │plugged │   │ it do?"  │   │ tools"    │   │server" │   │it live"│
  │ in?"   │   │          │   │           │   │        │   │        │
  └────────┘   └──────────┘   └───────────┘   └────────┘   └────────┘
                                                                │
                                                                ▼
                                                    http://0.0.0.0:7777/mcp
                                                                │
        Privileged framework steps (conditional, demo hardware) │
              ┌──────────────────┐     ┌──────────────────┐     │
              │ PERCEIVE         │     │ ARM              │◄────┤
              │ camera selected  │     │ arm tools        │     │
              │ + visual state   │     │ verified/patched │     │
              └──────────────────┘     └──────────────────┘     │
                                                                │
              ┌──────────────────────────────────────────┐      │
              │ DAEMON — WATCH → HEAL  (living backend)  │◄─────┘
              └──────────────────────────────────────────┘
```

The **general pipeline** is device-agnostic and works for whatever hardware is present.
The **privileged framework steps** (`protocol/privileged/perceive.md`, `protocol/privileged/arm.md`) are
conditional — they only do work if the demo-specific hardware (self-perception camera,
robotic arm) is discovered. This split keeps the pipeline general while still giving
the demo hardware reliable, curated support.

## How the public demo reaches our Pi

The buttons on [qsimeon.github.io/octopus-hw](https://qsimeon.github.io/octopus-hw)
drive a real Pi in our apartment. Here's the path a single button click takes:

```
   Your browser
        │
        │  HTTPS POST /tools/invoke
        ▼
   Railway bridge  (Flask, deploys from join39/)
        │
        │  MCP over Streamable-HTTP
        ▼
   Cloudflare quick-tunnel  (https://random.trycloudflare.com/mcp)
        │
        │  forwards to localhost:7777
        ▼
   Raspberry Pi 4
   ├─ fastmcp run _generated/serve/server.py   (the generated MCP server)
   ├─ octopus daemon                            (watch + heal)
   └─ cloudflared tunnel                        (publishes the server)
```

You don't need any of that to **use** Octopus on your own machine — `curl | bash`
gives you a local MCP server with no tunnel and no Railway involved. The hosted
demo is just a convenience for people who want to try it without hardware.

## The Five Stages

**PROBE** — "What's plugged in?" The agent detects the OS, runs appropriate discovery tools (`lsusb` on Linux, `system_profiler` on macOS, etc.), and writes a JSON manifest of every hardware device it finds.

**IDENTIFY** — "What can it do?" The agent reads the probe output and figures out each device's capabilities. It uses driver names, USB vendor/product IDs, web search, and common address tables. Each device gets a confidence score and concrete capabilities like `read_temperature`, `set_angle`, `capture_image`.

**INTERFACE** — "Make MCP tools." The agent generates MCP-compliant tool schemas from the identified capabilities — one tool per capability, with input parameters, descriptions, and implementation hints.

**SERVE** — "Write a server." The agent generates a complete FastMCP server (`server.py`) with real hardware I/O for each tool. The server is self-contained and ready to run.

**DEPLOY** — "Make it live." The agent installs the server's dependencies, starts it over HTTP, and generates config snippets so any AI client (Claude Desktop, OpenClaw, etc.) can connect.

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| **API key** | — | `OPENROUTER_API_KEY` is the only key Octopus needs — one key reaches all supported models. |
| **Python** | 3.11–3.13 | Auto-installed via `uv` if needed |
| **Node.js** | 18+ | Auto-installed via apt/brew if missing |
| **Git** | any | Must be on PATH |
| **OS** | macOS, Linux (Debian/Ubuntu/Pi OS), WSL | Windows native not supported |

## Quick Start

```bash
export OPENROUTER_API_KEY=sk-or-...
curl -fsSL https://raw.githubusercontent.com/qsimeon/octopus-hw/main/install.sh | bash
```

The installer discovers connected hardware, writes a tailored MCP server, starts it, and opens a public Cloudflare tunnel. An interactive menu lets you pick which model drives the agent; edit `[agent].model` in `octopus.toml` afterward to switch.

## CLI Commands

```bash
octopus run         # run pipeline (discovers hardware, generates server)
octopus start       # start deployed MCP server
octopus stop        # stop everything
octopus status      # show server/daemon/tools/perceive state
octopus dashboard   # open MCP Inspector (or: octopus dashboard http://host:port/mcp)
octopus logs        # tail octopus.log
octopus chat        # interactive agent session with full hardware context
octopus pause       # suspend daemon (server stays running, stops API token burn)
octopus resume      # restart daemon (reloads config)
octopus expose      # cloudflare tunnel → public HTTPS URL for remote clients
octopus perceive    # manual perception frame capture
octopus validate    # verify generated server syntax
```

## Connect Your Agent

After installation, the MCP server is running at the URL printed by the installer (also in `_generated/deploy/connection.json`). By default the installer also spins up a Cloudflare quick-tunnel and prints a public HTTPS URL — drop that straight into Claude Desktop / OpenClaw / your phone agent. The server exposes ~15-30 tools depending on which hardware is connected (the demo Pi rig currently serves 16; a richer setup with extra sensors / GPIO / audio surfaces more).

**Note**: `OPENROUTER_API_KEY` is the only credential Octopus needs locally. The hosted demo's camera-cleanup pipeline uses a separate `GEMINI_API_KEY` on the Railway bridge — that's a hosted-demo concern, not a local-install requirement.

### Claude Desktop (local Mac — stdio)

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "octopus": {
      "command": "/path/to/octopus/.venv/bin/python",
      "args": ["/path/to/octopus/_generated/serve/server.py"]
    }
  }
}
```
Use `_generated/deploy/clients/claude_desktop.json` — it has the correct path for your machine.

### Claude Desktop (remote — requires public HTTPS)

Run `octopus expose` to get a public URL, then in Claude Desktop Connectors (Pro/Max plan):
```json
{ "url": "https://xxx.trycloudflare.com/mcp" }
```

### OpenClaw

```json
{
  "mcp": {
    "servers": {
      "octopus": {
        "url": "https://xxx.trycloudflare.com/mcp",
        "transport": "streamable-http"
      }
    }
  }
}
```
The `transport: "streamable-http"` field is required (see openclaw/openclaw#55087).

### Claude Code

```bash
claude mcp add octopus --transport http --url http://localhost:7777/mcp
```

### MCP Inspector (browser-based debugging)

```bash
octopus dashboard                               # local server
octopus dashboard http://100.116.87.36:7778/mcp  # remote Pi via tailscale
```

## Running on Raspberry Pi

```bash
export OPENROUTER_API_KEY=sk-or-...
curl -fsSL https://raw.githubusercontent.com/qsimeon/octopus-hw/main/install.sh | bash
```

The agent discovers whatever's connected — USB webcam, GPIO sensors, I2C devices, serial arms — and generates an MCP server for all of them. On a Pi 4 with SO-ARM101 + Brio 100 + LifeCam + (optionally Arduino MKRZero rail + I²C sensors), the pipeline takes ~10–20 minutes with the Gemini 3 Flash default (~25–45 min with Sonnet 4.6 / Opus 4.7) and generates ~16–30 tools depending on which peripherals are connected at install time. The 10-min/stage budget guarantees the pipeline cannot run away on a slow stage.

## Try the hosted demo (no hardware needed)

Don't have a Pi or arm? Talk to our live Octopus instance through any of these endpoints:

- **Join39 app**: [`octopus-hardware`](https://join39.org/apps) — call from any Join39 agent with `{"action": "list"}` to see live tools, then `{"action": "invoke", "tool_name": "arm_set_joint_angle", "parameters": {"joint": 1, "angle": 90}}` to control the arm.
- **Railway REST bridge**: `https://mellow-miracle-production-b572.up.railway.app/discover` returns the live Pi tool list.
- **Cloudflare tunnel (MCP)**: printed by `octopus expose` after install — drop it into Claude Desktop Connectors or OpenClaw's MCP config.

All three ultimately point at the same Raspberry Pi running the SO-ARM101 + LifeCam Studio reference rig.

## Get Public HTTPS URL (for remote clients)

```bash
# On the device running Octopus:
octopus expose
# → Prints: https://xxx.trycloudflare.com
# Use this URL in any MCP client.
```

For a stable URL that survives restarts:
```bash
cloudflared login
cloudflared tunnel create octopus
cloudflared tunnel route dns octopus octopus.yourdomain.com
cloudflared tunnel run octopus  # runs persistently
```

## Project Structure

```
octopus/
  orchestrator.py     — RALPH loop + daemon + privileged steps
protocol/
  probe.md            — Stage 1: hardware enumeration
  identify.md         — Stage 2: capability identification
  interface.md        — Stage 3: MCP tool schema generation
  serve.md            — Stage 4: FastMCP server generation
  deploy.md           — Stage 5: install deps, start server, write client configs
  watch.md            — Daemon: health monitoring
  heal.md             — Daemon: automatic server repair
  privileged/         — Conditional demo-hardware specs (perceive + arm)
  PROTOCOL.md         — Full specification
tests/                — pytest suite
join39/               — REST→MCP bridge (powers the demo-site buttons)
docs/
  philosophy.md       — design principles
  octopus-commands.md — CLI reference
  index.html          — the demo site
  blog/               — technical blog
octopus.toml          — Configuration
install.sh            — One-command bootstrap
scripts/
  cli.sh              — `octopus` command wrapper
  dashboard.sh        — MCP Inspector launcher
  validate.sh         — verify generated server.py
```

## Philosophy

Ten principles, expanded in [`docs/philosophy.md`](docs/philosophy.md):
**Prompts as protocol** · **Self-reference (two faces: software daemon + hardware camera)** · **Privileged framework steps** · **Interface-agnostic, output-divergent** · **Model calls replace code debt** · **Minimal harness** · **RALPH loop** (Read–Agent–Loop–Pass; building on Geoffrey Huntley's agent-loop idea) · **Markov state propagation** (each iteration sees the current spec plus the immediately prior output, nothing further back) · **Schema discipline** (specs encode the shapes the agent must produce; the orchestrator stays minimal and never re-validates with `isinstance`) · **Bounded retries** (10-min hard budget per stage prevents wedged-stage runaway).

The four that matter most for understanding what makes Octopus structurally different: prompts as protocol (specs are the product), RALPH (the only control structure), Markov state propagation (bounded context across the system), and self-reference (the system observes itself in two distinct layers). Read `philosophy.md` for the full rationale.

## Key Technical Notes

- `feetech-servo-sdk` PyPI package installs Python module as `scservo_sdk` (not `feetech_servo_sdk`)
- `PacketHandler(0)` required for SCS/Feetech protocol version 0
- Motor IDs 1–6 are permanently flashed to the physical hardware — no re-configuration on new computers
- **Servo #1 is hardware-disabled** in the demo rig — generated tools no-op joint 1 so the broken motor doesn't dominate demos
- **No SYNC WRITE** on STS3215 — only individual `write_word` per servo (firmware bug)
- Arm port is opened **lazily** via `_get_arm()` (NOT at module import) so the server can boot when the arm is unplugged
- `transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False)` is required on every `FastMCP()` so cloudflared's public Host header isn't rejected
- Calibration file: `~/.cache/huggingface/lerobot/calibration/robots/so_follower/my_awsome_follower_arm.json`

---

**Quilee Simeon** | MIT MAS.664 | Spring 2026
