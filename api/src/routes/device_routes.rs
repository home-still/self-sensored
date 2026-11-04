use std::sync::Arc;

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::middleware;
use axum::routing::post;

use crate::auth::require_auth;
use crate::handlers::auth_handler::AppState;
use crate::handlers::device_handler;

/// Device registration is a small JSON payload; 8 KB is ample.
const DEVICE_BODY_LIMIT: usize = 8 * 1024;

pub fn routes(state: Arc<AppState>) -> Router {
    Router::new()
        .route(
            "/api/v1/devices/register",
            post(device_handler::register_device),
        )
        .layer(DefaultBodyLimit::max(DEVICE_BODY_LIMIT))
        .route_layer(middleware::from_fn_with_state(state.clone(), require_auth))
        .with_state(state)
}
