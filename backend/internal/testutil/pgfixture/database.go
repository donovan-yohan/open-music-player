package pgfixture

import (
	"context"
	"database/sql"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/db"
)

// NewMigratedDatabase provisions only a newly generated database. Startup SQL
// has public-qualified references and cannot run in a search_path substitute.
// The explicit disposable loopback provisioning role must have CREATEDB.
func NewMigratedDatabase(t *testing.T, dsn string) *db.DB {
	t.Helper()
	if os.Getenv(db.AllowProtectedDBTestsEnv) != "" {
		t.Fatal("database provisioning does not allow a protection override")
	}
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		t.Fatal(err)
	}
	target, err := url.Parse(dsn)
	if err != nil || target.Scheme != "postgres" || target.Port() == "" || target.User == nil || target.User.Username() == "" ||
		target.Path == "" || target.Path == "/" || target.Fragment != "" ||
		(target.Hostname() != "127.0.0.1" && target.Hostname() != "localhost") {
		t.Fatal("explicit disposable loopback PostgreSQL URL required")
	}
	query, err := url.ParseQuery(target.RawQuery)
	if err != nil {
		t.Fatal("invalid PostgreSQL URL query")
	}
	for key := range query {
		switch key {
		case "host", "hostaddr", "port", "user", "dbname", "service", "options":
			t.Fatal("fixture URL may not override the connection target")
		}
	}
	root, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal("open PostgreSQL provisioning database")
	}
	t.Cleanup(func() { _ = root.Close() })
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	if err := (&db.DB{DB: root}).CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatal(err)
	}
	name := "omp_fixture_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	identifier := pq.QuoteIdentifier(name)
	target.Path, target.RawPath = "/"+name, ""
	query.Set("search_path", "public")
	target.RawQuery = query.Encode()
	peerDSN := target.String()
	if err := db.CheckDSNNotProtected(peerDSN); err != nil {
		t.Fatal(err)
	}
	if _, err := root.ExecContext(ctx, "CREATE DATABASE "+identifier+" TEMPLATE template0"); err != nil {
		t.Fatalf("create database (CREATEDB required): %v", err)
	}
	t.Cleanup(func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if _, err := root.ExecContext(cleanup, "DROP DATABASE "+identifier); err != nil {
			t.Errorf("drop owned fixture: %v", err)
			return
		}
		var exists bool
		if err := root.QueryRowContext(cleanup, "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname=$1)", name).Scan(&exists); err != nil || exists {
			t.Error("owned PostgreSQL fixture deletion was not confirmed")
		}
	})
	raw, err := sql.Open("postgres", peerDSN)
	if err != nil {
		t.Fatal("open generated fixture database")
	}
	t.Cleanup(func() { _ = raw.Close() })
	database := &db.DB{DB: raw}
	var actual, role string
	if err := raw.QueryRowContext(ctx, "SELECT current_database(), current_user").Scan(&actual, &role); err != nil || actual != name || role != target.User.Username() {
		t.Fatal("generated fixture target mismatch")
	}
	if err := database.CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatal(err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatal(err)
	}
	post, cancelPost := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancelPost()
	if err := database.CheckDatabaseNotProtected(post); err != nil {
		t.Fatal(err)
	}
	return database
}
