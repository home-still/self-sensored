//! Integration tests for sync_sessions terminal-state guarantees and
//! `devices.last_seen` upkeep on the /sync path. These cover the bugs
//! surfaced in the 2026-05-04 health check: (a) `/check` with no
//! `needed_uuids` left rows stuck `pending`, and (b) `last_seen` was
//! only touched by `/devices/register`, not by data flow.

use std::sync::Arc;

use self_sensored_api::handlers::auth_handler::AppState;
use self_sensored_api::llm::LlmClient;
use self_sensored_api::llm::mock::MockLlmClient;
use self_sensored_api::models::meal::ParsedMeal;
use self_sensored_api::nutrition::cache::NutritionCache;
use self_sensored_api::routes;
use axum::Router;
use axum::body::{Body, to_bytes};
use axum::http::{Method, Request, StatusCode, header};
use serde_json::{Value, json};
use sqlx::PgPool;
use tower::ServiceExt;

const TEST_SECRET: &str = "ci-test-secret-at-least-32-chars-long";

fn null_llm() -> Arc<dyn LlmClient> {
    Arc::new(MockLlmClient::new(|_| {
        Ok(ParsedMeal { items: vec![] })
    }))
}

fn build_app(pool: PgPool) -> Router {
    let state = Arc::new(AppState {
        pool,
        jwt_secret: TEST_SECRET.into(),
        llm: null_llm(),
        nutrition_cache: NutritionCache::new(),
    });
    routes::app_router(state)
}

async fn json_body(body: Body) -> Value {
    let bytes = to_bytes(body, 1024 * 1024).await.unwrap();
    serde_json::from_slice(&bytes).unwrap_or(Value::Null)
}

async fn register_and_token(app: Router) -> String {
    let req = Request::builder()
        .method(Method::POST)
        .uri("/auth/register")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({"email": "sync-tester@example.com", "password": "correct horse battery"})
                .to_string(),
        ))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = json_body(resp.into_body()).await;
    body["token"].as_str().unwrap().to_string()
}

async fn register_device(app: Router, token: &str) -> String {
    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/v1/devices/register")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::from(
            json!({
                "identifier_for_vendor": "test-ifv-0001",
                "device_name": "iPhone",
                "device_model": "iPhone16,2",
                "system_name": "iOS",
                "system_version": "26.3.1",
                "app_version": "0.1.0",
                "watch_model": null,
                "watch_os_version": null
            })
            .to_string(),
        ))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = json_body(resp.into_body()).await;
    body["device_id"].as_str().unwrap().to_string()
}

async fn check_hashes(app: Router, token: &str, device_id: &str, items: Value) -> Value {
    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/v1/health/check")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::from(
            json!({
                "device_id": device_id,
                "sample_type": "HKQuantityTypeIdentifierStepCount",
                "items": items,
            })
            .to_string(),
        ))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    json_body(resp.into_body()).await
}

#[sqlx::test(migrations = "./migrations")]
async fn hash_check_with_empty_items_marks_session_completed(pool: PgPool) {
    let token = register_and_token(build_app(pool.clone())).await;
    let device_id = register_device(build_app(pool.clone()), &token).await;

    let resp = check_hashes(build_app(pool.clone()), &token, &device_id, json!([])).await;
    let session_id = resp["session_id"].as_i64().unwrap();
    assert!(resp["needed_uuids"].as_array().unwrap().is_empty());

    let row: (String, Option<chrono::DateTime<chrono::Utc>>) =
        sqlx::query_as("SELECT status, completed_at FROM sync_sessions WHERE id = $1")
            .bind(session_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(row.0, "completed", "empty /check must terminalize");
    assert!(row.1.is_some(), "completed_at must be set");
}

#[sqlx::test(migrations = "./migrations")]
async fn hash_check_with_needed_items_leaves_session_pending(pool: PgPool) {
    let token = register_and_token(build_app(pool.clone())).await;
    let device_id = register_device(build_app(pool.clone()), &token).await;

    let resp = check_hashes(
        build_app(pool.clone()),
        &token,
        &device_id,
        json!([{"hk_uuid": "AAAAAAAA-AAAA-AAAA-AAAA-000000000001", "content_hash": "h1"}]),
    )
    .await;
    let session_id = resp["session_id"].as_i64().unwrap();
    assert_eq!(resp["needed_uuids"].as_array().unwrap().len(), 1);

    let row: (String, Option<chrono::DateTime<chrono::Utc>>) =
        sqlx::query_as("SELECT status, completed_at FROM sync_sessions WHERE id = $1")
            .bind(session_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(row.0, "pending", "/check with needed items keeps pending until /sync");
    assert!(row.1.is_none(), "completed_at must be unset until /sync runs");
}

#[sqlx::test(migrations = "./migrations")]
async fn sync_success_marks_completed_and_advances_last_seen(pool: PgPool) {
    let token = register_and_token(build_app(pool.clone())).await;
    let device_id = register_device(build_app(pool.clone()), &token).await;

    // /check first to mint a session_id (server-side state machine)
    let check = check_hashes(
        build_app(pool.clone()),
        &token,
        &device_id,
        json!([{"hk_uuid": "BBBBBBBB-BBBB-BBBB-BBBB-000000000001", "content_hash": "h2"}]),
    )
    .await;
    let session_id = check["session_id"].as_i64().unwrap();

    // Capture last_seen before /sync. Subtract 1s of slack so a rapid test
    // run still sees a strict-monotonic advance.
    let before: chrono::DateTime<chrono::Utc> =
        sqlx::query_scalar("SELECT last_seen FROM devices WHERE id = $1::uuid")
            .bind(&device_id)
            .fetch_one(&pool)
            .await
            .unwrap();

    // Brief sleep so NOW() in the handler resolves to a strictly later
    // timestamp than `before`. 50 ms is enough on every CI substrate the
    // project uses (TimescaleDB on the Pi 5 is the slow target and even
    // there clock_gettime resolution is sub-ms).
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let now = chrono::Utc::now();
    let sync_req = Request::builder()
        .method(Method::POST)
        .uri("/api/v1/health/sync")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::from(
            json!({
                "session_id": session_id,
                "device_id": device_id,
                "sample_type": "HKQuantityTypeIdentifierStepCount",
                "samples": [{
                    "hk_uuid": "BBBBBBBB-BBBB-BBBB-BBBB-000000000001",
                    "sample_type": "HKQuantityTypeIdentifierStepCount",
                    "content_hash": "h2",
                    "source_name": "Apple Watch",
                    "source_bundle_id": null,
                    "source_device_id": null,
                    "start_date": now.to_rfc3339(),
                    "end_date": now.to_rfc3339(),
                    "quantity_value": 100.0,
                    "quantity_unit": "count",
                    "category_value": null,
                    "correlation_id": null,
                    "metadata": null,
                    "sync_session_id": session_id,
                }],
                "workouts": [],
                "deleted_uuids": []
            })
            .to_string(),
        ))
        .unwrap();
    let resp = build_app(pool.clone()).oneshot(sync_req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let row: (String, i32, i32) = sqlx::query_as(
        "SELECT status, samples_sent, samples_accepted FROM sync_sessions WHERE id = $1",
    )
    .bind(session_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(row.0, "completed");
    assert_eq!(row.1, 1, "samples_sent");
    assert_eq!(row.2, 1, "samples_accepted");

    let after: chrono::DateTime<chrono::Utc> =
        sqlx::query_scalar("SELECT last_seen FROM devices WHERE id = $1::uuid")
            .bind(&device_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(
        after > before,
        "devices.last_seen must advance on /sync (before={before}, after={after})"
    );
}
