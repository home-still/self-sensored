-- iodine_supplemental used SERIAL (legacy sequence-backed PK) while every
-- other nutrition table uses an explicit INTEGER with externally-supplied ids.
-- Convert to GENERATED ALWAYS AS IDENTITY — the modern Postgres equivalent
-- that avoids sequence-vs-column ownership edge cases on pg_dump/restore.

ALTER TABLE nutrition.iodine_supplemental
    ALTER COLUMN id DROP DEFAULT;

-- Capture the existing sequence's next value so the identity column continues
-- from where SERIAL left off.
DO $$
DECLARE
    seq regclass;
    next_val bigint;
BEGIN
    SELECT pg_get_serial_sequence('nutrition.iodine_supplemental', 'id') INTO seq;
    IF seq IS NOT NULL THEN
        EXECUTE format('SELECT last_value + 1 FROM %s', seq) INTO next_val;
        EXECUTE format('DROP SEQUENCE %s', seq);
    ELSE
        SELECT COALESCE(MAX(id), 0) + 1
        FROM nutrition.iodine_supplemental
        INTO next_val;
    END IF;

    EXECUTE format(
        'ALTER TABLE nutrition.iodine_supplemental ' ||
        'ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (START WITH %s)',
        next_val
    );
END$$;
