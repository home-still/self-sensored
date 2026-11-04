-- v2 of the post-reinstall device dedupe. The v1 script tried to UPDATE
-- 5.4M health_samples in one transaction with no index on
-- source_device_id — it seq-scanned the hypertable for 19+ minutes while
-- holding row locks, which starved live /sync writes (the SessionGuard
-- marked 8 sessions 'failed' before we cancelled it).
--
-- This version:
--   1. Builds a partial btree on (source_device_id, user_id) CONCURRENTLY
--      — no lock on the table, doesn't block live sync.
--   2. Repoints health_samples in 100k-row chunks, each its own tx, so
--      locks release between chunks and live sync can interleave.
--   3. Then does the sessions/workouts/devices cleanup (small tables).
--
-- Run from the Mac:
--   PGPASSWORD='…' psql "host=192.168.1.104 user=ladvien dbname=apple_health_source" \
--     -f scripts/ops/2026-05-28_redo_dedupe_v2_batched.sql

\set ON_ERROR_STOP on
\set USER_ID    '''1d8ef72c-f6e9-4439-b371-6b8726808af1'''
\set SURVIVOR   '''4f753ab3-a5a0-4341-95b4-3f30f7e3f612'''
\set DUPLICATE  '''cf371bf2-65b6-4dca-bd05-06456ffe23de'''

-- ---- Step 1: partial index. CONCURRENTLY isn't supported on TimescaleDB
-- hypertables; plain CREATE INDEX briefly locks each chunk individually
-- (not the whole hypertable). Idempotent.
CREATE INDEX IF NOT EXISTS health_samples_source_device_id_idx
    ON health_samples (source_device_id)
    WHERE source_device_id IS NOT NULL;

\echo '== index built =='

-- ---- Step 2: batched repoint. Each loop iteration is its own
-- autocommit, so locks release between batches and live sync can
-- interleave. ctid is fast on hypertables; 100k chunks finish in
-- low-single-digit seconds each.
DO $$
DECLARE
    rows_updated bigint := 1;
    total bigint := 0;
BEGIN
    WHILE rows_updated > 0 LOOP
        WITH cte AS (
            SELECT ctid FROM health_samples
             WHERE source_device_id = 'cf371bf2-65b6-4dca-bd05-06456ffe23de'
             LIMIT 100000
        )
        UPDATE health_samples h SET source_device_id = '4f753ab3-a5a0-4341-95b4-3f30f7e3f612'
          FROM cte WHERE h.ctid = cte.ctid;
        GET DIAGNOSTICS rows_updated = ROW_COUNT;
        total := total + rows_updated;
        RAISE NOTICE 'batch: % rows (total %)', rows_updated, total;
        COMMIT;
    END LOOP;
END $$;

\echo '== health_samples repointed =='

-- ---- Step 3: small-table fixups (single tx, fast)
BEGIN;

UPDATE sync_sessions SET device_id        = :SURVIVOR WHERE device_id        = :DUPLICATE;
UPDATE workouts      SET source_device_id = :SURVIVOR WHERE source_device_id = :DUPLICATE;

UPDATE devices
   SET first_seen = LEAST(first_seen,
                          (SELECT first_seen FROM devices WHERE id = :DUPLICATE))
 WHERE id = :SURVIVOR;

DELETE FROM devices WHERE id = :DUPLICATE;

\echo
\echo '== after (expect 1 row) =='
SELECT id, identifier_for_vendor, first_seen, last_seen,
       (SELECT COUNT(*) FROM sync_sessions s  WHERE s.device_id        = d.id) AS sessions,
       (SELECT COUNT(*) FROM workouts      w WHERE w.source_device_id = d.id) AS workouts
  FROM devices d
 WHERE user_id = :USER_ID;

COMMIT;
