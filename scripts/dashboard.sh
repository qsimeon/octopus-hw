#!/bin/bash
# Octopus Dashboard — launches MCP Inspector pre-connected to the Octopus server
# Usage: bash scripts/dashboard.sh [port]

OCTOPUS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Portable: kill process on a port (Mac + Linux)
kill_port() {
    local port=$1
    if command -v lsof &>/dev/null; then
        lsof -ti :"$port" | xargs kill 2>/dev/null || true
    elif command -v fuser &>/dev/null; then
        fuser -k "$port/tcp" 2>/dev/null || true
    fi
}

# Portable: check if a port is in use
port_in_use() {
    local port=$1
    if command -v lsof &>/dev/null; then
        lsof -i :"$port" >/dev/null 2>&1
    elif command -v ss &>/dev/null; then
        ss -tlnp | grep -q ":$port "
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -q ":$port "
    else
        # Best effort: try to connect
        (echo >/dev/tcp/localhost/"$port") 2>/dev/null
    fi
}

# Accept a full URL (e.g. http://100.116.87.36:7777/mcp) or just a port number.
# Usage examples:
#   octopus dashboard                          # local server
#   octopus dashboard http://100.116.87.36:7777/mcp   # remote Pi via tailscale
if [[ "$1" == http* ]]; then
    SERVER_URL="$1"
    SERVER_PORT=$(echo "$1" | grep -oE ':[0-9]+/' | tr -d ':/' || echo "7777")
    SKIP_PORT_CHECK=true
elif [ -n "$1" ]; then
    SERVER_PORT=$1
elif [ -f "$OCTOPUS_DIR/_generated/deploy/connection.json" ]; then
    SERVER_PORT=$(python3 -c "import json; print(json.load(open('$OCTOPUS_DIR/_generated/deploy/connection.json'))['port'])" 2>/dev/null || echo "7777")
else
    SERVER_PORT=7777
fi

if [ -z "$SERVER_URL" ]; then
    SERVER_URL="http://localhost:${SERVER_PORT}/mcp"
fi
DEVICE_IP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

# Check if local server is running (skip for remote URLs)
if [ "${SKIP_PORT_CHECK}" != "true" ] && ! port_in_use "$SERVER_PORT"; then
    echo "Octopus server not running on port $SERVER_PORT."
    echo "Start it with: bash $OCTOPUS_DIR/_generated/deploy/start.sh"
    exit 1
fi

# MCP Inspector uses fixed ports: 6274 (UI) and 6277 (proxy)
kill_port 6274
kill_port 6277
sleep 1

echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║       🐙 Octopus Dashboard                    ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""
echo "  MCP Server:    http://$DEVICE_IP:$SERVER_PORT/mcp"
echo "  Dashboard:     http://localhost:6274"
echo ""
echo "  Any MCP-compatible client can connect to:"
echo "    http://$DEVICE_IP:$SERVER_PORT/mcp"
echo ""
echo ""

# Launch Inspector in background, wait for URL, return terminal.
# MCP_AUTO_OPEN_ENABLED=false stops the Inspector itself from auto-opening
# a browser tab — we open it explicitly below, and we want exactly ONE tab,
# not two. (Inspector defaults to auto-opening when authentication is on.)
INSPECTOR_LOG="/tmp/octopus_inspector.log"
rm -f "$INSPECTOR_LOG"
nohup env MCP_AUTO_OPEN_ENABLED=false npx @modelcontextprotocol/inspector \
    --transport http --server-url "$SERVER_URL" > "$INSPECTOR_LOG" 2>&1 &
INSPECTOR_PID=$!
echo "  Starting MCP Inspector (PID $INSPECTOR_PID)..."

# Wait for the URL with token to appear
for i in $(seq 1 15); do
    INSPECTOR_URL=$(grep -o 'http://localhost:6274[^ ]*' "$INSPECTOR_LOG" 2>/dev/null | head -1)
    [ -n "$INSPECTOR_URL" ] && break
    sleep 1
done

if [ -n "$INSPECTOR_URL" ]; then
    echo ""
    echo "  ✅ Inspector ready: $INSPECTOR_URL"
    echo ""
    # Try to open in browser
    if command -v open &>/dev/null; then
        open "$INSPECTOR_URL" 2>/dev/null
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$INSPECTOR_URL" 2>/dev/null
    fi
    echo "  Terminal is yours. Inspector running in background (PID $INSPECTOR_PID)."
    echo "  To stop: kill $INSPECTOR_PID"
    echo "$INSPECTOR_PID" > /tmp/octopus_inspector.pid
else
    echo "  ⚠️  Inspector URL not detected. Check: cat $INSPECTOR_LOG"
    echo "  Or open manually: http://localhost:6274"
fi
