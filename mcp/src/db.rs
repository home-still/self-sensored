use anyhow::{Context, Result};
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::{ConnectOptions, PgPool};
use std::str::FromStr;
use std::time::Duration;

pub async fn build_pool(database_url: &str) -> Result<PgPool> {
    let mut opts =
        PgConnectOptions::from_str(database_url).context("invalid DATABASE_URL")?;
    opts = opts.application_name("self-sensored-mcp");
    opts = opts.log_statements(tracing::log::LevelFilter::Debug);

    PgPoolOptions::new()
        .max_connections(4)
        .acquire_timeout(Duration::from_secs(5))
        .connect_with(opts)
        .await
        .context("connecting to postgres")
}
