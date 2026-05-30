#!/bin/bash
# Octopus Protocol — Universal Hardware Control Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/qsimeon/octopus-hw/main/install.sh | bash
#   OR
#   chmod +x install.sh && ./install.sh
#
# Flags / env overrides:
#   --no-tunnel  / OCTOPUS_NO_TUNNEL=1  skip the auto Cloudflare tunnel
#   --no-run     / OCTOPUS_NO_RUN=1     skip the pipeline (deps + setup only)
#   OCTOPUS_MODEL=openrouter/<provider>/<model>  preset the coding-agent model
#
# What this does (8 stages):
#   1. Install Node.js (if missing) — needed for pi-coding-agent
#   2. Install pi-coding-agent + web-search extension + OpenRouter auth
#   3. Install uv — Python package manager for the orchestrator
#   4. Clone the octopus repo (or update if it exists) + uv sync
#   5. Configure agent personality + perception
#   6. Stop old processes + clean slate
#   7. Run the hardware discovery pipeline
#   8. Validate the generated server, start daemon, expose tunnel

set -e

# Wrap in a function so `curl | bash` reads the entire script before executing.
# Without this, subprocesses (pipeline, validate) consume stdin and bash never
# sees the post-pipeline section (server deploy, daemon, dashboard).
main() {

# --- Parse install flags ----------------------------------------------------
# `--no-tunnel`  / OCTOPUS_NO_TUNNEL=1  — skip the auto Cloudflare tunnel
# `--no-run`     / OCTOPUS_NO_RUN=1     — skip the pipeline entirely
NO_TUNNEL="${OCTOPUS_NO_TUNNEL:-0}"
for arg in "$@"; do
    case "$arg" in
        --no-tunnel) NO_TUNNEL=1 ;;
        --no-run)    OCTOPUS_NO_RUN=1 ;;
    esac
done

# Portable helper: kill process on a port (works on Mac + Linux)
kill_port() {
    local port=$1
    if command -v lsof &>/dev/null; then
        lsof -ti :"$port" | xargs kill 2>/dev/null || true
    elif command -v fuser &>/dev/null; then
        fuser -k "$port/tcp" 2>/dev/null || true
    fi
}

# Detect if running from within the repo (local dev) or via curl (fresh install)
if [ -f "$(dirname "$0")/octopus.toml" ]; then
    OCTOPUS_DIR="$(cd "$(dirname "$0")" && pwd)"
else
    OCTOPUS_DIR="${OCTOPUS_DIR:-$HOME/octopus}"
fi

# Tee all output to octopus.log so the daemon can see install events
mkdir -p "$OCTOPUS_DIR/_generated" 2>/dev/null || true
exec > >(tee -a "$OCTOPUS_DIR/_generated/octopus.log") 2>&1

echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║       🐙 Octopus Protocol Installer          ║"
echo "║       Universal Agentic Hardware Control      ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""

# --- 1. Check/install Node.js ---
if ! command -v node &>/dev/null; then
    echo "[1/8] Installing Node.js..."
    if command -v apt-get &>/dev/null; then
        # Debian/Ubuntu/Raspberry Pi OS
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt-get install -y nodejs
    elif command -v brew &>/dev/null; then
        brew install node
    else
        echo "ERROR: Cannot install Node.js automatically. Install it manually:"
        echo "  https://nodejs.org/en/download/"
        exit 1
    fi
else
    echo "[1/8] Node.js found: $(node --version)"
fi

# --- 1b. On Linux: disable ModemManager (it grabs /dev/ttyACM* and resets Arduinos) ---
# ModemManager auto-probes any new /dev/ttyACM* device with AT commands. For an
# Arduino MKRZero (rail controller) or Feetech servo bus, that triggers a board
# reset and an endless connect/disconnect loop. The arm + rail are unreachable
# until we tell ModemManager to stand down. macOS doesn't have it — skip silently.
if command -v systemctl &>/dev/null && systemctl list-unit-files 2>/dev/null | grep -q '^ModemManager.service'; then
    echo "[1b/8] Disabling ModemManager (it grabs /dev/ttyACM* and resets connected microcontrollers)..."
    sudo systemctl stop ModemManager 2>/dev/null || true
    sudo systemctl disable ModemManager 2>/dev/null || true
fi

# --- 2. Install pi-coding-agent + web search extension ---
# Package name migrated from @mariozechner/pi-coding-agent → @earendil/pi (2026-04)
# See: https://mariozechner.at/posts/2026-04-08-ive-sold-out/
#
# On Debian/Ubuntu/WSL where Node comes from apt, the global node_modules dir
# (/usr/lib/node_modules) is owned by root — a non-root `npm install -g` gets
# EACCES. Reconfigure npm to a user-local prefix instead of asking for sudo.
ensure_user_npm_prefix() {
    local npm_root
    npm_root=$(npm root -g 2>/dev/null || echo "")
    if [ -n "$npm_root" ] && [ -w "$npm_root" ]; then
        return 0  # system prefix is writable; nothing to do
    fi
    local user_prefix="$HOME/.npm-global"
    mkdir -p "$user_prefix/bin" "$user_prefix/lib/node_modules" 2>/dev/null || true
    npm config set prefix "$user_prefix" 2>/dev/null || true
    # Add to PATH for this session and persist for future shells
    export PATH="$user_prefix/bin:$PATH"
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc" ] && ! grep -q ".npm-global/bin" "$rc" 2>/dev/null; then
            echo "export PATH=\"\$HOME/.npm-global/bin:\$PATH\"" >> "$rc"
        fi
    done
    echo "       Configured user-local npm prefix: $user_prefix"
}

if ! command -v pi &>/dev/null; then
    echo "[2/8] Installing pi-coding-agent..."
    ensure_user_npm_prefix
    npm install -g @mariozechner/pi-coding-agent 2>/dev/null || npm install -g @earendil/pi
else
    echo "[2/8] pi-coding-agent found: $(pi --version 2>/dev/null || echo 'installed')"
    # Auto-update pi to the latest version. New pi versions occasionally change
    # provider-resolution semantics (e.g. 0.58 → 0.73 added stricter provider
    # routing for OpenRouter); pinning users to a stale version causes silent
    # auth failures. `npm install -g` upgrades in place.
    echo "       Upgrading pi to latest..."
    npm install -g @mariozechner/pi-coding-agent 2>/dev/null || \
        sudo npm install -g @mariozechner/pi-coding-agent 2>/dev/null || \
        echo "       (pi upgrade skipped — may need sudo)"
fi

# Install web search extension (needed for device identification via VID:PID lookup).
# pi-web-access ships TypeScript sources only (loaded by pi's runtime, not
# Node's require()). Its runtime dep @sinclair/typebox is NOT auto-installed
# by `pi install npm:pi-web-access`, so we install it globally first.
if ! npm ls -g @sinclair/typebox 2>/dev/null | grep -q "@sinclair/typebox"; then
    echo "       Installing @sinclair/typebox (pi-web-access runtime dep)..."
    ensure_user_npm_prefix
    npm install -g @sinclair/typebox 2>/dev/null || sudo npm install -g @sinclair/typebox
else
    echo "       @sinclair/typebox found"
fi

if ! pi list 2>/dev/null | grep -q "pi-web-access"; then
    echo "       Installing web search extension..."
    ensure_user_npm_prefix
    pi install npm:pi-web-access
else
    echo "       Web search extension found"
    # `pi update` refreshes installed extensions to their latest npm versions;
    # the pi 0.69+ TUI surfaces "Package Updates Available" otherwise.
    pi update 2>/dev/null || true
fi
# (Removed the `node -e require('pi-web-access')` sanity check — it always
# fails because the extension is TypeScript-only, loaded by pi's runtime.
# The extension works fine even when require() throws.)

# --- 2b. Pre-populate ~/.pi/agent/auth.json so pi knows about OpenRouter ─────
# Pi's provider resolution: CLI --api-key > auth.json > env > models.json.
# Without an `openrouter` entry in auth.json, pi defaults to Anthropic and
# 401s with `invalid x-api-key` even when OPENROUTER_API_KEY is exported —
# because pi doesn't auto-route Anthropic-shaped models through OpenRouter.
# The fix: write/merge an `openrouter` provider entry into auth.json so any
# `openrouter/...` model the orchestrator passes resolves cleanly.
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    PI_AUTH_DIR="$HOME/.pi/agent"
    PI_AUTH_FILE="$PI_AUTH_DIR/auth.json"
    mkdir -p "$PI_AUTH_DIR"
    PY_BIN="$(command -v python3 || command -v python || echo '')"
    if [ -f "$PI_AUTH_FILE" ] && [ -n "$PY_BIN" ]; then
        # Merge: keep any existing providers, replace/insert openrouter.
        "$PY_BIN" -c '
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f: data = json.load(f)
except Exception:
    data = {}
data["openrouter"] = {"type": "api_key", "key": key}
with open(path, "w") as f: json.dump(data, f, indent=2)
' "$PI_AUTH_FILE" "$OPENROUTER_API_KEY"
    else
        # Fresh file (or no python available): write a minimal valid JSON.
        cat > "$PI_AUTH_FILE" <<JSON
{
  "openrouter": { "type": "api_key", "key": "$OPENROUTER_API_KEY" }
}
JSON
    fi
    chmod 600 "$PI_AUTH_FILE" 2>/dev/null || true
    echo "       Pi auth: $PI_AUTH_FILE configured for OpenRouter"
else
    echo "       WARN: OPENROUTER_API_KEY not set; pi will prompt for OAuth on first run."
    echo "             Set it (export OPENROUTER_API_KEY=sk-or-v1-...) and re-run install.sh."
fi

# --- 3. Install uv ---
if ! command -v uv &>/dev/null; then
    echo "[3/8] Installing uv (Python package manager)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # Add to PATH for this session
    export PATH="$HOME/.local/bin:$PATH"
else
    echo "[3/8] uv found: $(uv --version)"
fi

# --- 4. Clone or update octopus ---
# OCTOPUS_DIR already set at top (auto-detected or default ~/octopus)
if [ ! -d "$OCTOPUS_DIR/.git" ]; then
    # Remove stale directory if it exists but isn't a git repo
    # (the log tee above creates _generated/ before clone runs)
    if [ -d "$OCTOPUS_DIR" ]; then
        echo "[4/8] Cleaning stale directory and cloning octopus..."
        rm -rf "$OCTOPUS_DIR"
    else
        echo "[4/8] Cloning octopus..."
    fi
    git clone https://github.com/qsimeon/octopus-hw.git "$OCTOPUS_DIR"
else
    echo "[4/8] Updating octopus..."
    cd "$OCTOPUS_DIR" && git pull --ff-only 2>/dev/null || true
fi
cd "$OCTOPUS_DIR"

# Ensure a compatible Python version (3.11-3.13) is available
# uv manages Python installations — this downloads one if needed
echo "       Ensuring Python 3.11-3.13..."
uv python install 3.13 2>/dev/null || true
uv sync

# --- 5. Configure agent personality ---
echo "[5/8] Configuring agent personality..."
mkdir -p ~/.pi/agent 2>/dev/null || true
cat > ~/.pi/agent/APPEND_SYSTEM.md << 'AGENT_PERSONALITY'
You are Octopus — an autonomous hardware discovery agent.

You execute protocol stages by reading a spec and writing output files.
The orchestrator tells you where to write. You have full tool access
(bash, file write, web search).

Rules:
- Do not ask for permission. Do not pause. Execute the spec fully.
- Write your output to the file path specified in the prompt.
- If something fails, try a different approach before giving up.
- Use only standard library + OS tools unless the spec says otherwise.
AGENT_PERSONALITY

# --- 5b. Perception ---
# Cameras are discovered through the normal pipeline (probe → identify → serve).
# The perceive stage then selects the best camera for self-perception.
echo ""
echo "  Perception: cameras will be auto-discovered by the pipeline."
echo "  After pipeline, Octopus selects the best camera for self-perception."
echo "  To disable: set enabled = false in [perception] in octopus.toml"

# --- Install CLI command ---
chmod +x "$OCTOPUS_DIR/scripts/cli.sh"
mkdir -p "$HOME/.local/bin" 2>/dev/null || true
ln -sf "$OCTOPUS_DIR/scripts/cli.sh" "$HOME/.local/bin/octopus"
# Ensure ~/.local/bin is on PATH for this session
export PATH="$HOME/.local/bin:$PATH"

# --- 6. Clean slate: stop old octopus, wipe previous build ---
echo ""
echo "[6/8] Preparing fresh build..."

# Stop old server and daemon using PID files (safe, no broad pattern matching)
for PIDFILE in "$OCTOPUS_DIR/_generated/deploy/server.pid" "$OCTOPUS_DIR/_generated/daemon.pid"; do
    if [ -f "$PIDFILE" ]; then
        OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            kill "$OLD_PID" 2>/dev/null
            echo "  Stopped process $OLD_PID ($(basename "$PIDFILE" .pid))"
        fi
    fi
done

# Also free the server port if something else grabbed it
if [ -f "$OCTOPUS_DIR/_generated/deploy/connection.json" ]; then
    OLD_PORT=$(python3 -c "import json; print(json.load(open('$OCTOPUS_DIR/_generated/deploy/connection.json'))['port'])" 2>/dev/null)
    if [ -n "$OLD_PORT" ]; then
        kill_port "$OLD_PORT"
    fi
fi

# Kill any old inspector
kill_port 6274
kill_port 6277

# Wipe previous generated output for a clean build
rm -rf "$OCTOPUS_DIR/_generated"
echo "  Cleared previous build"

# --- 6b. OpenRouter API key + model selection ---
# Octopus is OpenRouter-only — one key powers a curated dropdown of
# agentic-coding models. Multi-provider direct keys (Anthropic, Google,
# ZAI direct, etc.) were dropped because:
#   - more keys = more failure modes during install
#   - OpenRouter exposes nearly every frontier model via the same
#     {provider}/{model-slug} schema with one billing surface
#   - users were already converging on OpenRouter regardless
#
# Works with `curl | bash` because /dev/tty is the controlling terminal
# even when stdin is piped.
interactive_model_select() {
    # Bail if no controlling terminal (CI, ssh -T).
    if ! [ -t 0 ] && ! [ -t 1 ]; then
        return 0
    fi
    if ! [ -r /dev/tty ] || ! [ -w /dev/tty ]; then
        return 0
    fi

    # 1. OPENROUTER_API_KEY — auto-detect, confirm, or override
    local existing_key="${OPENROUTER_API_KEY:-}"
    if [ -n "$existing_key" ]; then
        {
            echo ""
            echo "─── OpenRouter API key ──────────────────────────────────────────"
            echo "  ✓ OPENROUTER_API_KEY found in environment"
            echo "    Use this key, or paste a different one?"
        } > /dev/tty
        read -r -p "Use existing key? [Y/n]: " USE_EXISTING < /dev/tty || USE_EXISTING="y"
        case "${USE_EXISTING:-y}" in
            n|N|no|NO)
                read -r -s -p "  Paste OPENROUTER_API_KEY: " API_KEY < /dev/tty
                echo "" > /dev/tty
                [ -n "$API_KEY" ] && export OPENROUTER_API_KEY="$API_KEY"
                ;;
        esac
    else
        {
            echo ""
            echo "─── OpenRouter API key required ─────────────────────────────────"
            echo "  Octopus uses OpenRouter to reach all supported models with one key."
            echo "  Get a key at openrouter.ai (starts with sk-or-)."
            echo "  (input is hidden; press Enter to skip and set manually later)"
        } > /dev/tty
        read -r -s -p "  OPENROUTER_API_KEY: " API_KEY < /dev/tty
        echo "" > /dev/tty
        if [ -z "$API_KEY" ]; then
            echo "  No key entered — set OPENROUTER_API_KEY and re-run to start the pipeline." > /dev/tty
            return 0
        fi
        export OPENROUTER_API_KEY="$API_KEY"
    fi

    # 2. Model selection — 10-model curated dropdown.
    # Slugs are the canonical OpenRouter {provider}/{model} IDs as of
    # 2026-05-03. If any 404, look up the current name at openrouter.ai/models.
    local default_choice=3   # Gemini 3 Flash — speed-first default (Sonnet 4.6 is too slow on Pi 3 within the 200s/stage budget)
    {
        echo ""
        echo "─── Select the coding-agent model ───────────────────────────────"
        echo "  All models route via OpenRouter — one key, ten options."
        echo ""
        echo "  1) Kimi K2.6                     moonshotai        — long context, agent-tuned"
        echo "  2) Claude Sonnet 4.6             anthropic         — strongest spec-following (slow + pricey; can timeout on Pi 3)"
        echo "  3) Gemini 3 Flash Preview        google            — DEFAULT, fast + cheap, fits Pi 3 200s/stage budget"
        echo "  4) DeepSeek V3.2                 deepseek          — strong reasoning, cheap"
        echo "  5) Claude Opus 4.7               anthropic         — highest quality (priciest)"
        echo "  6) Step 3.5 Flash                stepfun           — fast, latest gen"
        echo "  7) MiniMax M2.7                  minimax           — strong agentic reasoning"
        echo "  8) DeepSeek V4 Flash             deepseek          — fast + cheap"
        echo "  9) Grok 4.1 Fast                 x-ai              — speed-optimised"
        echo " 10) Hy3 Preview (FREE)            tencent           — free tier, top-volume"
        echo " 11) Stick with the existing octopus.toml setting"
    } > /dev/tty

    read -r -p "Choice [$default_choice]: " MODEL_CHOICE < /dev/tty || MODEL_CHOICE=""
    MODEL_CHOICE=${MODEL_CHOICE:-$default_choice}

    case "$MODEL_CHOICE" in
        1)  SELECTED_MODEL="openrouter/moonshotai/kimi-k2.6" ;;
        2)  SELECTED_MODEL="openrouter/anthropic/claude-sonnet-4.6" ;;
        3)  SELECTED_MODEL="openrouter/google/gemini-3-flash-preview" ;;
        4)  SELECTED_MODEL="openrouter/deepseek/deepseek-v3.2" ;;
        5)  SELECTED_MODEL="openrouter/anthropic/claude-opus-4.7" ;;
        6)  SELECTED_MODEL="openrouter/stepfun/step-3.5-flash" ;;
        7)  SELECTED_MODEL="openrouter/minimax/minimax-m2.7" ;;
        8)  SELECTED_MODEL="openrouter/deepseek/deepseek-v4-flash" ;;
        9)  SELECTED_MODEL="openrouter/x-ai/grok-4.1-fast" ;;
        10) SELECTED_MODEL="openrouter/tencent/hy3-preview:free" ;;
        11|*)
            echo "  Keeping octopus.toml model unchanged." > /dev/tty
            return 0 ;;
    esac

    # Persist the model choice into octopus.toml so both this run and future
    # `octopus run` calls use it. Safe, deterministic edit.
    # PYTHONIOENCODING=utf-8 forces stdout encoding to UTF-8 (Pi OS default is
    # latin-1, which crashes on any non-ASCII character — use plain ASCII here).
    PYTHONIOENCODING=utf-8 python3 - "$OCTOPUS_DIR/octopus.toml" "$SELECTED_MODEL" <<'PYEOF' || true
import re, sys, pathlib
toml_path, chosen = pathlib.Path(sys.argv[1]), sys.argv[2]
text = toml_path.read_text(encoding="utf-8")
new = re.sub(r'^(model\s*=\s*")[^"]*(".*)$', rf'\g<1>{chosen}\g<2>', text,
             count=1, flags=re.M)
if new != text:
    toml_path.write_text(new, encoding="utf-8")
    print(f"  octopus.toml model -> {chosen}")
PYEOF

    echo "" > /dev/tty
    echo "  ✓ Model: $SELECTED_MODEL" > /dev/tty
}
interactive_model_select

# --- Env-var override: OCTOPUS_MODEL=openrouter/<provider>/<model> ───────────
# When a user wants to script a fresh install with a specific model
# (e.g. for benchmarking, CI, or "rerun on Mac with Opus 4.7"), they can
# preset OCTOPUS_MODEL before piping curl|bash. This bypasses the
# interactive menu entirely and patches octopus.toml deterministically.
# Useful because the menu can't always read /dev/tty under macOS curl|bash.
#
#   Example: OCTOPUS_MODEL=openrouter/anthropic/claude-opus-4.7 \
#            curl -fsSL <install-url> | bash
if [ -n "${OCTOPUS_MODEL:-}" ]; then
    echo "  Env override: OCTOPUS_MODEL=$OCTOPUS_MODEL — patching octopus.toml..."
    PYTHONIOENCODING=utf-8 python3 - "$OCTOPUS_DIR/octopus.toml" "$OCTOPUS_MODEL" <<'PYEOF' || true
import re, sys, pathlib
toml_path, chosen = pathlib.Path(sys.argv[1]), sys.argv[2]
text = toml_path.read_text(encoding="utf-8")
new = re.sub(r'^(model\s*=\s*")[^"]*(".*)$', rf'\g<1>{chosen}\g<2>', text,
             count=1, flags=re.M)
if new != text:
    toml_path.write_text(new, encoding="utf-8")
    print(f"  octopus.toml model -> {chosen}")
PYEOF
fi

# --- 7. Write OPENROUTER_API_KEY to .env so the orchestrator subprocess finds it ---
# uv run creates a subprocess that may not inherit shell environment on some systems.
# Writing the key to .env ensures _load_env() in orchestrator.py always finds it.
# OPENROUTER_API_KEY is the only key Octopus needs.
if [ -n "$OPENROUTER_API_KEY" ]; then
    echo "OPENROUTER_API_KEY=$OPENROUTER_API_KEY" > "$OCTOPUS_DIR/.env"
fi

# --- 8. Run pipeline (if API key available) ---
HAS_KEY=false
if [ -n "$OPENROUTER_API_KEY" ]; then HAS_KEY=true; fi
if [ -f "$OCTOPUS_DIR/.env" ] && grep -q OPENROUTER_API_KEY "$OCTOPUS_DIR/.env"; then HAS_KEY=true; fi

PIPELINE_OK=false
if [ "$HAS_KEY" = true ] && [ "$OCTOPUS_NO_RUN" != "1" ]; then
    echo ""
    echo "[7/8] Running hardware discovery pipeline (typically ~10-20 min with Gemini Flash default; ~25-45 min with premium models). 10-min hard budget per stage."
    PIPELINE_START=$(date +%s)

    # --- Live progress ticker --------------------------------------------
    # Writes a single overwriting line to /dev/tty (bypasses tee, so the
    # log file isn't polluted with spinner frames). Tails octopus.log to
    # surface the current stage. Falls back to plain elapsed-only output
    # if /dev/tty isn't usable (CI, ssh -T) so the install still narrates
    # itself.
    LOGFILE="$OCTOPUS_DIR/_generated/octopus.log"
    LIVE=0
    if [ -w /dev/tty ]; then LIVE=1; fi
    SPINNER_FRAMES=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

    (
        F=0
        while true; do
            sleep 2
            F=$(( (F + 1) % 10 ))
            now=$(date +%s)
            elapsed=$((now - PIPELINE_START))
            mins=$((elapsed / 60))
            secs=$((elapsed % 60))

            # Pick the most recent meaningful pipeline event from the log.
            stage_line=$(grep -E '\[pipeline\] (probe|identify|interface|serve|deploy|complete) (attempt|success|FAILED)' \
                              "$LOGFILE" 2>/dev/null | tail -1)
            stage_msg=$(echo "$stage_line" | sed -E 's/.*\[pipeline\] (.*)$/\1/')
            [ -z "$stage_msg" ] && stage_msg="starting…"

            if [ "$LIVE" = "1" ]; then
                printf '\r\033[K  %s  %s — %dm%02ds' \
                    "${SPINNER_FRAMES[$F]}" "$stage_msg" "$mins" "$secs" > /dev/tty
            else
                # Headless fallback: one line every 60s, like the old ticker.
                if [ $((elapsed % 60)) -lt 2 ]; then
                    printf "    [%dm%02ds] %s\n" "$mins" "$secs" "$stage_msg"
                fi
            fi
        done
    ) &
    TICKER_PID=$!
    # Ensure the ticker dies and a final newline is written, even on error.
    cleanup_ticker() {
        kill "$TICKER_PID" 2>/dev/null || true
        [ "$LIVE" = "1" ] && printf '\r\033[K' > /dev/tty
    }
    trap cleanup_ticker EXIT
    if PYTHONIOENCODING=utf-8 uv run python -m octopus.orchestrator --verbose; then
        cleanup_ticker; trap - EXIT
        TOTAL=$(($(date +%s) - PIPELINE_START))
        printf "    [pipeline finished in %dm%02ds]\n" "$((TOTAL / 60))" "$((TOTAL % 60))"
        PIPELINE_OK=true
        echo ""
        echo "[8/8] Validating generated server..."
        bash "$OCTOPUS_DIR/scripts/validate.sh"
    else
        cleanup_ticker; trap - EXIT
        echo ""
        echo "╔═══════════════════════════════════════════════╗"
        echo "║  ❌  Pipeline failed — installation aborted   ║"
        echo "╚═══════════════════════════════════════════════╝"
        echo ""
        echo "Probe or another stage could not complete."
        echo ""
        echo "Common causes:"
        echo "  • OPENROUTER_API_KEY invalid or out of credits — check at openrouter.ai/credits"
        echo "  • Network issue (Pi: check WiFi/ethernet is up)"
        echo "  • Permission error (Pi: run: sudo chown -R \$USER:\$USER \$HOME/octopus)"
        echo ""
        echo "See full agent output:"
        echo "  cat $OCTOPUS_DIR/_generated/probe/agent.log"
        echo ""
        echo "Retry after fixing:"
        echo "  cd $OCTOPUS_DIR && uv run python -m octopus.orchestrator --verbose"
        exit 1
    fi
else
    echo ""
    echo "NOTE: No OPENROUTER_API_KEY found. Set one and re-run:"
    echo "  export OPENROUTER_API_KEY=sk-or-...    (one key, all supported models)"
    echo ""
    echo "  Get a key at openrouter.ai. Then re-run:"
    echo "    curl -fsSL https://raw.githubusercontent.com/qsimeon/octopus-hw/main/install.sh | bash"
    echo ""
    echo "  Or run the pipeline manually:"
    echo "    cd $OCTOPUS_DIR && uv run python -m octopus.orchestrator --verbose"
fi

if [ "$PIPELINE_OK" = true ]; then
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║       🐙 Installation complete!               ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
fi

# If deploy ran successfully, show its output instead of manual instructions
if [ -f "$OCTOPUS_DIR/_generated/deploy/connection.json" ]; then
    echo "Server deployed automatically by the pipeline."
    echo "Connection info: $OCTOPUS_DIR/_generated/deploy/connection.json"
    echo ""
    if [ -f "$OCTOPUS_DIR/_generated/deploy/server.pid" ]; then
        PID=$(cat "$OCTOPUS_DIR/_generated/deploy/server.pid")
        if kill -0 "$PID" 2>/dev/null; then
            PORT=$(python3 -c "import json; print(json.load(open('$OCTOPUS_DIR/_generated/deploy/connection.json'))['port'])" 2>/dev/null || echo "7777")
            echo "  Server RUNNING on port $PORT (PID $PID)"
        else
            echo "  Server not running. To start:"
            echo "    bash $OCTOPUS_DIR/_generated/deploy/start.sh"
        fi
    fi
    echo ""
    if [ -d "$OCTOPUS_DIR/_generated/deploy/clients" ]; then
        echo "Client configs written to: $OCTOPUS_DIR/_generated/deploy/clients/"
        ls "$OCTOPUS_DIR/_generated/deploy/clients/" 2>/dev/null | sed 's/^/    /'
    fi

    DEVICE_IP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    echo ""
    echo "  MCP Server: http://$DEVICE_IP:$PORT/mcp"
    echo "  Connect any MCP client to that URL."
    echo "  Client configs: $OCTOPUS_DIR/_generated/deploy/clients/"

    # Kill existing daemon if running (prevents duplicates on re-install)
    if [ -f "$OCTOPUS_DIR/_generated/daemon.pid" ]; then
        OLD_PID=$(cat "$OCTOPUS_DIR/_generated/daemon.pid")
        kill "$OLD_PID" 2>/dev/null && echo "  Stopped old daemon (PID $OLD_PID)"
        rm -f "$OCTOPUS_DIR/_generated/daemon.pid"
    fi

    # Start daemon in background (living backend)
    echo ""
    echo "Starting daemon (living backend)..."
    nohup uv run python -m octopus.orchestrator --resume --daemon \
      >> "$OCTOPUS_DIR/_generated/octopus.log" 2>&1 &
    DAEMON_PID=$!
    echo "  Daemon RUNNING (PID $DAEMON_PID)"
    echo "  The daemon watches octopus.log for errors and auto-heals the server."

    # --- Auto-tunnel: localhost -> public HTTPS via Cloudflare quick-tunnel ---
    # Tiny problem: the MCP server is localhost-only.
    # Tiny fix: one Cloudflare quick-tunnel command and any agent on the
    # internet can drive it (Claude Desktop, OpenClaw, Join39 bridge, etc.).
    # Skip with --no-tunnel or OCTOPUS_NO_TUNNEL=1 if you'd rather manage
    # your own networking.
    if [ "$NO_TUNNEL" = "1" ]; then
        echo ""
        echo "  Tunnel skipped (--no-tunnel). To expose later: octopus expose"
    else
        echo ""
        echo "─── Exposing the MCP server publicly ────────────────────────────"
        # cli.sh's expose case prints the URL + client-config snippets.
        bash "$OCTOPUS_DIR/scripts/cli.sh" expose || \
            echo "  (tunnel didn't come up; you can retry with: octopus expose)"
    fi
else
    echo "To start the MCP server (network-accessible):"
    echo "  cd $OCTOPUS_DIR"
    echo "  uv run fastmcp run _generated/serve/server.py --transport http --host 0.0.0.0 --port 7777"
fi
echo ""
echo "To see all logs:"
echo "  tail -f $OCTOPUS_DIR/_generated/octopus.log"
echo ""

# Print dashboard access info — don't auto-launch (would block terminal)
if [ -f "$OCTOPUS_DIR/_generated/deploy/connection.json" ]; then
    DASH_PORT=$(python3 -c "import json; print(json.load(open('$OCTOPUS_DIR/_generated/deploy/connection.json'))['port'])" 2>/dev/null || echo "7777")
    DEVICE_IP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    echo "To open the MCP Inspector dashboard:"
    echo "  octopus dashboard"
    echo ""
    echo "  MCP Server:  http://$DEVICE_IP:$DASH_PORT/mcp"
    echo "  Any MCP-compatible client can connect to that URL."
fi

} # end main()

# Run — the function is fully loaded before execution starts
main "$@"
