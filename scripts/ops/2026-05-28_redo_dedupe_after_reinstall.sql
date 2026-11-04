-- 2026-05-28: the dev-profile-induced reinstall on 2026-05-04 regenerated
-- identifierForVendor on the iPhone, creating a fresh device row
-- (4f753ab3-…) while the post-merge survivor from 2026-05-04
-- (cf371bf2-…) sat untouched. Repoint all FKs onto the LIVE row
-- (4f753ab3) and drop the stale one. Survivor is hard-coded by last_seen,
-- not heuristic, because the live row has fewer sessions but is the only
-- one the client will ever send to again.
--
-- Run from the Mac:
--   PGPASSWORD='…' psql "host=192.168.1.104 user=ladvien dbname=apple_health_source" \
--     -f scripts/ops/2026-05-28_redo_dedupe_after_reinstall.sql

\set ON_ERROR_STOP on
\set USER_ID    '''1d8ef72c-f6e9-4439-b371-6b8726808af1'''
\set SURVIVOR   '''4f753ab3-a5a0-4341-95b4-3f30f7e3f612'''
\set DUPLICATE  '''cf371bf2-65b6-4dca-bd05-06456ffe23de'''

BEGIN;

\echo
\echo '== before =='
SELECT id, identifier_for_vendor, first_seen, last_seen,
       (SELECT COUNT(*) FROM sync_sessions s  WHERE s.device_id        = d.id) AS sessions,
       (SELECT COUNT(*) FROM health_samples h WHERE h.source_device_id = d.id) AS samples,
       (SELECT COUNT(*) FROM workouts      w WHERE w.source_device_id = d.id) AS workouts
  FROM devices d
 WHERE user_id = :USER_ID
 ORDER BY last_seen DESC NULLS LAST;

UPDATE sync_sessions  SET device_id        = :SURVIVOR WHERE device_id        = :DUPLICATE;
UPDATE health_samples SET source_device_id = :SURVIVOR WHERE source_device_id = :DUPLICATE;
UPDATE workouts       SET source_device_id = :SURVIVOR WHERE source_device_id = :DUPLICATE;

UPDATE devices
   SET first_seen = LEAST(first_seen,
                          (SELECT first_seen FROM devices WHERE id = :DUPLICATE))
 WHERE id = :SURVIVOR;

DELETE FROM devices WHERE id = :DUPLICATE;

\echo
\echo '== after (expect 1 row) =='
SELECT id, identifier_for_vendor, first_seen, last_seen,
       (SELECT COUNT(*) FROM sync_sessions s  WHERE s.device_id        = d.id) AS sessions,
       (SELECT COUNT(*) FROM health_samples h WHERE h.source_device_id = d.id) AS samples
  FROM devices d
 WHERE user_id = :USER_ID;

COMMIT;
