use std::sync::Arc;

use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::*;
use rmcp::service::RequestContext;
use rmcp::{ErrorData as McpError, RoleServer, ServerHandler, tool, tool_handler, tool_router};
use serde_json::json;
use sqlx::PgPool;

use crate::config::Config;
use crate::resources;
use crate::tool_query::{self, QueryArgs};


#[derive(Clone)]
pub struct SelfSensoredMcp {
    pool: PgPool,
    cfg: Arc<Config>,
    #[allow(dead_code)]
    tool_router: ToolRouter<SelfSensoredMcp>,
}

#[tool_router]
impl SelfSensoredMcp {
    pub fn new(pool: PgPool, cfg: Config) -> Self {
        Self {
            pool,
            cfg: Arc::new(cfg),
            tool_router: Self::tool_router(),
        }
    }

    #[tool(description = "Run a single read-only SQL statement against the Self Sensored Postgres database and return rows as JSON.\n\n*** READ THIS FIRST *** The authenticated user's UUID is bound as $1, BUT the server does NOT enforce that your query uses it. If you omit `WHERE user_id = $1` on a user-scoped table, you will get other users' rows. Always include the filter.\n\nSAFETY: Only SELECT (including WITH … SELECT), EXPLAIN, and SHOW are allowed. Every query runs in a READ ONLY transaction with a statement_timeout. Input >8KB, >64 params, or referencing blocked functions (pg_read_file, dblink, pg_sleep, …), objects (pg_authid, pg_largeobject, public.raw_ingest, public.users, public._sqlx_migrations, …), or the users.password_hash column is rejected. Use the `public.users_safe` view when you need id/email.\n\nUSER SCOPING: $1 is your UUID. Put `WHERE user_id = $1` on every user-scoped table. Additional bind params start at $2 via `params`. For information_schema / pg_catalog exploration set `bind_user_id: false`.\n\nKEY TABLES (user-scoped unless noted): public.users_safe (id, email, created_at); public.devices; public.health_samples — hypertable, cols sample_type, start_date, end_date, quantity_value, quantity_unit, category_value, correlation_id, source_name, hk_uuid, metadata JSONB, synced_at; public.workouts — hypertable, cols activity_type, activity_name, start_date, end_date, duration_seconds, total_energy_burned_kcal, total_distance_m, total_swimming_stroke_count; public.workout_route_points — hypertable, cols timestamp, latitude, longitude, altitude, speed, course; public.user_characteristics; public.activity_summaries; nutrition.meal_logs (NOTE schema: `nutrition`, not public — cols raw_text, meal_type, parsed_items JSONB, matched_foods JSONB, final_nutrients JSONB, sync_identifier, created_at, updated_at); public.sync_sessions; nutrition.foods / food_nutrients / food_portions / nutrients / measure_units / nutrient_healthkit_map / iodine_supplemental (USDA FDC — NOT user-scoped).\n\nPITFALLS: `SELECT *` on health_samples can blow the 1 MB MCP transport limit because of the JSONB `metadata` column — always project the columns you need. Integer `activity_type` on workouts is opaque; the text `activity_name` column is usually what you want. Aggregations over health_samples / workouts without a time window filter will hit the 5s statement timeout on large tables; always bound with `AND start_date >= now() - interval '…'`.\n\nBEFORE WRITING a non-trivial query, call the `get_schema` tool for the full column lists and `get_examples` for 25+ analytic query templates. (These mirror MCP resources self-sensored://schema/overview.md and self-sensored://examples/queries.sql, which work in Claude Desktop but not claude.ai.)\n\nRESPONSE SHAPE: { columns: [...], rows: [[...]], row_count, truncated, elapsed_ms }.")]
    async fn query(
        &self,
        Parameters(args): Parameters<QueryArgs>,
    ) -> Result<CallToolResult, McpError> {
        match tool_query::execute(&self.pool, &self.cfg, args).await {
            Ok(result) => {
                let payload =
                    serde_json::to_string(&result).unwrap_or_else(|e| format!("{{\"serialize_error\":\"{e}\"}}"));
                Ok(CallToolResult::success(vec![Content::text(payload)]))
            }
            Err(err) => {
                let payload = json!({ "error": err.code, "message": err.message }).to_string();
                Ok(CallToolResult::error(vec![Content::text(payload)]))
            }
        }
    }

    #[tool(description = "Return the Self Sensored schema documentation — every table, column, hypertable partition key, view, and blocked-object note. Mirrors MCP resource self-sensored://schema/overview.md for clients (e.g. claude.ai web) that don't expose MCP resources. Call this before writing non-trivial queries.")]
    async fn get_schema(&self) -> Result<CallToolResult, McpError> {
        Ok(CallToolResult::success(vec![Content::text(
            resources::SCHEMA_OVERVIEW,
        )]))
    }

    #[tool(description = "Return a curated library of ~25 analytic example queries against the Self Sensored schema (steps, heart rate, sleep, workouts, meals, nutrition, body, correlational, operational). Mirrors MCP resource self-sensored://examples/queries.sql for clients that don't expose MCP resources. Use these as starting templates — copy one and adapt the time window or sample_type.")]
    async fn get_examples(&self) -> Result<CallToolResult, McpError> {
        Ok(CallToolResult::success(vec![Content::text(
            resources::EXAMPLES_QUERIES,
        )]))
    }
}

#[tool_handler]
impl ServerHandler for SelfSensoredMcp {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(
            ServerCapabilities::builder()
                .enable_resources()
                .enable_tools()
                .build(),
        )
        .with_server_info(Implementation::from_build_env())
        .with_protocol_version(ProtocolVersion::V_2024_11_05)
        .with_instructions(
            "Self Sensored SQL MCP. Single tool `query` runs read-only SQL against the \
             Self Sensored TimescaleDB. Before writing non-trivial queries, read the \
             resources `self-sensored://schema/overview.md` and \
             `self-sensored://examples/queries.sql`. Always filter user-scoped tables \
             with `WHERE user_id = $1`."
                .to_string(),
        )
    }

    async fn list_resources(
        &self,
        _request: Option<PaginatedRequestParams>,
        _: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, McpError> {
        Ok(ListResourcesResult {
            resources: vec![
                RawResource::new(resources::SCHEMA_OVERVIEW_URI, "Self Sensored schema overview")
                    .no_annotation(),
                RawResource::new(resources::EXAMPLES_QUERIES_URI, "Self Sensored example queries")
                    .no_annotation(),
                RawResource::new(resources::EXAMPLES_RECIPES_URI, "Self Sensored query recipes")
                    .no_annotation(),
            ],
            next_cursor: None,
            meta: None,
        })
    }

    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        _: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResult, McpError> {
        let uri = request.uri.clone();
        match resources::read(&uri) {
            Some((_mime, body)) => Ok(ReadResourceResult::new(vec![ResourceContents::text(
                body, uri,
            )])),
            None => Err(McpError::resource_not_found(
                "resource_not_found",
                Some(json!({ "uri": uri })),
            )),
        }
    }

    async fn list_resource_templates(
        &self,
        _request: Option<PaginatedRequestParams>,
        _: RequestContext<RoleServer>,
    ) -> Result<ListResourceTemplatesResult, McpError> {
        Ok(ListResourceTemplatesResult {
            next_cursor: None,
            resource_templates: Vec::new(),
            meta: None,
        })
    }
}
