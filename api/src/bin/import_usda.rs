//! Thin CLI wrapper around `self_sensored_api::importer::run`.
//!
//! Expected layout: `--dir <path>` pointing at an unzipped USDA CSV bundle
//! (SR Legacy or Foundation Foods) containing `food.csv`, `nutrient.csv`,
//! `food_nutrient.csv`, `food_portion.csv`, `measure_unit.csv`.
//!
//! Run twice (once per dataset) — `--reset` truncates first.
//!
//! `cargo run --bin import_usda -- --dir ./usda/sr_legacy --reset`
//! `cargo run --bin import_usda -- --dir ./usda/foundation`

use std::path::PathBuf;

use anyhow::{Context, Result};
use self_sensored_api::importer;
use clap::Parser;
use sqlx::postgres::PgPoolOptions;

#[derive(Parser, Debug)]
#[command(about = "Import USDA FoodData Central CSVs into the nutrition schema")]
struct Args {
    /// Directory containing the unzipped USDA CSV files.
    #[arg(long)]
    dir: PathBuf,
    /// TRUNCATE the nutrition tables before importing.
    #[arg(long, default_value_t = false)]
    reset: bool,
    /// Comma-separated USDA `data_type` values to include. Branded adds ~350k
    /// rows and pushes the DB to 2–3 GB — opt in explicitly with
    /// `--data-types sr_legacy_food,foundation_food,branded_food`.
    #[arg(long, default_value = "sr_legacy_food,foundation_food")]
    data_types: String,
    /// Skip rows that fail to parse instead of aborting.
    #[arg(long, default_value_t = false)]
    continue_on_error: bool,
    /// Skip `nutrient.csv` / `measure_unit.csv`. Use on the second dataset in
    /// a chained import (SR Legacy + Foundation) once the reference tables
    /// are already populated.
    #[arg(long, default_value_t = false)]
    skip_reference: bool,
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt::init();

    let args = Args::parse();
    let database_url = std::env::var("DATABASE_URL").context("DATABASE_URL not set")?;

    let data_types: Vec<String> = args
        .data_types
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let pool = PgPoolOptions::new()
        .max_connections(4)
        .connect(&database_url)
        .await?;

    // The CLI doesn't have an in-process NutritionCache to invalidate; API
    // processes pick up the fresh dataset on their own cache TTL.
    importer::run(
        importer::ImportArgs {
            dir: args.dir,
            reset: args.reset,
            data_types,
            continue_on_error: args.continue_on_error,
            skip_reference: args.skip_reference,
        },
        &pool,
        None,
    )
    .await
}
