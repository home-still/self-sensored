//! Tracing + Prometheus wiring for the API.
//!
//! Call `init_tracing(format)` once at startup before any `tracing::*!` macros
//! fire. Call `install_metrics()` to register the Prometheus exporter and
//! obtain a handle for the `/metrics` route. Finally, `metrics_layer()` is a
//! tower layer that records per-request `http_requests_total` and
//! `http_request_duration_seconds` with a low-cardinality `route` label.

use std::sync::Arc;
use std::time::Instant;

use axum::extract::{MatchedPath, Request};
use axum::middleware::Next;
use axum::response::Response;
use metrics_exporter_prometheus::{PrometheusBuilder, PrometheusHandle};
use tracing_subscriber::EnvFilter;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;

use crate::config::LogFormat;

pub fn init_tracing(format: LogFormat) {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    match format {
        LogFormat::Pretty => {
            tracing_subscriber::registry()
                .with(filter)
                .with(tracing_subscriber::fmt::layer())
                .init();
        }
        LogFormat::Json => {
            tracing_subscriber::registry()
                .with(filter)
                .with(
                    tracing_subscriber::fmt::layer()
                        .json()
                        .with_current_span(true)
                        .with_span_list(false),
                )
                .init();
        }
    }
}

pub fn install_metrics() -> Arc<PrometheusHandle> {
    let handle = PrometheusBuilder::new()
        .set_buckets_for_metric(
            metrics_exporter_prometheus::Matcher::Prefix("http_request_duration_seconds".into()),
            &[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0],
        )
        .expect("set http duration buckets")
        .set_buckets_for_metric(
            metrics_exporter_prometheus::Matcher::Prefix("meal_parse_latency_seconds".into()),
            &[0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 45.0],
        )
        .expect("set meal_parse buckets")
        .install_recorder()
        .expect("install prometheus recorder");
    Arc::new(handle)
}

/// Axum middleware that records `http_requests_total` + `http_request_duration_seconds`
/// labelled by method, matched-route pattern (e.g. `/api/meals/{id}`), and status.
pub async fn track_metrics(req: Request, next: Next) -> Response {
    let method = req.method().to_string();
    let route = req
        .extensions()
        .get::<MatchedPath>()
        .map(|m| m.as_str().to_owned())
        .unwrap_or_else(|| "unknown".to_owned());

    let start = Instant::now();
    let response = next.run(req).await;
    let latency = start.elapsed().as_secs_f64();
    let status = response.status().as_u16().to_string();

    metrics::counter!(
        "http_requests_total",
        "method" => method.clone(),
        "route" => route.clone(),
        "status" => status.clone(),
    )
    .increment(1);
    metrics::histogram!(
        "http_request_duration_seconds",
        "method" => method,
        "route" => route,
    )
    .record(latency);

    response
}
