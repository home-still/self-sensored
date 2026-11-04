pub mod mock;
pub mod ollama;
pub mod prompt;

use async_trait::async_trait;

use crate::error::AppError;
use crate::models::meal::ParsedMeal;

#[async_trait]
pub trait LlmClient: Send + Sync {
    async fn parse_meal(&self, text: &str) -> Result<ParsedMeal, AppError>;
}
