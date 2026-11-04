use std::time::Instant;

use bigdecimal::BigDecimal;
use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sqlx::postgres::{PgArguments, PgRow};
use sqlx::query::Query;
use sqlx::{Column, PgPool, Postgres, Row, TypeInfo, ValueRef, types::Json};
use uuid::Uuid;

use crate::config::Config;
use crate::sql_guard::{self, GuardError, MAX_PARAMS};

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct QueryArgs {
    /// A single read-only SQL statement (SELECT, WITH … SELECT, EXPLAIN, or SHOW).
    /// Your query MUST filter by the authenticated user's UUID, which is
    /// automatically bound as $1. Use $2, $3, … for additional parameters.
    pub sql: String,

    /// Optional positional parameters for $2, $3, … Accepts null, bool, number,
    /// string (including ISO-8601 timestamps and UUIDs), or arrays/objects for
    /// JSONB columns. Maximum 64 parameters.
    #[serde(default)]
    pub params: Vec<Value>,

    /// Maximum rows to return. Capped server-side by MCP_MAX_ROWS. Defaults to
    /// the server's configured cap.
    #[serde(default)]
    pub limit: Option<u32>,

    /// When true (default), the authenticated user's UUID is prepended to
    /// params as $1 and the query is expected to filter on it. Set false only
    /// for schema-introspection queries against information_schema/pg_catalog.
    #[serde(default = "default_true")]
    pub bind_user_id: bool,
}

fn default_true() -> bool { true }

#[derive(Debug, Serialize)]
pub struct QueryResult {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Value>>,
    pub row_count: usize,
    pub truncated: bool,
    pub elapsed_ms: u128,
}

#[derive(Debug, Serialize)]
pub struct QueryError {
    pub code: &'static str,
    pub message: String,
}

pub async fn execute(pool: &PgPool, cfg: &Config, args: QueryArgs) -> Result<QueryResult, QueryError> {
    if args.params.len() > MAX_PARAMS {
        return Err(QueryError {
            code: "input_too_large",
            message: format!("params length {} exceeds max {}", args.params.len(), MAX_PARAMS),
        });
    }

    let guarded = sql_guard::guard(&args.sql).map_err(|e| match e {
        GuardError::Parse(m) => QueryError { code: "parse_error", message: m },
        GuardError::InputTooLarge(m) => QueryError { code: "input_too_large", message: m },
        GuardError::MultiStatement(m) => QueryError { code: "multi_statement", message: m },
        GuardError::NotReadOnly(m) => QueryError { code: "not_read_only", message: m },
        GuardError::ForbiddenObject(m) => QueryError { code: "forbidden_object", message: m },
        GuardError::ForbiddenFunction(m) => QueryError { code: "forbidden_function", message: m },
    })?;
    let _ = guarded;

    let effective_limit = args
        .limit
        .map(|l| l.min(cfg.max_rows))
        .unwrap_or(cfg.max_rows);
    let fetch_cap = effective_limit.saturating_add(1) as i64;

    let start = Instant::now();

    let mut tx = pool.begin().await.map_err(db_err)?;

    sqlx::query("SET TRANSACTION READ ONLY")
        .execute(&mut *tx)
        .await
        .map_err(db_err)?;

    let timeout_stmt = format!("SET LOCAL statement_timeout = {}", cfg.statement_timeout_ms);
    sqlx::query(&timeout_stmt)
        .execute(&mut *tx)
        .await
        .map_err(db_err)?;

    let mut q: Query<'_, Postgres, PgArguments> = sqlx::query(&args.sql);

    if args.bind_user_id {
        q = q.bind(cfg.user_id);
    }
    for p in &args.params {
        q = bind_value(q, p)?;
    }

    let all_rows = q.fetch_all(&mut *tx).await.map_err(db_err)?;

    tx.rollback().await.map_err(db_err)?;

    let mut truncated = all_rows.len() as i64 > effective_limit as i64;
    let rows_slice: &[PgRow] = if truncated {
        &all_rows[..effective_limit as usize]
    } else {
        &all_rows[..]
    };
    let _ = fetch_cap;

    let columns: Vec<String> = rows_slice
        .first()
        .map(|r| r.columns().iter().map(|c| c.name().to_string()).collect())
        .unwrap_or_else(Vec::new);

    let mut out_rows = Vec::with_capacity(rows_slice.len());
    let mut accumulated_bytes: usize = 0;
    for row in rows_slice {
        let mut values = Vec::with_capacity(row.columns().len());
        for (i, col) in row.columns().iter().enumerate() {
            values.push(decode_column(row, i, col.type_info().name()));
        }
        // Byte cap on the full serialized response: MCP's JSON-RPC transport
        // has a ~1 MB limit, and a `SELECT *` that pulls wide JSONB columns
        // will overflow it silently. Bail once the accumulated row bytes
        // would cross the configured cap, and mark the result truncated.
        let row_bytes = serde_json::to_string(&values).map(|s| s.len() + 2).unwrap_or(0);
        if !out_rows.is_empty() && accumulated_bytes + row_bytes > cfg.max_response_bytes {
            truncated = true;
            break;
        }
        accumulated_bytes += row_bytes;
        out_rows.push(values);
    }

    let row_count = out_rows.len();
    Ok(QueryResult {
        columns,
        rows: out_rows,
        row_count,
        truncated,
        elapsed_ms: start.elapsed().as_millis(),
    })
}

fn bind_value<'q>(
    q: Query<'q, Postgres, PgArguments>,
    v: &'q Value,
) -> Result<Query<'q, Postgres, PgArguments>, QueryError> {
    Ok(match v {
        Value::Null => q.bind(Option::<i64>::None),
        Value::Bool(b) => q.bind(*b),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                q.bind(i)
            } else if let Some(f) = n.as_f64() {
                q.bind(f)
            } else {
                return Err(QueryError {
                    code: "parse_error",
                    message: format!("unsupported numeric parameter: {n}"),
                });
            }
        }
        Value::String(s) => {
            if let Ok(u) = Uuid::parse_str(s) {
                q.bind(u)
            } else if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
                q.bind(dt.with_timezone(&Utc))
            } else {
                q.bind(s.clone())
            }
        }
        Value::Array(_) | Value::Object(_) => q.bind(Json(v.clone())),
    })
}

fn decode_column(row: &PgRow, idx: usize, type_name: &str) -> Value {
    if let Ok(raw) = row.try_get_raw(idx) {
        if raw.is_null() {
            return Value::Null;
        }
    } else {
        return Value::Null;
    }

    match type_name {
        "BOOL" => row.try_get::<bool, _>(idx).map(Value::Bool).unwrap_or(Value::Null),
        "INT2" => row
            .try_get::<i16, _>(idx)
            .map(|v| json!(v))
            .unwrap_or(Value::Null),
        "INT4" => row
            .try_get::<i32, _>(idx)
            .map(|v| json!(v))
            .unwrap_or(Value::Null),
        "INT8" => row
            .try_get::<i64, _>(idx)
            .map(|v| json!(v))
            .unwrap_or(Value::Null),
        "FLOAT4" => row
            .try_get::<f32, _>(idx)
            .map(|v| json!(v))
            .unwrap_or(Value::Null),
        "FLOAT8" => row
            .try_get::<f64, _>(idx)
            .map(|v| json!(v))
            .unwrap_or(Value::Null),
        "NUMERIC" => row
            .try_get::<BigDecimal, _>(idx)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or(Value::Null),
        "TEXT" | "VARCHAR" | "BPCHAR" | "NAME" | "CITEXT" => row
            .try_get::<String, _>(idx)
            .map(Value::String)
            .unwrap_or(Value::Null),
        "UUID" => row
            .try_get::<Uuid, _>(idx)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or(Value::Null),
        "TIMESTAMPTZ" => row
            .try_get::<DateTime<Utc>, _>(idx)
            .map(|v| Value::String(v.to_rfc3339()))
            .unwrap_or(Value::Null),
        "TIMESTAMP" => row
            .try_get::<NaiveDateTime, _>(idx)
            .map(|v| Value::String(v.format("%Y-%m-%dT%H:%M:%S%.f").to_string()))
            .unwrap_or(Value::Null),
        "DATE" => row
            .try_get::<NaiveDate, _>(idx)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or(Value::Null),
        "TIME" => row
            .try_get::<NaiveTime, _>(idx)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or(Value::Null),
        "JSON" | "JSONB" => row
            .try_get::<Json<Value>, _>(idx)
            .map(|v| v.0)
            .unwrap_or(Value::Null),
        "BYTEA" => row
            .try_get::<Vec<u8>, _>(idx)
            .map(|v| Value::String(format!("\\x{}", hex(&v))))
            .unwrap_or(Value::Null),
        other => {
            // Fallback: try as text, then report the type name.
            if let Ok(s) = row.try_get::<String, _>(idx) {
                Value::String(s)
            } else {
                let mut obj = Map::new();
                obj.insert("unsupported_pg_type".to_string(), Value::String(other.to_string()));
                Value::Object(obj)
            }
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn db_err(e: sqlx::Error) -> QueryError {
    let msg = match &e {
        sqlx::Error::Database(db) => {
            let code = db.code().unwrap_or_default();
            let kind = match code.as_ref() {
                "57014" => "timeout",
                "25006" | "25008" => "not_read_only",
                _ => "db_error",
            };
            return QueryError {
                code: match kind {
                    "timeout" => "timeout",
                    "not_read_only" => "not_read_only",
                    _ => "db_error",
                },
                message: sanitize(db.message()),
            };
        }
        sqlx::Error::PoolTimedOut => "database pool timed out acquiring connection".to_string(),
        sqlx::Error::Io(_) => "database i/o error".to_string(),
        sqlx::Error::RowNotFound => "row not found".to_string(),
        other => format!("database error: {}", sanitize(&other.to_string())),
    };
    QueryError { code: "db_error", message: msg }
}

fn sanitize(msg: &str) -> String {
    let truncated: String = msg.chars().take(400).collect();
    truncated
        .replace('\n', " ")
        .replace('\r', " ")
        .trim()
        .to_string()
}
