use std::env;

use anyhow::{Context, Result, bail};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    Stdio,
    Http,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub user_id: Uuid,
    pub max_rows: u32,
    pub statement_timeout_ms: u32,
    pub max_response_bytes: usize,
    pub transport: Transport,
    pub http_bind: String,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        let database_url = env::var("DATABASE_URL").context("DATABASE_URL is required")?;
        if !database_url.starts_with("postgres://") && !database_url.starts_with("postgresql://") {
            bail!("DATABASE_URL must be a postgres:// connection string");
        }

        let user_id = env::var("MCP_USER_ID")
            .context("MCP_USER_ID is required (UUID of the authorized user)")?;
        let user_id = Uuid::parse_str(user_id.trim())
            .context("MCP_USER_ID must be a valid UUID")?;

        let max_rows = env::var("MCP_MAX_ROWS")
            .ok()
            .map(|s| s.parse::<u32>())
            .transpose()
            .context("MCP_MAX_ROWS must be a positive integer")?
            .unwrap_or(5000);
        if max_rows == 0 || max_rows > 100_000 {
            bail!("MCP_MAX_ROWS must be between 1 and 100000, got {max_rows}");
        }

        let statement_timeout_ms = env::var("MCP_STATEMENT_TIMEOUT_MS")
            .ok()
            .map(|s| s.parse::<u32>())
            .transpose()
            .context("MCP_STATEMENT_TIMEOUT_MS must be a positive integer")?
            .unwrap_or(5000);
        if statement_timeout_ms < 100 || statement_timeout_ms > 60_000 {
            bail!("MCP_STATEMENT_TIMEOUT_MS must be between 100 and 60000, got {statement_timeout_ms}");
        }

        let max_response_bytes = env::var("MCP_MAX_RESPONSE_BYTES")
            .ok()
            .map(|s| s.parse::<usize>())
            .transpose()
            .context("MCP_MAX_RESPONSE_BYTES must be a positive integer")?
            .unwrap_or(900_000);
        if max_response_bytes < 4096 || max_response_bytes > 4 * 1024 * 1024 {
            bail!(
                "MCP_MAX_RESPONSE_BYTES must be between 4096 and 4194304, got {max_response_bytes}"
            );
        }

        let transport = match env::var("MCP_TRANSPORT").ok().as_deref() {
            None | Some("") | Some("http") => Transport::Http,
            Some("stdio") => Transport::Stdio,
            Some(other) => bail!("MCP_TRANSPORT must be 'http' or 'stdio', got '{other}'"),
        };

        let http_bind = env::var("MCP_HTTP_BIND").unwrap_or_else(|_| "0.0.0.0:7446".to_string());

        Ok(Self {
            database_url,
            user_id,
            max_rows,
            statement_timeout_ms,
            max_response_bytes,
            transport,
            http_bind,
        })
    }
}
