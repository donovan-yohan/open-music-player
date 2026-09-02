package db

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// clearProtectionEnv gives each case a known baseline: the ambient environment
// on a dev box may already carry either knob.
func clearProtectionEnv(t *testing.T) {
	t.Helper()
	t.Setenv(ProtectedDBPortsEnv, "")
	t.Setenv(AllowProtectedDBTestsEnv, "")
}

func TestProtectedDSNPortsDefaultsToTheDogfoodPort(t *testing.T) {
	clearProtectionEnv(t)
	if got := ProtectedDSNPorts(); len(got) != 1 || got[0] != "5434" {
		t.Fatalf("ProtectedDSNPorts() = %v, want [5434]", got)
	}

	t.Setenv(ProtectedDBPortsEnv, " 5544 , 5434 ,")
	if got := ProtectedDSNPorts(); len(got) != 2 || got[0] != "5544" || got[1] != "5434" {
		t.Fatalf("ProtectedDSNPorts() = %v, want [5544 5434]", got)
	}
}

func TestCheckDSNNotProtectedRefusesProtectedPorts(t *testing.T) {
	tests := []struct {
		name        string
		dsn         string
		ports       string
		allow       string
		wantRefused bool
		wantNoDSN   bool
	}{
		{
			name:        "url dsn on the dogfood port",
			dsn:         "postgres://omp:pw@localhost:5434/openmusicplayer?sslmode=disable",
			wantRefused: true,
		},
		{
			name: "url dsn on the throwaway port",
			dsn:  "postgres://omp:pw@localhost:25217/openmusicplayer?sslmode=disable",
		},
		{
			name:        "key value dsn on the dogfood port",
			dsn:         "host=localhost port=5434 user=omp password=pw dbname=openmusicplayer sslmode=disable",
			wantRefused: true,
		},
		{
			name: "key value dsn on the throwaway port",
			dsn:  "host=localhost port=25217 user=omp password=pw dbname=openmusicplayer sslmode=disable",
		},
		{
			name:  "escape hatch overrides the refusal",
			dsn:   "postgres://omp:pw@localhost:5434/openmusicplayer?sslmode=disable",
			allow: "1",
		},
		{
			name:        "custom protected port list is honored",
			dsn:         "postgres://omp:pw@localhost:5544/openmusicplayer?sslmode=disable",
			ports:       "5544,5434",
			wantRefused: true,
		},
		{
			name:  "custom list narrows protection away from the default",
			dsn:   "postgres://omp:pw@localhost:5434/openmusicplayer?sslmode=disable",
			ports: "5544",
		},
		{
			name: "url dsn without an explicit port",
			dsn:  "postgres://ci.example/openmusicplayer",
		},
		{
			name: "unparseable dsn is not treated as protected",
			dsn:  "://not a dsn :5434 %%%",
		},
		{
			// An empty DSN has no port to inspect, but lib/pq still resolves it to
			// a real database through PGHOST/PGPORT or the local socket, so it is
			// refused outright rather than waved through.
			name:      "empty dsn is refused, not waved through",
			dsn:       "",
			wantNoDSN: true,
		},
		{
			name:      "blank dsn is refused like an empty one",
			dsn:       "   ",
			wantNoDSN: true,
		},
		{
			name:  "escape hatch lifts the empty-dsn refusal too",
			dsn:   "",
			allow: "1",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			clearProtectionEnv(t)
			if tc.ports != "" {
				t.Setenv(ProtectedDBPortsEnv, tc.ports)
			}
			if tc.allow != "" {
				t.Setenv(AllowProtectedDBTestsEnv, tc.allow)
			}

			err := CheckDSNNotProtected(tc.dsn)
			if tc.wantNoDSN {
				if !errors.Is(err, ErrNoTestDSN) {
					t.Fatalf("CheckDSNNotProtected(%q) = %v, want an ErrNoTestDSN", tc.dsn, err)
				}
				if !strings.Contains(err.Error(), "OMP_POSTGRES_TEST_DSN") {
					t.Fatalf("refusal does not name the DSN variables: %v", err)
				}
				return
			}
			if tc.wantRefused {
				if !errors.Is(err, ErrProtectedDatabase) {
					t.Fatalf("CheckDSNNotProtected(%q) = %v, want an ErrProtectedDatabase", tc.dsn, err)
				}
				if !strings.Contains(err.Error(), AllowProtectedDBTestsEnv) {
					t.Fatalf("refusal does not name the escape hatch: %v", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("CheckDSNNotProtected(%q) = %v, want nil", tc.dsn, err)
			}
		})
	}
}

func TestDSNHostPortReadsBothDSNDialects(t *testing.T) {
	tests := []struct {
		dsn      string
		wantHost string
		wantPort string
	}{
		{"postgres://omp:pw@db.internal:5434/openmusicplayer", "db.internal", "5434"},
		{"postgresql://omp@localhost:25217/openmusicplayer?sslmode=disable", "localhost", "25217"},
		{"host=db.internal port=5434 user=omp", "db.internal", "5434"},
		{"port='5434' host=\"db.internal\"", "db.internal", "5434"},
		{"user=omp dbname=openmusicplayer", "", ""},
	}
	for _, tc := range tests {
		host, port := dsnHostPort(tc.dsn)
		if host != tc.wantHost || port != tc.wantPort {
			t.Fatalf("dsnHostPort(%q) = (%q, %q), want (%q, %q)", tc.dsn, host, port, tc.wantHost, tc.wantPort)
		}
	}
}

// guardSubprocessEnv makes this test re-enter itself as a child process. The
// child is the thing under test: a REAL truncating helper, run against a DSN the
// port guard is configured to refuse.
const guardSubprocessEnv = "OMP_PROTECTED_GUARD_SUBPROCESS"

// unreachableProtectedDSN points at a port nothing listens on, so any code path
// that reaches sql.Open/Ping before the guard reports a connection error instead
// of a refusal. That difference is what makes this an ORDERING test.
const unreachableProtectedDSN = "postgres://omp:fake@127.0.0.1:1/openmusicplayer?sslmode=disable"

// TestProtectedDatabaseGuardStopsRealTruncatingHelper proves the guard fires
// inside newPlayEventTestDB itself -- not just in the guard's own unit tests --
// that it fails the test rather than skipping it, and that it fires BEFORE the
// helper opens a connection.
//
// It runs the helper in a child copy of this test binary against an unreachable
// DSN whose port is marked protected. A correctly ordered guard refuses without
// ever dialing; a guard moved below sql.Open, Migrate, or the TRUNCATE would
// instead report a connection failure, and the assertions below reject that.
func TestProtectedDatabaseGuardStopsRealTruncatingHelper(t *testing.T) {
	if os.Getenv(guardSubprocessEnv) == "1" {
		// Child process: this call must fail the test, and must do so before it
		// touches any database.
		newPlayEventTestDB(t)
		t.Fatal("newPlayEventTestDB returned against a protected DSN")
	}

	cmd := exec.Command(os.Args[0], "-test.run=^"+t.Name()+"$", "-test.v")
	cmd.Env = append(os.Environ(),
		guardSubprocessEnv+"=1",
		"OMP_POSTGRES_TEST_DSN="+unreachableProtectedDSN,
		ProtectedDBPortsEnv+"=1",
		AllowProtectedDBTestsEnv+"=",
	)
	output, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("child test passed; the helper did not refuse the protected DSN:\n%s", output)
	}
	for _, want := range []string{
		"refusing destructive test setup",
		"a protected host port",
		AllowProtectedDBTestsEnv,
	} {
		if !bytes.Contains(output, []byte(want)) {
			t.Fatalf("child output missing %q:\n%s", want, output)
		}
	}
	// Anything below proves the guard ran too late: these messages only appear
	// once the helper has tried to reach the database.
	for _, forbidden := range []string{
		"open test database",
		"ping test database",
		"migrate test database",
		"truncate test database",
		"connection refused",
	} {
		if bytes.Contains(output, []byte(forbidden)) {
			t.Fatalf("guard ran after %q; it must refuse before the first connection:\n%s", forbidden, output)
		}
	}
}
