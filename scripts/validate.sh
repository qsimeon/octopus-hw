#!/bin/bash
# Validate that the generated Octopus MCP server works.
# Usage: bash scripts/validate.sh

OCTOPUS_DIR="${OCTOPUS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SERVER="$OCTOPUS_DIR/_generated/serve/server.py"

echo ""
echo "=== Octopus Server Validation ==="

# Check 1: Server file exists
if [ ! -f "$SERVER" ]; then
    echo "FAIL: No server found at $SERVER"
    echo "  Run the pipeline first: uv run python -m octopus.orchestrator --verbose"
    exit 1
fi
echo "OK: Server exists ($(wc -l < "$SERVER") lines)"

# Check 2: Valid Python syntax (system python3 — avoids `uv run` overhead on
# memory-tight Pi installs where uv's venv resolution can spike ~80 MB and
# trip the OOM killer mid-install).
PY_BIN="$(command -v python3 || command -v python || true)"
if [ -z "$PY_BIN" ]; then
    echo "FAIL: no python3 on PATH"; exit 1
fi
if ! "$PY_BIN" -c "import py_compile; py_compile.compile('$SERVER', doraise=True)" 2>/dev/null; then
    echo "FAIL: Server has Python syntax errors"
    exit 1
fi
echo "OK: Valid Python"

# Check 3: List tools via pure-shell decorator scan (no Python subprocess).
# Earlier versions of this script ran (a) `fastmcp list <server.py>`, which
# spawns the server as a stdio subprocess and hangs forever when the server
# is configured for HTTP transport, and (b) `uv run python <ast.py>`, which
# spikes ~80 MB on Pi installs mid-install and triggers the OOM killer. Both
# fail under asciinema (no human present to ctrl-C). awk + sed is bytes of
# resident memory, runs in milliseconds, and matches the deploy-stage tool
# count for our generated FastMCP servers (which always emit @<obj>.tool()
# decorators on the line directly above the def).
echo ""
echo "Tools:"
# Match `@<obj>.tool(`, `@<obj>.tool ` or `@<obj>.tool` at end-of-line (i.e. the
# decorator marker, not its substring). Avoid \b — BSD awk on macOS doesn't
# support it; gawk on Pi does, but portability beats brevity here.
TOOLS_OUT=$(awk '
    /^[[:space:]]*@.*\.tool[(]/                                  { want=1; next }
    /^[[:space:]]*@.*\.tool[[:space:]]*$/                        { want=1; next }
    want && /^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+/   { print; want=0; next }
    # Allow stacked decorators on the same tool (e.g. @mcp.tool() then
    # @tool_wrapper from Yile/Plan-26-C). Stay in "want def" state until we
    # actually see a def or non-decorator code line.
    want && /^[[:space:]]*@/                                     { next }
    want && !/^[[:space:]]*$/ && !/^[[:space:]]*#/               { want=0 }
' "$SERVER" | sed -E 's/.*def[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*).*/  \1/')
echo "$TOOLS_OUT" | grep -E "^  \w" || echo "  (no tools found)"
N=$(echo "$TOOLS_OUT" | grep -cE "^  \w")
echo ""
echo "=== Validation complete: $N tools ready ==="
echo ""
