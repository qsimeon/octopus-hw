#!/bin/bash
# Octopus Stop — kill all octopus processes cleanly
# Usage: bash scripts/stop.sh

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

echo "Stopping Octopus..."

# Daemon (by PID file)
if [ -f "$OCTOPUS_DIR/_generated/daemon.pid" ]; then
    PID=$(cat "$OCTOPUS_DIR/_generated/daemon.pid")
    kill "$PID" 2>/dev/null && echo "  Daemon stopped (PID $PID)"
    rm -f "$OCTOPUS_DIR/_generated/daemon.pid"
fi

# Server (by PID file)
if [ -f "$OCTOPUS_DIR/_generated/deploy/server.pid" ]; then
    PID=$(cat "$OCTOPUS_DIR/_generated/deploy/server.pid")
    kill "$PID" 2>/dev/null && echo "  Server stopped (PID $PID)"
fi

# Also free the server port
if [ -f "$OCTOPUS_DIR/_generated/deploy/connection.json" ]; then
    PORT=$(python3 -c "import json; print(json.load(open('$OCTOPUS_DIR/_generated/deploy/connection.json'))['port'])" 2>/dev/null)
    if [ -n "$PORT" ]; then
        kill_port "$PORT"
    fi
fi

# Inspector (fixed ports)
kill_port 6274 && echo "  Inspector stopped"
kill_port 6277

echo "Done."
