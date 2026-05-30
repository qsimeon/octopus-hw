"""
Octopus — Join39 App Endpoints.

Two apps for the Join39 Agent Store:

1. /discover — List available MCP tools from the live Octopus server
2. /tools/invoke — Execute an MCP tool on the remote hardware

IMPORTANT: Set OCTOPUS_MCP_URL environment variable to point to your Octopus
MCP server. This is typically a Cloudflare tunnel URL:
  https://random-words.trycloudflare.com/mcp

On Railway: Settings → Variables → OCTOPUS_MCP_URL = https://YOUR-TUNNEL/mcp

If OCTOPUS_MCP_URL is not set, all requests return an error telling you to set it.
"""

import asyncio
import base64
import json
import os
import re

from flask import Flask, Response, jsonify, request

app = Flask(__name__)


# Wide-open CORS so the public landing page (qsimeon.github.io) and
# classmates' demo sites can call this bridge from the browser. The
# endpoint is already an unauthenticated public demo — CORS adds no
# new attack surface. If you lock this down later, restrict origins.
@app.after_request
def _cors(resp):
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    resp.headers["Access-Control-Max-Age"] = "600"
    return resp


# Browser preflight for POST /tools/invoke etc.
@app.route("/tools/invoke", methods=["OPTIONS"])
@app.route("/discover", methods=["OPTIONS"])
@app.route("/tools/list", methods=["OPTIONS"])
@app.route("/camera/latest.png", methods=["OPTIONS"])
@app.route("/camera/latest-clean.png", methods=["OPTIONS"])
@app.route("/tools/invoke_raw", methods=["OPTIONS"])
def _cors_preflight():
    return ("", 204)

# MCP server URL — MUST be set via OCTOPUS_MCP_URL env var
# On Railway: Settings → Variables → OCTOPUS_MCP_URL = https://YOUR-CLOUDFLARE-TUNNEL/mcp
_MCP_URL_RAW = os.environ.get("OCTOPUS_MCP_URL", "")
MCP_SERVER_URL = _MCP_URL_RAW.strip() if _MCP_URL_RAW.strip() else None

# Join39 response limit (their API caps at 2000 chars). Only applies when the
# caller *is* Join39 (JSON/text contract). The /camera/latest.png route returns
# raw bytes so the cap doesn't apply there.
MAX_RESPONSE_CHARS = 1900


# ---------------------------------------------------------------------------
# MCP Client Bridge — connects to the Octopus MCP server
# ---------------------------------------------------------------------------

def _check_mcp_url():
    """Return error dict if MCP URL is not configured, else None."""
    if not MCP_SERVER_URL:
        return {
            "status": "error",
            "error": "OCTOPUS_MCP_URL is not set. On Railway: Settings → Variables → OCTOPUS_MCP_URL = https://YOUR-CLOUDFLARE-TUNNEL/mcp",
            "hint": "Run 'octopus expose' on your Pi to get a cloudflare URL, then set it here."
        }
    return None


async def _call_mcp_tool(tool_name: str, arguments: dict) -> dict:
    """Call a tool on the Octopus MCP server via StreamableHTTP."""
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    async with streamablehttp_client(MCP_SERVER_URL) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(tool_name, arguments)
            texts = []
            for block in result.content:
                if hasattr(block, "text"):
                    texts.append(block.text)
            return {"status": "ok", "tool": tool_name, "result": texts}


async def _list_mcp_tools() -> list[dict]:
    """List available tools from the live Octopus MCP server."""
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    async with streamablehttp_client(MCP_SERVER_URL) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            return [
                {"name": t.name, "description": t.description or ""}
                for t in tools.tools
            ]


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/", methods=["GET"])
def index():
    return jsonify({
        "name": "octopus-hw",
        "version": "3.0.0",
        "description": "Universal hardware control for AI agents. "
                       "Discover devices at /discover, invoke tools at /tools/invoke.",
        "endpoints": {
            "discover": "/discover",
            "invoke": "/tools/invoke",
            "list_tools": "/tools/list",
        },
    })


@app.route("/discover", methods=["POST", "GET"])
def discover():
    """List available MCP tools from the live Octopus server.

    Returns the LIVE tool list by querying the MCP server — not stale data.
    Tool names vary by pipeline run and model, so always call this first.
    """
    err = _check_mcp_url()
    if err:
        return jsonify(err), 503

    if request.method == "POST":
        data = request.get_json(silent=True) or {}
    else:
        data = request.args.to_dict()

    scan_type = data.get("scan_type", "all")

    try:
        tools = asyncio.run(_list_mcp_tools())
    except Exception as e:
        return jsonify({
            "status": "error",
            "error": f"Cannot reach Octopus MCP server at {MCP_SERVER_URL}: {e}",
            "hint": "Check that the Pi is running and the cloudflare tunnel is active. Update OCTOPUS_MCP_URL on Railway if the tunnel URL changed."
        }), 502

    # Filter by scan_type if requested
    if scan_type == "input":
        tools = [t for t in tools if any(k in t["name"].lower() for k in ["capture", "read", "scan", "detect", "mic", "camera", "sensor"])]
    elif scan_type == "output":
        tools = [t for t in tools if any(k in t["name"].lower() for k in ["set", "move", "write", "play", "control", "servo", "motor", "arm"])]

    result = {
        "status": "ok",
        "protocol": "octopus",
        "mcp_server": MCP_SERVER_URL,
        "total_tools": len(tools),
        "tools": tools,
        "hint": "Use tool names from this list in /tools/invoke. Names vary by hardware and pipeline run.",
    }
    return jsonify(result)


@app.route("/tools/list", methods=["GET"])
def list_tools():
    """Alias for /discover — list available MCP tools from the live server."""
    err = _check_mcp_url()
    if err:
        return jsonify(err), 503
    try:
        tools = asyncio.run(_list_mcp_tools())
        return jsonify({"status": "ok", "mcp_server": MCP_SERVER_URL, "tools": tools})
    except Exception as e:
        return jsonify({"status": "error", "error": str(e), "mcp_server": MCP_SERVER_URL}), 502


@app.route("/tools/invoke", methods=["POST"])
def invoke_tool():
    """Unified Octopus hardware endpoint — list tools or invoke a specific tool.

    action=list   → {"action": "list"}
                    returns all available tool names and descriptions

    action=invoke → {"action": "invoke", "tool_name": "arm_set_joint_angle",
                     "parameters": {"joint": 1, "angle": 90}}
                    calls the tool and returns result

    Legacy mode: omit action, pass tool_name + parameters directly.
    """
    err = _check_mcp_url()
    if err:
        return jsonify(err), 503

    data = request.get_json(silent=True) or {}
    action = data.get("action", "invoke")

    if action == "list":
        try:
            tools = asyncio.run(_list_mcp_tools())
            return jsonify({
                "status": "ok",
                "mcp_server": MCP_SERVER_URL,
                "total_tools": len(tools),
                "tools": tools,
                "hint": "Use tool_name from this list with action=invoke"
            })
        except Exception as e:
            return jsonify({"status": "error", "error": str(e),
                            "hint": "Is the cloudflare tunnel active? Update OCTOPUS_MCP_URL in Railway if URL changed."}), 502

    tool_name = data.get("tool_name", "").strip()
    parameters = data.get("parameters", {})

    if not tool_name:
        return jsonify({
            "status": "error",
            "error": "tool_name required. Use action=list first to get available tool names."
        }), 400

    try:
        result = asyncio.run(_call_mcp_tool(tool_name, parameters))
        result_str = json.dumps(result)
        if len(result_str) > MAX_RESPONSE_CHARS:
            result["result"] = [r[:400] + "...(truncated)" for r in result.get("result", [])]
            result["truncated"] = True
        return jsonify(result)
    except BaseException as e:
        # Unwrap anyio / asyncio ExceptionGroup so the real cause surfaces instead
        # of the opaque "unhandled errors in a TaskGroup (1 sub-exception)" wrapper.
        msg = _flatten_exception(e)
        return jsonify({
            "status": "error", "tool": tool_name, "error": msg,
            "hint": f"Use action=list to verify tool name. MCP: {MCP_SERVER_URL}"
        }), 502


# ---------------------------------------------------------------------------
# Browser-friendly helpers (bypass Join39's 2000-char cap for web clients)
# ---------------------------------------------------------------------------

_B64_RE = re.compile(r'"image_base64"\s*:\s*"([A-Za-z0-9+/=]+)"')


def _pick_camera_tools(tools: list[dict], hint: str | None) -> list[str]:
    """Return ordered list of capture_image tools to try (preferred first).

    The hint parameter is the steering knob — exact name match first, then
    substring match (case-insensitive). Hint hits go to the front of the
    list. After that we include every capture_image tool, then anything
    else with `capture` in the name (in case naming drifts). The caller
    iterates this list trying each until one returns a valid PNG, so a
    flaky/broken physical device (e.g. a webcam with USB cable issues)
    doesn't take down the whole `/camera/latest*.png` route — it just
    falls through to the next candidate.

    Order rules: hinted matches first, then `*_capture_image` tools, then
    other `capture` tools. Within each tier we preserve the original
    discovery order.
    """
    effective_hint = hint or os.environ.get("DEFAULT_CAMERA_HINT", "").strip() or None
    out: list[str] = []
    seen: set[str] = set()

    def add(name: str) -> None:
        if name and name not in seen:
            out.append(name)
            seen.add(name)

    if effective_hint:
        for t in tools:
            if t["name"] == effective_hint:
                add(t["name"])
        h = effective_hint.lower()
        for t in tools:
            if h in t["name"].lower() and t["name"].endswith("capture_image"):
                add(t["name"])
    for t in tools:
        if t["name"].endswith("capture_image"):
            add(t["name"])
    for t in tools:
        if "capture" in t["name"] and "video" not in t["name"]:
            add(t["name"])
    return out


# Backwards-compat shim — some places (older deployments, tests) still call
# `_pick_camera_tool` and expect a single string. New code should use
# `_pick_camera_tools` and iterate.
def _pick_camera_tool(tools: list[dict], hint: str | None) -> str | None:
    candidates = _pick_camera_tools(tools, hint)
    return candidates[0] if candidates else None


def _extract_png_bytes(result: dict) -> bytes | None:
    """Pull a base64 PNG out of a `_call_mcp_tool` result and decode it.

    MCP tool returns text blocks; each block is typically JSON with an
    `image_base64` field. Regex-scan rather than re-parse to tolerate
    escaping quirks.
    """
    for block in result.get("result", []) or []:
        m = _B64_RE.search(block)
        if m:
            try:
                return base64.b64decode(m.group(1))
            except Exception:
                continue
    return None


@app.route("/camera/latest.png", methods=["GET"])
def camera_latest_png():
    """Return the latest camera frame as raw PNG bytes.

    Bypasses Join39's 2000-char text cap by responding with image/png instead
    of JSON. Query params:
      ?tool=brio_100_capture_image   (optional — default: auto-pick)
    """
    err = _check_mcp_url()
    if err:
        return jsonify(err), 503

    hint = request.args.get("tool")
    try:
        tools = asyncio.run(_list_mcp_tools())
    except Exception as e:
        return jsonify({"status": "error",
                        "error": f"Cannot list tools: {_flatten_exception(e)}"}), 502

    candidates = _pick_camera_tools(tools, hint)
    if not candidates:
        return jsonify({"status": "error",
                        "error": "No capture_image tool found in the live MCP server.",
                        "available": [t["name"] for t in tools]}), 404

    # Try each candidate in order — first one that yields a valid PNG wins.
    # Falls through transparently when a physical device is broken (e.g. USB
    # signal issues on one webcam) without taking down the whole route.
    attempts: list[dict] = []
    png: bytes | None = None
    chosen: str | None = None
    for candidate in candidates:
        try:
            result = asyncio.run(_call_mcp_tool(candidate, {}))
        except BaseException as e:
            attempts.append({"tool": candidate, "error": _flatten_exception(e)})
            continue
        png = _extract_png_bytes(result)
        if png:
            chosen = candidate
            break
        attempts.append({"tool": candidate, "error": "no image_base64 field",
                         "preview": (result.get("result") or [""])[0][:200]})

    if not png:
        return jsonify({"status": "error",
                        "error": "All camera tools failed.",
                        "attempts": attempts}), 502

    return Response(png, mimetype="image/png", headers={
        "Cache-Control": "no-store",
        "X-Octopus-Tool": chosen,
        "X-Octopus-Attempts": str(len(attempts) + 1),
    })


# ---------------------------------------------------------------------------
# Auto-i2i camera endpoint — gemini-2.5-flash-image with autocontrast
# preprocessing.
#
# Pipeline:
#   raw frame → autocontrast (recover exposure) → gemini i2i → cleaned PNG
#
# Why autocontrast first? The LifeCam over-saturates in apartment daylight —
# raw frames come back nearly all white with arm details barely visible.
# PIL's autocontrast (cutoff=2, dropping top/bottom 2% as outliers) gives
# the visible content the full 0-255 range so gemini has actual contrast
# to preserve and falls into "edit" mode rather than "generate" mode.
#
# (Briefly removed when we thought the rig had changed; restored after
# confirming the LifeCam still over-exposes.)
# ---------------------------------------------------------------------------

import io  # noqa: E402

_GEMINI_KEY = os.environ.get("GEMINI_API_KEY", "").strip() or None
_GEMINI_URL = (
    "https://generativelanguage.googleapis.com/v1beta/"
    "models/gemini-2.5-flash-image:generateContent?key={key}"
)
_CLEAN_PROMPT = "Remove the background in this photo. Make it a white room."


def _normalize_exposure(png_bytes: bytes) -> bytes | None:
    """Stretch histogram to recover dynamic range. The LifeCam saturates in
    apartment daylight — frames come back nearly all white with arm details
    barely visible. PIL's autocontrast (cutoff=2, drop top/bottom 2% as
    outliers) gives the visible content the full 0-255 range so gemini has
    actual contrast to preserve."""
    if not png_bytes:
        return None
    try:
        from PIL import Image, ImageOps  # type: ignore
        img = Image.open(io.BytesIO(png_bytes)).convert("RGB")
        normalized = ImageOps.autocontrast(img, cutoff=2)
        buf = io.BytesIO()
        normalized.save(buf, format="PNG", optimize=True)
        return buf.getvalue()
    except Exception:
        return None


def _clean_with_gemini(png_bytes: bytes) -> bytes | None:
    """Gemini-based background sanitization with exposure preprocessing.
    Returns cleaned PNG bytes, or None on any failure (caller falls back
    to autocontrast'd raw)."""
    if not _GEMINI_KEY or not png_bytes:
        return None
    # Normalize exposure first so gemini sees actual content, not white
    normalized = _normalize_exposure(png_bytes) or png_bytes
    import urllib.request
    import urllib.error
    body = json.dumps({
        "contents": [{"parts": [
            {"text": _CLEAN_PROMPT},
            {"inline_data": {"mime_type": "image/png",
                             "data": base64.b64encode(normalized).decode()}},
        ]}],
        "generationConfig": {
            "temperature": 0.1,
            "topP": 0.5,
            "candidateCount": 1,
        },
    }).encode()
    req = urllib.request.Request(
        _GEMINI_URL.format(key=_GEMINI_KEY),
        data=body, headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=45) as r:
            d = json.loads(r.read())
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        return None
    except Exception:
        return None
    for cand in d.get("candidates", []):
        for part in cand.get("content", {}).get("parts", []):
            inline = part.get("inline_data") or part.get("inlineData")
            if inline and inline.get("data"):
                try:
                    return base64.b64decode(inline["data"])
                except Exception:
                    continue
    return None


@app.route("/camera/latest-clean.png", methods=["GET"])
def camera_latest_clean_png():
    """Like /camera/latest.png but runs the frame through a gemini i2i
    background-clean pass first. Falls back transparently to the raw frame
    if gemini is unavailable / returns nothing in time. Adds X-Octopus-
    Cleaned header so callers can tell.
    """
    err = _check_mcp_url()
    if err:
        return jsonify(err), 503
    hint = request.args.get("tool")
    try:
        tools = asyncio.run(_list_mcp_tools())
    except Exception as e:
        return jsonify({"status": "error",
                        "error": f"Cannot list tools: {_flatten_exception(e)}"}), 502
    candidates = _pick_camera_tools(tools, hint)
    if not candidates:
        return jsonify({"status": "error",
                        "error": "No capture_image tool found.",
                        "available": [t["name"] for t in tools]}), 404
    attempts: list[dict] = []
    raw: bytes | None = None
    chosen: str | None = None
    for candidate in candidates:
        try:
            result = asyncio.run(_call_mcp_tool(candidate, {}))
        except BaseException as e:
            attempts.append({"tool": candidate, "error": _flatten_exception(e)})
            continue
        raw = _extract_png_bytes(result)
        if raw:
            chosen = candidate
            break
        attempts.append({"tool": candidate, "error": "no image_base64 field"})

    if not raw:
        return jsonify({"status": "error",
                        "error": "All camera tools failed.",
                        "attempts": attempts}), 502

    cleaned = _clean_with_gemini(raw)
    # If gemini fails, at least serve the autocontrast'd raw — much more
    # readable than the saturated original even without bg removal.
    fallback = _normalize_exposure(raw) or raw
    bytes_out = cleaned if cleaned else fallback
    if cleaned:
        method = "gemini-2.5-flash-image+autocontrast"
    elif fallback is not raw:
        method = "autocontrast-only"
    else:
        method = "raw"
    return Response(bytes_out, mimetype="image/png", headers={
        "Cache-Control": "no-store",
        "X-Octopus-Tool": chosen,
        "X-Octopus-Cleaned": "1" if cleaned else "0",
        "X-Octopus-Clean-Method": method,
        "X-Octopus-Attempts": str(len(attempts) + 1),
    })


@app.route("/tools/invoke_raw", methods=["POST"])
def invoke_tool_raw():
    """Same as /tools/invoke but without the 2000-char truncation.

    Browser clients (our landing page) can hit this for tools that produce
    large payloads (camera frames, video frames, audio). Join39's own runtime
    should keep using /tools/invoke.
    """
    err = _check_mcp_url()
    if err:
        return jsonify(err), 503

    data = request.get_json(silent=True) or {}
    tool_name = data.get("tool_name", "").strip()
    parameters = data.get("parameters", {})
    if not tool_name:
        return jsonify({"status": "error",
                        "error": "tool_name required"}), 400
    try:
        result = asyncio.run(_call_mcp_tool(tool_name, parameters))
        return jsonify(result)
    except BaseException as e:
        return jsonify({"status": "error", "tool": tool_name,
                        "error": _flatten_exception(e)}), 502


def _flatten_exception(exc) -> str:
    """Return a readable message from a possibly-nested ExceptionGroup."""
    parts = []
    def walk(e):
        inner = getattr(e, "exceptions", None)
        if inner:
            for sub in inner:
                walk(sub)
        else:
            parts.append(f"{type(e).__name__}: {e}")
    walk(exc)
    return " | ".join(parts) if parts else f"{type(exc).__name__}: {exc}"


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5050))
    mcp_status = MCP_SERVER_URL or "NOT SET — set OCTOPUS_MCP_URL environment variable!"
    print(f"Octopus Join39 endpoint on http://0.0.0.0:{port}")
    print(f"MCP server: {mcp_status}")
    if not MCP_SERVER_URL:
        print("WARNING: OCTOPUS_MCP_URL not set. All requests will return errors.")
    app.run(host="0.0.0.0", port=port)
