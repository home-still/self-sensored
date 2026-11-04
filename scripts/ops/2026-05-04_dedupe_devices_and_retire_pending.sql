-- One-time data fixup for the issues surfaced by the 2026-05-04 health
-- check. NOT a migration: these are user-data operations, not schema
-- changes, and they can't be replayed safely against a fresh DB.
--
-- 1. Retire any sync_sessions row stuck in 'pending' from before the
--    SessionGuard / hash_check finalization fix shipped. The guard ensures
--    every NEW session reaches a terminal state, but the existing row
--    from 2026-04-24 RestingHeartRate would otherwise sit forever.
--
-- 2. Merge the duplicate device row created when iOS regenerated
--    identifierForVendor on app reinstall. We keep the row that has the
--    most recent activity (sync_sessions referencing it) and repoint
--    every FK from the other one before deleting it.
--
-- Run on host `four` (192.168.1.104):
--   PGPASSWORD=... psql -h 192.168.1.104 -U <user> -d apple_health_source \
--     -f scripts/ops/2026-05-04_dedupe_devices_and_retire_pending.sql

\set ON_ERROR_STOP on
\set USER_ID '''1d8ef72c-f6e9-4439-b371-6b8726808af1'''

BEGIN;

-- ---- Step 1: investigate (read-only, prints to console) ----
\echo
\echo '== device rows for user before merge =='
SELECT id,
       identifier_for_vendor,
       device_name,
       device_model,
       system_version,
       app_version,
       first_seen,
       last_seen,
       (SELECT COUNT(*) FROM sync_sessions s WHERE s.device_id = d.id) AS sessions
  FROM devices d
 WHERE user_id = :USER_ID
 ORDER BY last_seen DESC NULLS LAST;

\echo
\echo '== orphaned pending sessions =='
SELECT id, device_id, sample_type, started_at
  FROM sync_sessions
 WHERE user_id = :USER_ID
   AND status = 'pending'
   AND started_at < now() - interval '1 hour';

-- ---- Step 2: pick survivor by activity ----
-- Survivor = whichever device row has the most sync_sessions pointing at
-- it. If there's a tie, latest last_seen wins. Result lands in a temp
-- table so we can reference it from multiple statements without
-- recomputing.
CREATE TEMP TABLE _device_merge ON COMMIT DROP AS
WITH ranked AS (
    SELECT d.id,
           d.last_seen,
           d.first_seen,
           (SELECT COUNT(*) FROM sync_sessions s WHERE s.device_id = d.id) AS sessions
      FROM devices d
     WHERE d.user_id = :USER_ID
)
SELECT
    (SELECT id FROM ranked ORDER BY sessions DESC, last_seen DESC NULLS LAST LIMIT 1) AS survivor,
    array(
        SELECT id FROM ranked
        WHERE id <> (SELECT id FROM ranked ORDER BY sessions DESC, last_seen DESC NULLS LAST LIMIT 1)
    ) AS duplicates;

\echo
\echo '== merge plan =='
SELECT survivor, duplicates FROM _device_merge;

-- ---- Step 3: repoint FKs from duplicates -> survivor ----
UPDATE sync_sessions
   SET device_id = m.survivor
  FROM _device_merge m
 WHERE sync_sessions.device_id = ANY(m.duplicates);

UPDATE health_samples
   SET source_device_id = m.survivor
  FROM _device_merge m
 WHERE health_samples.source_device_id = ANY(m.duplicates);

UPDATE workouts
   SET source_device_id = m.survivor
  FROM _device_merge m
 WHERE workouts.source_device_id = ANY(m.duplicates);

-- ---- Step 4: preserve oldest first_seen on the survivor ----
UPDATE devices
   SET first_seen = LEAST(devices.first_seen, sub.min_first_seen)
  FROM (
    SELECT MIN(d.first_seen) AS min_first_seen
      FROM devices d, _device_merge m
     WHERE d.id = ANY(m.duplicates)
  ) sub,
  _device_merge m
 WHERE devices.id = m.survivor
   AND sub.min_first_seen IS NOT NULL;

-- ---- Step 5: delete the duplicates ----
DELETE FROM devices
 USING _device_merge m
 WHERE devices.id = ANY(m.duplicates);

-- ---- Step 6: retire orphaned pending sync_sessions ----
-- These predate the SessionGuard. Any future pending row will be marked
-- 'failed' on Drop by the guard itself, so this fixup is one-shot.
UPDATE sync_sessions
   SET status = 'failed',
       error_message = 'client_abandoned_pre_terminal_guard',
       completed_at = started_at + interval '1 second'
 WHERE user_id = :USER_ID
   AND status = 'pending'
   AND started_at < now() - interval '1 hour';

-- ---- Step 7: verify ----
\echo
\echo '== device rows after merge (expect 1) =='
SELECT id, identifier_for_vendor, device_name, first_seen, last_seen,
       (SELECT COUNT(*) FROM sync_sessions s WHERE s.device_id = d.id) AS sessions
  FROM devices d
 WHERE user_id = :USER_ID;

\echo
\echo '== pending sync_sessions remaining for user (expect 0) =='
SELECT COUNT(*) AS pending_remaining
  FROM sync_sessions
 WHERE user_id = :USER_ID AND status = 'pending';

COMMIT;
