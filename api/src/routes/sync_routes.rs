use std::sync::Arc;

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::middleware;
use axum::routing::post;

use crate::auth::require_auth;
use crate::handlers::auth_handler::AppState;
use crate::handlers::sync_handler;

/// Health-sync batches from the iPhone can be large (tens of thousands of
/// samples in a single upload). 50 MB matches the previous global cap.
const SYNC_BODY_LIMIT: usize = 50 * 1024 * 1024;

pub fn routes(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/api/v1/health/check", post(sync_handler::hash_check))
        .route("/api/v1/health/sync", post(sync_handler::sync))
        .route("/api/v1/health/delete", post(sync_handler::delete))
        .route(
            "/api/v1/health/workout-routes",
            post(sync_handler::sync_routes),
        )
        .layer(DefaultBodyLimit::max(SYNC_BODY_LIMIT))
        .route_layer(middleware::from_fn_with_state(state.clone(), require_auth))
        .with_state(state)
}
