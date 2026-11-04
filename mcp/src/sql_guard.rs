use std::ops::ControlFlow;

use sqlparser::ast::{Expr, ObjectName, Statement, Visit, Visitor};
use sqlparser::dialect::PostgreSqlDialect;
use sqlparser::parser::Parser;

#[derive(Debug, thiserror::Error)]
pub enum GuardError {
    #[error("parse_error: {0}")]
    Parse(String),
    #[error("input_too_large: {0}")]
    InputTooLarge(String),
    #[error("multi_statement: {0}")]
    MultiStatement(String),
    #[error("not_read_only: {0}")]
    NotReadOnly(String),
    #[error("forbidden_object: {0}")]
    ForbiddenObject(String),
    #[error("forbidden_function: {0}")]
    ForbiddenFunction(String),
}

pub const MAX_SQL_BYTES: usize = 8 * 1024;
pub const MAX_PARAMS: usize = 64;

const FORBIDDEN_FUNCTIONS: &[&str] = &[
    "pg_read_file",
    "pg_read_binary_file",
    "pg_read_server_files",
    "pg_ls_dir",
    "pg_ls_logdir",
    "pg_ls_waldir",
    "pg_stat_file",
    "lo_import",
    "lo_export",
    "dblink",
    "dblink_exec",
    "dblink_connect",
    "dblink_disconnect",
    "copy_program",
    "pg_write_server_files",
    "pg_reload_conf",
    "pg_terminate_backend",
    "pg_cancel_backend",
    "pg_sleep",
    "pg_sleep_for",
    "pg_sleep_until",
    "pg_notify",
    "pg_advisory_lock",
    "pg_advisory_unlock",
    "pg_advisory_xact_lock",
];

const FORBIDDEN_OBJECT_PREFIXES: &[&str] = &[
    "pg_largeobject",
    "pg_authid",
    "pg_shadow",
    "pg_user_mappings",
    "pg_statistic",
    // self-sensored-specific: the raw_ingest table archives unparsed sync
    // payloads, and `users` exposes password_hash under SELECT *. Use the
    // `users_safe` view for user info.
    "users",
    "raw_ingest",
    // Internal migration tracking — of no analytic value.
    "_sqlx_migrations",
];

const FORBIDDEN_COLUMN_IDENTS: &[&str] = &[
    "password_hash",
];

#[derive(Debug)]
pub struct Guarded {
    #[allow(dead_code)]
    pub statement: Statement,
}

pub fn guard(sql: &str) -> Result<Guarded, GuardError> {
    if sql.len() > MAX_SQL_BYTES {
        return Err(GuardError::InputTooLarge(format!(
            "sql is {} bytes, max {}",
            sql.len(),
            MAX_SQL_BYTES
        )));
    }

    let dialect = PostgreSqlDialect {};
    let mut statements = Parser::parse_sql(&dialect, sql).map_err(|e| GuardError::Parse(e.to_string()))?;

    if statements.len() != 1 {
        return Err(GuardError::MultiStatement(format!(
            "exactly one statement required, got {}",
            statements.len()
        )));
    }

    let stmt = statements.remove(0);

    classify_top_level(&stmt)?;

    let mut visitor = GuardVisitor::default();
    let _ = stmt.visit(&mut visitor);
    if let Some(err) = visitor.error {
        return Err(err);
    }

    Ok(Guarded { statement: stmt })
}

fn classify_top_level(stmt: &Statement) -> Result<(), GuardError> {
    match stmt {
        Statement::Query(_) | Statement::Explain { .. } | Statement::ExplainTable { .. } => Ok(()),
        Statement::ShowVariable { .. }
        | Statement::ShowVariables { .. }
        | Statement::ShowColumns { .. }
        | Statement::ShowTables { .. }
        | Statement::ShowCreate { .. }
        | Statement::ShowFunctions { .. } => Ok(()),
        other => Err(GuardError::NotReadOnly(format!(
            "disallowed top-level statement: {}",
            statement_kind(other)
        ))),
    }
}

fn statement_kind(stmt: &Statement) -> &'static str {
    match stmt {
        Statement::Insert(_) => "INSERT",
        Statement::Update { .. } => "UPDATE",
        Statement::Delete(_) => "DELETE",
        Statement::Merge { .. } => "MERGE",
        Statement::Truncate { .. } => "TRUNCATE",
        Statement::Drop { .. } => "DROP",
        Statement::CreateTable(_) | Statement::CreateView { .. } | Statement::CreateSchema { .. } => "CREATE",
        Statement::CreateIndex(_) => "CREATE INDEX",
        Statement::CreateFunction(_) => "CREATE FUNCTION",
        Statement::CreateProcedure { .. } => "CREATE PROCEDURE",
        Statement::CreateRole { .. } => "CREATE ROLE",
        Statement::Grant { .. } => "GRANT",
        Statement::Revoke { .. } => "REVOKE",
        Statement::AlterTable { .. } | Statement::AlterIndex { .. } | Statement::AlterView { .. } => "ALTER",
        Statement::Copy { .. } => "COPY",
        Statement::Set(_) => "SET",
        Statement::Call(_) => "CALL",
        Statement::Prepare { .. } => "PREPARE",
        Statement::Execute { .. } => "EXECUTE",
        Statement::NOTIFY { .. } => "NOTIFY",
        Statement::LISTEN { .. } => "LISTEN",
        Statement::UNLISTEN { .. } => "UNLISTEN",
        Statement::StartTransaction { .. } | Statement::Commit { .. } | Statement::Rollback { .. } | Statement::Savepoint { .. } => "TRANSACTION",
        Statement::LockTables { .. } => "LOCK",
        _ => "other",
    }
}

#[derive(Default)]
struct GuardVisitor {
    error: Option<GuardError>,
}

impl Visitor for GuardVisitor {
    type Break = ();

    fn pre_visit_statement(&mut self, stmt: &Statement) -> ControlFlow<Self::Break> {
        match stmt {
            Statement::Query(_)
            | Statement::Explain { .. }
            | Statement::ExplainTable { .. }
            | Statement::ShowVariable { .. }
            | Statement::ShowVariables { .. }
            | Statement::ShowColumns { .. }
            | Statement::ShowTables { .. }
            | Statement::ShowCreate { .. }
            | Statement::ShowFunctions { .. } => ControlFlow::Continue(()),
            other => {
                self.error = Some(GuardError::NotReadOnly(format!(
                    "nested disallowed statement: {}",
                    statement_kind(other)
                )));
                ControlFlow::Break(())
            }
        }
    }

    fn pre_visit_relation(&mut self, relation: &ObjectName) -> ControlFlow<Self::Break> {
        let full = relation
            .0
            .iter()
            .map(|p| format!("{p}").trim_matches('"').to_lowercase())
            .collect::<Vec<_>>()
            .join(".");

        for prefix in FORBIDDEN_OBJECT_PREFIXES {
            if full == *prefix
                || full.ends_with(&format!(".{prefix}"))
                || full.starts_with(&format!("{prefix}."))
            {
                self.error = Some(GuardError::ForbiddenObject(full));
                return ControlFlow::Break(());
            }
        }

        // Table-function invocations (e.g. `FROM dblink(...)`) also arrive as
        // relations; block any that name a forbidden function.
        let leaf = full.rsplit('.').next().unwrap_or("");
        for bad in FORBIDDEN_FUNCTIONS {
            if leaf == *bad {
                self.error = Some(GuardError::ForbiddenFunction(full));
                return ControlFlow::Break(());
            }
        }

        ControlFlow::Continue(())
    }

    fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<Self::Break> {
        match expr {
            Expr::Function(func) => {
                let name = func
                    .name
                    .0
                    .iter()
                    .map(|p| format!("{p}").trim_matches('"').to_lowercase())
                    .collect::<Vec<_>>()
                    .join(".");

                let leaf = name.rsplit('.').next().unwrap_or("");
                for bad in FORBIDDEN_FUNCTIONS {
                    if leaf == *bad {
                        self.error = Some(GuardError::ForbiddenFunction(name));
                        return ControlFlow::Break(());
                    }
                }
            }
            Expr::Identifier(ident) => {
                let name = format!("{ident}").trim_matches('"').to_lowercase();
                for bad in FORBIDDEN_COLUMN_IDENTS {
                    if name == *bad {
                        self.error = Some(GuardError::ForbiddenObject(name));
                        return ControlFlow::Break(());
                    }
                }
            }
            Expr::CompoundIdentifier(parts) => {
                if let Some(last) = parts.last() {
                    let name = format!("{last}").trim_matches('"').to_lowercase();
                    for bad in FORBIDDEN_COLUMN_IDENTS {
                        if name == *bad {
                            let full = parts
                                .iter()
                                .map(|p| format!("{p}").trim_matches('"').to_lowercase())
                                .collect::<Vec<_>>()
                                .join(".");
                            self.error = Some(GuardError::ForbiddenObject(full));
                            return ControlFlow::Break(());
                        }
                    }
                }
            }
            _ => {}
        }
        ControlFlow::Continue(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(sql: &str) {
        guard(sql).unwrap_or_else(|e| panic!("expected ok, got {e} for sql: {sql}"));
    }

    fn err(sql: &str) -> GuardError {
        guard(sql).expect_err(&format!("expected err for sql: {sql}"))
    }

    #[test]
    fn accepts_plain_select() {
        ok("SELECT 1");
        ok("SELECT now()");
        ok("SELECT * FROM health_samples WHERE user_id = $1 LIMIT 10");
    }

    #[test]
    fn accepts_cte_select() {
        ok("WITH recent AS (SELECT * FROM meal_logs WHERE user_id = $1 ORDER BY synced_at DESC LIMIT 10) SELECT * FROM recent");
    }

    #[test]
    fn accepts_explain() {
        ok("EXPLAIN SELECT * FROM workouts WHERE user_id = $1");
        ok("EXPLAIN ANALYZE SELECT count(*) FROM health_samples");
    }

    #[test]
    fn accepts_show() {
        ok("SHOW timezone");
        ok("SHOW TIME ZONE");
    }

    #[test]
    fn rejects_insert() {
        assert!(matches!(err("INSERT INTO users (id) VALUES (1)"), GuardError::NotReadOnly(_)));
    }

    #[test]
    fn rejects_update() {
        assert!(matches!(err("UPDATE users SET email = 'x' WHERE id = 1"), GuardError::NotReadOnly(_)));
    }

    #[test]
    fn rejects_delete() {
        assert!(matches!(err("DELETE FROM meal_logs WHERE id = 1"), GuardError::NotReadOnly(_)));
    }

    #[test]
    fn rejects_drop() {
        assert!(matches!(err("DROP TABLE health_samples"), GuardError::NotReadOnly(_)));
    }

    #[test]
    fn rejects_truncate() {
        assert!(matches!(err("TRUNCATE users"), GuardError::NotReadOnly(_)));
    }

    #[test]
    fn rejects_create() {
        assert!(matches!(err("CREATE TABLE x (id int)"), GuardError::NotReadOnly(_)));
        assert!(matches!(err("CREATE INDEX idx ON users(id)"), GuardError::NotReadOnly(_)));
    }

    #[test]
    fn rejects_alter() {
        assert!(matches!(err("ALTER TABLE users ADD COLUMN foo int"), GuardError::NotReadOnly(_)));
    }

    #[test]
    fn rejects_grant_revoke() {
        assert!(matches!(err("GRANT SELECT ON users TO public"), GuardError::NotReadOnly(_)));
        assert!(matches!(err("REVOKE SELECT ON users FROM public"), GuardError::NotReadOnly(_)));
    }

    #[test]
    fn rejects_copy() {
        assert!(matches!(err("COPY users TO '/tmp/x'"), GuardError::NotReadOnly(_)));
    }

    #[test]
    fn rejects_set() {
        assert!(matches!(err("SET search_path = public"), GuardError::NotReadOnly(_)));
    }

    #[test]
    fn rejects_multi_statement() {
        let e = err("SELECT 1; DELETE FROM users_safe");
        assert!(matches!(e, GuardError::MultiStatement(_)), "got {e:?}");
    }

    #[test]
    fn rejects_pg_read_file() {
        let e = err("SELECT pg_read_file('/etc/passwd')");
        assert!(matches!(e, GuardError::ForbiddenFunction(_)), "got {e:?}");
    }

    #[test]
    fn rejects_lo_import() {
        let e = err("SELECT lo_import('/tmp/x')");
        assert!(matches!(e, GuardError::ForbiddenFunction(_)), "got {e:?}");
    }

    #[test]
    fn rejects_dblink() {
        let e = err("SELECT * FROM dblink('x', 'SELECT 1') AS t(a int)");
        assert!(matches!(e, GuardError::ForbiddenFunction(_)), "got {e:?}");
    }

    #[test]
    fn rejects_users_table() {
        assert!(matches!(err("SELECT * FROM users"), GuardError::ForbiddenObject(_)));
        assert!(matches!(err("SELECT id FROM public.users"), GuardError::ForbiddenObject(_)));
    }

    #[test]
    fn accepts_users_safe_view() {
        ok("SELECT id, email FROM users_safe WHERE id = $1");
        ok("SELECT id, email FROM public.users_safe");
    }

    #[test]
    fn rejects_sqlx_migrations() {
        assert!(matches!(err("SELECT * FROM _sqlx_migrations"), GuardError::ForbiddenObject(_)));
        assert!(matches!(err("SELECT version FROM public._sqlx_migrations"), GuardError::ForbiddenObject(_)));
    }

    #[test]
    fn rejects_raw_ingest() {
        assert!(matches!(err("SELECT * FROM raw_ingest"), GuardError::ForbiddenObject(_)));
        assert!(matches!(err("SELECT raw_body FROM public.raw_ingest"), GuardError::ForbiddenObject(_)));
    }

    #[test]
    fn rejects_password_hash_column() {
        assert!(matches!(err("SELECT password_hash FROM users_safe"), GuardError::ForbiddenObject(_)));
        assert!(matches!(err("SELECT u.password_hash FROM users_safe u"), GuardError::ForbiddenObject(_)));
    }

    #[test]
    fn rejects_pg_authid() {
        let e = err("SELECT * FROM pg_authid");
        assert!(matches!(e, GuardError::ForbiddenObject(_)), "got {e:?}");
    }

    #[test]
    fn rejects_too_large() {
        let sql = format!("SELECT '{}'", "x".repeat(MAX_SQL_BYTES));
        let e = guard(&sql).unwrap_err();
        assert!(matches!(e, GuardError::InputTooLarge(_)), "got {e:?}");
    }

    #[test]
    fn rejects_parse_error() {
        let e = err("SELEKT bogus FROMM");
        assert!(matches!(e, GuardError::Parse(_)), "got {e:?}");
    }

    #[test]
    fn rejects_modifying_cte_or_parse_error() {
        let e = err("WITH x AS (DELETE FROM meal_logs RETURNING *) SELECT * FROM x");
        assert!(
            matches!(e, GuardError::NotReadOnly(_) | GuardError::Parse(_)),
            "expected NotReadOnly or Parse, got {e:?}"
        );
    }

    #[test]
    fn case_insensitive_keyword_rejections() {
        assert!(matches!(err("drop table health_samples"), GuardError::NotReadOnly(_)));
        assert!(matches!(err("Insert Into users DEFAULT VALUES"), GuardError::NotReadOnly(_)));
    }
}
