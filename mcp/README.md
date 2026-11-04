# self-sensored-mcp

A Model Context Protocol server that exposes the Self Sensored Postgres database
to Claude Desktop as a single read-only SQL tool.

## What it does

Advertises one tool, `query`, that accepts a SQL string plus optional
parameters and returns rows as JSON. The authenticated user's UUID is bound
as `$1` automatically so every query is scoped to one person. Three resources
(`self-sensored://schema/overview.md`, `self-sensored://examples/queries.sql`,
`self-sensored://examples/recipes.md`) let the agent load the schema and
25+ example queries on demand.

## Security model (defense in depth)

1. **Read-only Postgres role.** Connect as `self_sensored_mcp`, which only has
   `SELECT` grants. This is the floor — even if every other layer is bypassed
   the DB refuses writes.
2. **Transaction-level `READ ONLY`.** Every query runs inside
   `BEGIN; SET TRANSACTION READ ONLY; SET LOCAL statement_timeout; …; ROLLBACK`.
3. **Static SQL validation** via the `sqlparser` crate. Rejects any statement
   that isn't `SELECT`, `WITH … SELECT`, `EXPLAIN`, or `SHOW`. Rejects writes
   hidden inside CTEs, multi-statement input, references to blocked functions
   (`pg_read_file`, `dblink`, `lo_import`, `pg_sleep`, `pg_notify`, …) or
   objects (`pg_authid`, `pg_largeobject`, …).
4. **Parameterized binds.** Parameters arrive as a typed JSON array and are
   bound via `sqlx`; never string-interpolated into the SQL.
5. **Input caps.** SQL ≤ 8 KB, ≤ 64 parameters, row cap of `MCP_MAX_ROWS`
   (default 5000), statement timeout of `MCP_STATEMENT_TIMEOUT_MS`
   (default 5000 ms).
6. **Sanitized errors.** Tool returns one of `parse_error`, `not_read_only`,
   `forbidden_object`, `forbidden_function`, `input_too_large`, `timeout`,
   `db_error` with a short message — no raw SQLSTATE payloads or stack traces.
7. **stderr-only logging.** stdout is reserved for MCP JSON-RPC framing.

## Build

```bash
cargo build -p self-sensored-mcp --release
# binary: target/release/self-sensored-mcp
```

## Configure

```bash
cp mcp/.env.example mcp/.env
$EDITOR mcp/.env   # fill DATABASE_URL (read-only role) and MCP_USER_ID
```

## Create the read-only DB role

The exact SQL is in `mcp/.env.example`. Run it once as a superuser on
`192.168.1.104` against the `self_sensored` database.

## Wire up Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "self-sensored": {
      "command": "/Users/ladvien/self-sensored/target/release/self-sensored-mcp",
      "env": {
        "DATABASE_URL": "postgres://self_sensored_mcp:...@192.168.1.104:5432/self_sensored",
        "MCP_USER_ID": "<user uuid>",
        "RUST_LOG": "self_sensored_mcp=info,rmcp=warn"
      }
    }
  }
}
```

Restart Claude Desktop. You should see `self-sensored` in the MCP picker.

## Smoke tests

```bash
# Unit tests (sqlparser guard)
cargo test -p self-sensored-mcp

# Manual stdio test with the MCP inspector
npx @modelcontextprotocol/inspector /Users/ladvien/self-sensored/target/release/self-sensored-mcp
```

Try in the inspector:

```json
{ "sql": "SELECT now() AS t" }
{ "sql": "SELECT count(*) FROM health_samples WHERE user_id = $1" }
{ "sql": "DROP TABLE health_samples" }   // must be rejected
```

## Keep the schema doc honest

`mcp/docs/schema.md` is hand-maintained. Any migration that adds/removes a
table or column should be mirrored there in the same PR. The schema doc is
the only thing the LLM consults before writing queries; drift is a silent
correctness bug.
