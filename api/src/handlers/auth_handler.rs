use argon2::password_hash::SaltString;
use argon2::password_hash::rand_core::OsRng;
use argon2::{Algorithm, Argon2, Params, PasswordHash, PasswordHasher, PasswordVerifier, Version};
use axum::Json;
use axum::extract::State;
use once_cell::sync::Lazy;
use sqlx::PgPool;
use validator::Validate;

use crate::auth::jwt;
use crate::error::AppError;
use crate::llm::LlmClient;
use crate::models::health_sample::AuthResponse;
use crate::models::{CreateUser, LoginRequest, User};
use crate::nutrition::cache::NutritionCache;

pub struct AppState {
    pub pool: PgPool,
    pub jwt_secret: String,
    pub llm: std::sync::Arc<dyn LlmClient>,
    pub nutrition_cache: NutritionCache,
}

// OWASP-recommended Argon2id params (m=19 MiB, t=2, p=1). Pinned so future
// crate upgrades don't silently drift the cost.
fn argon2() -> Argon2<'static> {
    let params = Params::new(19456, 2, 1, None).expect("argon2 params valid");
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
}

// Fixed hash of a dummy password, used to equalize timing when a login is
// attempted against a non-existent email.
static DUMMY_HASH: Lazy<String> = Lazy::new(|| {
    let salt = SaltString::generate(&mut OsRng);
    argon2()
        .hash_password(b"dummy-password-for-timing", &salt)
        .expect("hash dummy password")
        .to_string()
});

pub async fn register(
    State(state): State<std::sync::Arc<AppState>>,
    Json(payload): Json<CreateUser>,
) -> Result<Json<AuthResponse>, AppError> {
    payload.validate()?;

    let existing: Option<(uuid::Uuid,)> = sqlx::query_as("SELECT id FROM users WHERE email = $1")
        .bind(&payload.email)
        .fetch_optional(&state.pool)
        .await?;
    if existing.is_some() {
        return Err(AppError::BadRequest("email already registered".into()));
    }

    let salt = SaltString::generate(&mut OsRng);
    let password_hash = argon2()
        .hash_password(payload.password.as_bytes(), &salt)
        .map_err(|e| AppError::Internal(e.to_string()))?
        .to_string();

    let user: User = sqlx::query_as(
        r#"INSERT INTO users (email, password_hash)
           VALUES ($1, $2)
           RETURNING id, email, password_hash, created_at"#,
    )
    .bind(&payload.email)
    .bind(&password_hash)
    .fetch_one(&state.pool)
    .await
    .map_err(|e| match e {
        // Defense in depth for the race between the pre-check and the insert.
        sqlx::Error::Database(dbe) if dbe.code().as_deref() == Some("23505") => {
            AppError::BadRequest("email already registered".into())
        }
        other => AppError::Database(other),
    })?;

    let token = jwt::create_token(user.id, &state.jwt_secret)?;
    Ok(Json(AuthResponse {
        token,
        user_id: user.id,
    }))
}

pub async fn login(
    State(state): State<std::sync::Arc<AppState>>,
    Json(payload): Json<LoginRequest>,
) -> Result<Json<AuthResponse>, AppError> {
    payload.validate()?;

    let user: Option<User> =
        sqlx::query_as("SELECT id, email, password_hash, created_at FROM users WHERE email = $1")
            .bind(&payload.email)
            .fetch_optional(&state.pool)
            .await?;

    // Always run exactly one Argon2 verify so that timing does not reveal
    // whether the email exists.
    let (hash_to_check, user_found) = match user.as_ref() {
        Some(u) => (u.password_hash.as_str(), true),
        None => (DUMMY_HASH.as_str(), false),
    };

    let parsed_hash =
        PasswordHash::new(hash_to_check).map_err(|e| AppError::Internal(e.to_string()))?;
    let verify_ok = argon2()
        .verify_password(payload.password.as_bytes(), &parsed_hash)
        .is_ok();

    if !user_found || !verify_ok {
        return Err(AppError::Auth("invalid email or password".into()));
    }
    let user = user.expect("user_found is true");

    let token = jwt::create_token(user.id, &state.jwt_secret)?;
    Ok(Json(AuthResponse {
        token,
        user_id: user.id,
    }))
}
