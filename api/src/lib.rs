//! Library view of the API crate. Lets binaries and integration tests share
//! the same module tree instead of reaching into `main.rs` via `#[path]`.

pub mod auth;
pub mod config;
pub mod db;
pub mod error;
pub mod handlers;
pub mod importer;
pub mod llm;
pub mod models;
pub mod nutrition;
pub mod observability;
pub mod routes;
