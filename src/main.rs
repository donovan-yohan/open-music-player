use anyhow::Result;
use tracing::{info, Level};
use tracing_subscriber::FmtSubscriber;

use openmusicplayer::Database;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::INFO)
        .finish();
    tracing::subscriber::set_global_default(subscriber)?;

    // Load environment variables from .env file
    dotenvy::dotenv().ok();

    // Get database URL from environment
    let database_url = std::env::var("DATABASE_URL")
        .expect("DATABASE_URL must be set");

    info!("Connecting to database...");

    // Connect to database
    let db = Database::connect(&database_url).await?;

    // Run migrations
    info!("Running database migrations...");
    db.migrate().await?;

    info!("Database migrations completed successfully");

    // Health check
    db.health_check().await?;
    info!("Database health check passed");

    Ok(())
}
