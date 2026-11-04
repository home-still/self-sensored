//! Integration tests for the public HTTP surface. Each test gets a fresh DB
//! via `sqlx::test` and a fresh in-process router; the LLM client is mocked.

use std::sync::Arc;

use self_sensored_api::handlers::auth_handler::AppState;
use self_sensored_api::llm::LlmClient;
use self_sensored_api::llm::mock::MockLlmClient;
use self_sensored_api::models::meal::{Confidence, ParsedItem, ParsedMeal};
use self_sensored_api::nutrition::cache::NutritionCache;
use self_sensored_api::routes;
use axum::Router;
use axum::body::{Body, to_bytes};
use axum::http::{Method, Request, StatusCode, header};
use serde_json::{Value, json};
use sqlx::PgPool;
use tower::ServiceExt;

const TEST_SECRET: &str = "ci-test-secret-at-least-32-chars-long";

fn build_app(pool: PgPool, llm: Arc<dyn LlmClient>) -> Router {
    let state = Arc::new(AppState {
        pool,
        jwt_secret: TEST_SECRET.into(),
        llm,
        nutrition_cache: NutritionCache::new(),
    });
    routes::app_router(state)
}

fn echo_chicken_meal() -> Arc<dyn LlmClient> {
    Arc::new(MockLlmClient::new(|_text| {
        Ok(ParsedMeal {
            items: vec![ParsedItem {
                food_name: "grilled chicken breast".into(),
                quantity: 6.0,
                unit: "oz".into(),
                preparation_method: Some("grilled".into()),
                confidence: Confidence::High,
                database_search_terms: vec![
                    "grilled chicken breast".into(),
                    "chicken breast".into(),
                    "chicken".into(),
                ],
            }],
        })
    }))
}

fn always_bad_request() -> Arc<dyn LlmClient> {
    use self_sensored_api::error::AppError;
    Arc::new(MockLlmClient::new(|_| {
        Err(AppError::BadRequest("meal parse failed".into()))
    }))
}

async fn json_body(body: Body) -> Value {
    let bytes = to_bytes(body, 64 * 1024).await.unwrap();
    serde_json::from_slice(&bytes).unwrap_or(Value::Null)
}

async fn register(app: Router, email: &str, password: &str) -> (StatusCode, Value) {
    let req = Request::builder()
        .method(Method::POST)
        .uri("/auth/register")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({"email": email, "password": password}).to_string(),
        ))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    let status = resp.status();
    (status, json_body(resp.into_body()).await)
}

async fn login(app: Router, email: &str, password: &str) -> (StatusCode, Value) {
    let req = Request::builder()
        .method(Method::POST)
        .uri("/auth/login")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({"email": email, "password": password}).to_string(),
        ))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    let status = resp.status();
    (status, json_body(resp.into_body()).await)
}

#[sqlx::test(migrations = "./migrations")]
async fn register_happy_path(pool: PgPool) {
    let app = build_app(pool, echo_chicken_meal());
    let (status, body) = register(app, "alice@example.com", "correct horse battery").await;
    assert_eq!(status, StatusCode::OK);
    assert!(body.get("token").is_some(), "expected token in {body}");
}

#[sqlx::test(migrations = "./migrations")]
async fn register_duplicate_email_returns_400(pool: PgPool) {
    let llm = echo_chicken_meal();
    let app1 = build_app(pool.clone(), llm.clone());
    let _ = register(app1, "dup@example.com", "correct horse battery").await;

    let app2 = build_app(pool, llm);
    let (status, body) = register(app2, "dup@example.com", "correct horse battery").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"], "email already registered");
}

#[sqlx::test(migrations = "./migrations")]
async fn register_short_password_rejected(pool: PgPool) {
    let app = build_app(pool, echo_chicken_meal());
    let (status, body) = register(app, "a@b.com", "short").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("validation"));
}

#[sqlx::test(migrations = "./migrations")]
async fn register_invalid_email_rejected(pool: PgPool) {
    let app = build_app(pool, echo_chicken_meal());
    let (status, body) = register(app, "not-an-email", "correct horse battery").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("validation"));
}

#[sqlx::test(migrations = "./migrations")]
async fn login_happy_path(pool: PgPool) {
    let llm = echo_chicken_meal();
    let _ = register(
        build_app(pool.clone(), llm.clone()),
        "alice@example.com",
        "correct horse battery",
    )
    .await;
    let (status, body) = login(
        build_app(pool, llm),
        "alice@example.com",
        "correct horse battery",
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(body.get("token").is_some());
}

#[sqlx::test(migrations = "./migrations")]
async fn login_bad_password_returns_401(pool: PgPool) {
    let llm = echo_chicken_meal();
    let _ = register(
        build_app(pool.clone(), llm.clone()),
        "alice@example.com",
        "correct horse battery",
    )
    .await;
    let (status, body) = login(build_app(pool, llm), "alice@example.com", "wrong").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["error"], "invalid email or password");
}

#[sqlx::test(migrations = "./migrations")]
async fn login_unknown_email_returns_401(pool: PgPool) {
    let app = build_app(pool, echo_chicken_meal());
    let (status, body) = login(app, "nobody@example.com", "correct horse battery").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["error"], "invalid email or password");
}

#[sqlx::test(migrations = "./migrations")]
async fn parse_meal_without_jwt_returns_401(pool: PgPool) {
    let app = build_app(pool, echo_chicken_meal());
    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/meals/parse")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({"text": "6oz grilled chicken", "meal_type": "lunch"}).to_string(),
        ))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[sqlx::test(migrations = "./migrations")]
async fn parse_meal_with_tampered_jwt_returns_401(pool: PgPool) {
    let app = build_app(pool, echo_chicken_meal());
    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/meals/parse")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::AUTHORIZATION, "Bearer not.a.real.jwt")
        .body(Body::from(
            json!({"text": "6oz grilled chicken", "meal_type": "lunch"}).to_string(),
        ))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    let body = json_body(resp.into_body()).await;
    assert_eq!(body["error"], "invalid token");
}

#[sqlx::test(migrations = "./migrations", fixtures(path = "./fixtures", scripts("seed")))]
async fn parse_meal_happy_path(pool: PgPool) {
    let llm = echo_chicken_meal();
    let (_, register_body) = register(
        build_app(pool.clone(), llm.clone()),
        "alice@example.com",
        "correct horse battery",
    )
    .await;
    let token = register_body["token"].as_str().unwrap().to_owned();

    let app = build_app(pool, llm);
    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/meals/parse")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::from(
            json!({"text": "6oz grilled chicken", "meal_type": "lunch"}).to_string(),
        ))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = json_body(resp.into_body()).await;
    let totals = body["totals"].as_array().expect("totals array");
    assert!(!totals.is_empty(), "expected matched nutrients, got {body}");
    assert!(
        totals
            .iter()
            .any(|n| n["hk_identifier"] == "HKQuantityTypeIdentifierDietaryProtein")
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn parse_meal_llm_schema_violation_returns_400(pool: PgPool) {
    let llm = always_bad_request();
    let (_, register_body) = register(
        build_app(pool.clone(), echo_chicken_meal()),
        "alice@example.com",
        "correct horse battery",
    )
    .await;
    let token = register_body["token"].as_str().unwrap().to_owned();

    let app = build_app(pool, llm);
    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/meals/parse")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::from(
            json!({"text": "garbage", "meal_type": "lunch"}).to_string(),
        ))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = json_body(resp.into_body()).await;
    assert_eq!(body["error"], "meal parse failed");
}

#[sqlx::test(migrations = "./migrations")]
async fn meal_history_empty(pool: PgPool) {
    let llm = echo_chicken_meal();
    let (_, register_body) = register(
        build_app(pool.clone(), llm.clone()),
        "alice@example.com",
        "correct horse battery",
    )
    .await;
    let token = register_body["token"].as_str().unwrap().to_owned();

    let app = build_app(pool, llm);
    let req = Request::builder()
        .method(Method::GET)
        .uri("/api/meals/history?limit=10")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = json_body(resp.into_body()).await;
    assert!(body["items"].as_array().unwrap().is_empty());
    assert!(body["next_before"].is_null());
}
