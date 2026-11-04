use std::sync::Arc;

use anyhow::Result;
use rmcp::{
    ServiceExt,
    transport::{
        stdio,
        streamable_http_server::{
            StreamableHttpServerConfig, StreamableHttpService, session::local::LocalSessionManager,
        },
    },
};
use tokio_util::sync::CancellationToken;
use tracing_subscriber::EnvFilter;

mod config;
mod db;
mod resources;
mod server;
mod sql_guard;
mod tool_query;

use config::Transport;

#[tokio::main]
async fn main() -> Result<()> {
    let _ = dotenvy::dotenv();

    let cfg = config::Config::from_env()?;
    let stdio_mode = cfg.transport == Transport::Stdio;

    let env_filter = EnvFilter::try_from_env("RUST_LOG")
        .unwrap_or_else(|_| EnvFilter::new("self_sensored_mcp=info,rmcp=warn"));
    if stdio_mode {
        // stdout is reserved for MCP framing in stdio mode.
        tracing_subscriber::fmt()
            .with_env_filter(env_filter)
            .with_writer(std::io::stderr)
            .with_ansi(false)
            .init();
    } else {
        tracing_subscriber::fmt().with_env_filter(env_filter).init();
    }

    tracing::info!(
        user_id = %cfg.user_id,
        max_rows = cfg.max_rows,
        timeout_ms = cfg.statement_timeout_ms,
        transport = ?cfg.transport,
        "self-sensored-mcp starting"
    );

    let pool = db::build_pool(&cfg.database_url).await?;

    match cfg.transport {
        Transport::Stdio => {
            let svc = server::SelfSensoredMcp::new(pool, cfg);
            let service = svc.serve(stdio()).await.inspect_err(|e| {
                tracing::error!(error = %e, "stdio service failed");
            })?;
            service.waiting().await?;
        }
        Transport::Http => serve_http(pool, cfg).await?,
    }

    Ok(())
}

async fn serve_http(pool: sqlx::PgPool, cfg: config::Config) -> Result<()> {
    let bind = cfg.http_bind.clone();
    let cfg = Arc::new(cfg);

    let ct = CancellationToken::new();
    // Empty allowlist = accept any Host header. The deployment is LAN-only and the
    // bind address is the access boundary; rebinding the host validator to every
    // possible LAN/IP variant would be churn for no extra security.
    let http_cfg = StreamableHttpServerConfig::default()
        .with_cancellation_token(ct.clone())
        .with_allowed_hosts(Vec::<String>::new());

    let service: StreamableHttpService<server::SelfSensoredMcp, LocalSessionManager> =
        StreamableHttpService::new(
            {
                let pool = pool.clone();
                let cfg = cfg.clone();
                move || Ok(server::SelfSensoredMcp::new(pool.clone(), (*cfg).clone()))
            },
            Default::default(),
            http_cfg,
        );

    let router = axum::Router::new().nest_service("/mcp", service);
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    tracing::info!(addr = %bind, "self-sensored-mcp HTTP listening at /mcp");

    let shutdown = async move {
        let _ = tokio::signal::ctrl_c().await;
        ct.cancel();
    };

    axum::serve(listener, router)
        .with_graceful_shutdown(shutdown)
        .await?;
    Ok(())
}
