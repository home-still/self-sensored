# Self Sensored query recipes

Short prose about *which patterns to reach for* when the agent is writing a
new query. Read `self-sensored://schema/overview.md` for column names and
`self-sensored://examples/queries.sql` for copy-paste starts.

## 1. Always filter by `user_id = $1`

Every user-scoped table (`health_samples`, `workouts`, `workout_route_points`,
`meal_logs`, `sync_sessions`, `activity_summaries`, `user_characteristics`,
`devices`) **must** include `WHERE user_id = $1`. The MCP binds the user's
UUID as `$1` automatically. Forgetting this filter will return zero rows (the
read-only role may not even see other users' data) and wastes the query cap.

For `information_schema` / `pg_catalog` / `nutrition.*` queries, pass
`bind_user_id: false` in the tool call so `$1` points at your first real
parameter instead.

## 2. Bound the time window

The hypertables (`health_samples`, `workouts`, `workout_route_points`) are
partitioned by time. A `start_date >= now() - interval 'N days'` clause lets
Timescale prune chunks — the difference between a 200 ms and a 10 s query.

Older-than-30-days chunks are *compressed*; querying them is still fast for
aggregates but avoid `SELECT *` on huge ranges.

**Full-table aggregations WILL time out on `health_samples`.** The table has
5 M+ rows and counting. An unfiltered `SELECT sample_type, count(*) …
GROUP BY sample_type` or a bare `SELECT count(*) FROM health_samples WHERE
user_id = $1` regularly hits the 5 s `statement_timeout`. If you need a
full-history summary, reach for the `health_sample_manifest` table (one row
per sample, no quantity payload) or bucket with
`start_date >= now() - interval '5 years'` which still prunes to the oldest
relevant chunks. Same applies to `workouts` and `workout_route_points` as
they grow.

## 3. Aggregate, don't dump

The tool caps row count at `MCP_MAX_ROWS`. When the user asks "how's my sleep
trending," return a time series of daily/weekly totals — not raw samples.
Standard shape:

```sql
SELECT date_trunc('week', start_date) AS week,
       agg(quantity_value)
  FROM health_samples
 WHERE user_id = $1 AND sample_type = '…' AND start_date >= now() - interval 'N'
 GROUP BY 1 ORDER BY 1;
```

## 4. Local days vs UTC

`start_date` is stored in UTC. For calendar-day aggregations, cast through the
user's timezone first:

```sql
(start_date AT TIME ZONE 'America/Chicago')::date
```

Ask the user what zone they want if it matters.

## 5. Sleep is a category sample

`HKCategoryTypeIdentifierSleepAnalysis` rows use `category_value` (int) and
the duration is `end_date - start_date`. Stage codes:

| value | meaning               |
|------:|-----------------------|
|     0 | inBed                 |
|     1 | asleepUnspecified     |
|     2 | awake                 |
|     3 | asleepCore            |
|     4 | asleepDeep            |
|     5 | asleepREM             |

## 6. Nutrition joins

`nutrition.food_nutrients.amount` is per 100 g for `foundation_food` and
`sr_legacy_food`. `food_portions.gram_weight` gives grams per named portion
(e.g. "1 cup"). The meal parser has already applied portion math and stored
the user-facing totals in `meal_logs.final_nutrients` (keyed by HK nutrient
identifier). For ad-hoc nutrient lookups, start from `meal_logs`; only dig
into `nutrition.*` when the user wants generic food info.

## 7. Use pg_trgm for fuzzy food search

```sql
SELECT fdc_id, name, similarity(name, $2) AS score
  FROM nutrition.foods
 WHERE name % $2
 ORDER BY score DESC
 LIMIT 20;
```

The `%` operator uses the `gin_trgm_ops` index on `name`. Prefer over
`ILIKE '%…%'` which can't use the index.

## 8. Category + quantity in one table

`health_samples` holds both. Rows with `quantity_value IS NOT NULL` are
quantities (steps, heart rate, kg). Rows with `category_value IS NOT NULL`
are categories (sleep stage, menstrual flow, etc.). Filter by `sample_type`
and the correct value column will be populated.

## 9. Bulk time-series shape

Steps are emitted many times per day; heart rate every few seconds while
worn. Don't `SELECT *` a month of HR samples — aggregate on the server.

## 10. When the guard rejects you

- `parse_error` — the SQL didn't parse. Check quoting and semicolons.
- `not_read_only` — you wrote an `INSERT`, `UPDATE`, `DELETE`, `CREATE`,
  `ALTER`, `DROP`, `GRANT`, `COPY`, or `SET`, or multiple statements.
  Split into a pure `SELECT`.
- `forbidden_function` — `pg_read_file`, `dblink`, `lo_import`, etc. are
  blocked. There is no workaround; use a different approach.
- `forbidden_object` — you touched `pg_authid`, `pg_largeobject`, or similar.
  Use `information_schema.*` or `pg_catalog.pg_tables` for introspection.
- `timeout` — hit `MCP_STATEMENT_TIMEOUT_MS` (5 s default). Add a tighter
  `WHERE` clause or aggregate less data.
- `row_cap_exceeded` (`truncated: true` in the response) — you returned
  more than `MCP_MAX_ROWS`. Add `LIMIT` or aggregate.
