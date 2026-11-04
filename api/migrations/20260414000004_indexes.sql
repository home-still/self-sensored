-- Index tuning for the meal-parse hot path.
--
-- Old: idx_food_nutrients_fdc (fdc_id) + idx_food_nutrients_nutrient (nutrient_id).
-- The meal-parse query joins on both columns per row, so a composite that
-- covers `amount` lets Postgres answer straight from the index.
--
-- idx_foods_data_type is ~5-cardinality; drop it.
--
-- These are declared without CONCURRENTLY so they can run inside the normal
-- sqlx migration transaction. At present the tables are empty or small; the
-- builds take milliseconds. If the table ever grows past a few million rows
-- and a future index needs to be added without locking, skip sqlx-migrate and
-- apply that one manually with CONCURRENTLY.

CREATE INDEX IF NOT EXISTS idx_fn_fdc_nutrient
    ON nutrition.food_nutrients (fdc_id, nutrient_id) INCLUDE (amount);

DROP INDEX IF EXISTS nutrition.idx_food_nutrients_fdc;
DROP INDEX IF EXISTS nutrition.idx_foods_data_type;
