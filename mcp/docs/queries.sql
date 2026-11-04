-- Self Sensored example queries.
--
-- Each snippet assumes:
--   * $1 is the authenticated user's UUID (bound automatically by the MCP).
--   * Further parameters start at $2.
--
-- Copy one of these and adapt the time window or sample_type to taste.

-- ============================================================================
-- ACTIVITY
-- ============================================================================

-- 1. Step total for the last 7 days.
SELECT sum(quantity_value)::bigint AS steps_7d
  FROM health_samples
 WHERE user_id = $1
   AND sample_type = 'HKQuantityTypeIdentifierStepCount'
   AND start_date >= now() - interval '7 days';

-- 2. Daily step totals for the last 30 days (user's local time).
SELECT (start_date AT TIME ZONE 'America/Chicago')::date AS day,
       sum(quantity_value)::bigint AS steps
  FROM health_samples
 WHERE user_id = $1
   AND sample_type = 'HKQuantityTypeIdentifierStepCount'
   AND start_date >= now() - interval '30 days'
 GROUP BY 1 ORDER BY 1;

-- 3. Steps by day-of-week, last 90 days.
SELECT to_char(start_date AT TIME ZONE 'America/Chicago', 'Dy') AS dow,
       avg(quantity_value)::int AS avg_steps_per_sample,
       sum(quantity_value)::bigint AS total_steps
  FROM health_samples
 WHERE user_id = $1
   AND sample_type = 'HKQuantityTypeIdentifierStepCount'
   AND start_date >= now() - interval '90 days'
 GROUP BY 1
 ORDER BY total_steps DESC;

-- 4. Distance walked / run (km) per week, last 12 weeks.
SELECT date_trunc('week', start_date) AS week,
       round((sum(quantity_value) / 1000)::numeric, 2) AS km
  FROM health_samples
 WHERE user_id = $1
   AND sample_type = 'HKQuantityTypeIdentifierDistanceWalkingRunning'
   AND start_date >= now() - interval '12 weeks'
 GROUP BY 1 ORDER BY 1;

-- ============================================================================
-- HEART RATE
-- ============================================================================

-- 5. 30-day resting heart rate trend (week-bucketed).
SELECT date_trunc('week', start_date) AS week,
       round(avg(quantity_value)::numeric, 1) AS rhr_bpm
  FROM health_samples
 WHERE user_id = $1
   AND sample_type = 'HKQuantityTypeIdentifierRestingHeartRate'
   AND start_date >= now() - interval '90 days'
 GROUP BY 1 ORDER BY 1;

-- 6. HRV (SDNN) weekly average.
SELECT date_trunc('week', start_date) AS week,
       round(avg(quantity_value)::numeric, 1) AS hrv_ms
  FROM health_samples
 WHERE user_id = $1
   AND sample_type = 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN'
   AND start_date >= now() - interval '90 days'
 GROUP BY 1 ORDER BY 1;

-- 7. Heart-rate zone minutes during the most recent workout.
WITH last_workout AS (
    SELECT hk_uuid, start_date, end_date
      FROM workouts
     WHERE user_id = $1
     ORDER BY start_date DESC
     LIMIT 1
)
SELECT CASE
         WHEN quantity_value < 114 THEN 'Z1 (<60%)'
         WHEN quantity_value < 133 THEN 'Z2'
         WHEN quantity_value < 152 THEN 'Z3'
         WHEN quantity_value < 171 THEN 'Z4'
         ELSE 'Z5 (>90%)'
       END AS zone,
       count(*) AS samples
  FROM health_samples s, last_workout w
 WHERE s.user_id = $1
   AND s.sample_type = 'HKQuantityTypeIdentifierHeartRate'
   AND s.start_date BETWEEN w.start_date AND w.end_date
 GROUP BY 1 ORDER BY 1;

-- ============================================================================
-- SLEEP
-- ============================================================================

-- 8. Nightly sleep totals (minutes in bed), last 30 days.
SELECT (start_date AT TIME ZONE 'America/Chicago')::date AS night,
       round(sum(extract(epoch FROM (end_date - start_date))) / 60, 1) AS minutes
  FROM health_samples
 WHERE user_id = $1
   AND sample_type = 'HKCategoryTypeIdentifierSleepAnalysis'
   AND start_date >= now() - interval '30 days'
 GROUP BY 1 ORDER BY 1 DESC;

-- 9. Sleep-stage breakdown for last night.
-- category_value encodings: 0 inBed, 1 asleepUnspecified, 2 awake,
-- 3 asleepCore, 4 asleepDeep, 5 asleepREM.
SELECT category_value,
       round(sum(extract(epoch FROM (end_date - start_date))) / 60, 1) AS minutes
  FROM health_samples
 WHERE user_id = $1
   AND sample_type = 'HKCategoryTypeIdentifierSleepAnalysis'
   AND start_date >= now() - interval '24 hours'
 GROUP BY 1 ORDER BY 1;

-- ============================================================================
-- WORKOUTS
-- ============================================================================

-- 10. Weekly workout minutes, last 12 weeks.
SELECT date_trunc('week', start_date) AS week,
       round(sum(duration_seconds) / 60)::int AS minutes
  FROM workouts
 WHERE user_id = $1
   AND start_date >= now() - interval '12 weeks'
 GROUP BY 1 ORDER BY 1;

-- 11. Workouts with highest calorie burn in the last 90 days.
SELECT start_date, activity_name, activity_type,
       duration_seconds / 60 AS duration_min,
       total_energy_burned_kcal AS kcal,
       total_distance_m / 1000 AS km
  FROM workouts
 WHERE user_id = $1
   AND start_date >= now() - interval '90 days'
   AND total_energy_burned_kcal IS NOT NULL
 ORDER BY total_energy_burned_kcal DESC
 LIMIT 10;

-- 12. Personal best by activity_type (longest duration).
SELECT activity_type, max(duration_seconds / 60)::int AS longest_minutes,
       max(total_distance_m / 1000) AS longest_km
  FROM workouts
 WHERE user_id = $1
 GROUP BY activity_type
 ORDER BY longest_minutes DESC;

-- ============================================================================
-- MEALS & NUTRITION
-- ============================================================================

-- 13. Macro totals per day, last 14 days.
SELECT (created_at AT TIME ZONE 'America/Chicago')::date AS day,
       round(sum((final_nutrients->>'HKQuantityTypeIdentifierDietaryEnergyConsumed')::numeric), 0) AS kcal,
       round(sum((final_nutrients->>'HKQuantityTypeIdentifierDietaryProtein')::numeric), 1) AS protein_g,
       round(sum((final_nutrients->>'HKQuantityTypeIdentifierDietaryCarbohydrates')::numeric), 1) AS carbs_g,
       round(sum((final_nutrients->>'HKQuantityTypeIdentifierDietaryFatTotal')::numeric), 1) AS fat_g
  FROM nutrition.meal_logs
 WHERE user_id = $1
   AND created_at >= now() - interval '14 days'
 GROUP BY 1 ORDER BY 1 DESC;

-- 14. Meals with the highest calorie density (kcal per gram of input match).
SELECT id, meal_type, raw_text,
       (final_nutrients->>'HKQuantityTypeIdentifierDietaryEnergyConsumed')::numeric AS kcal,
       created_at
  FROM nutrition.meal_logs
 WHERE user_id = $1
   AND created_at >= now() - interval '30 days'
 ORDER BY kcal DESC NULLS LAST
 LIMIT 10;

-- 15. Recent meal history.
SELECT id, created_at, meal_type, raw_text
  FROM nutrition.meal_logs
 WHERE user_id = $1
 ORDER BY created_at DESC
 LIMIT 20;

-- 16. Fuzzy USDA food search (not user-scoped; set bind_user_id=false OR
--     just ignore $1 here — the guard still allows unused binds).
SELECT fdc_id, name, data_type,
       round(similarity(name, $2)::numeric, 3) AS score
  FROM nutrition.foods
 WHERE name % $2  -- pg_trgm trigram match
 ORDER BY score DESC
 LIMIT 20;
-- usage: params=[ "<user uuid>"? , "rolled oats" ]  (with bind_user_id=false,
-- the LLM passes the search string as $1 via params[0] instead).

-- 17. Nutrients for a single food (pass FDC id as $2).
SELECT n.id AS nutrient_id, n.name, n.unit_name, fn.amount
  FROM nutrition.food_nutrients fn
  JOIN nutrition.nutrients n ON n.id = fn.nutrient_id
 WHERE fn.fdc_id = $2
 ORDER BY n.rank NULLS LAST, n.name;

-- ============================================================================
-- BODY
-- ============================================================================

-- 18. Body mass trend, last 180 days.
SELECT (start_date AT TIME ZONE 'America/Chicago')::date AS day,
       round(avg(quantity_value)::numeric, 2) AS kg
  FROM health_samples
 WHERE user_id = $1
   AND sample_type = 'HKQuantityTypeIdentifierBodyMass'
   AND start_date >= now() - interval '180 days'
 GROUP BY 1 ORDER BY 1;

-- 19. Body fat % trend.
SELECT date_trunc('week', start_date) AS week,
       round(avg(quantity_value * 100)::numeric, 1) AS body_fat_pct
  FROM health_samples
 WHERE user_id = $1
   AND sample_type = 'HKQuantityTypeIdentifierBodyFatPercentage'
 GROUP BY 1 ORDER BY 1;

-- ============================================================================
-- CORRELATIONAL
-- ============================================================================

-- 20. Steps vs resting HR per week, last 90 days.
WITH steps AS (
    SELECT date_trunc('week', start_date) AS week,
           sum(quantity_value) AS steps
      FROM health_samples
     WHERE user_id = $1
       AND sample_type = 'HKQuantityTypeIdentifierStepCount'
       AND start_date >= now() - interval '90 days'
     GROUP BY 1
), rhr AS (
    SELECT date_trunc('week', start_date) AS week,
           avg(quantity_value) AS rhr
      FROM health_samples
     WHERE user_id = $1
       AND sample_type = 'HKQuantityTypeIdentifierRestingHeartRate'
       AND start_date >= now() - interval '90 days'
     GROUP BY 1
)
SELECT s.week, s.steps::bigint, round(r.rhr::numeric, 1) AS rhr
  FROM steps s JOIN rhr r USING (week)
 ORDER BY 1;

-- 21. Workout minutes in day N vs sleep minutes in night N+1.
WITH workout_day AS (
    SELECT (start_date AT TIME ZONE 'America/Chicago')::date AS d,
           sum(duration_seconds) / 60 AS minutes
      FROM workouts
     WHERE user_id = $1
       AND start_date >= now() - interval '60 days'
     GROUP BY 1
), sleep_night AS (
    SELECT ((start_date AT TIME ZONE 'America/Chicago')::date - 1) AS d,
           sum(extract(epoch FROM (end_date - start_date))) / 60 AS minutes
      FROM health_samples
     WHERE user_id = $1
       AND sample_type = 'HKCategoryTypeIdentifierSleepAnalysis'
       AND start_date >= now() - interval '60 days'
     GROUP BY 1
)
SELECT w.d, round(w.minutes::numeric, 0) AS workout_min,
       round(s.minutes::numeric, 0) AS next_sleep_min
  FROM workout_day w JOIN sleep_night s USING (d)
 ORDER BY 1;

-- 22. Kcal intake vs body-mass delta, last 30 days.
WITH kcal_day AS (
    SELECT (created_at AT TIME ZONE 'America/Chicago')::date AS day,
           sum((final_nutrients->>'HKQuantityTypeIdentifierDietaryEnergyConsumed')::numeric) AS kcal
      FROM nutrition.meal_logs
     WHERE user_id = $1
       AND created_at >= now() - interval '30 days'
     GROUP BY 1
), weight_day AS (
    SELECT (start_date AT TIME ZONE 'America/Chicago')::date AS day,
           avg(quantity_value) AS kg
      FROM health_samples
     WHERE user_id = $1
       AND sample_type = 'HKQuantityTypeIdentifierBodyMass'
       AND start_date >= now() - interval '31 days'
     GROUP BY 1
)
SELECT k.day, k.kcal,
       w.kg,
       w.kg - lag(w.kg) OVER (ORDER BY k.day) AS kg_delta
  FROM kcal_day k LEFT JOIN weight_day w USING (day)
 ORDER BY 1;

-- ============================================================================
-- OPERATIONAL / INTROSPECTION
-- ============================================================================

-- 23. Most recent sync sessions.
SELECT id, sample_type, status, samples_sent, samples_accepted,
       started_at, completed_at, error_message
  FROM sync_sessions
 WHERE user_id = $1
 ORDER BY started_at DESC
 LIMIT 20;

-- 24. What sample_types have we ever ingested, and how many of each?
SELECT sample_type, count(*) AS n, min(start_date) AS first, max(start_date) AS last
  FROM health_samples
 WHERE user_id = $1
 GROUP BY sample_type
 ORDER BY n DESC;

-- 25. Schema exploration (set bind_user_id: false).
SELECT table_schema, table_name
  FROM information_schema.tables
 WHERE table_schema IN ('public', 'nutrition')
 ORDER BY 1, 2;
