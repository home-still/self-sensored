# Apple Health Source — System Architecture

## 1. Overview

Apple Health Source extracts HealthKit data from an iPhone, syncs it over HTTPS to a Rust API, and stores it in TimescaleDB for personal health analytics. The sync protocol uses content hashing for idempotency — successive re-syncs skip unchanged data entirely.

```
┌──────────────────┐        HTTPS         ┌─────────────────────┐        HTTP         ┌──────────────────┐
│  iPhone / Watch  │ ──────────────────► │  two (.102)          │ ──────────────────► │  one (.101)      │
│  Self Sensored App  │  Cloudflare domain  │  Cloudflare Tunnel   │  LAN reverse proxy  │  Docker: Rust    │
│  Swift 6 / HK   │ ◄────────────────── │  + nginx             │ ◄────────────────── │  Axum API :3000  │
└──────────────────┘                     └─────────────────────┘                     └────────┬─────────┘
                                                                                              │ TCP 5432
                                                                                              ▼
                                                                                     ┌──────────────────┐
                                                                                     │  four (.104)     │
                                                                                     │  Postgres 17.7   │
                                                                                     │  TimescaleDB     │
                                                                                     │  339 GB NVMe     │
                                                                                     └──────────────────┘
```

**Traffic flow:** iPhone connects to a Cloudflare-issued public domain over HTTPS. The Cloudflare tunnel on `two` terminates TLS and forwards to nginx on `one` (LAN). nginx reverse-proxies to the Docker container running the Rust API on `localhost:3000`. The API connects to Postgres+TimescaleDB on `four` over LAN.

---

## 2. Components

| Component | Host | Technology | Role |
|-----------|------|-----------|------|
| **iOS App** | iPhone | Swift 6, SwiftUI, HealthKit, CryptoKit | Read health data, compute content hashes, push to API |
| **API Server** | one (192.168.1.101) | Rust (axum 0.8, tokio, sqlx 0.8) | Auth, hash-check, sync ingestion, device registry |
| **Database** | four (192.168.1.104) | Postgres 17.7 + TimescaleDB 2.26.1 | Hypertable storage, compression, continuous aggregates |
| **Gateway** | two (192.168.1.102) | Cloudflare tunnel + nginx | TLS termination, external HTTPS access |
| **Reverse Proxy** | one (192.168.1.101) | nginx | Route traffic to Docker container |

---

## 3. Database Design

### 3.1 Why One Wide Hypertable

All quantity and category HealthKit samples share the same temporal structure (`start_date`, `end_date`) and the same polymorphic value columns (`quantity_value`/`quantity_unit` for numbers, `category_value` for enums). Rather than creating 100+ tables for 100+ metric types:

- **One `health_samples` hypertable** with a `sample_type` discriminator column
- TimescaleDB partitions on `start_date` (1-month chunks)
- `compress_segmentby = 'user_id, sample_type'` gives per-metric compression
- Queries like "everything from last week" work without `UNION ALL` across tables
- Adding new HealthKit types requires zero schema changes

**Separate tables remain for:** workouts (activity-specific columns), route points (high-cardinality GPS, own hypertable), activity summaries (daily granularity), user characteristics (static, non-temporal), devices, and sync sessions.

### 3.2 Tables

**`users`** — Authentication accounts.

| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | `gen_random_uuid()` |
| email | TEXT UNIQUE | NOT NULL |
| password_hash | TEXT | Argon2, NOT NULL |
| created_at | TIMESTAMPTZ | DEFAULT NOW() |

**`devices`** — Registry of syncing devices. Updated on each app launch.

| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | `gen_random_uuid()` |
| user_id | UUID FK → users | NOT NULL |
| identifier_for_vendor | TEXT | iOS `identifierForVendor`, stable per-device |
| device_name | TEXT | e.g., "Thomas' Phone" |
| device_model | TEXT | e.g., "iPhone17,4" |
| system_name | TEXT | "iOS" or "watchOS" |
| system_version | TEXT | e.g., "18.4.1" |
| app_version | TEXT | e.g., "0.1.0" |
| watch_model | TEXT | nullable, paired Watch |
| watch_os_version | TEXT | nullable |
| first_seen | TIMESTAMPTZ | DEFAULT NOW() |
| last_seen | TIMESTAMPTZ | DEFAULT NOW() |
| | | UNIQUE(user_id, identifier_for_vendor) |

**`sync_sessions`** — One row per sync attempt. Tracks what happened.

| Column | Type | Notes |
|--------|------|-------|
| id | BIGSERIAL PK | |
| user_id | UUID FK → users | NOT NULL |
| device_id | UUID FK → devices | NOT NULL |
| sample_type | TEXT | nullable (NULL = multi-type) |
| client_ip | TEXT | nullable, from X-Forwarded-For |
| latitude | FLOAT8 | nullable, device location at sync time |
| longitude | FLOAT8 | nullable |
| samples_sent | INT | how many the client sent |
| samples_accepted | INT | how many were upserted |
| samples_skipped | INT | hash matched, no write needed |
| deletions | INT | |
| duration_ms | FLOAT8 | nullable, round-trip |
| status | TEXT | pending / completed / failed |
| error_message | TEXT | nullable |
| started_at | TIMESTAMPTZ | DEFAULT NOW() |
| completed_at | TIMESTAMPTZ | nullable |

**`health_samples`** — TimescaleDB hypertable. All quantity and category samples.

| Column | Type | Notes |
|--------|------|-------|
| start_date | TIMESTAMPTZ | **Hypertable partition key**, NOT NULL |
| user_id | UUID FK → users | NOT NULL |
| hk_uuid | TEXT | HealthKit sample UUID, NOT NULL |
| sample_type | TEXT | e.g., "HKQuantityTypeIdentifierStepCount", NOT NULL |
| content_hash | TEXT | SHA-256 of canonical payload, NOT NULL |
| source_name | TEXT | nullable, e.g., "Apple Watch" |
| source_bundle_id | TEXT | nullable, e.g., "com.apple.health" |
| source_device_id | UUID FK → devices | nullable |
| end_date | TIMESTAMPTZ | NOT NULL |
| quantity_value | FLOAT8 | nullable, for quantity types |
| quantity_unit | TEXT | nullable, e.g., "count", "bpm", "kcal" |
| category_value | INT | nullable, for category types |
| correlation_id | UUID | nullable, groups BP systolic+diastolic pairs |
| metadata | JSONB | nullable, HealthKit metadata dict |
| sync_session_id | BIGINT FK → sync_sessions | nullable |
| synced_at | TIMESTAMPTZ | DEFAULT NOW() |
| | | UNIQUE(user_id, hk_uuid, start_date) |

**Chunk interval:** 1 month. **Compression after:** 30 days. **Segment by:** `user_id, sample_type`. **Order by:** `start_date DESC`.

**`workouts`** — TimescaleDB hypertable. Structured workout records.

| Column | Type | Notes |
|--------|------|-------|
| start_date | TIMESTAMPTZ | **Hypertable partition key**, NOT NULL |
| user_id | UUID FK → users | NOT NULL |
| hk_uuid | TEXT | NOT NULL |
| content_hash | TEXT | NOT NULL |
| activity_type | INT | HKWorkoutActivityType raw value, NOT NULL |
| activity_name | TEXT | nullable, human-readable |
| duration_seconds | FLOAT8 | nullable |
| total_energy_burned_kcal | FLOAT8 | nullable |
| total_distance_m | FLOAT8 | nullable |
| total_swimming_stroke_count | FLOAT8 | nullable |
| end_date | TIMESTAMPTZ | NOT NULL |
| source_device_id | UUID FK → devices | nullable |
| metadata | JSONB | nullable |
| sync_session_id | BIGINT FK → sync_sessions | nullable |
| synced_at | TIMESTAMPTZ | DEFAULT NOW() |
| | | UNIQUE(user_id, hk_uuid, start_date) |

**Chunk interval:** 3 months.

**`workout_route_points`** — TimescaleDB hypertable. GPS data for workouts.

| Column | Type | Notes |
|--------|------|-------|
| timestamp | TIMESTAMPTZ | **Hypertable partition key**, NOT NULL |
| user_id | UUID FK → users | NOT NULL |
| workout_hk_uuid | TEXT | References workout by hk_uuid (no FK — hypertable limitation) |
| latitude | FLOAT8 | NOT NULL |
| longitude | FLOAT8 | NOT NULL |
| altitude | FLOAT8 | nullable |
| horizontal_accuracy | FLOAT8 | nullable |
| vertical_accuracy | FLOAT8 | nullable |
| speed | FLOAT8 | nullable, m/s |
| course | FLOAT8 | nullable, 0-360 degrees |

**Chunk interval:** 1 month. **Compression after:** 30 days.

**`activity_summaries`** — Daily Apple Watch ring data.

| Column | Type | Notes |
|--------|------|-------|
| date | DATE | NOT NULL |
| user_id | UUID FK → users | NOT NULL |
| content_hash | TEXT | NOT NULL |
| active_energy_burned | FLOAT8 | nullable, kcal |
| active_energy_burned_goal | FLOAT8 | nullable |
| apple_exercise_time | FLOAT8 | nullable, minutes |
| apple_exercise_time_goal | FLOAT8 | nullable |
| apple_stand_hours | INT | nullable, 0-24 |
| apple_stand_hours_goal | INT | nullable |
| apple_move_time | INT | nullable, iOS 17+ |
| apple_move_time_goal | INT | nullable |
| synced_at | TIMESTAMPTZ | DEFAULT NOW() |
| | | UNIQUE(user_id, date) |

**`user_characteristics`** — Static profile data. One row per user.

| Column | Type | Notes |
|--------|------|-------|
| user_id | UUID PK FK → users | |
| biological_sex | TEXT | nullable (female, male, other) |
| date_of_birth | DATE | nullable |
| blood_type | TEXT | nullable |
| fitzpatrick_skin_type | TEXT | nullable |
| wheelchair_use | BOOLEAN | nullable |
| activity_move_mode | TEXT | nullable (activeEnergy, appleMoveTime) |
| content_hash | TEXT | NOT NULL |
| updated_at | TIMESTAMPTZ | DEFAULT NOW() |

### 3.3 Indexes

```sql
-- health_samples
CREATE INDEX idx_samples_user_type_date ON health_samples (user_id, sample_type, start_date DESC);
CREATE INDEX idx_samples_hash_check    ON health_samples (user_id, hk_uuid, content_hash);

-- workouts
CREATE INDEX idx_workouts_user_date    ON workouts (user_id, start_date DESC);
CREATE INDEX idx_workouts_hash_check   ON workouts (user_id, hk_uuid, content_hash);

-- workout_route_points
CREATE INDEX idx_routes_workout        ON workout_route_points (user_id, workout_hk_uuid, timestamp);

-- sync_sessions
CREATE INDEX idx_sessions_user_time    ON sync_sessions (user_id, started_at DESC);
```

### 3.4 TimescaleDB Continuous Aggregates

Pre-computed rollups for dashboard queries:

```sql
-- Daily step totals
CREATE MATERIALIZED VIEW daily_steps WITH (timescaledb.continuous) AS
SELECT user_id, time_bucket('1 day', start_date) AS day,
       SUM(quantity_value) AS total, COUNT(*) AS samples
FROM health_samples WHERE sample_type = 'HKQuantityTypeIdentifierStepCount'
GROUP BY user_id, time_bucket('1 day', start_date);

-- Hourly heart rate stats
CREATE MATERIALIZED VIEW hourly_heart_rate WITH (timescaledb.continuous) AS
SELECT user_id, time_bucket('1 hour', start_date) AS hour,
       AVG(quantity_value) AS avg_bpm, MIN(quantity_value) AS min_bpm,
       MAX(quantity_value) AS max_bpm, COUNT(*) AS samples
FROM health_samples WHERE sample_type = 'HKQuantityTypeIdentifierHeartRate'
GROUP BY user_id, time_bucket('1 hour', start_date);
```

---

## 4. Sync Protocol

### 4.1 Content Hash Computation (iOS)

Each sample's hash is computed deterministically from its semantic content using CryptoKit SHA-256:

```
hash = SHA-256(sample_type | start_date_iso8601 | end_date_iso8601 | quantity_value | quantity_unit | category_value | sorted_metadata_keys_values)
```

Fields are pipe-delimited. Metadata keys are sorted alphabetically for determinism. The same HealthKit data always produces the same hash regardless of when it's computed.

### 4.2 Two-Phase Sync Flow

**Phase A — Hash Check**

```
iOS                              API                              DB
 │                                │                                │
 │  POST /api/v1/health/check     │                                │
 │  { sample_type: "stepCount",   │                                │
 │    items: [                    │                                │
 │      {hk_uuid, content_hash}, │                                │
 │      ...                       │                                │
 │    ] }                         │                                │
 │ ──────────────────────────────►│                                │
 │                                │  SELECT hk_uuid, content_hash  │
 │                                │  FROM health_samples            │
 │                                │  WHERE user_id = $1             │
 │                                │    AND hk_uuid = ANY($2)       │
 │                                │ ──────────────────────────────►│
 │                                │                                │
 │                                │  Compare: missing → needed     │
 │                                │  Compare: hash differs → needed│
 │                                │  Compare: hash matches → skip  │
 │                                │                                │
 │  { needed_uuids: [...],       │                                │
 │    session_id: 42 }           │                                │
 │◄──────────────────────────────│                                │
```

**Phase B — Filtered Push (only if needed_uuids is non-empty)**

```
iOS                              API                              DB
 │                                │                                │
 │  POST /api/v1/health/sync      │                                │
 │  { session_id: 42,             │                                │
 │    samples: [only needed ones],│                                │
 │    location: {lat, lon} }      │                                │
 │ ──────────────────────────────►│                                │
 │                                │  BEGIN                         │
 │                                │  UPSERT health_samples          │
 │                                │  UPDATE sync_sessions           │
 │                                │  COMMIT                         │
 │                                │ ──────────────────────────────►│
 │                                │                                │
 │  { samples_synced: N }         │                                │
 │◄──────────────────────────────│                                │
```

### 4.3 Re-sync Behavior

| Scenario | What happens |
|----------|-------------|
| **First sync** (no anchor) | All samples are new. All hashes sent to `/check`, all come back as needed. Full push. |
| **Incremental sync** (anchor exists) | Only delta from HKAnchoredObjectQuery. Small hash check, small push. |
| **Full re-sync** (anchor reset) | All 100K+ samples hashed. `/check` compares hashes. Only truly changed data gets pushed. ~3MB hash pairs vs ~50MB full payloads. |

### 4.4 Per-Metric Parallelism

Each sample type syncs independently. The iOS app runs them concurrently:

```swift
await withTaskGroup(of: Void.self) { group in
    for sampleType in HKTypes.allSampleTypes {
        group.addTask { await self.syncType(sampleType) }
    }
}
```

Each `syncType` does its own `/check` → `/sync` pair. Failure in one type doesn't block others.

---

## 5. API Endpoints

### Authentication

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/auth/register` | None | Create account → JWT |
| `POST` | `/auth/login` | None | Authenticate → JWT |

### Device Registration

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/api/v1/devices/register` | JWT | Upsert device metadata → `device_id` |

Request:
```json
{
    "identifier_for_vendor": "A1B2C3D4-...",
    "device_name": "Thomas' Phone",
    "device_model": "iPhone17,4",
    "system_name": "iOS",
    "system_version": "18.4.1",
    "app_version": "0.1.0",
    "watch_model": "Apple Watch Series 10",
    "watch_os_version": "11.4"
}
```

### Health Sync

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/api/v1/health/check` | JWT | Compare content hashes → needed UUIDs |
| `POST` | `/api/v1/health/sync` | JWT | Upsert only needed samples |
| `POST` | `/api/v1/health/delete` | JWT | Process HealthKit deletion notifications |
| `POST` | `/api/v1/health/characteristics` | JWT | Upsert user characteristics |
| `POST` | `/api/v1/health/activity-summaries` | JWT | Upsert daily ring data |
| `POST` | `/api/v1/health/workout-routes` | JWT | Bulk insert GPS route points |
| `GET` | `/health` | None | Health check |

### Hash Check Request/Response

```json
// POST /api/v1/health/check
{
    "device_id": "uuid",
    "sample_type": "HKQuantityTypeIdentifierStepCount",
    "items": [
        { "hk_uuid": "abc-123", "content_hash": "e3b0c44298fc..." },
        { "hk_uuid": "def-456", "content_hash": "d7a8fbb307d7..." }
    ]
}

// Response
{
    "needed_uuids": ["abc-123"],
    "session_id": 42
}
```

### Sync Request/Response

```json
// POST /api/v1/health/sync
{
    "session_id": 42,
    "device_id": "uuid",
    "sample_type": "HKQuantityTypeIdentifierStepCount",
    "samples": [
        {
            "hk_uuid": "abc-123",
            "content_hash": "e3b0c44298fc...",
            "sample_type": "HKQuantityTypeIdentifierStepCount",
            "start_date": "2026-04-10T08:00:00Z",
            "end_date": "2026-04-10T09:00:00Z",
            "quantity_value": 1234.0,
            "quantity_unit": "count",
            "source_name": "Apple Watch",
            "source_bundle_id": "com.apple.health",
            "metadata": {}
        }
    ],
    "location": { "latitude": 32.7767, "longitude": -96.7970 }
}

// Response
{ "samples_synced": 1, "workouts_synced": 0, "session_id": 42 }
```

---

## 6. Device & Context Metadata

### What We Collect

| Data Point | Source | Where Stored |
|------------|--------|-------------|
| Device name | `UIDevice.current.name` | devices.device_name |
| Device model | `UIDevice.current.model` + sysctlbyname | devices.device_model |
| iOS version | `UIDevice.current.systemVersion` | devices.system_version |
| App version | `Bundle.main.infoDictionary` | devices.app_version |
| Device ID | `UIDevice.identifierForVendor` | devices.identifier_for_vendor |
| Watch model | `WCSession.defaultSession` (if paired) | devices.watch_model |
| WatchOS version | `WCSession` | devices.watch_os_version |
| Client IP | `X-Forwarded-For` header (set by nginx) | sync_sessions.client_ip |
| Geolocation | `CoreLocation` at sync time | sync_sessions.latitude/longitude |
| Per-sample source | `HKSample.sourceRevision.source.name` | health_samples.source_name |
| Per-sample device | `HKSample.device` properties | linked via source_device_id |

### What We Don't Collect (and Why)

| Data Point | Reason |
|------------|--------|
| MAC address | iOS randomizes Wi-Fi MAC since iOS 14, no API to read real MAC |
| Outside temperature | Requires third-party weather API; deferred. Lat/lon stored for future backfill |
| UDID | Deprecated, not accessible to apps |

---

## 7. Supported HealthKit Data Types

### Quantity Types (100+)

All stored in `health_samples` with `quantity_value` + `quantity_unit`.

| Category | Types |
|----------|-------|
| **Body** | bodyMass, bodyMassIndex, bodyFatPercentage, height, leanBodyMass, waistCircumference |
| **Fitness** | stepCount, distanceWalkingRunning, distanceCycling, distanceSwimming, distanceWheelchair, distanceDownhillSnowSports, pushCount, swimmingStrokeCount |
| **Running** | runningSpeed, runningPower, runningStrideLength, runningVerticalOscillation, runningGroundContactTime |
| **Cycling** | cyclingSpeed, cyclingPower, cyclingCadence, cyclingFunctionalThresholdPower |
| **Activity** | basalEnergyBurned, activeEnergyBurned, flightsClimbed, appleExerciseTime, appleMoveTime, appleStandTime, physicalEffort, estimatedWorkoutEffortScore, underwaterDepth |
| **Vitals** | heartRate, restingHeartRate, walkingHeartRateAverage, heartRateVariabilitySDNN, heartRateRecoveryOneMinute, oxygenSaturation, bodyTemperature, basalBodyTemperature, bloodPressureSystolic, bloodPressureDiastolic, respiratoryRate |
| **Lab** | bloodGlucose, electrodermalActivity, forcedExpiratoryVolume1, forcedVitalCapacity, inhalerUsage, insulinDelivery, peakExpiratoryFlowRate, numberOfTimesFallen |
| **Nutrition** (38 types) | dietaryEnergyConsumed, dietaryProtein, dietaryCarbohydrates, dietaryFatTotal, dietaryFiber, dietarySugar, dietaryCaffeine, dietaryWater, dietaryFatSaturated, dietaryFatMonounsaturated, dietaryFatPolyunsaturated, dietaryCholesterol, dietarySodium, dietaryPotassium, dietaryCalcium, dietaryIron, dietaryVitaminA/B6/B12/C/D/E/K, dietaryFolate, dietaryNiacin, dietaryRiboflavin, dietaryThiamin, dietaryPantothenicAcid, dietaryPhosphorus, dietaryMagnesium, dietaryManganese, dietaryZinc, dietaryCopper, dietaryChromium, dietaryIodine, dietaryMolybdenum, dietaryBiotin, dietaryChloride |
| **Audio** | environmentalAudioExposure, environmentalSoundReduction, headphoneAudioExposure |
| **UV** | uvExposure |

### Category Types (15+)

All stored in `health_samples` with `category_value` (integer enum).

| Type | Values |
|------|--------|
| sleepAnalysis | inBed(0), asleepUnspecified(1), asleepCore(2), asleepDeep(3), asleepREM(4), awake(5) |
| appleStandHour | idle(0), stood(1) |
| menstrualFlow | unspecified(1), light(2), medium(3), heavy(4), none(5) |
| ovulationTestResult | negative(1), lhSurge(2), estrogenSurge(3), indeterminate(4) |
| cervicalMucusQuality | dry(1), sticky(2), creamy(3), watery(4), eggWhite(5) |
| intermenstrualBleeding | presence-only |
| sexualActivity | presence-only |
| mindfulSession | presence-only (duration = end - start) |
| highHeartRateEvent | presence-only |
| lowHeartRateEvent | presence-only |
| irregularHeartRhythmEvent | presence-only |
| pregnancyTestResult | negative(1), positive(2), indeterminate(3) |
| progesteroneTestResult | negative(1), positive(2), indeterminate(3) |
| lowCardioFitnessEvent | presence-only |
| appleWalkingSteadinessEvent | presence-only |

### Composite Types

| Type | Table | Notes |
|------|-------|-------|
| Workouts | `workouts` | 80+ activity types, optional energy/distance/duration |
| Workout Routes | `workout_route_points` | GPS lat/lon/alt/speed/course series |
| Activity Summaries | `activity_summaries` | Daily move/exercise/stand ring data |
| Blood Pressure | `health_samples` | Systolic + diastolic paired via `correlation_id` |
| Characteristics | `user_characteristics` | Static: sex, DOB, blood type, skin type, wheelchair, move mode |

### Future Types (iOS 18+)

| Type | Notes | Status |
|------|-------|--------|
| Medications | Per-object auth, name/dosage/frequency | Deferred (needs dedicated table) |
| State of Mind | Mood labels + category value | Deferred |
| Ground Reaction Force | Running biomechanics | Deferred |
| ECG | Classification only (raw waveform restricted) | Deferred |
| Vision Prescriptions | Static optical data | Deferred |

---

## 8. Deployment

### Docker on one

```dockerfile
FROM rust:1.94-bookworm AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY api/ api/
RUN cargo build --release -p self-sensored-api

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/self-sensored-api /usr/local/bin/
EXPOSE 3000
CMD ["self-sensored-api"]
```

Cross-compilation from Mac (ARM64 → ARM64, same arch) or build directly on the Pi. The Docker image runs on `one` behind nginx.

### nginx on one

```nginx
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 50M;
        proxy_read_timeout 120s;
    }
}
```

### Cloudflare Tunnel on two

Add ingress rule in `/etc/cloudflared/config.yml`:

```yaml
ingress:
  - hostname: health.yourdomain.com
    service: http://192.168.1.101:80
```

### Database on four

Postgres already configured to accept LAN connections. Needs:

```
# pg_hba.conf — allow API on one
host self_sensored self_sensored 192.168.1.101/32 scram-sha-256
```

---

## 9. Implementation Phases

### Phase 1: Documentation (this step)
Write ARCHITECTURE.md and ERD.md. No code changes.

### Phase 2: Database Schema
New migrations for: devices, sync_sessions, content_hash columns, hypertable conversion, compression policies. Run against four.

### Phase 3: API — Device Registration + Hash Check
New endpoints: `POST /devices/register`, `POST /health/check`. New models for device, sync session, hash check.

### Phase 4: API — Redesigned Sync
Rewrite sync handler for two-phase protocol with session tracking, per-metric payloads, batch inserts.

### Phase 5: iOS — Hashing + Device Registration
Add CryptoKit SHA-256 hashing, device info collection, two-phase sync in SyncEngine.

### Phase 6: iOS — Expand Data Types
Add all 100+ quantity types, all category types, characteristics reader, activity summary reader, workout route reader, blood pressure correlation handling.

### Phase 7: Deployment
Docker + nginx on one, Cloudflare tunnel config on two, iOS app pointed to public domain.

### Phase 8: Hardening
Rate limiting, compression, structured logging, retry with backoff, continuous aggregates, data retention policies.
