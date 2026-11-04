-- Relocate meal_logs into the nutrition schema alongside foods/food_nutrients
-- and tighten its constraints: meal_type is now a CHECK'd enum, there is an
-- updated_at column for future edit flows, and (user_id, sync_identifier) is
-- unique per-user instead of globally unique.

ALTER TABLE public.meal_logs SET SCHEMA nutrition;

ALTER TABLE nutrition.meal_logs
    ADD CONSTRAINT meal_logs_meal_type_check
    CHECK (meal_type IN ('breakfast','lunch','dinner','snack'));

ALTER TABLE nutrition.meal_logs
    ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Drop the globally-unique constraint on sync_identifier and replace with a
-- per-user unique. The auto-named constraint from the original migration is
-- meal_logs_sync_identifier_key; we drop it defensively in case the name
-- varies across environments.
DO $$
DECLARE
    cons text;
BEGIN
    SELECT conname INTO cons
    FROM pg_constraint
    WHERE conrelid = 'nutrition.meal_logs'::regclass
      AND contype = 'u'
      AND pg_get_constraintdef(oid) LIKE '%(sync_identifier)%';
    IF cons IS NOT NULL THEN
        EXECUTE format('ALTER TABLE nutrition.meal_logs DROP CONSTRAINT %I', cons);
    END IF;
END$$;

ALTER TABLE nutrition.meal_logs
    ADD CONSTRAINT meal_logs_user_sync_unique
    UNIQUE (user_id, sync_identifier);
