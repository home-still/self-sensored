# Self Sensored database schema

This is the read-only view of the Self Sensored Postgres/TimescaleDB schema exposed
through the `self-sensored-mcp` SQL tool.

- Every user-scoped table has a `user_id UUID` column that **must** be filtered
  with `WHERE user_id = $1`. The tool binds the authenticated user's UUID as
  `$1` automatically; additional parameters start at `$2`.
- Timestamps are `TIMESTAMPTZ` unless noted. Dates are `DATE`.
- Hypertable chunk intervals are listed; queries do not need to think about
  chunks but time-bounded `WHERE` clauses hit fewer of them and run faster.
- A single query is capped at `MCP_MAX_ROWS` and `MCP_STATEMENT_TIMEOUT_MS`.

## `public.users`
- `id UUID PRIMARY KEY`
- `email TEXT UNIQUE`
- `password_hash TEXT` — **blocked** by the MCP guard; any query naming this
  column is rejected with `forbidden_object`.
- `created_at TIMESTAMPTZ`

## `public.devices`
One row per (user, iOS vendor identifier).
- `id UUID PK`
- `user_id UUID` → users.id
- `identifier_for_vendor UUID`
- `device_name TEXT`, `device_model TEXT`
- `system_name TEXT`, `system_version TEXT`
- `app_version TEXT`
- `watch_model TEXT`, `watch_os_version TEXT`
- `first_seen TIMESTAMPTZ`, `last_seen TIMESTAMPTZ`

## `public.sync_sessions`
One row per sync request from the iOS app.
- `id BIGSERIAL PK`
- `user_id UUID`, `device_id UUID`
- `sample_type TEXT`
- `client_ip INET`, `latitude DOUBLE PRECISION`, `longitude DOUBLE PRECISION`
- `samples_sent INT`, `samples_accepted INT`, `samples_skipped INT`
- `status TEXT` (`"in_progress"`, `"completed"`, `"error"`)
- `error_message TEXT`
- `started_at TIMESTAMPTZ`, `completed_at TIMESTAMPTZ`

## `public.health_samples` *(TimescaleDB hypertable, 1-month chunks)*
The main time-series table — HealthKit quantity + category samples.
- `start_date TIMESTAMPTZ NOT NULL` (partition column)
- `end_date TIMESTAMPTZ NOT NULL`
- `user_id UUID` → users.id
- `hk_uuid TEXT`, `content_hash TEXT`
- `sample_type TEXT` — the HealthKit type identifier, e.g.
  - `HKQuantityTypeIdentifierStepCount`
  - `HKQuantityTypeIdentifierHeartRate`
  - `HKQuantityTypeIdentifierRestingHeartRate`
  - `HKQuantityTypeIdentifierHeartRateVariabilitySDNN`
  - `HKQuantityTypeIdentifierActiveEnergyBurned`
  - `HKQuantityTypeIdentifierDistanceWalkingRunning`
  - `HKQuantityTypeIdentifierBodyMass`
  - `HKQuantityTypeIdentifierBodyFatPercentage`
  - `HKCategoryTypeIdentifierSleepAnalysis` (uses `category_value`)
  - (~100 types in total)
- `quantity_value DOUBLE PRECISION` (for quantity types)
- `quantity_unit TEXT` (HealthKit unit string)
- `category_value INT` (for category types — sleep stage, etc.)
- `correlation_id UUID` (groups e.g. systolic/diastolic blood-pressure pairs)
- `source_name TEXT`, `source_bundle_id TEXT`, `source_device_id UUID`
- `metadata JSONB`
- `synced_at TIMESTAMPTZ`
- Compression: after 30 days, segmented by `(user_id, sample_type)`.
- Useful indexes: `(user_id, sample_type, start_date DESC)`.

## `public.workouts` *(hypertable, 3-month chunks)*
- `start_date TIMESTAMPTZ`, `end_date TIMESTAMPTZ`
- `user_id UUID`, `hk_uuid TEXT`, `content_hash TEXT`
- `activity_type INT` (HKWorkoutActivityType raw value)
- `activity_name TEXT`
- `duration_seconds DOUBLE PRECISION`
- `total_energy_burned_kcal DOUBLE PRECISION`
- `total_distance_m DOUBLE PRECISION`
- `total_swimming_stroke_count DOUBLE PRECISION`
- `metadata JSONB`, `source_device_id UUID`

## `public.workout_route_points` *(hypertable, 1-month chunks)*
- `timestamp TIMESTAMPTZ` (partition column)
- `user_id UUID`, `workout_id UUID`
- `latitude`, `longitude`, `altitude`, `speed`, `course` (all `DOUBLE PRECISION`)
- `horizontal_accuracy`, `vertical_accuracy`

## `public.user_characteristics`
One row per user.
- `user_id UUID PRIMARY KEY`
- `biological_sex TEXT`, `date_of_birth DATE`
- `blood_type TEXT`, `fitzpatrick_skin_type INT`
- `wheelchair_use BOOLEAN`
- `activity_move_mode TEXT`
- `content_hash TEXT`

## `public.activity_summaries`
One row per (user, day) — Apple's daily ring totals.
- `date DATE`, `user_id UUID`
- `active_energy_burned DOUBLE PRECISION`, `active_energy_burned_goal`
- `apple_exercise_time DOUBLE PRECISION`, `apple_exercise_time_goal`
- `apple_stand_hours INT`, `apple_stand_hours_goal INT`
- `apple_move_time INT`, `apple_move_time_goal INT`
- `synced_at TIMESTAMPTZ`

## `public.health_sample_manifest`
Fast-lookup table used by the sync `/check` phase.
- `user_id UUID`, `hk_uuid TEXT`, `sample_type TEXT`, `content_hash TEXT`,
  `updated_at TIMESTAMPTZ`
- Normally not interesting for analytics.

## `public.users_safe` *(view)*
Safe projection of `public.users` that excludes `password_hash`. Use this
view whenever you need user info — `public.users` itself is blocked by the
MCP guard.
- `id UUID`, `email TEXT`, `created_at TIMESTAMPTZ`

## `public.raw_ingest`
Raw sync payload archive. **Blocked by the MCP guard.** Contains the
unparsed JSON body of every sync request and may include sensitive data
that's already decomposed into typed tables. Use `health_samples`,
`workouts`, etc. instead.

---

## `nutrition.meal_logs`  *(note: lives in the `nutrition` schema, not `public`)*
LLM-parsed natural-language meal entries.
- `id UUID PK`
- `user_id UUID` → users.id (ON DELETE CASCADE)
- `sync_identifier UUID UNIQUE`
- `raw_text TEXT` — what the user spoke/typed
- `meal_type TEXT` — breakfast/lunch/dinner/snack
- `parsed_items JSONB` — `[{"name":"oatmeal","quantity":1,"unit":"cup"}, …]`
- `matched_foods JSONB` — USDA FDC matches per parsed item
- `final_nutrients JSONB` — totals per HealthKit nutrient identifier
- `created_at TIMESTAMPTZ`
- `updated_at TIMESTAMPTZ`

---

## `nutrition.foods`  *(not user-scoped — USDA FDC public data)*
- `fdc_id INTEGER PRIMARY KEY`
- `name TEXT`
- `data_type TEXT` — `sr_legacy_food`, `foundation_food`, `branded_food`
- `food_category_id INTEGER`
- `publication_date DATE`
- `search_vector tsvector` *(generated)* — for `@@ to_tsquery('english', …)` matches
- pg_trgm index on `name` enables `similarity(name, 'query') > 0.3` / `ORDER BY name <-> 'query'`.

## `nutrition.nutrients`
- `id INTEGER PK`, `name TEXT`, `unit_name TEXT`, `nutrient_nbr TEXT`, `rank INTEGER`
- Common ids: `1008` Energy (kcal), `1003` Protein (g), `1004` Total fat (g),
  `1005` Carbohydrate (g), `1079` Fiber (g), `2000` Sugars (g), `1093` Sodium (mg).

## `nutrition.food_nutrients`
- `id BIGINT PK`, `fdc_id INTEGER`, `nutrient_id INTEGER`, `amount REAL`
- Amounts are per 100 g of food unless the food's portions table specifies otherwise.

## `nutrition.food_portions`
- `id BIGINT PK`, `fdc_id INTEGER`
- `amount REAL`, `measure_unit_id INTEGER` → `nutrition.measure_units.id`
- `portion_description TEXT`, `modifier TEXT`
- `gram_weight REAL` — the grams per one portion of this kind.

## `nutrition.measure_units`
- `id INTEGER PK`, `name TEXT` — e.g. `cup`, `tbsp`, `slice`, `oz`.

## `nutrition.nutrient_healthkit_map`
- `nutrient_id INTEGER` → `nutrition.nutrients.id`
- `healthkit_identifier TEXT`
- `is_sparse BOOLEAN` — whether most foods lack this nutrient (fallback needed).

## `nutrition.iodine_supplemental`
Hand-curated iodine-per-100g fallbacks for foods USDA doesn't report.
- `id INTEGER PRIMARY KEY`
- `name TEXT`
- `iodine_mcg_per_100g DOUBLE PRECISION`
- `search_vector tsvector` *(generated from `name`)* — `@@ to_tsquery('english', …)` and
  `name % 'query'` (pg_trgm) both index-accelerated.

---

## Column lists for user-scoped tables (full, for reference)

- `public.users_safe(id, email, created_at)` — use this view; `public.users` and the `password_hash` column are guard-blocked.
- `public.devices(id, user_id, identifier_for_vendor, device_name,
  device_model, system_name, system_version, app_version, watch_model,
  watch_os_version, first_seen, last_seen)`
- `public.health_samples(start_date, user_id, hk_uuid, sample_type,
  content_hash, source_name, source_bundle_id, source_device_id, end_date,
  quantity_value, quantity_unit, category_value, correlation_id, metadata,
  sync_session_id, synced_at)`
- `public.workouts(start_date, user_id, hk_uuid, content_hash,
  activity_type, activity_name, duration_seconds,
  total_energy_burned_kcal, total_distance_m, total_swimming_stroke_count,
  end_date, source_device_id, metadata, sync_session_id, synced_at)`
- `public.workout_route_points(timestamp, user_id, workout_id, latitude,
  longitude, altitude, speed, course, horizontal_accuracy,
  vertical_accuracy)`
- `public.activity_summaries(date, user_id, content_hash,
  active_energy_burned, active_energy_burned_goal, apple_exercise_time,
  apple_exercise_time_goal, apple_stand_hours, apple_stand_hours_goal,
  apple_move_time, apple_move_time_goal, synced_at)`
- `public.user_characteristics(user_id, biological_sex, date_of_birth,
  blood_type, fitzpatrick_skin_type, wheelchair_use, activity_move_mode,
  content_hash)`
- `public.sync_sessions(id, user_id, device_id, sample_type, client_ip,
  latitude, longitude, samples_sent, samples_accepted, samples_skipped,
  status, error_message, started_at, completed_at)` — note `client_ip`,
  `latitude`, `longitude` are sensitive request metadata.
- `nutrition.meal_logs(id, user_id, sync_identifier, raw_text, meal_type,
  parsed_items, matched_foods, final_nutrients, created_at, updated_at)`

---

## Blocked & visible-but-out-of-scope objects

- `public.users` — blocked by guard (use `users_safe` instead).
- `public.raw_ingest` — blocked (archives unparsed sync payloads).
- `public._sqlx_migrations` — blocked (internal migration tracking; no analytic value).
- `pg_authid`, `pg_largeobject`, `pg_shadow`, `pg_user_mappings`, `pg_statistic` — blocked.
- `users.password_hash` column — blocked wherever referenced.
- PostGIS system views (`geography_columns`, `geometry_columns`, `spatial_ref_sys`) —
  queryable but out of scope for health analytics.

## Conventions

- **Always** filter user-scoped tables with `WHERE user_id = $1`.
- Prefer bounded time ranges: `AND start_date >= now() - interval '90 days'`.
- Use `AT TIME ZONE` for local-day aggregations:
  `date_trunc('day', start_date AT TIME ZONE 'America/Chicago')`.
- Cast big sums: `sum(quantity_value)::bigint`.
- For category samples (sleep), `category_value` is the HK raw int value;
  look up meanings in the HealthKit docs.
- For `information_schema` or `pg_catalog` introspection, pass
  `bind_user_id: false` so the user UUID isn't prepended.
