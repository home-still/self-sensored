use std::sync::Arc;
use std::time::Duration;

use moka::future::Cache;
use sqlx::PgPool;

use crate::error::AppError;
use crate::models::meal::MatchedFood;

/// In-memory cache fronting the nutrition FTS query. Entries survive 24h and
/// the cache holds up to 10k distinct terms — plenty for the long tail of
/// "chicken breast", "brown rice", etc.
#[derive(Clone)]
pub struct NutritionCache {
    inner: Cache<String, Arc<Option<MatchedFood>>>,
}

impl NutritionCache {
    pub fn new() -> Self {
        Self {
            inner: Cache::builder()
                .max_capacity(10_000)
                .time_to_live(Duration::from_secs(24 * 60 * 60))
                .build(),
        }
    }

    /// Drop every cached entry. Used by the USDA importer after `--reset` so
    /// callers don't see stale `fdc_id` mappings for up to 24h.
    #[allow(dead_code)] // called from the importer library in Phase 3.3
    pub async fn invalidate_all(&self) {
        self.inner.invalidate_all();
        // moka queues invalidations; run pending tasks to finalize immediately.
        self.inner.run_pending_tasks().await;
    }

    /// Look up `term` through the cache. On miss, call `fetch` and memoize.
    pub async fn get_or_fetch<F, Fut>(
        &self,
        term: &str,
        fetch: F,
    ) -> Result<Option<MatchedFood>, AppError>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = Result<Option<MatchedFood>, AppError>>,
    {
        let key = normalize(term);
        if let Some(hit) = self.inner.get(&key).await {
            metrics::counter!("nutrition_cache_hits_total").increment(1);
            return Ok((*hit).clone());
        }
        metrics::counter!("nutrition_cache_misses_total").increment(1);
        let fetched = fetch().await?;
        self.inner.insert(key, Arc::new(fetched.clone())).await;
        Ok(fetched)
    }
}

impl Default for NutritionCache {
    fn default() -> Self {
        Self::new()
    }
}

fn normalize(term: &str) -> String {
    term.trim().to_ascii_lowercase()
}

/// Convenience: iterate search terms through the cache, hitting `pool` on miss.
pub async fn cached_best_match(
    cache: &NutritionCache,
    pool: &PgPool,
    search_terms: &[String],
) -> Result<Option<MatchedFood>, AppError> {
    for term in search_terms {
        let trimmed = term.trim();
        if trimmed.is_empty() {
            continue;
        }
        let hit = cache
            .get_or_fetch(trimmed, || async {
                super::lookup::best_match_for_term(pool, trimmed).await
            })
            .await?;
        if hit.is_some() {
            return Ok(hit);
        }
    }
    Ok(None)
}
