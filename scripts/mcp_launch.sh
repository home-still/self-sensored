#!/bin/zsh
# Wrapper used by Claude Desktop to launch self-sensored-mcp.
#
# Claude Desktop's app sandbox blocks outbound LAN traffic, so the MCP
# cannot reach postgres on 192.168.1.104 directly. This wrapper first
# ensures an SSH tunnel to host `four` is up on 127.0.0.1:15432, then
# execs the MCP binary. Loopback is always allowed inside the sandbox.
#
# DATABASE_URL (passed in from claude_desktop_config.json) should point at
# 127.0.0.1:15432 — this wrapper does NOT rewrite it.

set -eu

LOCAL_PORT="${HEALTHSYNC_TUNNEL_PORT:-15432}"
REMOTE="192.168.1.104:5432"
SSH_ALIAS="${HEALTHSYNC_TUNNEL_HOST:-four}"
BIN="$(cd "$(dirname "$0")/.." && pwd)/target/release/self-sensored-mcp"

# Claude Desktop ships with a minimal PATH; make sure we can find ssh/nc/pgrep.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

# If nothing is listening on the loopback port, start a background SSH tunnel.
if ! /usr/bin/nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1; then
    /usr/bin/ssh -fN \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o StrictHostKeyChecking=accept-new \
        -L "127.0.0.1:${LOCAL_PORT}:${REMOTE}" \
        "$SSH_ALIAS" >&2

    # Give ssh a moment to bind the local port.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        /usr/bin/nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1 && break
        /bin/sleep 0.2
    done
fi

# The self-sensored-mcp binary defaults to HTTP transport. Desktop runs us as a
# subprocess and speaks JSON-RPC over stdio, so force stdio mode here.
export MCP_TRANSPORT=stdio
exec "$BIN"
