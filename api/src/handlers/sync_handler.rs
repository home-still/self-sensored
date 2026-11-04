use axum::Json;
use axum::extract::State;
use chrono::{DateTime, Utc};
use sqlx::PgPool;
use std::collections::HashMap;
use uuid::Uuid;

use crate::auth::Claims;
use crate::error::AppError;
use crate::handlers::auth_handler::AppState;
use crate::models::{
    DeleteRequest, HashCheckRequest, HashCheckResponse, SyncPayload, SyncResponse,
    WorkoutRoutePayload,
};

/// RAII guard that marks a `sync_sessions` row as `failed` if the handler
/// returns before reaching the success path. Any `?` between session creation
/// and `disarm()` will trip this on Drop, so a row can never be left
/// `pending` by an unhandled error.
struct SessionGuard {
    pool: PgPool,
    session_id: i64,
    finalized: bool,
}

impl SessionGuard {
    fn new(pool: &PgPool, session_id: i64) -> Self {
        Self {
            pool: pool.clone(),
            session_id,
            finalized: false,
        }
    }

    fn disarm(&mut self) {
        self.finalized = true;
    }
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        if self.finalized {
            return;
        }
        let pool = self.pool.clone();
        let id = self.session_id;
        // The handler is on the tokio runtime; spawn a detached UPDATE so
        // failure-finalization happens even when we're unwinding from `?`.
        // The `WHERE status='pending'` clause makes it a no-op if some
        // other path already set a terminal state.
        tokio::spawn(async move {
            if let Err(e) = sqlx::query(
                r#"UPDATE sync_sessions
                      SET status = 'failed',
                          error_message = COALESCE(error_message, 'handler_error_pre_commit'),
                          completed_at = NOW()
                    WHERE id = $1 AND status = 'pending'"#,
            )
            .bind(id)
            .execute(&pool)
            .await
            {
                tracing::warn!(error = ?e, session_id = id,
                    "SessionGuard failed to finalize abandoned sync_session");
            }
        });
    }
}

/// POST /api/v1/health/check
pub async fn hash_check(
    State(state): State<std::sync::Arc<AppState>>,
    claims: Claims,
    Json(payload): Json<HashCheckRequest>,
) -> Result<Json<HashCheckResponse>, AppError> {
    let user_id = claims.sub;

    // Create sync session (skip raw_ingest for /check — payloads are huge and redundant)
    let session_row: (i64,) = sqlx::query_as(
        r#"INSERT INTO sync_sessions (user_id, device_id, sample_type, status)
           VALUES ($1, $2, $3, 'pending')
           RETURNING id"#,
    )
    .bind(user_id)
    .bind(payload.device_id)
    .bind(&payload.sample_type)
    .fetch_one(&state.pool)
    .await?;
    let session_id = session_row.0;

    // Bulk-fetch existing hashes in chunks to avoid Postgres OOM on large arrays
    let mut existing_map: HashMap<String, Option<String>> = HashMap::new();
    let all_uuids: Vec<&str> = payload.items.iter().map(|i| i.hk_uuid.as_str()).collect();

    for chunk in all_uuids.chunks(2000) {
        let chunk_vec: Vec<&str> = chunk.to_vec();
        // Sub-100ms PK probe against the manifest; the hypertable is no
        // longer on the hot read path for the sync protocol. hk_uuid is
        // globally unique so the sample_type filter is unnecessary.
        let rows: Vec<(String, String)> = sqlx::query_as(
            r#"SELECT hk_uuid, content_hash
               FROM health_sample_manifest
               WHERE user_id = $1 AND hk_uuid = ANY($2)"#,
        )
        .bind(user_id)
        .bind(&chunk_vec)
        .fetch_all(&state.pool)
        .await?;

        for (uuid, hash) in rows {
            existing_map.insert(uuid, Some(hash));
        }
    }

    let needed_uuids: Vec<String> = payload
        .items
        .iter()
        .filter(|item| match existing_map.get(&item.hk_uuid) {
            None => true,
            Some(server_hash) => server_hash.as_deref() != Some(item.content_hash.as_str()),
        })
        .map(|item| item.hk_uuid.clone())
        .collect();

    // Finalize the session here when no follow-up `/sync` is expected. If
    // there's nothing for the client to send, this row should reach a
    // terminal state immediately — otherwise the client correctly skips
    // `/sync`, leaving the row stuck in `pending` forever (the bug that
    // motivated this guard).
    if needed_uuids.is_empty() {
        sqlx::query(
            r#"UPDATE sync_sessions
                  SET status = 'completed',
                      samples_sent = 0,
                      samples_accepted = 0,
                      completed_at = NOW()
                WHERE id = $1"#,
        )
        .bind(session_id)
        .execute(&state.pool)
        .await?;
    }

    Ok(Json(HashCheckResponse {
        needed_uuids,
        session_id,
    }))
}

/// POST /api/v1/health/sync
///
/// Batch upsert using UNNEST for speed.
pub async fn sync(
    State(state): State<std::sync::Arc<AppState>>,
    claims: Claims,
    Json(payload): Json<SyncPayload>,
) -> Result<Json<SyncResponse>, AppError> {
    let user_id = claims.sub;

    // Record raw ingest
    let raw_body = serde_json::to_value(&payload)
        .map_err(|e| AppError::Internal(format!("serialise: {e}")))?;

    sqlx::query(
        r#"INSERT INTO raw_ingest (user_id, sync_session_id, endpoint, raw_body)
           VALUES ($1, $2, '/api/v1/health/sync', $3)"#,
    )
    .bind(user_id)
    .bind(payload.session_id)
    .bind(&raw_body)
    .execute(&state.pool)
    .await?;

    // Arm the failure-finalization guard. Any `?` between here and
    // `guard.disarm()` (after the success commit below) marks the session
    // 'failed' on Drop, so a row can never be left silently 'pending'.
    let mut guard = SessionGuard::new(&state.pool, payload.session_id);

    let mut tx = state.pool.begin().await?;
    let samples_synced = payload.samples.len();
    let workouts_synced = payload.workouts.len();

    // Record device liveness on every successful sync. `register_device`
    // only runs on first install, so without this `last_seen` would only
    // ever reflect the install time, not actual data flow. Inside the same
    // tx as the sample inserts so a rolled-back batch doesn't move it.
    sqlx::query(
        "UPDATE devices SET last_seen = NOW() WHERE id = $1 AND user_id = $2",
    )
    .bind(payload.device_id)
    .bind(user_id)
    .execute(&mut *tx)
    .await?;

    // Batch upsert health_samples using UNNEST
    if !payload.samples.is_empty() {
        let mut p_user_ids: Vec<Uuid> = Vec::with_capacity(samples_synced);
        let mut p_hk_uuids: Vec<String> = Vec::with_capacity(samples_synced);
        let mut p_sample_types: Vec<String> = Vec::with_capacity(samples_synced);
        let mut p_content_hashes: Vec<String> = Vec::with_capacity(samples_synced);
        let mut p_source_names: Vec<Option<String>> = Vec::with_capacity(samples_synced);
        let mut p_source_bundle_ids: Vec<Option<String>> = Vec::with_capacity(samples_synced);
        let mut p_source_device_ids: Vec<Option<Uuid>> = Vec::with_capacity(samples_synced);
        let mut p_start_dates: Vec<DateTime<Utc>> = Vec::with_capacity(samples_synced);
        let mut p_end_dates: Vec<DateTime<Utc>> = Vec::with_capacity(samples_synced);
        let mut p_quantity_values: Vec<Option<f64>> = Vec::with_capacity(samples_synced);
        let mut p_quantity_units: Vec<Option<String>> = Vec::with_capacity(samples_synced);
        let mut p_category_values: Vec<Option<i32>> = Vec::with_capacity(samples_synced);
        let mut p_correlation_ids: Vec<Option<Uuid>> = Vec::with_capacity(samples_synced);
        let mut p_metadatas: Vec<Option<serde_json::Value>> = Vec::with_capacity(samples_synced);
        let mut p_session_ids: Vec<i64> = Vec::with_capacity(samples_synced);

        for s in &payload.samples {
            p_user_ids.push(user_id);
            p_hk_uuids.push(s.hk_uuid.clone());
            p_sample_types.push(s.sample_type.clone());
            p_content_hashes.push(s.content_hash.clone().unwrap_or_default());
            p_source_names.push(s.source_name.clone());
            p_source_bundle_ids.push(s.source_bundle_id.clone());
            p_source_device_ids.push(s.source_device_id);
            p_start_dates.push(s.start_date);
            p_end_dates.push(s.end_date);
            p_quantity_values.push(s.quantity_value);
            p_quantity_units.push(s.quantity_unit.clone());
            p_category_values.push(s.category_value);
            p_correlation_ids.push(s.correlation_id);
            p_metadatas.push(s.metadata.clone());
            p_session_ids.push(payload.session_id);
        }

        sqlx::query(
            r#"INSERT INTO health_samples
               (user_id, hk_uuid, sample_type, content_hash,
                source_name, source_bundle_id, source_device_id,
                start_date, end_date,
                quantity_value, quantity_unit, category_value,
                correlation_id, metadata, sync_session_id, synced_at)
               SELECT * FROM UNNEST(
                 $1::uuid[], $2::text[], $3::text[], $4::text[],
                 $5::text[], $6::text[], $7::uuid[],
                 $8::timestamptz[], $9::timestamptz[],
                 $10::float8[], $11::text[], $12::int4[],
                 $13::uuid[], $14::jsonb[], $15::int8[]
               ), NOW()
               ON CONFLICT (user_id, hk_uuid, start_date) DO UPDATE SET
                 content_hash     = EXCLUDED.content_hash,
                 source_name      = EXCLUDED.source_name,
                 source_bundle_id = EXCLUDED.source_bundle_id,
                 source_device_id = EXCLUDED.source_device_id,
                 end_date         = EXCLUDED.end_date,
                 quantity_value   = EXCLUDED.quantity_value,
                 quantity_unit    = EXCLUDED.quantity_unit,
                 category_value   = EXCLUDED.category_value,
                 correlation_id   = EXCLUDED.correlation_id,
                 metadata         = EXCLUDED.metadata,
                 sync_session_id  = EXCLUDED.sync_session_id,
                 synced_at        = NOW()"#,
        )
        .bind(&p_user_ids)
        .bind(&p_hk_uuids)
        .bind(&p_sample_types)
        .bind(&p_content_hashes)
        .bind(&p_source_names)
        .bind(&p_source_bundle_ids)
        .bind(&p_source_device_ids)
        .bind(&p_start_dates)
        .bind(&p_end_dates)
        .bind(&p_quantity_values)
        .bind(&p_quantity_units)
        .bind(&p_category_values)
        .bind(&p_correlation_ids)
        .bind(&p_metadatas)
        .bind(&p_session_ids)
        .execute(&mut *tx)
        .await?;

        // Mirror into the /check sidecar. Reuses the already-built parallel
        // vectors so this is zero extra allocations — just one round-trip to
        // PG inside the same tx so the manifest can't drift from the
        // hypertable under normal operation.
        sqlx::query(
            r#"INSERT INTO health_sample_manifest
               (user_id, hk_uuid, sample_type, content_hash, updated_at)
               SELECT * FROM UNNEST(
                 $1::uuid[], $2::text[], $3::text[], $4::text[]
               ), NOW()
               ON CONFLICT (user_id, hk_uuid) DO UPDATE SET
                 sample_type  = EXCLUDED.sample_type,
                 content_hash = EXCLUDED.content_hash,
                 updated_at   = NOW()"#,
        )
        .bind(&p_user_ids)
        .bind(&p_hk_uuids)
        .bind(&p_sample_types)
        .bind(&p_content_hashes)
        .execute(&mut *tx)
        .await?;
    }

    // Batch upsert workouts using UNNEST
    if !payload.workouts.is_empty() {
        let n = payload.workouts.len();
        let mut p_user_ids: Vec<Uuid> = Vec::with_capacity(n);
        let mut p_hk_uuids: Vec<String> = Vec::with_capacity(n);
        let mut p_content_hashes: Vec<String> = Vec::with_capacity(n);
        let mut p_activity_types: Vec<i32> = Vec::with_capacity(n);
        let mut p_activity_names: Vec<Option<String>> = Vec::with_capacity(n);
        let mut p_durations: Vec<Option<f64>> = Vec::with_capacity(n);
        let mut p_energy: Vec<Option<f64>> = Vec::with_capacity(n);
        let mut p_distance: Vec<Option<f64>> = Vec::with_capacity(n);
        let mut p_strokes: Vec<Option<i32>> = Vec::with_capacity(n);
        let mut p_start_dates: Vec<DateTime<Utc>> = Vec::with_capacity(n);
        let mut p_end_dates: Vec<DateTime<Utc>> = Vec::with_capacity(n);
        let mut p_device_ids: Vec<Option<Uuid>> = Vec::with_capacity(n);
        let mut p_metadatas: Vec<Option<serde_json::Value>> = Vec::with_capacity(n);
        let mut p_session_ids: Vec<i64> = Vec::with_capacity(n);

        for w in &payload.workouts {
            p_user_ids.push(user_id);
            p_hk_uuids.push(w.hk_uuid.clone());
            p_content_hashes.push(w.content_hash.clone().unwrap_or_default());
            p_activity_types.push(w.activity_type);
            p_activity_names.push(w.activity_name.clone());
            p_durations.push(w.duration_seconds);
            p_energy.push(w.total_energy_burned_kcal);
            p_distance.push(w.total_distance_m);
            p_strokes.push(w.total_swimming_stroke_count);
            p_start_dates.push(w.start_date);
            p_end_dates.push(w.end_date);
            p_device_ids.push(w.source_device_id);
            p_metadatas.push(w.metadata.clone());
            p_session_ids.push(payload.session_id);
        }

        sqlx::query(
            r#"INSERT INTO workouts
               (user_id, hk_uuid, content_hash, activity_type, activity_name,
                duration_seconds, total_energy_burned_kcal, total_distance_m,
                total_swimming_stroke_count,
                start_date, end_date, source_device_id,
                metadata, sync_session_id, synced_at)
               SELECT * FROM UNNEST(
                 $1::uuid[], $2::text[], $3::text[], $4::int4[], $5::text[],
                 $6::float8[], $7::float8[], $8::float8[], $9::int4[],
                 $10::timestamptz[], $11::timestamptz[], $12::uuid[],
                 $13::jsonb[], $14::int8[]
               ), NOW()
               ON CONFLICT (user_id, hk_uuid, start_date) DO UPDATE SET
                 content_hash                = EXCLUDED.content_hash,
                 activity_name               = EXCLUDED.activity_name,
                 duration_seconds            = EXCLUDED.duration_seconds,
                 total_energy_burned_kcal    = EXCLUDED.total_energy_burned_kcal,
                 total_distance_m            = EXCLUDED.total_distance_m,
                 total_swimming_stroke_count = EXCLUDED.total_swimming_stroke_count,
                 end_date                    = EXCLUDED.end_date,
                 source_device_id            = EXCLUDED.source_device_id,
                 metadata                    = EXCLUDED.metadata,
                 sync_session_id             = EXCLUDED.sync_session_id,
                 synced_at                   = NOW()"#,
        )
        .bind(&p_user_ids)
        .bind(&p_hk_uuids)
        .bind(&p_content_hashes)
        .bind(&p_activity_types)
        .bind(&p_activity_names)
        .bind(&p_durations)
        .bind(&p_energy)
        .bind(&p_distance)
        .bind(&p_strokes)
        .bind(&p_start_dates)
        .bind(&p_end_dates)
        .bind(&p_device_ids)
        .bind(&p_metadatas)
        .bind(&p_session_ids)
        .execute(&mut *tx)
        .await?;
    }

    // Update sync session. Deletions are reported as *requested* — the
    // actual DELETE runs after commit as a detached task (see below)
    // because a hypertable DELETE without a `start_date` predicate
    // scans every chunk and, with compression enabled, takes minutes.
    // Keeping it inside this transaction was orphaning /sync requests
    // at the iOS URLSession 120 s timeout.
    let deletions_requested = payload.deleted_uuids.len();
    let latitude = payload.location.as_ref().map(|l| l.latitude);
    let longitude = payload.location.as_ref().map(|l| l.longitude);

    sqlx::query(
        r#"UPDATE sync_sessions
           SET samples_sent = $2, samples_accepted = $2, deletions = $3,
               latitude = $4, longitude = $5, status = 'completed', completed_at = NOW()
           WHERE id = $1"#,
    )
    .bind(payload.session_id)
    .bind((samples_synced + workouts_synced) as i64)
    .bind(deletions_requested as i64)
    .bind(latitude)
    .bind(longitude)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    guard.disarm();

    // Detached deletion. HealthKit keeps re-reporting deletions until the
    // phone sees the sample gone from the server on next read, so losing a
    // spawned task on restart is self-healing — next /sync re-sends the
    // same `deleted_uuids`.
    if !payload.deleted_uuids.is_empty() {
        let pool = state.pool.clone();
        let sample_type = payload.sample_type.clone();
        let deleted_uuids = payload.deleted_uuids.clone();
        tokio::spawn(async move {
            let samples_result = sqlx::query(
                "DELETE FROM health_samples WHERE user_id = $1 AND sample_type = $2 AND hk_uuid = ANY($3)",
            )
            .bind(user_id)
            .bind(&sample_type)
            .bind(&deleted_uuids)
            .execute(&pool)
            .await;
            if let Err(e) = samples_result {
                tracing::warn!(error = ?e, user_id = ?user_id, sample_type = %sample_type,
                    "background DELETE on health_samples failed");
                return;
            }
            if let Err(e) = sqlx::query(
                "DELETE FROM health_sample_manifest WHERE user_id = $1 AND hk_uuid = ANY($2)",
            )
            .bind(user_id)
            .bind(&deleted_uuids)
            .execute(&pool)
            .await
            {
                tracing::warn!(error = ?e, user_id = ?user_id,
                    "background DELETE on health_sample_manifest failed");
            }
        });
    }

    Ok(Json(SyncResponse {
        samples_synced,
        workouts_synced,
        deleted: deletions_requested,
    }))
}

/// POST /api/v1/health/delete
///
/// Removes every server-side trace of the given HealthKit UUIDs for the
/// authenticated user: samples, workouts, and any workout route points keyed
/// by the same UUID. Wrapped in a transaction so a mid-delete failure leaves
/// nothing half-removed.
pub async fn delete(
    State(state): State<std::sync::Arc<AppState>>,
    claims: Claims,
    Json(payload): Json<DeleteRequest>,
) -> Result<Json<serde_json::Value>, AppError> {
    let user_id = claims.sub;

    let mut tx = state.pool.begin().await?;

    let samples =
        sqlx::query("DELETE FROM health_samples WHERE user_id = $1 AND hk_uuid = ANY($2)")
            .bind(user_id)
            .bind(&payload.hk_uuids)
            .execute(&mut *tx)
            .await?
            .rows_affected();

    sqlx::query(
        "DELETE FROM health_sample_manifest WHERE user_id = $1 AND hk_uuid = ANY($2)",
    )
    .bind(user_id)
    .bind(&payload.hk_uuids)
    .execute(&mut *tx)
    .await?;

    let route_points = sqlx::query(
        "DELETE FROM workout_route_points WHERE user_id = $1 AND workout_hk_uuid = ANY($2)",
    )
    .bind(user_id)
    .bind(&payload.hk_uuids)
    .execute(&mut *tx)
    .await?
    .rows_affected();

    let workouts = sqlx::query("DELETE FROM workouts WHERE user_id = $1 AND hk_uuid = ANY($2)")
        .bind(user_id)
        .bind(&payload.hk_uuids)
        .execute(&mut *tx)
        .await?
        .rows_affected();

    tx.commit().await?;

    Ok(Json(serde_json::json!({
        "deleted": samples + workouts + route_points,
        "samples_deleted": samples,
        "workouts_deleted": workouts,
        "route_points_deleted": route_points,
    })))
}

/// POST /api/v1/health/workout-routes
///
/// Full-replace the route points for a given workout. The caller must own the
/// workout — we gate on `workouts.user_id` so a malicious client cannot
/// create route points keyed to another user's `hk_uuid`. The DELETE+INSERT
/// pair runs in a single transaction so a mid-write failure can never leave
/// the workout with an empty route.
pub async fn sync_routes(
    State(state): State<std::sync::Arc<AppState>>,
    claims: Claims,
    Json(payload): Json<WorkoutRoutePayload>,
) -> Result<Json<serde_json::Value>, AppError> {
    let user_id = claims.sub;

    let (workout_exists,): (bool,) = sqlx::query_as(
        "SELECT EXISTS(SELECT 1 FROM workouts WHERE user_id = $1 AND hk_uuid = $2)",
    )
    .bind(user_id)
    .bind(&payload.workout_hk_uuid)
    .fetch_one(&state.pool)
    .await?;
    if !workout_exists {
        return Err(AppError::BadRequest("unknown workout".into()));
    }

    let mut tx = state.pool.begin().await?;

    sqlx::query("DELETE FROM workout_route_points WHERE user_id = $1 AND workout_hk_uuid = $2")
        .bind(user_id)
        .bind(&payload.workout_hk_uuid)
        .execute(&mut *tx)
        .await?;

    if payload.points.is_empty() {
        tx.commit().await?;
        return Ok(Json(serde_json::json!({ "points_synced": 0 })));
    }

    let n = payload.points.len();
    let mut p_timestamps: Vec<DateTime<Utc>> = Vec::with_capacity(n);
    let mut p_user_ids: Vec<Uuid> = Vec::with_capacity(n);
    let mut p_workout_uuids: Vec<String> = Vec::with_capacity(n);
    let mut p_latitudes: Vec<f64> = Vec::with_capacity(n);
    let mut p_longitudes: Vec<f64> = Vec::with_capacity(n);
    let mut p_altitudes: Vec<Option<f64>> = Vec::with_capacity(n);
    let mut p_h_acc: Vec<Option<f64>> = Vec::with_capacity(n);
    let mut p_v_acc: Vec<Option<f64>> = Vec::with_capacity(n);
    let mut p_speeds: Vec<Option<f64>> = Vec::with_capacity(n);
    let mut p_courses: Vec<Option<f64>> = Vec::with_capacity(n);

    for p in &payload.points {
        p_timestamps.push(p.timestamp);
        p_user_ids.push(user_id);
        p_workout_uuids.push(payload.workout_hk_uuid.clone());
        p_latitudes.push(p.latitude);
        p_longitudes.push(p.longitude);
        p_altitudes.push(p.altitude);
        p_h_acc.push(p.horizontal_accuracy);
        p_v_acc.push(p.vertical_accuracy);
        p_speeds.push(p.speed);
        p_courses.push(p.course);
    }

    sqlx::query(
        r#"INSERT INTO workout_route_points
           (timestamp, user_id, workout_hk_uuid, latitude, longitude,
            altitude, horizontal_accuracy, vertical_accuracy, speed, course)
           SELECT * FROM UNNEST(
             $1::timestamptz[], $2::uuid[], $3::text[], $4::float8[], $5::float8[],
             $6::float8[], $7::float8[], $8::float8[], $9::float8[], $10::float8[]
           )"#,
    )
    .bind(&p_timestamps)
    .bind(&p_user_ids)
    .bind(&p_workout_uuids)
    .bind(&p_latitudes)
    .bind(&p_longitudes)
    .bind(&p_altitudes)
    .bind(&p_h_acc)
    .bind(&p_v_acc)
    .bind(&p_speeds)
    .bind(&p_courses)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;

    Ok(Json(serde_json::json!({ "points_synced": n })))
}
