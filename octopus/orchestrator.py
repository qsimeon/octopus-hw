"""
Octopus pipeline orchestrator v4.5

Philosophy:
  - The coding agent IS the software, not a tool for building it
  - Prompts ARE infrastructure — specs replace platform-specific code
  - Minimal harness — the only code is the loop and the agent call
  - Two-tier calls — heavy (coding agent) for stages, light (model API) for summaries
  - Self-referencing — the agent can edit its own instructions on retry
  - Living backend — the builder is also the maintainer (daemon)
  - Embodied perception — the octopus can see its own physical state (camera)

Entry point: octopus-pipeline = "octopus.orchestrator:main"
"""

import argparse
import json
import os
import subprocess
import sys
import time
import tomllib
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

STAGES = [
    ("probe", "output.json"),
    ("identify", "output.json"),
    ("interface", "output.json"),
    ("serve", "server.py"),
    ("deploy", "connection.json"),
]

DEFAULT_MODEL = "openrouter/google/gemini-3-flash-preview"
DEFAULT_MAX_ATTEMPTS = 3
LOG_MAX_LINES = 500

PROJECT_DIR = Path(__file__).resolve().parent.parent
GENERATED_DIR = PROJECT_DIR / "_generated"
PROTOCOL_DIR = PROJECT_DIR / "protocol"
CONFIG_PATH = PROJECT_DIR / "octopus.toml"
LOG_PATH = GENERATED_DIR / "octopus.log"
SERVER_PID = GENERATED_DIR / "deploy" / "server.pid"
DAEMON_PID = GENERATED_DIR / "daemon.pid"


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def _load_env():
    """Load API keys from .env (project) and ~/.secrets (user), project wins."""
    for env_file in [PROJECT_DIR / ".env", Path.home() / ".secrets"]:
        if env_file.exists():
            for line in env_file.read_text(encoding='utf-8').splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, val = line.split("=", 1)
                    key = key.removeprefix("export ").strip()
                    os.environ.setdefault(key, val.strip())


def load_config() -> dict:
    """Load config from octopus.toml, falling back to defaults."""
    defaults = {
        "agent_command": "pi",
        "model": DEFAULT_MODEL,
        "max_attempts": DEFAULT_MAX_ATTEMPTS,
        "stages": [s for s, _ in STAGES],
        "watch_interval": 300,
        # Per-stage time budget: 10 min total, 200s per attempt at max_attempts=3.
        # Hard cap prevents a wedged stage from running away on API spend.
        "stage_budget_sec": 600,
        "stage_attempt_timeout_sec": 200,
    }
    if not CONFIG_PATH.exists():
        return defaults
    try:
        with open(CONFIG_PATH, "rb") as f:
            raw = tomllib.load(f)
        config = dict(defaults)
        if "agent" in raw:
            config["agent_command"] = raw["agent"].get("command", config["agent_command"])
            config["model"] = raw["agent"].get("model", config["model"])
            config["light_model"] = raw["agent"].get("light_model", "claude-haiku-4-5-20251001")
            config["max_attempts"] = raw["agent"].get("max_attempts", config["max_attempts"])
            config["stage_budget_sec"] = raw["agent"].get("stage_budget_sec", config["stage_budget_sec"])
            config["stage_attempt_timeout_sec"] = raw["agent"].get("stage_attempt_timeout_sec", config["stage_attempt_timeout_sec"])
        if "stages" in raw:
            config["stages"] = raw["stages"].get("order", config["stages"])
        if "daemon" in raw:
            config["watch_interval"] = raw["daemon"].get("watch_interval", config["watch_interval"])
        if "perception" in raw:
            p = raw["perception"]
            config["perception_enabled"] = p.get("enabled", False)
            config["perception_capture_interval"] = p.get("capture_interval", 300)
            config["perception_frame_dir"] = p.get("frame_dir", "perceive/frames")
            config["perception_max_frames"] = p.get("max_frames", 50)
            config["perception_expected_camera"] = p.get("expected_camera", "")
        if "arm" in raw:
            a = raw["arm"]
            config["arm_enabled"] = a.get("enabled", True)
            config["arm_expected"] = a.get("expected_arm", "")
        else:
            config["arm_enabled"] = True
            config["arm_expected"] = ""
        # The [perception] section governs the entire perception subsystem
        # (camera + rail — rail is the perception actuator since the camera
        # is mounted on it). A legacy [rail] section in older octopus.toml
        # files is read for backwards compatibility but no longer drives
        # a separate stage — its `enabled` flag becomes a no-op.
        return config
    except Exception:
        return defaults


# ---------------------------------------------------------------------------
# Two-tier agent calls: heavy (coding agent) + light (model API)
# ---------------------------------------------------------------------------

def ask_model(prompt: str, config: dict) -> str:
    """Lightweight model call — text in, text out. No tools, no shell.

    Used for: heal summaries, log enrichment, small judgments. OpenRouter only
    (the same key the heavy agent uses). Returns "" on any failure so callers
    can use a fallback path.
    """
    try:
        import httpx
    except ImportError:
        return ""

    or_key = os.environ.get("OPENROUTER_API_KEY")
    if not or_key:
        return ""

    model = config.get("light_model", DEFAULT_MODEL)
    api_model = model.removeprefix("openrouter/")
    try:
        resp = httpx.post(
            "https://openrouter.ai/api/v1/chat/completions",
            headers={"Authorization": f"Bearer {or_key}",
                     "content-type": "application/json"},
            json={"model": api_model, "max_tokens": 200,
                  "messages": [{"role": "user", "content": prompt}]},
            timeout=15,
        )
        if resp.status_code == 200:
            return resp.json()["choices"][0]["message"]["content"].strip()
    except Exception:
        pass
    return ""


# ---------------------------------------------------------------------------
# Logging — structured tags for grep-friendly output
# ---------------------------------------------------------------------------

def log(tag: str, msg: str, verbose: bool = False) -> None:
    """Append a tagged, timestamped line to octopus.log."""
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    line = f"[{ts}] [{tag}] {msg}"
    with open(LOG_PATH, "a", encoding='utf-8') as f:
        f.write(line + "\n")
    if verbose:
        print(line)


def _blind_trim_log(path: Path = LOG_PATH, keep: int = LOG_MAX_LINES) -> None:
    """Last-resort fallback: truncate log if ask_model fails."""
    if not path.exists():
        return
    lines = path.read_text(encoding='utf-8').splitlines()
    if len(lines) > keep * 2:
        path.write_text("\n".join(lines[-keep:]) + "\n", encoding='utf-8')


# ---------------------------------------------------------------------------
# Markov context propagation — each stage sees only its spec + prev output
# ---------------------------------------------------------------------------

def build_prompt(stage: str, output_path: Path, prev_path: Path | None,
                 config: dict | None = None) -> str:
    """First attempt: spec(Si) || output(Si-1). This is the Markov boundary.

    `config` is accepted for signature stability but is no longer injected
    into general-stage prompts — hardware-identity rules live in the specs
    themselves (see protocol/identify.md). Privileged framework steps
    (run_perceive, run_arm) read config directly.
    """
    spec_path = PROTOCOL_DIR / f"{stage}.md"
    parts = [
        f"Execute the spec below. Write your final output to:\n  {output_path}\n",
    ]
    if prev_path and prev_path.exists():
        parts.append(f"Read the previous stage's output from:\n  {prev_path}\n")
    parts.append(f"---\n\n{spec_path.read_text(encoding='utf-8')}")
    return "\n".join(parts)


def build_retry_prompt(stage: str, output_path: Path, prev_path: Path | None,
                       agent_log: Path, *, edit_specs: bool = True,
                       config: dict | None = None) -> str:
    """Retry: failure context + optional self-edit instruction.

    On retry, don't embed the spec — point the agent at the file so it can
    edit and re-read in the same session (self-editing specifications).
    """
    spec_path = PROTOCOL_DIR / f"{stage}.md"
    parts = [
        f"Execute the spec below. Write your final output to:\n  {output_path}\n",
    ]
    if prev_path and prev_path.exists():
        parts.append(f"Read the previous stage's output from:\n  {prev_path}\n")

    # Self-editing specs: let the agent modify the protocol if needed
    if edit_specs:
        parts.append(
            f"The spec is at:\n  {spec_path}\n"
            f"Read it before executing. If you believe the failure is due to a "
            f"problem with the spec itself (outdated instructions, wrong assumptions "
            f"about this environment), edit the spec file first, then re-read and "
            f"execute the updated version. Only edit if genuinely wrong — not for "
            f"transient errors.\n"
        )
    else:
        parts.append(f"---\n\n{spec_path.read_text(encoding='utf-8')}")

    # Failure context injection: bounded tail of previous attempt's log
    if agent_log.exists():
        lines = agent_log.read_text(encoding='utf-8').splitlines()
        tail = "\n".join(lines[-100:])
        parts.append(
            f"\n--- PREVIOUS ATTEMPT (failed) ---\n"
            f"The previous attempt did not produce the expected output.\n"
            f"Here is the log from that attempt:\n```\n{tail}\n```\n"
            f"Please try a different approach or fix the issue.\n"
        )
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Agent invocation
# ---------------------------------------------------------------------------

def run_agent(prompt: str, config: dict, log_path: Path,
              image_paths: list[Path] | None = None) -> int:
    """Invoke the coding agent. Capture all output to log file. Return exit code.

    If image_paths are provided, they are passed as @file.png to the agent CLI
    for multimodal (vision) input — e.g. perception camera frames.
    """
    prompt_file = GENERATED_DIR / "_prompt.md"
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    prompt_file.write_text(prompt, encoding='utf-8')

    cmd = [
        config.get("agent_command", "pi"),
        "-p", f"@{prompt_file}",
        "--model", config.get("model", DEFAULT_MODEL),
    ]
    if image_paths:
        for img in image_paths:
            if img.exists():
                cmd.append(f"@{img}")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    timeout = config.get("stage_attempt_timeout_sec", 200)
    with open(log_path, "w") as logf:
        result = subprocess.run(
            cmd, stdout=logf, stderr=subprocess.STDOUT,
            cwd=PROJECT_DIR, timeout=timeout,
        )
    return result.returncode


# ---------------------------------------------------------------------------
# RALPH loop — Read, Agent, Loop, Pass, Halt
# ---------------------------------------------------------------------------

def run_pipeline(config: dict, max_attempts: int, edit_specs: bool,
                 resume: bool, verbose: bool,
                 stages: list[tuple[str, str]] | None = None) -> None:
    """The RALPH loop: sequence the agent through protocol stages.

    `stages` defaults to the full STAGES list. Pass a subset to run a
    partial pipeline (e.g. probe + identify only, for `octopus reprobe`).
    """
    prev_path: Path | None = None
    stage_budget_sec = config.get("stage_budget_sec", 600)
    attempt_timeout_sec = config.get("stage_attempt_timeout_sec", 200)

    for stage, filename in (stages if stages is not None else STAGES):
        stage_dir = GENERATED_DIR / stage
        stage_dir.mkdir(parents=True, exist_ok=True)
        out = stage_dir / filename
        agent_log = stage_dir / "agent.log"

        # Resume: skip if output already exists
        if resume and out.exists() and out.stat().st_size > 0:
            log("pipeline", f"{stage} resumed (output exists)", verbose)
            prev_path = out
            continue

        out.unlink(missing_ok=True)
        stage_start = time.time()

        for attempt in range(1, max_attempts + 1):
            # Per-stage budget: stop retrying once total stage time exceeds budget
            elapsed_stage = time.time() - stage_start
            if elapsed_stage >= stage_budget_sec:
                log("pipeline", f"{stage} BUDGET EXCEEDED ({elapsed_stage:.0f}s >= {stage_budget_sec}s) — stopping retries", verbose)
                break
            log("pipeline", f"{stage} attempt {attempt}/{max_attempts}", verbose)
            t0 = time.time()

            try:
                # Markov propagation: first attempt embeds spec, retries point to file
                if attempt == 1:
                    prompt = build_prompt(stage, out, prev_path, config=config)
                else:
                    prompt = build_retry_prompt(stage, out, prev_path, agent_log,
                                               edit_specs=edit_specs, config=config)
                run_agent(prompt, config, agent_log)
                elapsed = time.time() - t0
            except subprocess.TimeoutExpired:
                log("pipeline", f"{stage} attempt timeout after {attempt_timeout_sec}s", verbose)
                continue

            if out.exists() and out.stat().st_size > 0:
                # Detect self-editing specs via git diff
                spec_path = PROTOCOL_DIR / f"{stage}.md"
                diff = subprocess.run(
                    ["git", "diff", "--quiet", str(spec_path)],
                    cwd=PROJECT_DIR, capture_output=True,
                )
                if diff.returncode != 0:
                    log("pipeline", f"{stage} agent edited {spec_path.name}", verbose)
                log("pipeline", f"{stage} success ({elapsed:.1f}s)", verbose)
                break
            else:
                log("pipeline", f"{stage} output missing ({elapsed:.1f}s)", verbose)
        else:
            log("pipeline", f"{stage} FAILED after {max_attempts} attempts", verbose)
            print(f"FATAL: {stage} failed after {max_attempts} attempts", file=sys.stderr)
            sys.exit(1)

        prev_path = out

    log("pipeline", "complete", verbose)
    print(f"\nPipeline complete. Outputs in {GENERATED_DIR}/")


# ---------------------------------------------------------------------------
# Privileged framework step: perceive — camera setup + heartbeat capture
# ---------------------------------------------------------------------------

def run_perceive(config: dict, verbose: bool) -> bool:
    """Run the perceive stage — select a camera from discovered MCP tools.

    The pipeline already discovered cameras and generated MCP tools for them.
    Perceive reads the interface + deploy output to find camera tools, selects
    the best one for self-perception, and generates a capture.py bridge.
    """
    if not config.get("perception_enabled", False):
        log("perceive", "perception disabled in config, skipping", verbose)
        return False

    stage_dir = GENERATED_DIR / "perceive"
    stage_dir.mkdir(parents=True, exist_ok=True)
    out = stage_dir / "output.json"
    agent_log = stage_dir / "agent.log"

    # Point the agent at the pipeline outputs so it can find camera tools
    interface_out = GENERATED_DIR / "interface" / "output.json"
    deploy_out = GENERATED_DIR / "deploy" / "connection.json"

    context_parts = []
    if interface_out.exists():
        context_parts.append(f"Interface output (tool schemas):\n  {interface_out}")
    if deploy_out.exists():
        context_parts.append(f"Deploy output (server connection):\n  {deploy_out}")
    context = "\n".join(context_parts)

    spec = (PROTOCOL_DIR / "privileged" / "perceive.md").read_text(encoding='utf-8')
    prompt = (
        f"Execute the spec below. Write your output to:\n  {out}\n\n"
        f"{context}\n"
        f"---\n\n{spec}"
    )

    log("perceive", "selecting perception camera from discovered tools", verbose)
    try:
        run_agent(prompt, config, agent_log)
    except subprocess.TimeoutExpired:
        log("perceive", "timeout", verbose)
        return False

    if out.exists() and out.stat().st_size > 0:
        try:
            result = json.loads(out.read_text(encoding='utf-8'))
        except json.JSONDecodeError:
            log("perceive", "output not valid JSON", verbose)
            return False
        if result.get("status") == "ok":
            log("perceive", f"camera: {result.get('camera_tool')}", verbose)
            return True
        log("perceive", f"no camera: {result.get('reason', result.get('status'))}", verbose)
    return False


# ---------------------------------------------------------------------------
# Privileged framework step: arm (robotic arm verification, conditional)
# ---------------------------------------------------------------------------

def run_arm(config: dict, verbose: bool) -> bool:
    """Run the arm stage — verify/patch arm tools in the generated server.

    Conditional: only does real work if identify flagged a robotic arm. Analogous
    to run_perceive for the camera. Reads the identify + serve outputs, and if
    the arm tools look wrong, the agent rewrites them using scservo_sdk.
    """
    if not config.get("arm_enabled", True):
        log("arm", "arm step disabled in config, skipping", verbose)
        return False

    identify_out = GENERATED_DIR / "identify" / "output.json"
    server_py = GENERATED_DIR / "serve" / "server.py"
    if not identify_out.exists() or not server_py.exists():
        log("arm", "identify or serve output missing; skipping", verbose)
        return False

    stage_dir = GENERATED_DIR / "arm"
    stage_dir.mkdir(parents=True, exist_ok=True)
    out = stage_dir / "output.json"
    agent_log = stage_dir / "agent.log"

    spec = (PROTOCOL_DIR / "privileged" / "arm.md").read_text(encoding='utf-8')
    context = (
        f"Identify output (check for a robotic arm):\n  {identify_out}\n"
        f"Generated server to inspect/patch:\n  {server_py}\n"
    )
    prompt = (
        f"Execute the spec below. Write your output to:\n  {out}\n\n"
        f"{context}\n---\n\n{spec}"
    )

    log("arm", "checking for robotic arm and verifying tools", verbose)
    try:
        run_agent(prompt, config, agent_log)
    except subprocess.TimeoutExpired:
        log("arm", "timeout", verbose)
        return False

    if out.exists() and out.stat().st_size > 0:
        try:
            result = json.loads(out.read_text(encoding='utf-8'))
        except json.JSONDecodeError:
            log("arm", "output not valid JSON", verbose)
            return False
        status = result.get("status", "unknown")
        if status == "no_arm":
            log("arm", "no robotic arm detected; skipping", verbose)
            return False
        if status in ("ok", "patched"):
            tools = result.get("arm_tools", [])
            log("arm", f"{status}: {len(tools)} arm tool(s)", verbose)
            return True
        log("arm", f"status={status}", verbose)
    return False


# ---------------------------------------------------------------------------
# Reprobe — port-dynamic re-discovery
# ---------------------------------------------------------------------------

def run_reprobe(config: dict, verbose: bool) -> bool:
    """Re-discover hardware and patch the live server in place.

    Tiny problem: you re-plugged the arm and the live server now points at a
    /dev/ttyACM* path that no longer exists. Tiny fix: re-run probe + identify
    to pick up the new wiring, then let the perceive + arm privileged steps
    rewrite their portions of the running server. Does NOT regenerate
    serve/deploy from scratch — the port-dynamic update is targeted.

    The daemon calls this automatically when it sees a `device_moved_error`
    from heal (see protocol/heal.md). Users can also invoke it manually
    via `octopus reprobe`.
    """
    log("reprobe", "starting port-dynamic re-discovery", verbose)

    # Clear probe + identify outputs so the RALPH loop re-runs them.
    for stage_name in ("probe", "identify"):
        out = GENERATED_DIR / stage_name / "output.json"
        out.unlink(missing_ok=True)

    max_attempts = config.get("max_attempts", DEFAULT_MAX_ATTEMPTS)
    edit_specs = not config.get("no_edit_specs", False)
    try:
        run_pipeline(config, max_attempts, edit_specs, resume=False, verbose=verbose,
                     stages=[("probe", "output.json"), ("identify", "output.json")])
    except SystemExit:
        log("reprobe", "probe/identify FAILED; live server left unchanged", verbose)
        return False

    # Patch the running server in place via the privileged framework steps.
    run_perceive(config, verbose)
    run_arm(config, verbose)

    log("reprobe", "complete — live server patched in place", verbose)
    return True


# The perception subsystem (camera + rail) is one privileged step.
# run_perceive() generates the camera capture utility AND, if the rig has a
# rail, the rail_* tools per protocol/privileged/perceive.md's Camera-rail section.


def _capture_frame(config: dict, verbose: bool) -> Path | None:
    """Capture a single frame using the agent-generated capture script."""
    capture_script = GENERATED_DIR / "perceive" / "capture.py"
    if not capture_script.exists():
        return None

    frame_dir = GENERATED_DIR / config.get("perception_frame_dir", "perceive/frames")
    frame_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    frame_path = frame_dir / f"frame_{ts}.png"

    try:
        result = subprocess.run(
            ["uv", "run", "python", str(capture_script), "--output", str(frame_path)],
            cwd=PROJECT_DIR, timeout=30, capture_output=True, text=True,
        )
        if result.returncode == 0 and frame_path.exists():
            _prune_frames(frame_dir, config.get("perception_max_frames", 50))
            return frame_path
    except subprocess.TimeoutExpired:
        pass
    return None


def _prune_frames(frame_dir: Path, max_frames: int) -> None:
    """Keep rolling buffer of daemon heartbeat frames; keep only latest capture frame."""
    # Daemon heartbeat frames (frame_*.png) — rolling buffer of max_frames
    frames = sorted(frame_dir.glob("frame_*.png"))
    for old in frames[:-max_frames]:
        old.unlink(missing_ok=True)
    # MCP tool captures (capture_*.*) — keep only the single most recent per format
    for pattern in ["capture_*.png", "capture_*.jpg", "capture_*.jpeg"]:
        captures = sorted(frame_dir.glob(pattern))
        for old in captures[:-1]:
            old.unlink(missing_ok=True)


def _update_state_summary(frame_path: Path | None, watch_report: dict | None,
                          config: dict) -> None:
    """Compress visual history into a rolling text summary (Markov state).

    After each watch cycle: ask the light model to update state_summary.txt
    with any new observations from the current frame + watch report.
    This keeps visual context bounded without losing accumulated knowledge.
    """
    summary_path = GENERATED_DIR / "perceive" / "state_summary.txt"
    prev = summary_path.read_text(encoding='utf-8') if summary_path.exists() else ""

    parts = []
    if prev:
        parts.append(f"Previous state summary:\n{prev}\n")
    if watch_report:
        parts.append(f"Latest watch report: {watch_report.get('summary', '')}\n"
                     f"Status: {watch_report.get('status', 'unknown')}")
    if frame_path:
        parts.append(f"New frame captured: {frame_path.name}")

    if not parts:
        return

    new_summary = ask_model(
        "You are maintaining a rolling state summary for an Octopus hardware controller. "
        "Update the summary below to incorporate the new information. "
        "Keep it under 200 words. Focus on: hardware physical state, recurring errors, "
        "device positions, anything a future health check should know.\n\n"
        + "\n".join(parts),
        config,
    )
    if new_summary:
        summary_path.parent.mkdir(parents=True, exist_ok=True)
        summary_path.write_text(new_summary, encoding='utf-8')


# ---------------------------------------------------------------------------
# Self-healing daemon — WATCH → HEAL → sleep → repeat
# ---------------------------------------------------------------------------

def is_server_running() -> bool:
    """Check if the deployed MCP server process is alive."""
    if not SERVER_PID.exists():
        return False
    try:
        pid = int(SERVER_PID.read_text().strip())
        os.kill(pid, 0)
        return True
    except (ValueError, ProcessLookupError, PermissionError):
        return False


def _kill_old_daemon() -> None:
    """Kill a previously running daemon (prevents duplicates)."""
    if not DAEMON_PID.exists():
        return
    try:
        os.kill(int(DAEMON_PID.read_text().strip()), 9)
    except (ValueError, ProcessLookupError, PermissionError):
        pass
    DAEMON_PID.unlink(missing_ok=True)


def _run_daemon_stage(name: str, spec: str, context: str,
                      config: dict, verbose: bool,
                      image_paths: list[Path] | None = None) -> dict | None:
    """Run a daemon spec (watch or heal). Returns parsed JSON or None."""
    stage_dir = GENERATED_DIR / name
    stage_dir.mkdir(parents=True, exist_ok=True)
    out = stage_dir / "output.json"
    out.unlink(missing_ok=True)

    prompt = (
        f"Execute the spec below. Write your output to:\n  {out}\n\n"
        f"{context}\n---\n\n{(PROTOCOL_DIR / f'{spec}.md').read_text(encoding='utf-8')}"
    )
    try:
        run_agent(prompt, config, stage_dir / "agent.log", image_paths=image_paths)
    except subprocess.TimeoutExpired:
        return None

    if out.exists() and out.stat().st_size > 0:
        return json.loads(out.read_text())
    return None


def daemon_loop(config: dict, interval: int, verbose: bool) -> None:
    """Watch → Heal → Sleep → Repeat. The living backend."""
    _kill_old_daemon()
    DAEMON_PID.parent.mkdir(parents=True, exist_ok=True)
    DAEMON_PID.write_text(str(os.getpid()))
    log("daemon", f"entering watch loop (interval={interval}s, pid={os.getpid()})", verbose)

    # Track perception heartbeat separately from watch interval
    last_capture_time = 0.0
    capture_interval = config.get("perception_capture_interval", 180)

    try:
        while True:
            try:
                # 1. Restart server if down
                if not is_server_running():
                    log("daemon", "server down, restarting", verbose)
                    start_sh = GENERATED_DIR / "deploy" / "start.sh"
                    if start_sh.exists():
                        subprocess.run(["bash", str(start_sh)], cwd=PROJECT_DIR, timeout=30)
                        time.sleep(3)

                # 2. PERCEIVE heartbeat: capture a frame for visual context
                frame_path = None
                if config.get("perception_enabled", False):
                    now = time.time()
                    if now - last_capture_time >= capture_interval:
                        frame_path = _capture_frame(config, verbose)
                        if frame_path:
                            log("perceive", f"heartbeat: {frame_path.name}", verbose)
                        last_capture_time = now

                # 3. WATCH: let the agent analyze the log (with optional visual context)
                server_log = LOG_PATH.read_text(encoding='utf-8') if LOG_PATH.exists() else ""
                if not server_log:
                    log("daemon", "no log yet, waiting", verbose)
                    time.sleep(interval)
                    continue

                watch_context = f"Here are the latest logs from our MCP backend:\n```\n{server_log}\n```"

                # Inject Markov visual state: current frame + compressed history summary
                summary_path = GENERATED_DIR / "perceive" / "state_summary.txt"
                if summary_path.exists():
                    watch_context += (
                        f"\n\nVisual history summary (from previous perception cycles):\n"
                        f"{summary_path.read_text(encoding='utf-8')}"
                    )
                if frame_path:
                    watch_context += (
                        "\n\nThe current perception frame is attached. "
                        "Note any visible hardware issues (loose cables, LED indicators, "
                        "physical damage, disconnected peripherals)."
                    )

                log("daemon", "running watch", verbose)
                report = _run_daemon_stage(
                    "watch", "watch", watch_context, config, verbose,
                    image_paths=[frame_path] if frame_path else None,
                )

                # Update rolling state summary (Markov compression of visual history)
                if config.get("perception_enabled", False):
                    _update_state_summary(frame_path, report, config)

                if report and report.get("status") != "healthy":
                    log("daemon", f"status={report['status']}, healing", verbose)
                    heal = _run_daemon_stage(
                        "heal", "heal",
                        f"Watch report:\n```json\n{json.dumps(report, indent=2)}\n```\n"
                        f"Server file: {GENERATED_DIR / 'serve' / 'server.py'}",
                        config, verbose,
                    )
                    if heal:
                        summary = ask_model(
                            f"Summarize in one sentence what was fixed: "
                            f"{json.dumps(heal.get('actions_taken', []))}",
                            config,
                        )
                        heal_msg = summary or heal.get("status", "unknown")
                        log("daemon", f"healed: {heal_msg}", verbose)

                        # If heal classified the failure as device_moved
                        # (e.g. /dev/ttyACM* changed after a re-plug),
                        # trigger the port-dynamic re-discovery.
                        if heal.get("status") == "device_moved_error":
                            log("daemon", "device_moved_error -> running reprobe", verbose)
                            run_reprobe(config, verbose)
                else:
                    log("daemon", "healthy", verbose)

                # Agent-compressed log: if log is large, ask the light model
                # to summarize it rather than blindly truncating
                if LOG_PATH.exists():
                    lines = LOG_PATH.read_text(encoding='utf-8').splitlines()
                    if len(lines) > LOG_MAX_LINES:
                        compressed = ask_model(
                            f"Compress this server log to ~{LOG_MAX_LINES // 2} lines. "
                            f"Keep all errors, tool calls, and daemon events. "
                            f"Summarize repetitive healthy checks. "
                            f"Preserve timestamps and tags.\n\n"
                            + "\n".join(lines),
                            config,
                        )
                        if compressed:
                            LOG_PATH.write_text(compressed + "\n", encoding='utf-8')
                        else:
                            _blind_trim_log()  # fallback if model call fails

                time.sleep(interval)
            except KeyboardInterrupt:
                raise
            except Exception as e:
                log("daemon", f"error: {e}", verbose)
                time.sleep(interval)
    except KeyboardInterrupt:
        log("daemon", "stopped", verbose)
        print("\nDaemon stopped.")
    finally:
        DAEMON_PID.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Key validation
# ---------------------------------------------------------------------------

def _warn_if_key_missing(config: dict, verbose: bool = True) -> None:
    """Warn early if OPENROUTER_API_KEY isn't set.

    Octopus is OpenRouter-only — OPENROUTER_API_KEY is the single key
    the system needs to reach all supported models.
    """
    model = config.get("model", DEFAULT_MODEL)
    if not os.environ.get("OPENROUTER_API_KEY"):
        log("warning", f"OPENROUTER_API_KEY not set (model={model}) -- "
            "set OPENROUTER_API_KEY and re-run", verbose)
        return
    if not model.startswith("openrouter/"):
        log("warning", f"model={model} doesn't start with openrouter/ -- "
            "Octopus only supports openrouter/* models now", verbose)


# ---------------------------------------------------------------------------
# Interactive perceive/arm prompts are intentionally not implemented here —
# TTY-bridged prompts were a frequent source of failures on Pi, ssh -t,
# asciinema, and curl|bash. The orchestrator silently picks the first
# auto-discovered camera/arm; users override via [perception] / [arm]
# sections in octopus.toml.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    _load_env()

    parser = argparse.ArgumentParser(description="Octopus orchestrator v4.5")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--resume", action="store_true",
                        help="Skip stages whose output already exists")
    parser.add_argument("--model", type=str, default=None)
    parser.add_argument("--max-attempts", type=int, default=None)
    parser.add_argument("--daemon", action="store_true",
                        help="After pipeline, enter watch/heal loop")
    parser.add_argument("--watch-interval", type=int, default=None)
    parser.add_argument("--no-edit-specs", action="store_true",
                        help="Disable spec self-editing on retry")
    parser.add_argument("--reprobe", action="store_true",
                        help="Re-discover hardware (probe+identify) and patch the live server "
                             "via perceive+arm. Skips serve/deploy regeneration.")
    args = parser.parse_args()

    config = load_config()
    if args.model:
        config["model"] = args.model
    if args.max_attempts:
        config["max_attempts"] = args.max_attempts

    max_attempts = config.get("max_attempts", DEFAULT_MAX_ATTEMPTS)
    edit_specs = not args.no_edit_specs
    interval = args.watch_interval or config.get("watch_interval", 300)

    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    if not args.resume:
        LOG_PATH.unlink(missing_ok=True)

    _warn_if_key_missing(config, args.verbose)

    # --reprobe is its own short path. Re-discover hardware and patch the live
    # server in place; do not run the full pipeline.
    if args.reprobe:
        log("reprobe", f"start model={config.get('model')}", args.verbose)
        ok = run_reprobe(config, args.verbose)
        sys.exit(0 if ok else 1)

    log("pipeline", f"start model={config.get('model')} edit_specs={edit_specs}", args.verbose)

    run_pipeline(config, max_attempts, edit_specs, args.resume, args.verbose)

    # Privileged framework steps run after the general pipeline. Two steps:
    # perceive owns the perception subsystem (camera selection + the rail
    # controller, if a rail is wired — the rail is the perception actuator
    # since the camera is mounted on it) and arm owns the robotic arm.
    run_perceive(config, args.verbose)
    run_arm(config, args.verbose)

    if args.daemon:
        daemon_loop(config, interval, args.verbose)


if __name__ == "__main__":
    main()
