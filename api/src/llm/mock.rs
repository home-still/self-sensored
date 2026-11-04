//! In-process mock of `LlmClient` for tests.

use std::sync::Arc;

use async_trait::async_trait;
use tokio::sync::Mutex;

use crate::error::AppError;
use crate::llm::LlmClient;
use crate::models::meal::ParsedMeal;

type Handler = Arc<dyn Fn(&str) -> Result<ParsedMeal, AppError> + Send + Sync>;

/// Drop-in replacement for `OllamaClient`. Each test constructs a
/// `MockLlmClient::new(...)` with whatever response (or error) it wants.
///
/// The closure also has a side-effect hook exposing the last call — tests that
/// want to assert on the text the handler forwarded can inspect
/// [`last_prompt`](Self::last_prompt) after driving the handler.
pub struct MockLlmClient {
    handler: Handler,
    last_prompt: Mutex<Option<String>>,
}

impl MockLlmClient {
    pub fn new<F>(handler: F) -> Self
    where
        F: Fn(&str) -> Result<ParsedMeal, AppError> + Send + Sync + 'static,
    {
        Self {
            handler: Arc::new(handler),
            last_prompt: Mutex::new(None),
        }
    }

    pub async fn last_prompt(&self) -> Option<String> {
        self.last_prompt.lock().await.clone()
    }
}

#[async_trait]
impl LlmClient for MockLlmClient {
    async fn parse_meal(&self, text: &str) -> Result<ParsedMeal, AppError> {
        *self.last_prompt.lock().await = Some(text.to_string());
        (self.handler)(text)
    }
}
