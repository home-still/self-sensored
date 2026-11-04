-- Every table that references users.id must cascade on user-delete so a GDPR
-- account purge can be done as a single DELETE. Previously most FKs were
-- ON DELETE NO ACTION (implicit), which blocked deletion entirely.
--
-- workout_route_points is a special case: the original migration declared
-- user_id UUID NOT NULL with no FK at all. We add one here.

-- Helper: drop the existing FK on user_id (if any) and re-add with cascade.
-- Each table's FK has a unique auto-generated name, so we look it up.
DO $$
DECLARE
    t TEXT;
    fqn TEXT;
    cons TEXT;
    tables TEXT[] := ARRAY[
        'public.health_samples',
        'public.workouts',
        'public.activity_summaries',
        'public.sync_sessions',
        'public.devices',
        'public.raw_ingest',
        'public.user_characteristics',
        'nutrition.meal_logs'
    ];
BEGIN
    FOREACH fqn IN ARRAY tables LOOP
        SELECT conname INTO cons
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.contype = 'f'
          AND (n.nspname || '.' || t.relname) = fqn
          AND pg_get_constraintdef(c.oid) LIKE '%REFERENCES users(id)%'
        LIMIT 1;

        IF cons IS NOT NULL THEN
            EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', fqn, cons);
        END IF;

        EXECUTE format(
            'ALTER TABLE %s ADD CONSTRAINT %I_user_id_fkey ' ||
            'FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE',
            fqn, split_part(fqn, '.', 2)
        );
        cons := NULL;
    END LOOP;
END$$;

-- workout_route_points had no FK at all. Add one directly.
-- (TimescaleDB hypertables can reference non-hypertable parents; child-side FKs
-- are supported.)
ALTER TABLE public.workout_route_points
    ADD CONSTRAINT workout_route_points_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
