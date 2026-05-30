# The Octopus Protocol — Universal Agentic Hardware Control

**Version 4.6 (Plan 22)** | MIT MAS.664 | Quilee Simeon, Yile Fan, Minggan (Justin) Wei

## Overview

Octopus is a protocol for autonomous hardware discovery, control, and deployment. The "app" is a coding agent plus markdown specs in two tiers: **five general pipeline specs** (probe → identify → interface → serve → deploy) that work for any hardware, and **privileged framework steps** (`privileged/perceive.md`, `privileged/arm.md`) that run conditionally if demo-critical hardware is discovered. A separate **watch/heal daemon** keeps the generated server alive after install. There is no static OS-specific code — each spec is a prompt the coding agent reads and implements at runtime.

The orchestrator sequences the stages using a single control loop — **RALPH** (Read–Agent–Loop–Pass), borrowing from Geoffrey Huntley's agent-loop idea: each stage writes its output to a file in `_generated/{stage}/`, the next stage reads from there. The orchestrator only checks "did a file appear?" — all intelligence lives in the specs. Each iteration sees the current spec plus the immediately prior output, nothing further back (**Markov state propagation**, the bounded-context invariant the system depends on). Agent stdout/stderr is captured to `agent.log` files for debugging.

**Demonstrated**: SO-ARM101 (6-DoF Feetech STS3215 servos, USB-serial via `scservo_sdk`) + USB camera pointed at the arm → closed-loop visual-motor control on Raspberry Pi 4. The same five general specs run on a Mac with a completely different discovered tool set.

## Architecture

```
install.sh
  └─→ installs the coding-agent harness (default: pi-coding-agent)
  └─→ drops protocol/ folder (the specs)
  └─→ runs orchestrator (RALPH loop)
        │
        ▼   General pipeline (device-agnostic, runs on any platform)
  ┌────────┐   ┌──────────┐   ┌───────────┐   ┌────────┐   ┌────────┐
  │ PROBE  │─→ │ IDENTIFY │─→ │ INTERFACE │─→ │ SERVE  │─→ │ DEPLOY │
  │"what's │   │"what can │   │"make MCP  │   │"write  │   │"make   │
  │plugged │   │ it do?"  │   │ tools"    │   │server" │   │it live"│
  │ in?"   │   │          │   │           │   │        │   │        │
  └────────┘   └──────────┘   └───────────┘   └────────┘   └────────┘
                                                                │
                                                                ▼
                                                    http://0.0.0.0:7777/mcp
        Privileged framework steps (conditional, demo-critical)  │
              ┌──────────────────────────┐    ┌──────────────────┐│
              │ PERCEIVE                 │    │ ARM              ││
              │ (camera + rail subsystem)│    │ arm tools        │◄┤
              │ camera selection,        │    │ verified/patched ││
              │ rail GPIO stepper tools, │    │ via scservo_sdk  ││
              │ Markov visual state      │    │                  ││
              └──────────────────────────┘    └──────────────────┘│
                                                                  │
        Daemon — the software half of "self-reference"           │
              ┌──────────────────────────────────────────┐       │
              │ WATCH → HEAL  (living backend)           │◄──────┘
              │ tails the log, classifies failures,      │
              │ patches the server in place              │
              └──────────────────────────────────────────┘

  Public surface
              ┌──────────────────────────────────────────┐
              │ octopus expose                           │
              │   tiny problem: server is localhost-only │
              │   tiny fix: one command spins a Cloudflare quick-tunnel
              │   and prints a public HTTPS URL.         │
              └──────────────────────────────────────────┘
```

## Output Directory

```
_generated/
  probe/
    output.json       ← hardware enumeration
    agent.log         ← agent stdout/stderr
  identify/
    output.json       ← device capabilities
    agent.log
  interface/
    output.json       ← MCP tool schemas
    agent.log
  serve/
    server.py         ← the FastMCP server
    agent.log
  deploy/
    connection.json   ← server URL, port, tool_count
    server.pid        ← background process PID
    server.log        ← server stdout/stderr
    start.sh          ← server launcher (portable)
    clients/          ← config snippets for AI clients
    agent.log
  perceive/                    ← self-perception (optional)
    output.json            ← selected camera tool info
    capture.py             ← thin MCP bridge for daemon
    frames/                ← 2 rolling frames (current + last)
    state_summary.txt      ← compressed visual history (Markov)
    agent.log
  watch/output.json + agent.log   ← daemon health report
  heal/output.json + agent.log    ← daemon repair report
  daemon.pid
  octopus.log                     ← orchestrator log
```

## The Five Pipeline Stages

| Stage | Spec | Input | Output |
|-------|------|-------|--------|
| **PROBE** | `probe.md` | system hardware | `output.json`: platform, devices[], scan_methods[] |
| **IDENTIFY** | `identify.md` | probe output | `output.json`: devices[] with capabilities, confidence |
| **INTERFACE** | `interface.md` | identify output | `output.json`: MCP tool definitions array |
| **SERVE** | `serve.md` | interface output | `server.py`: runnable FastMCP server |
| **DEPLOY** | `deploy.md` | server.py | `connection.json`: URL, port, client configs |

## The Daemon Loop (living backend)

Two specs drive a continuous watch/heal cycle at configurable intervals (default 5 min):

| Stage | Spec | Purpose |
|-------|------|---------|
| **WATCH** | `watch.md` | Read logs + optional perception frame → health report |
| **HEAL** | `heal.md` | Fix errors found by WATCH (install deps, rewrite code, restart) |

**Privileged framework steps** (separate from the daemon — they run *once*
after the general pipeline, not on every tick):

| Stage | Spec | Purpose |
|-------|------|---------|
| **PERCEIVE** | `privileged/perceive.md` | Select camera MCP tool, generate thin capture bridge, set up the camera rail (GPIO stepper). Runs once after `deploy`; subsequent capture is invoked by the daemon. (Plan 21 Phase F merged the standalone `rail.md` here — rail is the perception actuator, not its own subsystem.) |
| **ARM** | `privileged/arm.md` | Verify and (if needed) repair arm tools generated by `serve`. Mandates lazy `_get_arm()` port open and forbids SYNC WRITE on STS3215. |

**Markov visual compression**: the daemon keeps 2 frames (current + last) + a rolling `state_summary.txt` that the light model updates after each watch cycle. Visual history is bounded, not accumulated.

## Running

```bash
uv run python -m octopus.orchestrator --verbose               # pipeline + perceive
uv run python -m octopus.orchestrator --resume --verbose      # skip completed stages
uv run python -m octopus.orchestrator --daemon --verbose      # living backend (watch/heal)
```

## CLI Commands

```bash
octopus run         # run pipeline
octopus start       # start deployed server
octopus stop        # stop everything
octopus status      # show server/daemon/tools/perceive state
octopus dashboard   # open MCP Inspector (or: octopus dashboard http://host:port/mcp)
octopus logs        # tail octopus.log
octopus chat        # interactive agent session with full hardware context
octopus pause       # suspend daemon (server stays running)
octopus resume      # restart daemon (reloads config)
octopus expose      # cloudflare tunnel → public HTTPS URL
octopus perceive    # manual frame capture
octopus validate    # check generated server
```

## Configuration (`octopus.toml`)

```toml
[agent]
command = "pi"
model = "openrouter/google/gemini-3-flash-preview"     # Plan 22 default — speed-first, multimodal
light_model = "openrouter/google/gemini-3-flash-preview"
max_attempts = 3
stage_budget_sec = 600          # 10-min hard budget per stage
stage_attempt_timeout_sec = 200 # ≈3.33 min × 3 attempts ≈ stage_budget_sec
# OPENROUTER_API_KEY is the only credential Octopus needs (Plan 22 Phase B2).
# Installer's interactive menu offers ten OpenRouter models; see octopus.toml
# in the repo for the full slug list (Kimi K2.6, Sonnet 4.6, Gemini 3 Flash,
# DeepSeek V3.2, Opus 4.7, Step 3.5 Flash, MiniMax M2.7, DeepSeek V4 Flash,
# Grok 4.1 Fast, Hy3 Preview free).

[daemon]
watch_interval = 300   # seconds (5 min)

[perception]
enabled = true
capture_interval = 300
frame_dir = "perceive/frames"
max_frames = 2         # current + last; history in state_summary.txt
expected_camera = "Microsoft LifeCam Studio"   # rail-mounted, not the static Brio
rail_step_pulse_us = 800                        # safe range 300-1500 us

[arm]
enabled = true
expected_arm = "SO-ARM101"
# arm.md mandates: lazy `_get_arm()` port open (NOT module import); NO SYNC WRITE
# on STS3215 (firmware bug); servo #1 is hardware-disabled in the demo rig.
```

## What Makes This Different

| Existing Approach | Octopus |
|-------------------|---------|
| Pre-configured MCP tools | Auto-discovers and generates tools at runtime |
| One MCP server per device type | One server adapts to any hardware |
| Human writes tool definitions | Agent generates from device capabilities |
| Static hardware setup | Plug in new device → discovered automatically |
| OS-specific code shipped | Agent writes platform-specific code at runtime |
| Manual server deployment | Agent installs deps, starts server, writes client configs |
| No self-healing | Daemon watches and repairs broken tools automatically |

## Key Implementation Notes

- **feetech-servo-sdk** installs the Python module as `scservo_sdk` (not `feetech_servo_sdk`)
- **Protocol version 0** required for PacketHandler: `PacketHandler(0)` for SCS/Feetech servos
- **Baudrate**: 1,000,000 (1 Mbps) for SO-ARM101
- **No SYNC WRITE** on STS3215 — only individual `write_word` per servo (firmware bug); `privileged/arm.md` enforces this
- **Lazy port open**: `privileged/arm.md` mandates `_get_arm()` getter (NOT module import) so FastMCP boots when the arm is unplugged; the cache also self-heals on transient port errors
- **Servo #1 is hardware-disabled** in the demo rig — generated tools no-op joint 1
- **FastMCP DNS-rebinding protection OFF**: every `FastMCP(...)` is constructed with `transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False)` so the public `*.trycloudflare.com` Host header isn't rejected
- **cloudflared `--http-host-header localhost`**: the auto-tunnel rewrites Host so even strict middleware on the FastMCP side sees a localhost request (paired with the setting above — both required)
- **Schema discipline**: the orchestrator never `isinstance`-checks agent output. Output shapes live in the spec the agent reads; the orchestrator only checks "did the declared output file appear with valid JSON?"
- **Bounded retries**: each stage gets `stage_budget_sec=600` divided across `max_attempts=3` (≈3.33 min × 3) — burning the budget stops retries
- **nohup requires PATH**: generated `start.sh` exports `$HOME/.local/bin:$PATH` for uv
- **latin-1 locale on Pi**: all file I/O uses `encoding='utf-8'` explicitly
- **OpenRouter-only auth**: installer writes `OPENROUTER_API_KEY` to `$OCTOPUS_DIR/.env`; direct Anthropic / Gemini / Z.AI paths were dropped in Plan 22 Phase B2
