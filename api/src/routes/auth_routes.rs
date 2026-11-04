use std::sync::Arc;

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::routing::post;

use crate::handlers::auth_handler::{self, AppState};

/// 4 KB is plenty for an email + password JSON body; anything bigger is abuse.
const AUTH_BODY_LIMIT: usize = 4 * 1024;

pub fn routes(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/auth/register", post(auth_handler::register))
        .route("/auth/login", post(auth_handler::login))
        .layer(DefaultBodyLimit::max(AUTH_BODY_LIMIT))
        .with_state(state)
}
