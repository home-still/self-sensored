use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use chrono::{Duration, Utc};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation, decode, encode};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::AppError;

pub const JWT_ISSUER: &str = "self-sensored";
pub const JWT_AUDIENCE: &str = "self-sensored-ios";
pub const JWT_ALGORITHM: Algorithm = Algorithm::HS256;
// Access-token TTL. TODO: shorten to 1h once iOS refresh-token flow lands.
const TOKEN_TTL_DAYS: i64 = 30;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Claims {
    pub sub: Uuid, // user id
    pub exp: i64,  // expiration (unix timestamp)
    pub iat: i64,  // issued at
    pub iss: String,
    pub aud: String,
}

impl<S: Send + Sync> FromRequestParts<S> for Claims {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        parts
            .extensions
            .get::<Claims>()
            .cloned()
            .ok_or_else(|| AppError::Auth("not authenticated".into()))
    }
}

pub fn create_token(user_id: Uuid, secret: &str) -> Result<String, jsonwebtoken::errors::Error> {
    let now = Utc::now();
    let claims = Claims {
        sub: user_id,
        iat: now.timestamp(),
        exp: (now + Duration::days(TOKEN_TTL_DAYS)).timestamp(),
        iss: JWT_ISSUER.to_string(),
        aud: JWT_AUDIENCE.to_string(),
    };

    encode(
        &Header::new(JWT_ALGORITHM),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
}

pub fn validate_token(token: &str, secret: &str) -> Result<Claims, jsonwebtoken::errors::Error> {
    let mut validation = Validation::new(JWT_ALGORITHM);
    validation.set_required_spec_claims(&["exp", "iat", "sub", "iss", "aud"]);
    validation.set_issuer(&[JWT_ISSUER]);
    validation.set_audience(&[JWT_AUDIENCE]);

    let token_data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &validation,
    )?;
    Ok(token_data.claims)
}
