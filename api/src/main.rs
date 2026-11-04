use self_sensored_api::{config, db, handlers, llm, nutrition, observability, routes};

use std::sync::Arc;

use axum::http::{HeaderMap, Request, Response};
use axum::routing::get;
use handlers::auth_handler::AppState;
use llm::ollama::OllamaClient;
use std::time::Duration;
use tower_http::catch_panic::CatchPanicLayer;
use tower_http::request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer};
use tower_http::trace::{MakeSpan, OnRequest, OnResponse, TraceLayer};
use tracing::Span;

#[derive(Clone, Copy)]
struct ApiTrace;

impl<B> MakeSpan<B> for ApiTrace {
    fn make_span(&mut self, request: &Request<B>) -> Span {
        let request_id = request
            .headers()
            .get("x-request-id")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        tracing::info_span!(
            "http",
            method = %request.method(),
            uri = %request.uri(),
            request_id = %request_id,
        )
    }
}

impl<B> OnRequest<B> for ApiTrace {
    fn on_request(&mut self, _request: &Request<B>, _span: &Span) {
        tracing::debug!("request received");
    }
}

impl<B> OnResponse<B> for ApiTrace {
    fn on_response(self, response: &Response<B>, latency: Duration, _span: &Span) {
        tracing::info!(
            status = %response.status(),
            latency_ms = latency.as_millis() as u64,
            "response"
        );
    }
}

// Narrow helper used by the tracing layer; keeping it here in case we want to
// log a safe subset of headers later without re-introducing the authorization
// leak the default TraceLayer has.
#[allow(dead_code)]
fn redacted_headers(headers: &HeaderMap) -> Vec<(&str, &str)> {
    headers
        .iter()
        .filter(|(name, _)| {
            let n = name.as_str();
            n != "authorization" && n != "cookie" && n != "proxy-authorization"
        })
        .filter_map(|(name, value)| value.to_str().ok().map(|v| (name.as_str(), v)))
        .collect()
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    let config = config::Config::from_env()?;
    observability::init_tracing(config.log_format);
    let metrics_handle = observability::install_metrics();

    let pool = db::init_pool(&config.database_url).await?;

    tracing::info!("connected to database");

    let llm = Arc::new(OllamaClient::new(
        config.ollama_api_key,
        config.ollama_base_url,
        config.ollama_model,
    ));

    let state = Arc::new(AppState {
        pool,
        jwt_secret: config.jwt_secret,
        llm,
        nutrition_cache: nutrition::cache::NutritionCache::new(),
    });

    // `/metrics` is unauthed and lives on the same port as the API. If that's
    // ever a concern, front the whole service with a reverse proxy that
    // exposes /metrics only to the scraper's subnet.
    let metrics_route = axum::Router::new().route(
        "/metrics",
        get({
            let handle = metrics_handle.clone();
            move || {
                let handle = handle.clone();
                async move { handle.render() }
            }
        }),
    );

    // Per-route body limits are set inside each router module. CORS is
    // intentionally absent — this service is consumed by a native iOS client.
    let app = routes::app_router(state)
        .merge(metrics_route)
        .layer(axum::middleware::from_fn(observability::track_metrics))
        .layer(
            TraceLayer::new_for_http()
                .make_span_with(ApiTrace)
                .on_request(ApiTrace)
                .on_response(ApiTrace),
        )
        .layer(PropagateRequestIdLayer::x_request_id())
        .layer(SetRequestIdLayer::x_request_id(MakeRequestUuid))
        .layer(CatchPanicLayer::new());

    let addr = format!("{}:{}", config.api_host, config.api_port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;

    tracing::info!("listening on {addr}");
    axum::serve(listener, app).await?;
    Ok(())
}
