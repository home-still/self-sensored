# Project Consolidation

This repo (`home-still/apple_health_source`) is the canonical home for the
Apple-Health personal-data stack:

- **iOS app** — `ios/Self Sensored/` (SwiftUI, HealthKit read/write, speech-to-meal).
- **REST API** — `api/` (Rust, axum, JWT, Ollama meal parsing, USDA nutrition).
- **Database DDLs** — `api/migrations/` (Postgres 17 + TimescaleDB hypertables).
- **MCP server** — `mcp/` (`self-sensored-mcp`, read-only SQL tool for Claude Desktop).

## Archived predecessors

The following GitHub repos have been archived. They are read-only and preserved
for history; no code was deleted. Each of their READMEs now carries a banner
pointing back here.

| Repo                                                                 | Archived date | What it was                                                              |
|----------------------------------------------------------------------|---------------|--------------------------------------------------------------------------|
| [`Ladvien/self-sensored-io`](https://github.com/Ladvien/self-sensored-io) | 2026-04-18    | AWS Lambda + DynamoDB Rust API (SAM CLI). 2024 iteration.                |
| [`Ladvien/self-sensored`](https://github.com/Ladvien/self-sensored)       | 2026-04-18    | Rust HealthKit ingest server. 2025 iteration.                            |
| [`Ladvien/auto_health`](https://github.com/Ladvien/auto_health)           | 2026-04-18    | Rust api+mcp workspace backing `health.lolzlab.com`. 2026 iteration.     |

## Live services not affected by this consolidation

`auto_health` remains the backend for `https://health.lolzlab.com`. Archiving
the GitHub repo does not stop the running binary on the Pi. A future migration
may re-point that hostname to this repo's API, but that effort is out of scope
for the consolidation recorded here.
