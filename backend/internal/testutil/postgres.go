package testutil

import "os"

// PostgresTestDSN returns the shared integration-test database fallback chain.
func PostgresTestDSN() string {
	if dsn := os.Getenv("OMP_POSTGRES_TEST_DSN"); dsn != "" {
		return dsn
	}
	if dsn := os.Getenv("QA_DATABASE_URL"); dsn != "" {
		return dsn
	}
	return os.Getenv("DATABASE_URL")
}
