-- Minimal nutrition seed for handler integration tests.
-- One food ("grilled chicken breast") with three nutrients mapped to HK ids
-- by the existing 20260413000002 migration. Lets the meal-parse happy-path
-- test resolve to non-empty nutrients.

INSERT INTO nutrition.nutrients (id, name, unit_name, nutrient_nbr, rank) VALUES
    (1003, 'Protein',           'G',    '203', 600),
    (1004, 'Total lipid (fat)', 'G',    '204', 800),
    (1008, 'Energy',            'KCAL', '208', 300)
ON CONFLICT (id) DO NOTHING;

INSERT INTO nutrition.foods (fdc_id, name, data_type, food_category_id, publication_date) VALUES
    (171477,
     'Chicken, broilers or fryers, breast, meat only, cooked, grilled',
     'sr_legacy_food', 5, '2019-04-01')
ON CONFLICT (fdc_id) DO NOTHING;

INSERT INTO nutrition.food_nutrients (id, fdc_id, nutrient_id, amount) VALUES
    (1, 171477, 1003,  31.02),  -- protein g per 100g
    (2, 171477, 1004,   3.57),  -- fat g per 100g
    (3, 171477, 1008, 165.0)   -- kcal per 100g
ON CONFLICT (id) DO NOTHING;
