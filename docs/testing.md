# Testing

## Rust

`cargo test --workspace` runs three test surfaces:

- **Unit tests** in `api/src/**/*.rs` — pure logic, no DB required.
- **LLM wiremock tests** in `api/src/llm/ollama.rs` — stub HTTP server, no DB required.
- **Handler integration tests** in `api/tests/handlers.rs` — `sqlx::test` provisions a fresh DB per test from a template, runs every migration, then drives the axum router with `tower::ServiceExt::oneshot`. Requires a Postgres with the **TimescaleDB extension** because `migrations/20260409000005_create_health_samples.sql` calls `create_hypertable`.

### Local Postgres for tests

```bash
docker compose -f docker-compose.test.yml up -d
DATABASE_URL=postgres://postgres:postgres@localhost:5433/self_sensored \
    cargo test --workspace
docker compose -f docker-compose.test.yml down
```

The compose file pulls `timescale/timescaledb:latest-pg17` and exposes it on
`127.0.0.1:5433`. It's loopback-only so it can coexist with whatever you run
on `:5432`.

The first time you start the container, run once:

```bash
PGPASSWORD=postgres psql -h localhost -p 5433 -U postgres -d self_sensored \
    -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
```

Subsequent test runs reuse the extension automatically.

### CI

GitHub Actions runs the same suite against a `postgres:17` service container,
plus `cargo fmt --check`, `cargo clippy -D warnings`, and `cargo deny check`.
See `.github/workflows/ci.yml`.

CI uses `timescale/timescaledb:latest-pg17` as the Postgres service image and
enables the extension before running migrations.

## iOS

```bash
cd ios
xcodegen
xcodebuild test \
    -project Self Sensored.xcodeproj \
    -scheme Self Sensored \
    -destination "platform=iOS Simulator,name=iPhone 17"
```

Tests cover JSON Codable round-trips, the `SyncRunner` actor's serial
execution guarantee, and the `PendingMealQueue` offline persistence. Tests
that require HealthKit / Keychain / live audio are intentionally out of
scope — they need a signed simulator and granted permissions, which CI can't
reliably provide.
