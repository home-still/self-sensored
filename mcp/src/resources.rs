pub const SCHEMA_OVERVIEW_URI: &str = "self-sensored://schema/overview.md";
pub const EXAMPLES_QUERIES_URI: &str = "self-sensored://examples/queries.sql";
pub const EXAMPLES_RECIPES_URI: &str = "self-sensored://examples/recipes.md";

pub const SCHEMA_OVERVIEW: &str = include_str!("../docs/schema.md");
pub const EXAMPLES_QUERIES: &str = include_str!("../docs/queries.sql");
pub const EXAMPLES_RECIPES: &str = include_str!("../docs/recipes.md");

pub fn read(uri: &str) -> Option<(&'static str, &'static str)> {
    match uri {
        SCHEMA_OVERVIEW_URI => Some(("text/markdown", SCHEMA_OVERVIEW)),
        EXAMPLES_QUERIES_URI => Some(("text/x-sql", EXAMPLES_QUERIES)),
        EXAMPLES_RECIPES_URI => Some(("text/markdown", EXAMPLES_RECIPES)),
        _ => None,
    }
}
