use sqlx::PgPool;

use crate::error::AppError;
use crate::models::meal::{MatchedFood, NutrientValue};
use crate::nutrition::units::Portion;

/// Single-term FTS lookup. Call through `nutrition::cache::cached_best_match`
/// for the memoized iteration over the LLM's search-term list.
pub async fn best_match_for_term(
    pool: &PgPool,
    term: &str,
) -> Result<Option<MatchedFood>, AppError> {
    let row: Option<(i32, String, String)> = sqlx::query_as(
        r#"
        SELECT f.fdc_id, f.name, f.data_type
        FROM nutrition.foods f
        WHERE f.search_vector @@ plainto_tsquery('english', $1)
           OR f.name % $1
        ORDER BY
            ts_rank(f.search_vector, plainto_tsquery('english', $1)) DESC,
            similarity(f.name, $1) DESC
        LIMIT 1
        "#,
    )
    .bind(term)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(|(fdc_id, name, data_type)| MatchedFood {
        fdc_id,
        name,
        data_type,
    }))
}

/// Pull every mapped nutrient for a food as amounts per 100 g.
pub async fn nutrients_per_100g(
    pool: &PgPool,
    fdc_id: i32,
) -> Result<Vec<(String, String, f64, bool)>, AppError> {
    let rows: Vec<(String, String, f64, bool)> = sqlx::query_as(
        r#"
        SELECT m.hk_identifier, n.unit_name, fn.amount, m.sparse
        FROM nutrition.food_nutrients fn
        JOIN nutrition.nutrients n ON n.id = fn.nutrient_id
        JOIN nutrition.nutrient_healthkit_map m ON m.nutrient_id = n.id
        WHERE fn.fdc_id = $1
        "#,
    )
    .bind(fdc_id)
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

pub async fn portions_for(pool: &PgPool, fdc_id: i32) -> Result<Vec<Portion>, AppError> {
    #[allow(clippy::type_complexity)] // sqlx row tuple
    let rows: Vec<(Option<f64>, Option<String>, Option<String>, f64)> = sqlx::query_as(
        r#"
        SELECT amount, portion_description, modifier, gram_weight
        FROM nutrition.food_portions
        WHERE fdc_id = $1
        "#,
    )
    .bind(fdc_id)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(
            |(amount, portion_description, modifier, gram_weight)| Portion {
                amount,
                portion_description,
                modifier,
                gram_weight,
            },
        )
        .collect())
}

/// Minimum full-text rank or trigram similarity for an iodine match. Tuned so
/// nonsense queries ("cod salad", "foo bar") return `None` instead of
/// inheriting the top-ranked row of a no-op query.
const IODINE_TS_RANK_FLOOR: f32 = 0.05;
const IODINE_SIMILARITY_FLOOR: f32 = 0.3;

/// Fuzzy-match a food name against the supplemental iodine table. Returns
/// mcg per 100 g when a match exists, otherwise `None`.
pub async fn iodine_supplemental(pool: &PgPool, food_name: &str) -> Result<Option<f64>, AppError> {
    let row: Option<(f64,)> = sqlx::query_as(
        r#"
        SELECT iodine_mcg_per_100g
        FROM nutrition.iodine_supplemental
        WHERE (
            search_vector @@ plainto_tsquery('english', $1)
            AND ts_rank(search_vector, plainto_tsquery('english', $1)) > $2
        )
        OR (
            name % $1
            AND similarity(name, $1) > $3
        )
        ORDER BY
            ts_rank(search_vector, plainto_tsquery('english', $1)) DESC,
            similarity(name, $1) DESC
        LIMIT 1
        "#,
    )
    .bind(food_name)
    .bind(IODINE_TS_RANK_FLOOR)
    .bind(IODINE_SIMILARITY_FLOOR)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(v,)| v))
}

/// Scale the per-100g amounts to the user's actual grams consumed.
pub fn scale_nutrients(
    per_100g: Vec<(String, String, f64, bool)>,
    grams: f64,
) -> Vec<NutrientValue> {
    let factor = grams / 100.0;
    per_100g
        .into_iter()
        .map(|(hk_identifier, unit, amount, sparse)| NutrientValue {
            hk_identifier,
            unit,
            amount: amount * factor,
            sparse,
        })
        .collect()
}
