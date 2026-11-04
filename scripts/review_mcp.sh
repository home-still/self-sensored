#!/usr/bin/env bash
# review_mcp.sh — bundle the self-sensored-mcp crate + review checklist into a
# single markdown file that can be pasted into Claude Desktop for a design
# review.
#
# Usage: scripts/review_mcp.sh
# Output: reports/mcp_review_<YYYYMMDD-HHMMSS>.md

set -eu
# Don't set pipefail: `head` closes stdin early and we expect SIGPIPE upstream.

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

ts="$(date +%Y%m%d-%H%M%S)"
out_dir="reports"
out="${out_dir}/mcp_review_${ts}.md"
mkdir -p "$out_dir"

head_sha="$(git rev-parse HEAD 2>/dev/null || echo '(not a git checkout)')"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
status_short="$(git status --short 2>/dev/null || true)"

emit_file() {
    local path="$1"
    local lang="${2:-}"
    if [[ ! -f "$path" ]]; then
        printf '\n### %s\n\n_missing file_\n' "$path" >> "$out"
        return
    fi
    printf '\n### %s\n\n```%s\n' "$path" "$lang" >> "$out"
    cat "$path" >> "$out"
    # ensure fence starts on its own line
    if [[ "$(tail -c 1 "$path" | xxd -p)" != "0a" ]]; then
        printf '\n' >> "$out"
    fi
    printf '```\n' >> "$out"
}

{
cat <<'EOF'
# Self Sensored MCP — Design & Implementation Review

You are reviewing a newly written Rust MCP server, `self-sensored-mcp`, that
exposes the Self Sensored Postgres/TimescaleDB database to Claude Desktop via a
single read-only SQL tool. The packet below contains every source file,
documentation resource, and configuration artifact for the crate, along with
a snapshot of the repository's schema migrations so you can independently
verify the MCP's schema documentation.

## What to evaluate

1. **SQL-safety layers.** Do the four defenses (read-only DB role, READ ONLY
   transaction, sqlparser AST walk, input caps) compose correctly? Is any
   write path missed — e.g. data-modifying CTEs, `SELECT INTO`,
   `CREATE TEMP TABLE AS`, advisory locks, `LOCK TABLE`, `NOTIFY`,
   `LISTEN`, `PREPARE`/`EXECUTE`, `SECURITY DEFINER` function calls?
2. **Forbidden-function/object list.** Are the right things blocked? Would
   you add anything? Are any blocks false positives that would surprise a
   legitimate analytic query?
3. **Parameter handling.** Does the `bind_value` code preserve type safety?
   What happens with JSONB params, arrays, UUIDs written as strings?
   Any risk of type coercion surprising the query?
4. **Schema documentation accuracy.** Diff `mcp/docs/schema.md` against the
   migrations included below. Flag anything missing or stale.
5. **Example queries.** Are the 25 examples in `mcp/docs/queries.sql`
   correct against the schema? Are there analytically valuable queries that
   are missing?
6. **Claude Desktop UX.** Is the `query` tool description clear enough that
   an LLM will write correct queries on the first try? Are the resource
   URIs discoverable?
7. **Error surfacing.** Do the sanitized error codes leak anything
   sensitive (bound values, SQLSTATE internals, stack info)? Are the error
   messages actionable?
8. **Build/test story.** Does the unit-test table cover every forbidden
   construct? What would you add?
9. **stdio discipline.** Is any logging going to stdout? (stdout is
   reserved for MCP JSON-RPC framing.)

Please walk through the checklist below and answer each item with
yes/no/unsure + a short justification. Call out any show-stopper findings
at the top of your reply.

## Review checklist

- [ ] The read-only Postgres role SQL grants only `SELECT`, and the
      `.env.example` documents it clearly.
- [ ] Every query runs inside `BEGIN; SET TRANSACTION READ ONLY; …;
      ROLLBACK`.
- [ ] `SET LOCAL statement_timeout` is applied *inside* the transaction
      (not a session setting leaking between connections).
- [ ] The sqlparser guard rejects `INSERT`, `UPDATE`, `DELETE`, `MERGE`,
      `TRUNCATE`, `DROP`, `ALTER`, `CREATE`, `GRANT`, `REVOKE`, `COPY`,
      `SET`, `CALL`, `PREPARE`, `EXECUTE`, `NOTIFY`, `LISTEN`, `LOCK`,
      and savepoint/transaction statements.
- [ ] Modifying CTEs (`WITH x AS (DELETE … RETURNING *) SELECT *`) are
      either rejected by the parser or by the guard visitor.
- [ ] Multi-statement input (`SELECT 1; DELETE …`) is rejected.
- [ ] Forbidden functions (`pg_read_file`, `pg_read_binary_file`,
      `pg_ls_dir`, `lo_import`, `lo_export`, `dblink*`, `copy_program`,
      `pg_notify`, `pg_advisory_*`, `pg_sleep*`,
      `pg_terminate_backend`, `pg_cancel_backend`) are blocked.
- [ ] Forbidden objects (`pg_authid`, `pg_largeobject`, `pg_shadow`,
      `pg_statistic`, `pg_user_mappings`) are blocked; the allowed
      introspection surface (`information_schema.*`, `pg_catalog.pg_tables`,
      `pg_catalog.pg_indexes`) still works.
- [ ] Input size caps (`MAX_SQL_BYTES = 8192`, `MAX_PARAMS = 64`) and row
      cap (`MCP_MAX_ROWS`, default 5000) are enforced.
- [ ] Errors returned to Claude Desktop do not echo SQLSTATE internals,
      bound values, stack traces, or file paths.
- [ ] All tracing output goes to stderr; nothing writes to stdout except
      MCP framing.
- [ ] The schema doc at `mcp/docs/schema.md` matches the migrations
      included below; call out any drift.
- [ ] The example queries in `mcp/docs/queries.sql` reference only
      columns/tables that actually exist.
- [ ] The `query` tool description is sufficient for the LLM to write a
      correct query with `$1` = user UUID on the first attempt.
- [ ] `cargo test -p self-sensored-mcp` covers every branch of the guard.

EOF

printf '## Repo fingerprint\n\n'
printf -- '- commit: `%s`\n' "$head_sha"
printf -- '- branch: `%s`\n' "$branch"
printf '\n'
if [[ -n "$status_short" ]]; then
    printf '### git status --short\n\n```\n%s\n```\n\n' "$status_short"
else
    printf '_working tree is clean_\n\n'
fi

printf '## System summary (excerpt from ARCHITECTURE.md)\n\n'
if [[ -f ARCHITECTURE.md ]]; then
    printf '```\n'
    # First 80 non-blank lines are enough orientation for the reviewer.
    awk 'NF' ARCHITECTURE.md | head -n 80
    printf '\n```\n\n'
else
    printf '_ARCHITECTURE.md not found_\n\n'
fi

printf '## API surface inventory\n\n'
printf 'What the HTTP API exposes today — for context on what the MCP intentionally does NOT wrap.\n\n'
printf '```\n'
if compgen -G "api/src/routes/*.rs" > /dev/null; then
    grep -HnE '\.route\(|Router::new|axum::Router' api/src/routes/*.rs 2>/dev/null \
        | grep -vE '^\s*//' \
        | head -n 80 || true
else
    echo '(no routes found)'
fi
printf '```\n\n'

printf '## Schema snapshot\n\n'
printf '### Migrations present\n\n```\n'
ls -1 api/migrations/ 2>/dev/null || echo '(no migrations dir)'
printf '```\n\n'
printf '### Tables defined by migrations\n\n```\n'
if compgen -G "api/migrations/*.sql" > /dev/null; then
    grep -hE '^\s*CREATE (TABLE|MATERIALIZED VIEW|VIEW|SCHEMA|EXTENSION)' api/migrations/*.sql \
        | sed -E 's/\s+/ /g' \
        | sed -E 's/\(.*$//' \
        | sort -u
else
    echo '(no migrations)'
fi
printf '```\n\n'

printf '## MCP crate source\n'
printf '\nEvery file required to build and run `self-sensored-mcp`.\n'
} > "$out"

emit_file "Cargo.toml"                toml
emit_file "mcp/Cargo.toml"            toml
emit_file "mcp/src/main.rs"           rust
emit_file "mcp/src/config.rs"         rust
emit_file "mcp/src/db.rs"             rust
emit_file "mcp/src/sql_guard.rs"      rust
emit_file "mcp/src/tool_query.rs"     rust
emit_file "mcp/src/resources.rs"      rust
emit_file "mcp/src/server.rs"         rust
emit_file "mcp/docs/schema.md"        markdown
emit_file "mcp/docs/queries.sql"      sql
emit_file "mcp/docs/recipes.md"       markdown
emit_file "mcp/.env.example"          ""
emit_file "mcp/README.md"             markdown

{
printf '\n## Claude Desktop wiring snippet\n\n'
printf '```json\n'
cat <<'EOF'
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
EOF
printf '```\n'
} >> "$out"

echo "wrote $out" >&2
echo "copy into Claude Desktop: pbcopy < $out" >&2
