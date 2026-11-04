# Project Consolidation

This repo (`home-still/self-sensored`, formerly `home-still/apple_health_source`)
is the canonical home for the Apple-Health personal-data stack:

- **iOS app** — `ios/SelfSensored/` (SwiftUI, HealthKit read/write, speech-to-meal),
  bundle id `com.ladvien.selfsensored`, display name **Self Sensored**.
- **REST API** — `api/` (crate `self-sensored-api`; Rust, axum, JWT, Ollama meal
  parsing, USDA nutrition).
- **Database DDLs** — `api/migrations/` (Postgres 17 + TimescaleDB hypertables).
- **MCP server** — `mcp/` (crate `self-sensored-mcp`, read-only SQL tool for
  Claude Desktop).

Served at `https://health.lolzlab.com` (Cloudflare Tunnel on `two` →
nginx on `one` :8090 → API container :3000).

## Archived predecessors

The following GitHub repos are archived. They are read-only and preserved for
history; no code was deleted. Each README carries a banner pointing back here.

| Repo                                                                              | Archived    | What it was                                                           |
|-----------------------------------------------------------------------------------|-------------|-----------------------------------------------------------------------|
| [`Ladvien/self-sensored-ios`](https://github.com/Ladvien/self-sensored-ios)         | 2026-11-04  | 2020 iOS app writing HealthKit to a personal MySQL server.             |
| [`Ladvien/self-sensored-api`](https://github.com/Ladvien/self-sensored-api)         | 2026-11-04  | 2021 REST API (empty repo).                                            |
| [`Ladvien/self-sensored-sync-app`](https://github.com/Ladvien/self-sensored-sync-app) | 2026-11-04 | 2021 React Native sync client.                                         |
| [`Ladvien/self_sensored_rust`](https://github.com/Ladvien/self_sensored_rust)       | 2026-11-04  | 2021 Rust/Actix/Diesel/MariaDB REST API.                               |
| [`Ladvien/self_sensored_flask`](https://github.com/Ladvien/self_sensored_flask)     | 2026-11-04  | 2021 Flask prototype.                                                  |
| [`Ladvien/self_sensored_python_sdk`](https://github.com/Ladvien/self_sensored_python_sdk) | 2026-11-04 | 2021 Python REST client.                                          |
| [`Ladvien/self-sensored-blog`](https://github.com/Ladvien/self-sensored-blog)       | 2026-11-04  | Project blog.                                                          |
| [`Ladvien/self-sensored-io`](https://github.com/Ladvien/self-sensored-io)           | 2026-04-18  | AWS Lambda + DynamoDB Rust API (SAM CLI). 2024 iteration.              |
| [`Ladvien/self-sensored`](https://github.com/Ladvien/self-sensored)                 | 2026-04-18  | NodeJS server grabbing HealthKit data. 2021 iteration.                 |
| [`Ladvien/auto_health`](https://github.com/Ladvien/auto_health)                     | 2026-04-18  | Rust api+mcp workspace; its binary backed `health.lolzlab.com`.         |
| [`Ladvien/self-sensored-api-flask`](https://github.com/Ladvien/self-sensored-api-flask) | 2021    | Flask API stub.                                                        |
| [`Ladvien/self_sensored_iac`](https://github.com/Ladvien/self_sensored_iac)         | 2022-11-09  | IaC for the health data warehouse.                                     |
| [`Ladvien/apple-android-health-datatype-scrapper`](https://github.com/Ladvien/apple-android-health-datatype-scrapper) | 2021-04-10 | Scrapy bot gathering Apple Health datatypes.       |

## Live services and the hostname

`https://health.lolzlab.com` is now served by this repo's API, not by the
`auto_health` binary. The `auto_health` systemd unit on `one` was disabled on
2026-11-04 and its crash-looping container stopped; the API runs as
`self-sensored-api.service` (docker, host network) behind the existing nginx
site on port 8090.

## Database

`four` (`192.168.1.104`) hosts Postgres 17 under the `postgresql-beast.service`
unit on `/mnt/nvme`. The API uses database `self_sensored`, owned by role
`self_sensored`; the MCP server uses read-only role `self_sensored_mcp`.

The pre-relabel database (2025 schema: `activity_metrics`, `heart_rate_metrics`,
… with ~1.14M rows from September 2025) was renamed to
`self_sensored_legacy_2025` and dumped to
`/mnt/nvme/backups/self-sensored/self_sensored_pre_relabel_20261104.{dump,sql}`.
It is not read by either service; the current schema is the repo's 22
migrations, with `health_samples`, `workouts` and `workout_route_points` as
TimescaleDB hypertables.

TimescaleDB required adding it to `shared_preload_libraries` on that cluster
(previously `pg_stat_statements` only) and a restart of
`postgresql-beast.service`.
