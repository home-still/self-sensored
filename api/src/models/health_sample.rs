use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// ---------- health_samples table ----------

#[derive(Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct HealthSample {
    pub hk_uuid: String,
    pub sample_type: String,
    pub content_hash: Option<String>,
    pub source_name: Option<String>,
    pub source_bundle_id: Option<String>,
    pub source_device_id: Option<Uuid>,
    pub start_date: DateTime<Utc>,
    pub end_date: DateTime<Utc>,
    pub quantity_value: Option<f64>,
    pub quantity_unit: Option<String>,
    pub category_value: Option<i32>,
    pub correlation_id: Option<Uuid>,
    pub metadata: Option<serde_json::Value>,
    pub sync_session_id: Option<i64>,
}

// ---------- workouts table ----------

#[derive(Debug, Serialize, Deserialize)]
pub struct Workout {
    pub hk_uuid: String,
    pub activity_type: i32,
    pub activity_name: Option<String>,
    pub duration_seconds: Option<f64>,
    pub total_energy_burned_kcal: Option<f64>,
    pub total_distance_m: Option<f64>,
    pub total_swimming_stroke_count: Option<i32>,
    pub content_hash: Option<String>,
    pub start_date: DateTime<Utc>,
    pub end_date: DateTime<Utc>,
    pub source_device_id: Option<Uuid>,
    pub metadata: Option<serde_json::Value>,
    pub sync_session_id: Option<i64>,
}

// ---------- sync payloads ----------

#[derive(Debug, Deserialize, Serialize)]
pub struct SyncPayload {
    pub session_id: i64,
    pub device_id: Uuid,
    pub sample_type: String,
    #[serde(default)]
    pub location: Option<Location>,
    #[serde(default)]
    pub samples: Vec<HealthSample>,
    #[serde(default)]
    pub workouts: Vec<Workout>,
    #[serde(default)]
    pub deleted_uuids: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct SyncResponse {
    pub samples_synced: usize,
    pub workouts_synced: usize,
    pub deleted: usize,
}

// ---------- auth ----------

#[derive(Debug, Serialize)]
pub struct AuthResponse {
    pub token: String,
    pub user_id: Uuid,
}

// ---------- hash check (dedup) ----------

#[derive(Debug, Deserialize, Serialize)]
pub struct HashCheckItem {
    pub hk_uuid: String,
    pub content_hash: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct HashCheckRequest {
    pub device_id: Uuid,
    pub sample_type: String,
    pub items: Vec<HashCheckItem>,
}

#[derive(Debug, Serialize)]
pub struct HashCheckResponse {
    pub needed_uuids: Vec<String>,
    pub session_id: i64,
}

// ---------- device registration ----------

#[derive(Debug, Deserialize, Serialize)]
pub struct DeviceRegistration {
    pub identifier_for_vendor: String,
    pub device_name: Option<String>,
    pub device_model: Option<String>,
    pub system_name: Option<String>,
    pub system_version: Option<String>,
    pub app_version: Option<String>,
    pub watch_model: Option<String>,
    pub watch_os_version: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct DeviceResponse {
    pub device_id: Uuid,
}

// ---------- location ----------

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Location {
    pub latitude: f64,
    pub longitude: f64,
}

// ---------- delete request ----------

#[derive(Debug, Deserialize)]
pub struct DeleteRequest {
    pub hk_uuids: Vec<String>,
}

// ---------- activity summaries ----------

// Populated from `activity_summaries` rows for future read endpoints.
#[allow(dead_code)]
#[derive(Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct ActivitySummary {
    pub date: NaiveDate,
    pub user_id: Uuid,
    pub content_hash: Option<String>,
    pub active_energy_burned: Option<f64>,
    pub active_energy_burned_goal: Option<f64>,
    pub apple_exercise_time: Option<f64>,
    pub apple_exercise_time_goal: Option<f64>,
    pub apple_stand_hours: Option<f64>,
    pub apple_stand_hours_goal: Option<f64>,
    pub apple_move_time: Option<f64>,
    pub apple_move_time_goal: Option<f64>,
    pub synced_at: Option<DateTime<Utc>>,
}

// ---------- user characteristics ----------

// Populated from `user_characteristics` rows for future read endpoints.
#[allow(dead_code)]
#[derive(Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct UserCharacteristics {
    pub user_id: Uuid,
    pub biological_sex: Option<String>,
    pub date_of_birth: Option<NaiveDate>,
    pub blood_type: Option<String>,
    pub fitzpatrick_skin_type: Option<String>,
    pub wheelchair_use: Option<String>,
    pub activity_move_mode: Option<String>,
    pub content_hash: Option<String>,
    pub updated_at: Option<DateTime<Utc>>,
}

// ---------- workout route points ----------

#[derive(Debug, Deserialize, Serialize)]
pub struct WorkoutRoutePayload {
    pub workout_hk_uuid: String,
    pub points: Vec<RoutePoint>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct RoutePoint {
    pub timestamp: DateTime<Utc>,
    pub latitude: f64,
    pub longitude: f64,
    pub altitude: Option<f64>,
    pub horizontal_accuracy: Option<f64>,
    pub vertical_accuracy: Option<f64>,
    pub speed: Option<f64>,
    pub course: Option<f64>,
}
