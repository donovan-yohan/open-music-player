package radartest

import (
	"context"
	"database/sql"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/db"
)

// RadarDatabase creates and migrates a database owned by a single fixture.
// Never fall back to ambient developer/provider database configuration.
func RadarDatabase(t *testing.T) *db.DB {
	t.Helper()
	dsn := os.Getenv("SOUNDQ_RADAR_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("SOUNDQ_RADAR_POSTGRES_DSN not set (owned local fixture required)")
	}
	u, e := url.Parse(dsn)
	if e != nil || u.Scheme != "postgres" || u.Hostname() != "127.0.0.1" || u.Port() == "" || u.User == nil || u.User.Username() != "radar_daily_fixture" || u.Path != "/radar_daily_fixture" || u.RawQuery != "sslmode=disable" {
		t.Fatal("refusing non-owned radar fixture target")
	}
	if e := db.CheckDSNNotProtected(dsn); e != nil {
		t.Fatal(e)
	}
	admin, e := sql.Open("postgres", dsn)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { admin.Close() })
	if e := (&db.DB{DB: admin}).CheckDatabaseNotProtected(context.Background()); e != nil {
		t.Fatal(e)
	}
	name := "radar_daily_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	if _, e := admin.Exec(`CREATE DATABASE ` + pq.QuoteIdentifier(name) + ` TEMPLATE template0`); e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		if _, e := admin.Exec(`DROP DATABASE ` + pq.QuoteIdentifier(name)); e != nil {
			t.Error(e)
		}
	})
	u.Path = "/" + name
	raw, e := sql.Open("postgres", u.String())
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { raw.Close() })
	database := &db.DB{DB: raw}
	if e := database.Migrate(); e != nil {
		t.Fatal(e)
	}
	return database
}
func RadarAccount(t *testing.T, database *db.DB) uuid.UUID {
	t.Helper()
	u := uuid.New()
	if _, e := database.Exec(`INSERT INTO users(id,email,username,password_hash) VALUES($1,$2,'synthetic radar fixture','not-a-real-password')`, u, u.String()+"@example.test"); e != nil {
		t.Fatal(e)
	}
	return u
}
