pub mod models;

use sqlx::postgres::{PgPool, PgPoolOptions};
use std::time::Duration;
use thiserror::Error;

pub use models::*;

/// Database error types
#[derive(Error, Debug)]
pub enum DbError {
    #[error("Database connection error: {0}")]
    Connection(#[from] sqlx::Error),

    #[error("Migration error: {0}")]
    Migration(#[from] sqlx::migrate::MigrateError),

    #[error("Record not found")]
    NotFound,

    #[error("Duplicate record: {0}")]
    Duplicate(String),
}

pub type DbResult<T> = Result<T, DbError>;

/// Database connection pool
#[derive(Clone)]
pub struct Database {
    pool: PgPool,
}

impl Database {
    /// Create a new database connection pool
    pub async fn connect(database_url: &str) -> DbResult<Self> {
        let pool = PgPoolOptions::new()
            .max_connections(10)
            .acquire_timeout(Duration::from_secs(3))
            .connect(database_url)
            .await?;

        Ok(Self { pool })
    }

    /// Get a reference to the connection pool
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Run database migrations
    pub async fn migrate(&self) -> DbResult<()> {
        sqlx::migrate!("./migrations").run(&self.pool).await?;
        Ok(())
    }

    /// Check if the database connection is healthy
    pub async fn health_check(&self) -> DbResult<()> {
        sqlx::query("SELECT 1")
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    #[ignore] // Requires database connection
    async fn test_database_connection() {
        let database_url = std::env::var("DATABASE_URL")
            .expect("DATABASE_URL must be set");

        let db = Database::connect(&database_url).await
            .expect("Failed to connect to database");

        db.health_check().await
            .expect("Health check failed");
    }
}
