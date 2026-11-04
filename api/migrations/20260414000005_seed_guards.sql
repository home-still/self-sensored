-- Defense against silent duplicate nutrient rows on a future re-seed. The
-- importer keys lookups by id, but if someone manually inserts a row the
-- case-insensitive name collision is hard to catch without this index.

CREATE UNIQUE INDEX IF NOT EXISTS nutrients_name_lower
    ON nutrition.nutrients (lower(name));
