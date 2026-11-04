# Self Sensored

Sync Apple Health to your own Postgres database and talk to it with any LLM via MCP.

> Part of the [home-still](https://github.com/home-still/home) ecosystem — a
> set of free, self-hosted tools for owning your personal data. Local-first,
> no subscriptions, no third-party SaaS. Your health data stays on hardware
> you own.

This repo is the canonical home for a full-stack personal health pipeline:

- **iOS app** (SwiftUI + HealthKit) that reads everything HealthKit exposes
  and pushes it to your own server.
- **Rust API** (axum) that content-hashes incoming samples, deduplicates,
  and writes them to Postgres + TimescaleDB.
- **MCP server** (`self-sensored-mcp`) that exposes the database to Claude
  Desktop — or any MCP-aware LLM — as a single, read-only SQL tool.
- **Voice meal logger** that transcribes spoken meal descriptions on-device,
  parses them with an Ollama-hosted LLM, looks up nutrients in the USDA
  database, and writes the result back to HealthKit.

It consolidates three archived predecessor repos (`self-sensored-io`,
`self-sensored`, `auto_health`) — see [`docs/MIGRATION.md`](docs/MIGRATION.md).

---

## What it does

```
   iPhone                      Rust API                 Postgres 17
 ┌─────────┐  JWT / HTTPS   ┌─────────────┐  sqlx    ┌──────────────┐
 │HealthKit│ ─────────────▶ │ axum        │ ───────▶ │ TimescaleDB  │
 │SwiftUI  │  hash-check    │ handlers    │  hyper-  │ 1-month      │
 │Speech   │ ◀──── then ──▶ │ LLM (Ollama)│  tables  │ chunks       │
 │CryptoKit│  push-needed   │             │          └──────┬───────┘
 └─────────┘                └─────────────┘                 │
                                                            │ read-only role
                                                            ▼
                                                   ┌──────────────────┐
                                                   │ self-sensored-mcp   │
                                                   │ read-only SQL    │
                                                   │ + sqlparser guard│
                                                   └────────┬─────────┘
                                                            │ stdio
                                                            ▼
                                                   ┌──────────────────┐
                                                   │ Claude Desktop / │
                                                   │ any MCP client   │
                                                   └──────────────────┘
```

The sync protocol is **two-phase and idempotent**. Phase one
(`/api/v1/health/check`): the phone sends `{hk_uuid, content_hash}` pairs and
the API returns the subset of UUIDs it doesn't already have. Phase two
(`/api/v1/health/sync`): the phone sends only the missing samples with full
payloads. Re-running a full sync never pushes unchanged data — the SHA-256
content hash is deterministic per sample.

---

## Features

### HealthKit sync

- **100+ quantity types** — body metrics, fitness (steps, distances, cycling
  power), vitals (heart rate, BP, SpO₂, temperature), lab values (glucose,
  respiratory rate), and 38 nutrition types (calories, macros, fiber,
  vitamins, minerals).
- **15+ category types** — sleep stages, stand hours, menstrual flow,
  ovulation, mindfulness, heart rate events.
- **Workouts** — 80+ activity types with duration, energy, distance,
  swimming strokes.
- **GPS route points** — high-cardinality lat/lon/alt/speed/course traces on
  their own hypertable.
- **Daily activity summaries** — Apple Watch ring data.
- **User characteristics** — sex, DOB, blood type, skin type.
- **Anchor-based delta reads** (`HKAnchoredObjectQuery`) with content-hash
  dedup for idempotent full resyncs. A full resync on a 100k-sample library
  pushes ~3 MB of hash pairs instead of ~50 MB of raw payloads.

### Storage

- **Postgres 17 + TimescaleDB 2.26** hypertables with 1-month chunks.
- **Compression** segmented by `(user_id, sample_type)` — per-metric
  compression ratios.
- **Single wide `health_samples` table** keyed by a `sample_type`
  discriminator. Adding a new HealthKit identifier is zero schema change.
- **Lightweight manifest table** (`health_sample_manifest`) for fast hash
  lookups during the `/check` phase, so the hot path doesn't scan the
  multi-month hypertable.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) and [`ERD.md`](ERD.md) for the full
schema; [`api/migrations/`](api/migrations/) is the authoritative source.

### Voice meal logging

- **On-device `SFSpeechRecognizer`** with a custom food-vocabulary model —
  no audio leaves the phone before transcription.
- **Ollama Cloud LLM** (default `gpt-oss:120b-cloud`) parses the transcript
  into structured JSON: `{ items: [{ food_name, quantity, unit, prep,
  confidence, search_terms }] }`.
- **USDA nutrition database** — ~9,900 foods from SR Legacy + Foundation
  Foods, matched via GIN full-text + trigram indexes, with portion
  resolution ("2 cups of milk" → exact grams).
- **Write-back to HealthKit** via `HKCorrelation` tagged with a sync
  identifier so the next read-sync cycle skips it (no upload loop).

### MCP server (`self-sensored-mcp`)

One tool, `query(sql, params?)`, scoped to the authenticated user
(UUID bound as `$1` automatically). Defense in depth:

1. **Read-only Postgres role** (`self_sensored_mcp`) — only `SELECT` grants.
2. **Transaction-level `READ ONLY`** — every query runs inside
   `BEGIN; SET TRANSACTION READ ONLY; SET LOCAL statement_timeout; ...; ROLLBACK`.
3. **Static SQL validation** (`sqlparser` crate) — rejects anything that
   isn't `SELECT`, `WITH ... SELECT`, `EXPLAIN`, or `SHOW`; blocks writes
   hidden inside CTEs, multi-statement input, and dangerous functions /
   objects (`pg_read_file`, `dblink`, `pg_sleep`, `pg_authid`, ...).
4. **Parameterized binds** via `sqlx` — no string interpolation.
5. **Input caps** — SQL ≤ 8 KB, ≤ 64 parameters, row cap (default 5000),
   5 s statement timeout.
6. **Sanitized errors** — returns `parse_error`, `forbidden_object`,
   `timeout`, etc.; never leaks SQLSTATE payloads or stack traces.
7. **stderr-only logging** — stdout is reserved for MCP JSON-RPC framing.

Three MCP resources ship alongside the tool so the LLM can load the schema
and example queries on demand:

| URI                                      | Contents                   |
|------------------------------------------|----------------------------|
| `self-sensored://schema/overview.md`        | Read-only schema reference |
| `self-sensored://examples/queries.sql`      | 25+ example queries        |
| `self-sensored://examples/recipes.md`       | Query cookbook             |

Full writeup: [`mcp/README.md`](mcp/README.md). Schema reference:
[`mcp/docs/schema.md`](mcp/docs/schema.md).

### Auth & secrets

- **JWT HS256** signing, Argon2 password hashing.
- **iOS Keychain** storage for the JWT (with one-time migration from legacy
  `UserDefaults`).
- **Bitwarden as the source of truth** for `JWT_SECRET`, DB password, and
  the Ollama API key. `api/.env` is a derived artifact generated by
  `scripts/render-env.sh`; `scripts/rotate-secrets.sh` rotates the JWT and
  DB password atomically.
- Full narrative: [`docs/secrets.md`](docs/secrets.md).

### Operational niceties

- **GDPR cascades** — `ON DELETE CASCADE` on every user-scoped table
  (migration [`20260414000003_gdpr_cascades.sql`](api/migrations/20260414000003_gdpr_cascades.sql)).
- **Observability** — `tracing` + `tracing-subscriber` (JSON in prod,
  pretty in dev), Prometheus metrics at `/metrics`, request-id middleware,
  `tower-http` panic catcher.
- **Compile-time query checks** — `SQLX_OFFLINE=1` with checked-in
  `.sqlx/` cache so CI doesn't need a live database for typechecking.

---

## Architecture

| Component     | Default host                  | Tech                                          | Role                                                |
|---------------|-------------------------------|-----------------------------------------------|-----------------------------------------------------|
| iOS App       | iPhone / Apple Watch          | Swift 6, SwiftUI, HealthKit, Speech, CryptoKit| Read/write HealthKit, hash, sync, record meals      |
| API Server    | `one` (192.168.1.101), Docker | Rust, axum 0.8, tokio, sqlx 0.8, reqwest      | Auth, hash-check, sync ingestion, meal parsing      |
| Database      | `four` (192.168.1.104)        | Postgres 17.7 + TimescaleDB 2.26.1            | Hypertable storage, compression                     |
| Gateway       | `two` (192.168.1.102)         | Cloudflare tunnel + nginx                     | TLS termination, public HTTPS                       |
| MCP server    | any client machine            | Rust, rmcp 1.4, sqlparser 0.61, sqlx 0.8      | Read-only SQL tool for Claude Desktop               |

The host names above are from the author's home-lab topology; the services
are ordinary Docker / Rust binaries and run fine on one box.

---

## Tech stack

**Rust workspace** (`api/` + `mcp/`) — axum 0.8, tokio, sqlx 0.8 (compile-time
query checks), jsonwebtoken 9 (HS256), argon2 0.5, reqwest 0.12 (rustls),
moka 0.12 (in-memory LRU), sha2, validator, tracing, metrics-exporter-prometheus,
rmcp 1.4, sqlparser 0.61.

**iOS** (`ios/Self Sensored/`) — Swift 6 with strict concurrency, SwiftUI,
HealthKit, AVFoundation + Speech (on-device transcription), CryptoKit
(SHA-256), URLSession, Keychain. Project generated by XcodeGen from
[`ios/project.yml`](ios/project.yml).

**Database** — Postgres 17.7 + TimescaleDB 2.26.1 with `pg_trgm` for food
name fuzzy matching; 22 tracked migrations in [`api/migrations/`](api/migrations/).

**Deployment** — multi-stage Dockerfile (Rust 1.94 builder → Debian slim
runtime), `docker-compose.yml` for the API, optional Cloudflare tunnel for
public HTTPS. Separate `docker-compose.test.yml` brings up a throwaway
TimescaleDB on `:5433` for tests.

---

## Repository layout

```
self-sensored/
├── api/                    Rust API crate (apple-health-api)
│   ├── src/
│   │   ├── auth/           JWT middleware + helpers
│   │   ├── handlers/       Endpoint implementations (auth, device, sync, meals)
│   │   ├── routes/         axum router wiring
│   │   ├── models/         Request / response types
│   │   ├── llm/            LLM client abstraction (ollama, mock)
│   │   ├── nutrition/      USDA lookup + portion resolution
│   │   ├── config.rs       Env var parsing
│   │   ├── db.rs           sqlx pool
│   │   └── main.rs         axum setup, tracing, metrics
│   ├── migrations/         22 TimescaleDB migrations
│   ├── tests/              Integration tests (real DB)
│   └── Cargo.toml
├── ios/
│   ├── Self Sensored/         SwiftUI app
│   │   ├── HealthKit/      Type registry, anchor store, background delivery
│   │   ├── Sync/           SyncEngine, SyncQueue, APIClient, Keychain
│   │   ├── Speech/         On-device transcription + food vocabulary
│   │   ├── Models/         HealthSample, MealNutrition, SyncState
│   │   └── Views/          Auth, Sync, Meal log, History, Settings
│   ├── Self SensoredTests/    Unit + integration tests
│   └── project.yml         XcodeGen config
├── mcp/                    self-sensored-mcp crate (MCP server)
│   ├── src/
│   │   ├── sql_guard.rs    sqlparser-based validation
│   │   ├── tool_query.rs   query tool implementation
│   │   └── resources.rs    MCP resources (schema, queries, recipes)
│   └── docs/               schema.md, queries.sql, recipes.md
├── docs/
│   ├── secrets.md          Bitwarden workflow
│   ├── testing.md          Rust + iOS test setup
│   └── MIGRATION.md        Archived predecessor repos
├── scripts/
│   ├── render-env.sh       Bitwarden → api/.env
│   ├── rotate-secrets.sh   JWT + DB password rotation
│   └── README.md           Script reference
├── ARCHITECTURE.md         System design, schema, endpoints
├── ERD.md                  Mermaid ER diagram
├── BACKLOG.md              Roadmap (M1–M9 phases)
├── Dockerfile
├── docker-compose.yml
├── docker-compose.test.yml
├── Cargo.toml              Workspace root (members: api, mcp)
└── LICENSE                 AGPL-3.0
```

---

## Quickstart

### Prerequisites

```bash
# macOS
brew install rustup-init bitwarden-cli jq libpq
rustup-init -y
# Xcode 16+ from the App Store or developer.apple.com
# Docker Desktop or OrbStack

# Optional but recommended: put psql on your PATH
echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.zshrc
```

### 1. Clone

```bash
git clone https://github.com/home-still/self-sensored
cd self-sensored
```

### 2. Secrets (Bitwarden)

Create three Login items in your Bitwarden vault with these literal names
(the `/` is part of the title, not a folder):

| Vault item         | Contents                            |
|--------------------|-------------------------------------|
| `self-sensored/jwt`   | Placeholder — auto-rotated on first run |
| `self-sensored/db`    | Placeholder — auto-rotated on first run |
| `self-sensored/ollama`| Your real Ollama Cloud API key      |

Then unlock once per shell and render `api/.env`:

```bash
export BW_SESSION="$(bw unlock --raw)"
scripts/render-env.sh           # writes api/.env mode 600
```

Full walkthrough: [`docs/secrets.md`](docs/secrets.md).

### 3. Start a test database

```bash
docker compose -f docker-compose.test.yml up -d
# Postgres + TimescaleDB on localhost:5433
```

### 4. Build and run the API

```bash
cd api
cargo sqlx migrate run \
    --database-url postgres://postgres:postgres@localhost:5433/self-sensored
cargo run
# API on http://localhost:3000
```

Or via Docker:

```bash
docker compose up -d
docker compose logs -f api
```

### 5. Build and run the iOS app

```bash
cd ios
brew install xcodegen        # one-time
xcodegen
open Self Sensored.xcodeproj
# Select the Self Sensored scheme, iPhone 17 simulator, press Run (Cmd+R).
# In Settings, point the API base URL at http://localhost:3000 for local dev.
```

### 6. Register an account

In the app, enter an email + password on the Auth screen and tap **Register**.
This calls `POST /auth/register`, stores the JWT in Keychain, and advances
to the main tab view. The sync tab will start pushing data as soon as
HealthKit permissions are granted.

---

## Configuration

Environment variables consumed by the API (shape in
[`api/.env.example`](api/.env.example)):

| Variable           | Default (example)                                    | Notes                              |
|--------------------|------------------------------------------------------|------------------------------------|
| `DATABASE_URL`     | `postgres://user:password@localhost:5432/self-sensored` | sqlx connection string             |
| `JWT_SECRET`       | from Bitwarden                                       | HS256 signing key, ≥ 32 bytes      |
| `API_HOST`         | `0.0.0.0`                                            |                                    |
| `API_PORT`         | `3000`                                               |                                    |
| `RUST_LOG`         | `self_sensored_api=debug,tower_http=debug`            |                                    |
| `LOG_FORMAT`       | `pretty`                                             | `json` for production              |
| `OLLAMA_API_KEY`   | from Bitwarden                                       | Required for meal parsing          |
| `OLLAMA_BASE_URL`  | `https://ollama.com/v1`                              | OpenAI-compatible endpoint         |
| `OLLAMA_MODEL`     | `gpt-oss:120b-cloud`                                 | Any compatible model works         |

The MCP server has its own `mcp/.env.example` with `DATABASE_URL` (read-only
role), `MCP_USER_ID`, `MCP_MAX_ROWS`, and `MCP_STATEMENT_TIMEOUT_MS`.

The iOS app has no env vars. API base URL is configurable in the Settings
tab at runtime (defaults to a placeholder you should change).

---

## Connecting it to Claude via MCP

This is the whole point.

### 1. Build the server

```bash
cargo build -p self-sensored-mcp --release
# Binary: target/release/self-sensored-mcp
```

### 2. Create a read-only Postgres role

The exact SQL is in `mcp/.env.example`. Run once as a superuser:

```sql
CREATE ROLE self_sensored_mcp LOGIN PASSWORD 'strong-password';
GRANT CONNECT ON DATABASE self_sensored TO self_sensored_mcp;
GRANT USAGE ON SCHEMA public TO self_sensored_mcp;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO self_sensored_mcp;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO self_sensored_mcp;
```

### 3. Wire up Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "self-sensored": {
      "command": "/absolute/path/to/self-sensored/target/release/self-sensored-mcp",
      "env": {
        "DATABASE_URL": "postgres://self_sensored_mcp:...@host:5432/self_sensored",
        "MCP_USER_ID": "your-user-uuid",
        "RUST_LOG": "self_sensored_mcp=info,rmcp=warn"
      }
    }
  }
}
```

Restart Claude Desktop. `self-sensored` shows up in the MCP picker. You can
now ask things like:

- "What was my average resting heart rate last week?"
- "Graph my step count by day for the last 30 days."
- "How many grams of protein did I eat yesterday and where did it come from?"
- "Compare my sleep duration on weekdays vs. weekends this month."

Claude drafts a `SELECT` query, the `sqlparser` guard validates it, the
read-only role runs it inside a `READ ONLY` transaction with a 5-second
timeout, and the rows come back as JSON. Writes, `pg_sleep`, file I/O, and
access to system catalogs are impossible by construction.

Manual smoke test (without Claude):

```bash
npx @modelcontextprotocol/inspector ./target/release/self-sensored-mcp
# then try:
#   { "sql": "SELECT now() AS t" }                                      -> ok
#   { "sql": "SELECT count(*) FROM health_samples WHERE user_id = $1" } -> ok
#   { "sql": "DROP TABLE health_samples" }                              -> rejected
```

Full design & security writeup: [`mcp/README.md`](mcp/README.md).

---

## API endpoints

| Method | Path                          | Auth | Body                           |
|--------|-------------------------------|------|--------------------------------|
| POST   | `/auth/register`              | —    | `{ email, password }`          |
| POST   | `/auth/login`                 | —    | `{ email, password }`          |
| POST   | `/api/v1/devices/register`    | JWT  | device info                    |
| POST   | `/api/v1/health/check`        | JWT  | `{ sample_type, pairs[] }`     |
| POST   | `/api/v1/health/sync`         | JWT  | `{ session_id, samples[] }`    |
| POST   | `/api/v1/health/delete`       | JWT  | deletion notifications         |
| POST   | `/api/v1/health/workout-routes`| JWT | GPS route points               |
| POST   | `/api/meals/parse`            | JWT  | `{ text, meal_type }`          |
| GET    | `/api/meals/history`          | JWT  | —                              |
| GET    | `/api/meals/{id}`             | JWT  | —                              |
| GET    | `/health`                     | —    | readiness check                |
| GET    | `/metrics`                    | —    | Prometheus (intentionally open)|

Full endpoint contracts and examples live in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## Testing

```bash
# Rust unit tests (handlers with mocks, sqlparser guard)
cargo test --workspace --lib

# Rust integration tests (real Postgres via docker-compose.test.yml)
docker compose -f docker-compose.test.yml up -d
DATABASE_URL=postgres://postgres:postgres@localhost:5433/self-sensored \
    cargo test --workspace
docker compose -f docker-compose.test.yml down

# iOS
cd ios && xcodegen
xcodebuild test -project Self Sensored.xcodeproj -scheme Self Sensored \
    -destination "platform=iOS Simulator,name=iPhone 17"
```

More detail: [`docs/testing.md`](docs/testing.md).

---

## Deployment

The author runs the API as a Docker container on a Raspberry Pi 5
(`one`, 192.168.1.101) behind an nginx reverse proxy, with public HTTPS
terminated by a Cloudflare tunnel on a second Pi (`two`, 192.168.1.102).
Postgres + TimescaleDB run on a third Pi (`four`, 192.168.1.104) with NVMe
storage. Nothing about the design requires that exact topology — the
`Dockerfile` and `docker-compose.yml` at the repo root bring up the API
anywhere Docker runs. [`ARCHITECTURE.md`](ARCHITECTURE.md) covers the full
production layout.

---

## Roadmap

Tracked in [`BACKLOG.md`](BACKLOG.md) as M1–M9 milestones. Completed items
are marked inline. Current focus: precision refinements to the nutrition
lookup, continuous aggregates for common roll-ups, and broader MCP
resource coverage.

---

## Related projects

Other repos in the home-still family:

- [**home-still**](https://github.com/home-still/home) — academic research
  pipeline: search 6 paper providers, convert PDFs to markdown via layout
  detection + VLM OCR, index into Qdrant, semantic search, MCP server.
  Same philosophy, different domain.

---

## Archived predecessors

Three earlier GitHub repos preceded this one. They are archived and
read-only; each carries a banner pointing back here. Full list and history:
[`docs/MIGRATION.md`](docs/MIGRATION.md).

| Repo                                                                      | Era   | What it was                                            |
|---------------------------------------------------------------------------|-------|--------------------------------------------------------|
| [`Ladvien/self-sensored-io`](https://github.com/Ladvien/self-sensored-io) | 2024  | AWS Lambda + DynamoDB Rust API                         |
| [`Ladvien/self-sensored`](https://github.com/Ladvien/self-sensored)       | 2025  | Rust HealthKit ingest server                           |
| [`Ladvien/auto_health`](https://github.com/Ladvien/auto_health)           | 2026  | Rust api + mcp workspace (backed `health.lolzlab.com`) |

---

## License

[AGPL-3.0](LICENSE).
