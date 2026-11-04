use sqlx::PgPool;
use sqlx::postgres::PgPoolOptions;
use std::str::FromStr;
use std::time::Duration;

pub async fn init_pool(database_url: &str) -> Result<PgPool, sqlx::Error> {
    let opts = sqlx::postgres::PgConnectOptions::from_str(database_url)?
        // 5 minutes — initial historical sync against a multi-million-row
        // TimescaleDB hypertable does cross-chunk hash-check scans that can
        // legitimately take a couple of minutes per batch. Daily incremental
        // syncs after the initial fill are sub-second.
        .options([("statement_timeout", "300000")]);

    PgPoolOptions::new()
        .max_connections(20)
        // Keep a small warm pool so the first request after quiet periods
        // doesn't pay a connection-establishment cost.
        .min_connections(2)
        // Bound how long a handler waits for a connection under contention.
        // A stuck handler will 500 instead of hanging the tokio task forever.
        .acquire_timeout(Duration::from_secs(5))
        // Recycle idle connections after 10 minutes so the pool doesn't hold
        // sessions open through deploys / server-side config reloads.
        .idle_timeout(Duration::from_secs(600))
        .connect_with(opts)
        .await
}
