use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::json;
use thiserror::Error;

/// Every fallible handler path returns `AppError`. The `#[source]` attribute
/// on `Database` lets `error.source()` walk into the underlying sqlx chain,
/// which the tracing subscriber serializes for structured logs.
#[derive(Debug, Error)]
pub enum AppError {
    #[error("database error")]
    Database(#[source] sqlx::Error),
    #[error("auth error: {0}")]
    Auth(String),
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("internal error: {0}")]
    Internal(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            AppError::Database(ref e) => {
                tracing::error!(error = ?e, "Database error");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal server error")
            }
            AppError::Auth(ref msg) => {
                tracing::warn!("Auth error: {msg}");
                (StatusCode::UNAUTHORIZED, msg.as_str())
            }
            AppError::BadRequest(ref msg) => (StatusCode::BAD_REQUEST, msg.as_str()),
            AppError::Internal(ref msg) => {
                tracing::error!("Internal error: {msg}");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal server error")
            }
        };

        let body = json!({ "error": message });
        (status, Json(body)).into_response()
    }
}

impl From<sqlx::Error> for AppError {
    fn from(e: sqlx::Error) -> Self {
        AppError::Database(e)
    }
}

impl From<jsonwebtoken::errors::Error> for AppError {
    fn from(_e: jsonwebtoken::errors::Error) -> Self {
        // Collapse all jsonwebtoken variants into a single opaque error so that
        // clients cannot distinguish "expired" from "tampered" from "malformed".
        AppError::Auth("invalid token".into())
    }
}

impl From<validator::ValidationErrors> for AppError {
    fn from(e: validator::ValidationErrors) -> Self {
        AppError::BadRequest(format!("validation failed: {e}"))
    }
}
