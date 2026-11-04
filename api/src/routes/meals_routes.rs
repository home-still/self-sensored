use std::sync::Arc;

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::middleware;
use axum::routing::{get, post};

use crate::auth::require_auth;
use crate::handlers::auth_handler::AppState;
use crate::handlers::meals_handler;

/// Meal descriptions are short natural-language strings; 64 KB covers the most
/// verbose plausible input without giving a client room to abuse the LLM path.
const MEALS_BODY_LIMIT: usize = 64 * 1024;

pub fn routes(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/api/meals/parse", post(meals_handler::parse_meal))
        .route("/api/meals/history", get(meals_handler::history))
        .route("/api/meals/{id}", get(meals_handler::history_detail))
        .layer(DefaultBodyLimit::max(MEALS_BODY_LIMIT))
        .route_layer(middleware::from_fn_with_state(state.clone(), require_auth))
        .with_state(state)
}
