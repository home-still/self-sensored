use axum::Json;
use axum::extract::State;
use uuid::Uuid;

use crate::auth::Claims;
use crate::error::AppError;
use crate::handlers::auth_handler::AppState;
use crate::models::{DeviceRegistration, DeviceResponse};

/// POST /api/v1/devices/register
///
/// Upserts a device for the authenticated user. Returns the device UUID.
pub async fn register_device(
    State(state): State<std::sync::Arc<AppState>>,
    claims: Claims,
    Json(payload): Json<DeviceRegistration>,
) -> Result<Json<DeviceResponse>, AppError> {
    let user_id = claims.sub;

    let row: (Uuid,) = sqlx::query_as(
        r#"INSERT INTO devices
           (user_id, identifier_for_vendor, device_name, device_model,
            system_name, system_version, app_version,
            watch_model, watch_os_version,
            first_seen, last_seen)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW(), NOW())
           ON CONFLICT (user_id, identifier_for_vendor) DO UPDATE SET
             device_name      = EXCLUDED.device_name,
             device_model     = EXCLUDED.device_model,
             system_name      = EXCLUDED.system_name,
             system_version   = EXCLUDED.system_version,
             app_version      = EXCLUDED.app_version,
             watch_model      = EXCLUDED.watch_model,
             watch_os_version = EXCLUDED.watch_os_version,
             last_seen        = NOW()
           RETURNING id"#,
    )
    .bind(user_id)
    .bind(&payload.identifier_for_vendor)
    .bind(&payload.device_name)
    .bind(&payload.device_model)
    .bind(&payload.system_name)
    .bind(&payload.system_version)
    .bind(&payload.app_version)
    .bind(&payload.watch_model)
    .bind(&payload.watch_os_version)
    .fetch_one(&state.pool)
    .await?;

    Ok(Json(DeviceResponse { device_id: row.0 }))
}
