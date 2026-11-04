use std::env;

use anyhow::{Context, Result, anyhow};

pub struct Config {
    pub database_url: String,
    pub jwt_secret: String,
    pub api_host: String,
    pub api_port: u16,
    pub ollama_api_key: String,
    pub ollama_base_url: String,
    pub ollama_model: String,
    pub log_format: LogFormat,
}

#[derive(Debug, Clone, Copy)]
pub enum LogFormat {
    Pretty,
    Json,
}

impl LogFormat {
    fn from_env() -> Self {
        match env::var("LOG_FORMAT").as_deref() {
            Ok("json") => LogFormat::Json,
            _ => LogFormat::Pretty,
        }
    }
}

impl Config {
    pub fn from_env() -> Result<Self> {
        let jwt_secret = env::var("JWT_SECRET").context("JWT_SECRET not set")?;
        if jwt_secret.len() < 32 {
            return Err(anyhow!(
                "JWT_SECRET must be at least 32 bytes (got {})",
                jwt_secret.len()
            ));
        }

        let api_port: u16 = env::var("API_PORT")
            .unwrap_or_else(|_| "3000".into())
            .parse()
            .context("API_PORT must be a valid u16")?;

        Ok(Self {
            database_url: env::var("DATABASE_URL").context("DATABASE_URL not set")?,
            jwt_secret,
            api_host: env::var("API_HOST").unwrap_or_else(|_| "0.0.0.0".into()),
            api_port,
            ollama_api_key: env::var("OLLAMA_API_KEY").context("OLLAMA_API_KEY not set")?,
            ollama_base_url: env::var("OLLAMA_BASE_URL")
                .unwrap_or_else(|_| "https://ollama.com/v1".into()),
            ollama_model: env::var("OLLAMA_MODEL").unwrap_or_else(|_| "gpt-oss:120b-cloud".into()),
            log_format: LogFormat::from_env(),
        })
    }
}
