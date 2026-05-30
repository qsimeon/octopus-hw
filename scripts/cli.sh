#!/bin/bash
# Octopus CLI — control your Octopus installation
# Installed to ~/.local/bin/octopus by the installer

OCTOPUS_DIR="${OCTOPUS_DIR:-$HOME/octopus}"

# Ensure uv and local binaries are always on PATH (works on Mac, Linux, Pi)
export PATH="$HOME/.local/bin:$PATH"

# Auto-detect if running from within the repo
if [ -f "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/../octopus.toml" ]; then
    OCTOPUS_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/.." && pwd)"
fi

case "${1:-help}" in
    stop)
        bash "$OCTOPUS_DIR/scripts/stop.sh"
        ;;
    start)
        if [ -f "$OCTOPUS_DIR/_generated/deploy/start.sh" ]; then
            bash "$OCTOPUS_DIR/_generated/deploy/start.sh"
        else
            echo "No server to start. Run the pipeline first:"
            echo "  octopus run"
        fi
        ;;
    run)
        cd "$OCTOPUS_DIR" && PYTHONIOENCODING=utf-8 uv run python -m octopus.orchestrator --verbose "${@:2}"
        ;;
    dashboard)
        bash "$OCTOPUS_DIR/scripts/dashboard.sh" "${2:-}"
        ;;
    dashboard-stop|stop-dashboard)
        # Kill the MCP Inspector + any proxy children.
        KILLED=0
        for PAT in '@modelcontextprotocol/inspector' 'mcp-inspector' 'mcpinspector-server'; do
            pkill -f "$PAT" 2>/dev/null && KILLED=1
        done
        if [ "$KILLED" -eq 1 ]; then
            echo "Dashboard stopped."
        else
            echo "No dashboard process found."
        fi
        ;;
    expose-stop)
        # Kill the Cloudflare quick-tunnel and drop the pid file.
        CF_PID=$(cat /tmp/octopus_tunnel.pid 2>/dev/null)
        if [ -n "$CF_PID" ] && kill -0 "$CF_PID" 2>/dev/null; then
            kill "$CF_PID" && echo "Tunnel stopped (PID $CF_PID)."
            rm -f /tmp/octopus_tunnel.pid
        elif pgrep -f 'cloudflared tunnel' >/dev/null 2>&1; then
            pkill -f 'cloudflared tunnel' && echo "Tunnel stopped (orphaned cloudflared killed)."
            rm -f /tmp/octopus_tunnel.pid
        else
            echo "No tunnel running."
        fi
        ;;
    status)
        # Optional --reconcile flag: actively rewrite/clean stale pid files
        # so they match the actual process tree (pgrep is the source of truth).
        RECONCILE=0
        for arg in "${@:2}"; do
            case "$arg" in
                --reconcile|-r) RECONCILE=1 ;;
            esac
        done

        # Resolve pid for a process using pgrep (cross-platform; Mac + Linux).
        # Echoes the *first* matching pid, or empty string if none.
        # Excludes our own status process to avoid self-matches.
        find_proc_pid() {
            local pattern="$1"
            pgrep -f "$pattern" 2>/dev/null | grep -v "^$$\$" | head -1
        }

        # Reconcile a single pid file against pgrep.
        # Args: pid_file_path, pgrep_pattern
        # Echoes the *authoritative* live pid (or empty if nothing alive).
        # Sets pidfile state if RECONCILE=1.
        reconcile_pid() {
            local pid_file="$1"
            local pattern="$2"
            local file_pid=""
            local live_pid=""
            [ -f "$pid_file" ] && file_pid=$(cat "$pid_file" 2>/dev/null | tr -d '[:space:]')
            live_pid=$(find_proc_pid "$pattern")

            # Case 1: pid-file alive AND matches a live process — trust it.
            if [ -n "$file_pid" ] && kill -0 "$file_pid" 2>/dev/null; then
                # Sanity: ensure it actually matches the pattern (otherwise it's
                # a recycled PID belonging to some unrelated process).
                if [ -n "$live_pid" ] && [ "$file_pid" = "$live_pid" ]; then
                    echo "$file_pid"
                    return
                fi
                # PID alive but NOT matching pattern → recycled PID. Treat as stale.
                if [ "$RECONCILE" = "1" ] && [ -n "$pid_file" ]; then
                    if [ -n "$live_pid" ]; then
                        mkdir -p "$(dirname "$pid_file")" 2>/dev/null
                        echo "$live_pid" > "$pid_file" 2>/dev/null || true
                    else
                        rm -f "$pid_file"
                    fi
                fi
                echo "$live_pid"
                return
            fi

            # Case 2: pid-file dead but pgrep finds a live process → file is stale.
            #   - In reconcile mode, rewrite the file to the live pid.
            #   - Either way, report the live pid (the user manually restarted).
            if [ -n "$live_pid" ]; then
                if [ "$RECONCILE" = "1" ] && [ -n "$pid_file" ]; then
                    mkdir -p "$(dirname "$pid_file")" 2>/dev/null
                    echo "$live_pid" > "$pid_file" 2>/dev/null || true
                fi
                echo "$live_pid"
                return
            fi

            # Case 3: pid-file present but dead AND no matching process → stale.
            if [ -n "$file_pid" ] && [ "$RECONCILE" = "1" ]; then
                rm -f "$pid_file"
            fi
            echo ""
        }

        echo "Octopus v4.5 (demo mode)"
        if [ "$RECONCILE" = "1" ]; then
            echo "  (reconciling pid files against process tree...)"
        fi
        echo ""
        # Server — match fastmcp running our generated server.py
        SERVER_PID_FILE="$OCTOPUS_DIR/_generated/deploy/server.pid"
        SERVER_PATTERN="fastmcp.*_generated/serve/server.py"
        SERVER_PID=$(reconcile_pid "$SERVER_PID_FILE" "$SERVER_PATTERN")
        if [ -n "$SERVER_PID" ]; then
            PORT=$(python3 -c "import json; print(json.load(open('$OCTOPUS_DIR/_generated/deploy/connection.json'))['port'])" 2>/dev/null || echo "7777")
            LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
            echo "  Server:  RUNNING (PID $SERVER_PID, port $PORT)"
            echo "           Local:  http://$LOCAL_IP:$PORT/mcp"
            echo "           LAN:    http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo $LOCAL_IP):$PORT/mcp"
        elif [ -f "$OCTOPUS_DIR/_generated/deploy/connection.json" ]; then
            echo "  Server:  STOPPED   ← run: octopus start"
        else
            echo "  Server:  NOT DEPLOYED  ← run: octopus run"
        fi
        # Cloudflare tunnel — derive the log path from the actual port the
        # server is on (or fall back to the most recently modified tunnel log
        # if no server-port info is available). Hardcoding port 7777 caused
        # `octopus status` to print a stale URL from a previous run while
        # `octopus expose` printed the *new* URL — they pointed at different
        # log files when the deployed port wasn't 7777.
        CF_PID=$(reconcile_pid "/tmp/octopus_tunnel.pid" "cloudflared tunnel")
        if [ -n "${PORT:-}" ] && [ -f "/tmp/octopus_tunnel_${PORT}.log" ]; then
            CF_LOG="/tmp/octopus_tunnel_${PORT}.log"
        else
            CF_LOG=$(ls -t /tmp/octopus_tunnel_*.log 2>/dev/null | head -1)
        fi
        if [ -n "$CF_PID" ]; then
            CF_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1)
            if [ -n "$CF_URL" ]; then
                echo "  Tunnel:  $CF_URL/mcp"
                echo "           (use this for OpenClaw, Claude Desktop, Railway)"
            else
                echo "  Tunnel:  RUNNING (PID $CF_PID — URL not found in log)"
            fi
        else
            echo "  Tunnel:  NOT RUNNING  ← run: octopus expose"
        fi
        # Daemon — match the orchestrator running with --daemon
        DAEMON_PID_FILE="$OCTOPUS_DIR/_generated/daemon.pid"
        DAEMON_PATTERN="octopus.orchestrator.*--daemon"
        DAEMON_PID=$(reconcile_pid "$DAEMON_PID_FILE" "$DAEMON_PATTERN")
        if [ -n "$DAEMON_PID" ]; then
            echo "  Daemon:  RUNNING (PID $DAEMON_PID)"
        else
            echo "  Daemon:  NOT RUNNING  ← run: octopus resume"
        fi
        # Tools
        if [ -f "$OCTOPUS_DIR/_generated/deploy/connection.json" ]; then
            TOOLS=$(python3 -c "import json; print(json.load(open('$OCTOPUS_DIR/_generated/deploy/connection.json')).get('tool_count','?'))" 2>/dev/null || echo "?")
            echo "  Tools:   $TOOLS"
        else
            echo "  Tools:   NOT GENERATED"
        fi
        # Perception
        if [ -f "$OCTOPUS_DIR/_generated/perceive/output.json" ]; then
            CAM_STATUS=$(python3 -c "import json; print(json.load(open('$OCTOPUS_DIR/_generated/perceive/output.json'))['status'])" 2>/dev/null || echo "?")
            FRAME_COUNT=$(ls "$OCTOPUS_DIR/_generated/perceive/frames"/frame_*.png 2>/dev/null | wc -l | tr -d ' ')
            echo "  Perceive: $CAM_STATUS ($FRAME_COUNT frames)"
        else
            echo "  Perceive: NOT SET UP"
        fi
        echo ""
        echo "  Dir:     $OCTOPUS_DIR"
        ;;
    logs)
        if [ -f "$OCTOPUS_DIR/_generated/octopus.log" ]; then
            tail -f "$OCTOPUS_DIR/_generated/octopus.log"
        else
            echo "No logs yet. Run the pipeline first: octopus run"
        fi
        ;;
    perceive)
        echo "Capturing perception frame..."
        if [ -f "$OCTOPUS_DIR/_generated/perceive/capture.py" ]; then
            FRAME="$OCTOPUS_DIR/_generated/perceive/frames/manual_$(date +%Y%m%d_%H%M%S).png"
            mkdir -p "$(dirname "$FRAME")"
            cd "$OCTOPUS_DIR" && uv run python _generated/perceive/capture.py --output "$FRAME"
            if [ -f "$FRAME" ]; then
                echo "Frame saved: $FRAME"
                # Try to open the image
                if command -v open &>/dev/null; then
                    open "$FRAME"
                elif command -v xdg-open &>/dev/null; then
                    xdg-open "$FRAME"
                fi
            else
                echo "Capture failed. Check _generated/perceive/agent.log for details."
            fi
        else
            echo "No perception setup. Enable [perception] in octopus.toml and run:"
            echo "  octopus run"
        fi
        ;;
    pause)
        # Resolve daemon PID from file OR process tree (handles manual restarts).
        PID=$(cat "$OCTOPUS_DIR/_generated/daemon.pid" 2>/dev/null | tr -d '[:space:]')
        if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
            PID=$(pgrep -f "octopus.orchestrator.*--daemon" 2>/dev/null | head -1)
        fi
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null
            rm -f "$OCTOPUS_DIR/_generated/daemon.pid"
            echo "Daemon paused (PID $PID). MCP server is still running."
            echo "Resume with: octopus resume"
        else
            rm -f "$OCTOPUS_DIR/_generated/daemon.pid"
            echo "Daemon is not running."
        fi
        ;;
    resume)
        # Cross-check both pid file and pgrep — pid file alone is unreliable
        # if the daemon was started/killed manually.
        PID=$(cat "$OCTOPUS_DIR/_generated/daemon.pid" 2>/dev/null | tr -d '[:space:]')
        if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
            PID=$(pgrep -f "octopus.orchestrator.*--daemon" 2>/dev/null | head -1)
        fi
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "Daemon is already running (PID $PID)."
            # Heal a stale pid file so future status calls are accurate.
            echo "$PID" > "$OCTOPUS_DIR/_generated/daemon.pid"
            exit 0
        fi
        # Nothing alive — clear any stale pid file before relaunching.
        rm -f "$OCTOPUS_DIR/_generated/daemon.pid"
        echo "Resuming daemon (living backend)..."
        cd "$OCTOPUS_DIR" && PYTHONIOENCODING=utf-8 nohup uv run python -m octopus.orchestrator \
            --resume --daemon --verbose \
            >> "$OCTOPUS_DIR/_generated/octopus.log" 2>&1 &
        echo "Daemon resumed (PID $!)"
        ;;
    reprobe)
        # Reprobe: re-discover hardware and patch the live server
        # in place. Tiny problem (you re-plugged the arm and the live server
        # can't find it) -> tiny fix (re-runs probe + identify + perceive +
        # arm; does NOT regenerate serve/deploy).
        echo "🔄 Octopus reprobe — re-discovering hardware and patching live server..."
        cd "$OCTOPUS_DIR"

        # Pause the daemon (don't kill — caller may want it resumed after).
        DAEMON_WAS_RUNNING=0
        DPID=$(cat "$OCTOPUS_DIR/_generated/daemon.pid" 2>/dev/null | tr -d '[:space:]')
        if [ -z "$DPID" ] || ! kill -0 "$DPID" 2>/dev/null; then
            DPID=$(pgrep -f "octopus.orchestrator.*--daemon" 2>/dev/null | head -1)
        fi
        if [ -n "$DPID" ] && kill -0 "$DPID" 2>/dev/null; then
            DAEMON_WAS_RUNNING=1
            kill "$DPID" 2>/dev/null && echo "   Paused daemon (PID $DPID)"
        fi

        # Run the targeted re-discovery.
        if uv run python -m octopus.orchestrator --reprobe --verbose; then
            echo "   ✅ Reprobe complete — live server patched in place."
        else
            echo "   ⚠️  Reprobe finished with errors. Check _generated/octopus.log."
        fi

        # Resume daemon if we paused it.
        if [ "$DAEMON_WAS_RUNNING" = "1" ]; then
            echo "   Resuming daemon..."
            bash "$OCTOPUS_DIR/scripts/cli.sh" resume
        fi
        ;;
    expose)
        PORT=$(python3 -c \
            "import json; print(json.load(open('$OCTOPUS_DIR/_generated/deploy/connection.json'))['port'])" \
            2>/dev/null || echo "7777")

        if ! command -v cloudflared &>/dev/null; then
            echo "Installing cloudflared..."
            if [[ "$OSTYPE" == "darwin"* ]]; then
                brew install cloudflared 2>/dev/null || {
                    echo "Could not auto-install. Run: brew install cloudflared"
                    exit 1
                }
            else
                ARCH=$(uname -m)
                [ "$ARCH" = "aarch64" ] && DEB_ARCH="arm64" || DEB_ARCH="amd64"
                curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$DEB_ARCH" \
                    -o "$HOME/.local/bin/cloudflared" && chmod +x "$HOME/.local/bin/cloudflared" \
                    || { echo "Could not install cloudflared. Download from: https://github.com/cloudflare/cloudflared/releases"; exit 1; }
            fi
        fi

        # Fix clock drift before tunnel — cloudflare TLS validation fails if clock is wrong
        if command -v timedatectl &>/dev/null; then
            sudo timedatectl set-ntp true 2>/dev/null || true
        elif command -v ntpdate &>/dev/null; then
            sudo ntpdate -s pool.ntp.org 2>/dev/null || true
        fi

        TUNNEL_LOG="/tmp/octopus_tunnel_$PORT.log"
        rm -f "$TUNNEL_LOG"

        # ── Named-tunnel detection ────────────────────────────────────────────
        # Cloudflare quick-tunnels rotate URL on every restart. For a stable
        # demo URL, the user runs `cloudflared tunnel login`, then
        # `cloudflared tunnel create octopus`, then adds a CNAME record
        # mapping (e.g.) `octopus.qsimeon.dev` → `<UUID>.cfargotunnel.com`.
        # That produces ~/.cloudflared/config.yml + ~/.cloudflared/<UUID>.json.
        # If both exist, prefer the named tunnel; otherwise fall back to a
        # quick-tunnel. See docs/named-tunnel-setup.md.
        CF_CONFIG="$HOME/.cloudflared/config.yml"
        NAMED_TUNNEL=0
        NAMED_HOSTNAME=""
        if [ -f "$CF_CONFIG" ]; then
            # Look for a credentials JSON file matching any UUID-shaped filename.
            CRED_JSON=$(ls "$HOME/.cloudflared"/*.json 2>/dev/null | head -1)
            if [ -n "$CRED_JSON" ]; then
                # Parse the hostname from the config (best-effort, awk-grade).
                # YAML schema is:
                #   ingress:
                #     - hostname: octopus.qsimeon.dev
                #       service: http://localhost:7777
                NAMED_HOSTNAME=$(grep -E '^\s*-?\s*hostname:' "$CF_CONFIG" 2>/dev/null \
                    | head -1 | sed -E 's/^\s*-?\s*hostname:\s*//' | tr -d '"' | tr -d "'")
                if [ -n "$NAMED_HOSTNAME" ]; then
                    NAMED_TUNNEL=1
                fi
            fi
        fi

        echo ""
        if [ "$NAMED_TUNNEL" = "1" ]; then
            echo "🌐 Starting NAMED Cloudflare tunnel (stable URL) in background..."
            echo "   Config: $CF_CONFIG"
            echo "   Hostname: $NAMED_HOSTNAME"
            # Named tunnels read everything from config.yml: tunnel UUID,
            # credentials file, and ingress rules (which include the localhost
            # service). We pass --http-host-header so FastMCP's host-validator
            # accepts the rewritten Host header.
            nohup cloudflared tunnel --config "$CF_CONFIG" \
                --http-host-header localhost run \
                > "$TUNNEL_LOG" 2>&1 &
            TUNNEL_PID=$!
            echo "   Tunnel PID: $TUNNEL_PID  (kill with: kill $TUNNEL_PID)"

            # Named tunnels don't print a *.trycloudflare.com URL — the URL is
            # the CNAME we configured. Wait briefly for "Registered tunnel
            # connection" to appear in the log to confirm it came up.
            for i in $(seq 1 20); do
                if grep -q 'Registered tunnel connection' "$TUNNEL_LOG" 2>/dev/null; then
                    break
                fi
                sleep 1
            done

            CF_URL="https://$NAMED_HOSTNAME"
            echo ""
            echo "   ✅ Named tunnel live: $CF_URL"
            echo ""
            echo "   Claude Desktop Connectors: $CF_URL/mcp"
            echo "   OpenClaw MCP config: { \"url\": \"$CF_URL/mcp\", \"transport\": \"streamable-http\" }"
            echo "   Railway OCTOPUS_MCP_URL: $CF_URL/mcp"
            echo ""
            echo "   Terminal is yours. Tunnel stays running (PID $TUNNEL_PID)."
            echo "   To stop: kill $TUNNEL_PID  or  octopus expose-stop"
            echo "$TUNNEL_PID" > /tmp/octopus_tunnel.pid
        else
            echo "🌐 Starting Cloudflare quick-tunnel (port $PORT) in background..."
            echo "   (URL will rotate on each restart — for stable URL see"
            echo "    docs/named-tunnel-setup.md)"
            # --http-host-header localhost rewrites the Host header so FastMCP
            # (which validates Host) accepts the request — without it cloudflared
            # forwards the public *.trycloudflare.com hostname and FastMCP returns
            # "Invalid Host header" 400 on every call.
            nohup cloudflared tunnel --url "http://localhost:$PORT" --http-host-header localhost > "$TUNNEL_LOG" 2>&1 &
            TUNNEL_PID=$!
            echo "   Tunnel PID: $TUNNEL_PID  (kill with: kill $TUNNEL_PID)"

            # Wait for URL to appear (up to 20 seconds)
            for i in $(seq 1 20); do
                CF_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1)
                [ -n "$CF_URL" ] && break
                sleep 1
            done

            if [ -n "$CF_URL" ]; then
                echo ""
                echo "   ✅ Tunnel live: $CF_URL"
                echo ""
                echo "   Claude Desktop Connectors: $CF_URL/mcp"
                echo "   OpenClaw MCP config: { \"url\": \"$CF_URL/mcp\", \"transport\": \"streamable-http\" }"
                echo "   Railway OCTOPUS_MCP_URL: $CF_URL/mcp"
                echo ""
                echo "   Terminal is yours. Tunnel stays running (PID $TUNNEL_PID)."
                echo "   To stop: kill $TUNNEL_PID  or  kill \$(cat /tmp/octopus_tunnel.pid 2>/dev/null)"
                echo "$TUNNEL_PID" > /tmp/octopus_tunnel.pid
            else
                echo "   ⚠️  URL not detected after 20s. Check: cat $TUNNEL_LOG"
            fi
        fi
        ;;
    uninstall)
        echo "Stopping Octopus processes..."
        bash "$OCTOPUS_DIR/scripts/stop.sh" 2>/dev/null || true

        echo "Removing generated files (_generated/)..."
        rm -rf "$OCTOPUS_DIR/_generated"

        echo "Removing CLI symlink..."
        rm -f "$HOME/.local/bin/octopus"

        echo ""
        echo "✓ Octopus uninstalled."
        echo ""
        echo "The repository is still at: $OCTOPUS_DIR"
        echo "To remove it completely:  rm -rf $OCTOPUS_DIR"
        echo ""
        echo "To reinstall from scratch:"
        echo "  export OPENROUTER_API_KEY=your-key   # recommended"
        echo "  curl -fsSL https://raw.githubusercontent.com/qsimeon/octopus-hw/main/install.sh | bash"
        ;;
    validate)
        bash "$OCTOPUS_DIR/scripts/validate.sh"
        ;;
    chat)
        shift
        # Build a context file with current Octopus state
        CTX_FILE=$(mktemp /tmp/octopus-chat-XXXXXX.md)
        {
            echo "You are a live assistant for Octopus, a universal agentic hardware controller."
            echo "Project directory: $OCTOPUS_DIR"
            echo ""
            echo "## Connected hardware"
            ls /dev/ttyACM* 2>/dev/null && echo "Serial arm: $(ls /dev/ttyACM* | tr '\n' ' ')" || echo "Serial arm: not detected"
            ls /dev/video* 2>/dev/null && echo "Camera: $(ls /dev/video* | tr '\n' ' ')" || echo "Camera: not detected"
            echo ""
            if [ -f "$OCTOPUS_DIR/_generated/deploy/connection.json" ]; then
                echo "## MCP Server (deployed)"
                cat "$OCTOPUS_DIR/_generated/deploy/connection.json"
                echo ""
            fi
            if [ -f "$OCTOPUS_DIR/_generated/octopus.log" ]; then
                echo "## Recent logs"
                tail -40 "$OCTOPUS_DIR/_generated/octopus.log"
                echo ""
            fi
            echo "## Notes"
            echo "MCP server (if running): http://localhost:7777/mcp"
            echo "Call a tool: curl -s -X POST http://localhost:7777/mcp -H 'Content-Type: application/json' -d '{\"method\":\"tools/call\",\"params\":{\"name\":\"<tool>\",\"arguments\":{...}}}'"
            if [ $# -gt 0 ]; then
                echo ""
                echo "## Initial request"
                echo "$*"
            fi
        } > "$CTX_FILE"

        MODEL=$(python3 -c "
import tomllib
try:
    c = tomllib.load(open('$OCTOPUS_DIR/octopus.toml','rb'))
    print(c.get('agent',{}).get('model','openrouter/google/gemini-3-flash-preview'))
except: print('openrouter/google/gemini-3-flash-preview')
" 2>/dev/null || echo "openrouter/google/gemini-3-flash-preview")

        echo "🐙 Octopus Chat  (model: $MODEL)"
        echo "   Full tool access: read, write, bash, edit"
        echo "   Ctrl+C to exit"
        echo "---"
        pi --model "$MODEL" --system-prompt "@$CTX_FILE"
        rm -f "$CTX_FILE"
        ;;
    help|--help|-h|"")
        echo "🐙 Octopus — Universal Agentic Hardware Control"
        echo ""
        echo "Usage: octopus <command>"
        echo ""
        echo "Commands:"
        echo "  run         Run the hardware discovery pipeline"
        echo "  start       Start the MCP server"
        echo "  stop        Stop server, daemon, and dashboard"
        echo "  status      Show what's running (use --reconcile to fix stale pid files)"
        echo "  dashboard   Open the MCP Inspector dashboard"
        echo "  dashboard-stop  Kill the MCP Inspector"
        echo "  expose-stop     Kill the Cloudflare tunnel (octopus expose)"
        echo "  logs        Tail the octopus log"
        echo "  perceive    Capture a frame from the perception camera"
        echo "  chat        Interactive agent session with full hardware context"
        echo "  pause       Suspend the daemon (server stays running)"
        echo "  resume      Resume the daemon after pause"
        echo "  reprobe     Re-discover hardware after a re-plug; patch live server"
        echo "  expose      Create a public HTTPS tunnel via Cloudflare"
        echo "  validate    Check the generated server"
        echo "  uninstall   Stop everything, remove _generated/, remove CLI symlink"
        echo "  help        Show this help"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'octopus help' for usage."
        exit 1
        ;;
esac
