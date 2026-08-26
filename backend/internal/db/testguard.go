package db

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
)

// ErrProtectedDatabase is returned by both protection guards. Callers that need
// to assert the refusal (rather than just print it) match with errors.Is.
var ErrProtectedDatabase = errors.New("refusing to run destructive test setup against a protected database")

// ErrNoTestDSN is returned by CheckDSNNotProtected for an empty DSN. An empty
// DSN is not "no target": lib/pq falls back to PGHOST/PGPORT/PGDATABASE or the
// local socket, so sql.Open("postgres", "") reaches whatever database the ambient
// environment happens to name -- one no port list can guard, because there is no
// port in the DSN to inspect. Destructive test setup must skip on an empty DSN
// (see newGuardedTestDB) rather than dial an ambient database; this refusal is
// the backstop for a helper that forgets.
var ErrNoTestDSN = errors.New("refusing to run destructive test setup without an explicit DSN")

const (
	// AllowProtectedDBTestsEnv is the single escape hatch for both guards. It is
	// deliberately awkward: destroying the dogfood library should take a
	// deliberate, greppable act.
	AllowProtectedDBTestsEnv = "OMP_ALLOW_PROTECTED_DB_TESTS"

	// ProtectedDBPortsEnv overrides the protected host-port list (comma
	// separated) for hosts whose protected stack is published elsewhere.
	ProtectedDBPortsEnv = "OMP_PROTECTED_DB_PORTS"

	// defaultProtectedDBPort is the dogfood stack's published Postgres port.
	defaultProtectedDBPort = "5434"
)

// ProtectedDSNPorts returns the host ports that destructive test setup refuses
// to touch: OMP_PROTECTED_DB_PORTS when set to a non-empty list, otherwise the
// built-in default.
func ProtectedDSNPorts() []string {
	ports := make([]string, 0, 2)
	for _, field := range strings.Split(os.Getenv(ProtectedDBPortsEnv), ",") {
		if field = strings.TrimSpace(field); field != "" {
			ports = append(ports, field)
		}
	}
	if len(ports) == 0 {
		return []string{defaultProtectedDBPort}
	}
	return ports
}

// protectedDatabaseTestsAllowed reports whether the operator explicitly opted
// into destroying a protected database.
func protectedDatabaseTestsAllowed() bool {
	return os.Getenv(AllowProtectedDBTestsEnv) == "1"
}

// CheckDSNNotProtected refuses a DSN whose host port is protected, WITHOUT
// opening a connection. This is the guard that still fires when the target
// database predates the omp_environment marker, so it must run before sql.Open.
//
// A DSN this function cannot parse is not treated as protected: guessing would
// break every unusual-but-harmless throwaway DSN, and the marker check that runs
// after Migrate() is the backstop for anything that gets through here. An EMPTY
// DSN is the one exception -- it is refused outright (ErrNoTestDSN), because it
// carries no host and no port for either check to bite on while still resolving
// to a real database through lib/pq's environment fallback.
func CheckDSNNotProtected(dsn string) error {
	if protectedDatabaseTestsAllowed() {
		return nil
	}
	if strings.TrimSpace(dsn) == "" {
		return fmt.Errorf(
			"%w: empty DSN; lib/pq would fall back to PGHOST/PGPORT or the local socket. "+
				"Set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL, or skip the test when no DSN is configured",
			ErrNoTestDSN,
		)
	}
	host, port := dsnHostPort(dsn)
	if port == "" {
		return nil
	}
	protected := ProtectedDSNPorts()
	for _, candidate := range protected {
		if candidate != port {
			continue
		}
		if host == "" {
			host = "localhost"
		}
		return fmt.Errorf(
			"%w: DSN targets %s:%s, a protected host port (%s=%s); set %s=1 only if you mean to destroy that data",
			ErrProtectedDatabase, host, port, ProtectedDBPortsEnv, strings.Join(protected, ","), AllowProtectedDBTestsEnv,
		)
	}
	return nil
}

// CheckDatabaseNotProtected refuses a database whose omp_environment row is
// marked protected. Call it immediately after Migrate() and before the first
// destructive statement.
func (db *DB) CheckDatabaseNotProtected(ctx context.Context) error {
	if protectedDatabaseTestsAllowed() {
		return nil
	}
	marker, err := db.EnvironmentMarker(ctx)
	if err != nil {
		return fmt.Errorf("check database protection: %w", err)
	}
	if !marker.Protected {
		return nil
	}
	return fmt.Errorf(
		"%w: omp_environment marks this database as %q with protected = true; set %s=1 only if you mean to destroy that data",
		ErrProtectedDatabase, marker.Name, AllowProtectedDBTestsEnv,
	)
}

// dsnHostPort extracts host and port from either DSN dialect lib/pq accepts.
// Both are empty when the DSN is unparseable or carries no explicit port.
func dsnHostPort(dsn string) (string, string) {
	trimmed := strings.TrimSpace(dsn)
	if trimmed == "" {
		return "", ""
	}
	if strings.HasPrefix(trimmed, "postgres://") || strings.HasPrefix(trimmed, "postgresql://") {
		parsed, err := url.Parse(trimmed)
		if err != nil {
			return "", ""
		}
		return parsed.Hostname(), parsed.Port()
	}
	// key=value DSN ("host=localhost port=5434 user=omp ..."). Quoted values are
	// rare enough in test DSNs that a tolerant field scan beats a full parser;
	// anything it cannot read falls through to the marker check.
	var host, port string
	for _, field := range strings.Fields(trimmed) {
		key, value, ok := strings.Cut(field, "=")
		if !ok {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(key)) {
		case "host":
			host = strings.Trim(value, `'"`)
		case "port":
			port = strings.Trim(value, `'"`)
		}
	}
	return host, port
}
