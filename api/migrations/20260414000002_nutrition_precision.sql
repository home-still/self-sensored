-- food_nutrients.amount was REAL (f32, ~7 digits of precision). Small-value
-- nutrients (micrograms after portion scaling) accumulate rounding error
-- across multi-item meals. DOUBLE PRECISION (f64) costs 4 extra bytes per row
-- and removes the precision concern.
--
-- NOTE: ALTER COLUMN ... TYPE rewrites the table. On the populated foods DB
-- (~350k rows after USDA) this takes a few seconds with an ACCESS EXCLUSIVE
-- lock. Schedule outside peak usage.

ALTER TABLE nutrition.food_nutrients
    ALTER COLUMN amount TYPE DOUBLE PRECISION;

-- food_portions.gram_weight and .amount likewise deserve f64 for consistency
-- with the runtime conversion path.
ALTER TABLE nutrition.food_portions
    ALTER COLUMN amount TYPE DOUBLE PRECISION,
    ALTER COLUMN gram_weight TYPE DOUBLE PRECISION;

-- iodine_supplemental.iodine_mcg_per_100g likewise.
ALTER TABLE nutrition.iodine_supplemental
    ALTER COLUMN iodine_mcg_per_100g TYPE DOUBLE PRECISION;
