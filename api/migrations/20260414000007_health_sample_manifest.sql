-- A small, uncompressed sidecar keyed on (user_id, hk_uuid) that mirrors the
-- content_hash of every row in the health_samples hypertable. /check reads
-- from here instead of walking 130 TimescaleDB chunks + decompressing
-- bloom-filter false positives on every request.
CREATE TABLE health_sample_manifest (
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    hk_uuid      TEXT NOT NULL,
    sample_type  TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, hk_uuid)
);

-- One-time backfill from the hypertable. DISTINCT ON because health_samples
-- is UNIQUE on (user_id, hk_uuid, start_date), not (user_id, hk_uuid); if the
-- same hk_uuid somehow exists across multiple start_dates, the most recently
-- synced row wins.
INSERT INTO health_sample_manifest (user_id, hk_uuid, sample_type, content_hash)
SELECT DISTINCT ON (user_id, hk_uuid)
       user_id, hk_uuid, sample_type, content_hash
FROM health_samples
WHERE content_hash IS NOT NULL AND content_hash <> ''
ORDER BY user_id, hk_uuid, synced_at DESC
ON CONFLICT (user_id, hk_uuid) DO NOTHING;
