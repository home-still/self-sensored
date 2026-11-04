use std::time::Duration;

use async_trait::async_trait;
use futures_util::StreamExt;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::error::AppError;
use crate::llm::LlmClient;
use crate::llm::prompt::{SYSTEM_PROMPT, meal_json_schema, wrap_user_meal};
use crate::models::meal::ParsedMeal;

/// Ollama Cloud documents ~10-15s cold starts; 45s covers cold + one completion.
const LLM_REQUEST_TIMEOUT: Duration = Duration::from_secs(45);
/// Upper bound on model output tokens. Guards against a crafted prompt that
/// tries to drain the quota by eliciting huge responses.
const LLM_MAX_TOKENS: u32 = 2048;
/// Hard cap on bytes read from a non-2xx response body before logging.
const MAX_ERROR_BODY_BYTES: usize = 4 * 1024;
/// Upper bound on items returned from the model. Anything larger is treated as
/// abuse — a realistic meal has well under 20 distinct foods.
const MAX_ITEMS: usize = 20;
/// Upper bound on any parsed string field (food_name, unit, preparation_method,
/// database_search_terms). Matches the schema's maxLength.
const MAX_STRING_LEN: usize = 200;

pub struct OllamaClient {
    http: Client,
    base_url: String,
    model: String,
    api_key: String,
}

impl OllamaClient {
    pub fn new(api_key: String, base_url: String, model: String) -> Self {
        let http = Client::builder()
            .timeout(LLM_REQUEST_TIMEOUT)
            .build()
            .expect("failed to build reqwest client");
        Self {
            http,
            base_url,
            model,
            api_key,
        }
    }
}

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: Vec<ChatMessage<'a>>,
    response_format: serde_json::Value,
    temperature: f32,
    max_tokens: u32,
}

#[derive(Serialize)]
struct ChatMessage<'a> {
    role: &'a str,
    content: &'a str,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatResponseMessage,
}

#[derive(Deserialize)]
struct ChatResponseMessage {
    content: String,
}

#[async_trait]
impl LlmClient for OllamaClient {
    async fn parse_meal(&self, text: &str) -> Result<ParsedMeal, AppError> {
        let wrapped = wrap_user_meal(text);
        let body = ChatRequest {
            model: &self.model,
            messages: vec![
                ChatMessage {
                    role: "system",
                    content: SYSTEM_PROMPT,
                },
                ChatMessage {
                    role: "user",
                    content: &wrapped,
                },
            ],
            response_format: json!({
                "type": "json_schema",
                "json_schema": {
                    "name": "parsed_meal",
                    "strict": true,
                    "schema": meal_json_schema()
                }
            }),
            temperature: 0.0,
            max_tokens: LLM_MAX_TOKENS,
        };

        let resp = self
            .http
            .post(format!("{}/chat/completions", self.base_url))
            .bearer_auth(&self.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|e| {
                tracing::warn!(error = %e, "LLM request failed");
                let kind = if e.is_timeout() { "timeout" } else { "network" };
                metrics::counter!("llm_errors_total", "kind" => kind).increment(1);
                AppError::Internal("LLM request failed".into())
            })?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = read_body_capped(resp, MAX_ERROR_BODY_BYTES).await;
            tracing::warn!(%status, body = %truncate(&body, 500), "LLM non-2xx response");
            metrics::counter!("llm_errors_total", "kind" => "upstream").increment(1);
            return Err(AppError::Internal("LLM upstream error".into()));
        }

        let parsed: ChatResponse = resp.json().await.map_err(|e| {
            tracing::warn!(error = %e, "LLM response envelope parse failed");
            metrics::counter!("llm_errors_total", "kind" => "schema").increment(1);
            AppError::Internal("LLM response envelope parse failed".into())
        })?;

        let content = parsed
            .choices
            .into_iter()
            .next()
            .ok_or_else(|| {
                metrics::counter!("llm_errors_total", "kind" => "schema").increment(1);
                AppError::BadRequest("meal parse failed".into())
            })?
            .message
            .content;

        let parsed_meal: ParsedMeal = serde_json::from_str(&content).map_err(|e| {
            tracing::warn!(error = %e, body = %truncate(&content, 500), "LLM schema violation");
            metrics::counter!("llm_errors_total", "kind" => "schema").increment(1);
            AppError::BadRequest("meal parse failed".into())
        })?;

        validate_parsed_meal(&parsed_meal).inspect_err(|_| {
            metrics::counter!("llm_errors_total", "kind" => "schema").increment(1);
        })?;
        Ok(parsed_meal)
    }
}

/// Defensive post-parse validation: the Ollama Cloud `strict: true` mode is
/// best-effort. Catch semantically bad JSON here and convert to a 400 so we
/// never hand malformed data to the nutrition layer.
fn validate_parsed_meal(meal: &ParsedMeal) -> Result<(), AppError> {
    if meal.items.is_empty() || meal.items.len() > MAX_ITEMS {
        return Err(AppError::BadRequest("meal parse failed".into()));
    }
    for item in &meal.items {
        if !item.quantity.is_finite() || item.quantity <= 0.0 {
            return Err(AppError::BadRequest("meal parse failed".into()));
        }
        if !is_clean_str(&item.food_name) || item.food_name.len() > MAX_STRING_LEN {
            return Err(AppError::BadRequest("meal parse failed".into()));
        }
        if !is_clean_str(&item.unit) || item.unit.len() > 50 {
            return Err(AppError::BadRequest("meal parse failed".into()));
        }
        if let Some(prep) = item.preparation_method.as_deref()
            && (!is_clean_str(prep) || prep.len() > MAX_STRING_LEN)
        {
            return Err(AppError::BadRequest("meal parse failed".into()));
        }
        if item.database_search_terms.is_empty() || item.database_search_terms.len() > 10 {
            return Err(AppError::BadRequest("meal parse failed".into()));
        }
        for term in &item.database_search_terms {
            if !is_clean_str(term) || term.len() > MAX_STRING_LEN {
                return Err(AppError::BadRequest("meal parse failed".into()));
            }
        }
    }
    Ok(())
}

/// Reject strings with any ASCII control characters (including newlines) or
/// a leading/trailing blank, which are signs of a structured-output bypass
/// attempt.
fn is_clean_str(s: &str) -> bool {
    if s.is_empty() {
        return false;
    }
    if s.trim().len() != s.len() {
        return false;
    }
    !s.chars().any(|c| c.is_control())
}

/// Read at most `cap` bytes from a response body. A misbehaving upstream can
/// ship a multi-MB error page; we never want the whole thing in memory just
/// to log a truncated prefix.
async fn read_body_capped(resp: reqwest::Response, cap: usize) -> String {
    let mut buf: Vec<u8> = Vec::with_capacity(cap.min(1024));
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        match chunk {
            Ok(bytes) => {
                let remaining = cap.saturating_sub(buf.len());
                if remaining == 0 {
                    break;
                }
                let take = bytes.len().min(remaining);
                buf.extend_from_slice(&bytes[..take]);
                if buf.len() >= cap {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    String::from_utf8_lossy(&buf).into_owned()
}

/// Truncate a string to at most `max` bytes on a char boundary for safe logging.
fn truncate(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn envelope(content: &str) -> serde_json::Value {
        json!({ "choices": [{ "message": { "content": content } }] })
    }

    async fn client_for(server: &MockServer) -> OllamaClient {
        OllamaClient::new("test-key".into(), server.uri(), "gpt-oss:120b-cloud".into())
    }

    #[tokio::test]
    async fn parses_structured_meal() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(envelope(
                "{\"items\":[{\"food_name\":\"grilled chicken breast\",\"quantity\":6,\"unit\":\"oz\",\"preparation_method\":\"grilled\",\"confidence\":\"high\",\"database_search_terms\":[\"grilled chicken breast\",\"chicken breast\",\"chicken\"]}]}",
            )))
            .mount(&server)
            .await;

        let client = client_for(&server).await;
        let meal = client.parse_meal("6oz grilled chicken").await.unwrap();
        assert_eq!(meal.items.len(), 1);
        assert_eq!(meal.items[0].food_name, "grilled chicken breast");
        assert!((meal.items[0].quantity - 6.0).abs() < f32::EPSILON);
    }

    #[tokio::test]
    async fn rejects_upstream_500() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(500).set_body_string("upstream boom"))
            .mount(&server)
            .await;
        let client = client_for(&server).await;
        let err = client.parse_meal("burger").await.unwrap_err();
        matches!(err, AppError::Internal(_));
    }

    #[tokio::test]
    async fn rejects_malformed_json() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(envelope("not json")))
            .mount(&server)
            .await;
        let client = client_for(&server).await;
        let err = client.parse_meal("burger").await.unwrap_err();
        matches!(err, AppError::BadRequest(_));
    }

    #[tokio::test]
    async fn rejects_schema_valid_but_empty_items() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(envelope("{\"items\":[]}")))
            .mount(&server)
            .await;
        let client = client_for(&server).await;
        let err = client.parse_meal("burger").await.unwrap_err();
        matches!(err, AppError::BadRequest(_));
    }

    #[tokio::test]
    async fn rejects_zero_quantity() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(envelope(
                "{\"items\":[{\"food_name\":\"x\",\"quantity\":0,\"unit\":\"g\",\"confidence\":\"high\",\"database_search_terms\":[\"x\"]}]}",
            )))
            .mount(&server)
            .await;
        let client = client_for(&server).await;
        let err = client.parse_meal("x").await.unwrap_err();
        matches!(err, AppError::BadRequest(_));
    }

    #[tokio::test]
    async fn rejects_control_chars_in_food_name() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(envelope(
                "{\"items\":[{\"food_name\":\"bad\\nname\",\"quantity\":1,\"unit\":\"g\",\"confidence\":\"high\",\"database_search_terms\":[\"x\"]}]}",
            )))
            .mount(&server)
            .await;
        let client = client_for(&server).await;
        let err = client.parse_meal("x").await.unwrap_err();
        matches!(err, AppError::BadRequest(_));
    }

    #[tokio::test]
    async fn rejects_http_429() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(429).set_body_string("rate limited"))
            .mount(&server)
            .await;
        let client = client_for(&server).await;
        let err = client.parse_meal("x").await.unwrap_err();
        matches!(err, AppError::Internal(_));
    }

    #[tokio::test]
    async fn rejects_http_401_bad_api_key() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(401).set_body_string("bad key"))
            .mount(&server)
            .await;
        let client = client_for(&server).await;
        let err = client.parse_meal("x").await.unwrap_err();
        matches!(err, AppError::Internal(_));
    }

    #[tokio::test]
    async fn rejects_empty_choices() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "choices": [] })))
            .mount(&server)
            .await;
        let client = client_for(&server).await;
        let err = client.parse_meal("x").await.unwrap_err();
        matches!(err, AppError::BadRequest(_));
    }

    #[tokio::test]
    async fn rejects_oversized_items_array() {
        let mut items = String::from("[");
        for i in 0..21 {
            if i > 0 {
                items.push(',');
            }
            items.push_str(
                "{\"food_name\":\"x\",\"quantity\":1,\"unit\":\"g\",\"confidence\":\"high\",\"database_search_terms\":[\"x\"]}",
            );
        }
        items.push(']');
        let content = format!("{{\"items\":{items}}}");

        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(envelope(&content)))
            .mount(&server)
            .await;
        let client = client_for(&server).await;
        let err = client.parse_meal("x").await.unwrap_err();
        matches!(err, AppError::BadRequest(_));
    }
}
