use axum::Router;
use axum::http::StatusCode;
use axum::routing::get;

async fn health() -> StatusCode {
    StatusCode::OK
}

pub fn routes() -> Router {
    Router::new().route("/health", get(health))
}
