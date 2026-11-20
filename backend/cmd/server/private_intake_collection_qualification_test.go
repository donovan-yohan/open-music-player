package main

import (
	"context"
	"database/sql"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/storage"
)

// Collect has two global selectors (expiry and retirement). Give the entire
// real repository a case-local namespace, with no fallthrough to public on a
// new physical connection. Copy the migrated table definitions, not their rows
// or the collector SQL. This fixture never writes a canonical track/receipt.
func isolatePrivateIntakeCollector(t *testing.T, pg *db.DB) *db.DB {
	t.Helper()
	baseDSN, marker := os.Getenv("OMP_PRIVATE_FENCE_TEST_DSN"), os.Getenv("OMP_PRIVATE_FENCE_TEST_MARKER")
	parts := privateImportFixtureDSN.FindStringSubmatch(baseDSN)
	if len(parts) != 3 || parts[1] != parts[2] || !privateImportFixtureMarker.MatchString(marker) || os.Getenv(db.AllowProtectedDBTestsEnv) != "" {
		t.Fatal("refusing non-disposable collector fixture DSN")
	}
	attest := func(ctx context.Context, target *db.DB) {
		t.Helper()
		if err := target.CheckDatabaseNotProtected(ctx); err != nil {
			t.Fatal(err)
		}
		var name, role, comment string
		if err := target.QueryRowContext(ctx, `SELECT current_database(),current_user,shobj_description(oid,'pg_database')
			FROM pg_database WHERE datname=current_database()`).Scan(&name, &role, &comment); err != nil || name != parts[1] || role != name || comment != "private-fence-fixture:"+marker {
			t.Fatal("collector fixture database attestation mismatch")
		}
	}
	schema := "pif_collect_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	dsn := baseDSN + "&search_path=" + schema
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		t.Fatal(err)
	}
	setup, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	attest(setup, pg)
	ident := pq.QuoteIdentifier(schema)
	users, tracks := ident+".users", ident+".tracks"
	receipts, attempts := ident+".private_import_receipts", ident+".private_import_attempts"
	markerView := ident + ".omp_environment"
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		attest(cleanup, pg)
		// No CASCADE: unexpected dependencies must not authorize wider deletion.
		if _, err := pg.ExecContext(cleanup, `DROP VIEW IF EXISTS `+markerView+`; DROP TABLE IF EXISTS `+users+`,`+tracks+`,`+receipts+`,`+attempts+`; DROP SCHEMA IF EXISTS `+ident); err != nil {
			t.Errorf("remove exact collector namespace: %v", err)
			return
		}
		var exists bool
		if err := pg.QueryRowContext(cleanup, `SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname=$1)`, schema).Scan(&exists); err != nil || exists {
			t.Errorf("collector namespace still present: %t %v", exists, err)
		}
	})
	// One implicit transaction. Do not copy tracks' serial default, which would
	// reach the shared tracks sequence. The read-only view keeps the real
	// database protection marker visible without exposing public tables.
	if _, err := pg.ExecContext(setup, `CREATE SCHEMA `+ident+`;
		CREATE TABLE `+users+` (LIKE public.users INCLUDING ALL);
		CREATE TABLE `+tracks+` (LIKE public.tracks INCLUDING ALL EXCLUDING DEFAULTS);
		CREATE TABLE `+receipts+` (LIKE public.private_import_receipts INCLUDING ALL);
		CREATE TABLE `+attempts+` (LIKE public.private_import_attempts INCLUDING ALL);
		CREATE VIEW `+markerView+` AS SELECT id,name,protected,updated_at FROM public.omp_environment OFFSET 0`); err != nil {
		t.Fatalf("create isolated collector namespace: %v", err)
	}
	pool, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal("construct isolated collector connection")
	}
	t.Cleanup(func() { _ = pool.Close() })
	isolated := &db.DB{DB: pool}
	connect, stop := context.WithTimeout(t.Context(), 5*time.Second)
	defer stop()
	attest(connect, isolated)
	var schemaBound bool
	if err := pool.QueryRowContext(connect, `SELECT current_schema()=$1 AND current_schemas(false)=ARRAY[$1::name]`, schema).Scan(&schemaBound); err != nil || !schemaBound {
		t.Fatalf("collector must resolve only case-local relations: %t %v", schemaBound, err)
	}
	return isolated
}

// Seed a genuine acknowledged, expired operation in a sibling namespace,
// then move only its deadline into the past to model elapsed retry backoff.
// It would win Collect(ctx, 1) if the case shared that namespace. Keeping the
// witness out of public also keeps it out of other tests' real collectors.
func previousPrivateCollectorAttempt(t *testing.T, ctx context.Context, pg *db.DB) (db.PrivateImportIntent, func(*testing.T)) {
	t.Helper()
	m := stageManifest(seedPrivateImportUser(t, pg, ctx), []byte("previous collector fixture"))
	in := storedPrivateCollectorAttempt(t, ctx, pg, m, true)
	var retry time.Time
	if err := pg.QueryRowContext(ctx, `UPDATE private_import_attempts SET cleanup_after=clock_timestamp()-INTERVAL '1 minute'
		WHERE owner_id=$1 AND operation_id=$2 AND attempt_id=$3 AND phase='retiring' RETURNING cleanup_after`, in.OwnerID, in.OperationID, in.AttemptID).Scan(&retry); err != nil {
		t.Fatalf("establish elapsed retry control: %v", err)
	}
	return in, func(t *testing.T) {
		t.Helper()
		var eligible bool
		if err := pg.QueryRowContext(ctx, `SELECT phase='retiring' AND cleanup_after=$4 AND cleanup_after<=clock_timestamp() AND byte_length=$5
			FROM private_import_attempts WHERE owner_id=$1 AND operation_id=$2 AND attempt_id=$3`, in.OwnerID, in.OperationID, in.AttemptID, retry, in.ByteLength).Scan(&eligible); err != nil || !eligible {
			t.Errorf("previous eligible retiring row was missing or changed: %t %v", eligible, err)
		}
	}
}

func storedPrivateCollectorAttempt(t *testing.T, ctx context.Context, pg *db.DB, m db.PrivateImportManifest, expireBeforeAck bool) db.PrivateImportIntent {
	t.Helper()
	repo := db.NewTrackRepository(pg)
	reservation, receipt, err := repo.ReservePrivateImportStage(ctx, m)
	if err != nil || receipt != nil || reservation == nil {
		t.Fatalf("could not reserve exact fixture attempt: %v", err)
	}
	in, err := reservation.AuthorizePut(ctx, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if expireBeforeAck {
		expirePrivateIntakeFixture(t, ctx, pg, m)
	}
	if err := repo.AcknowledgePrivateImportPut(ctx, in); err != nil {
		t.Fatal(err)
	}
	if !expireBeforeAck {
		expirePrivateIntakeFixture(t, ctx, pg, m)
	}
	return in
}

// Real collector and PostgreSQL custody transaction; only the S3 peer is
// synthetic. The pinned SDK and production net/http transport see real HTTP/1.1.
func TestPrivateIntakeCollectionRejectsLateMetadataAndMalformedAbsence(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 60*time.Second)
	defer cancel()
	shared := openPrivateImportFixtureDB(t, ctx)
	if err := shared.Migrate(); err != nil {
		t.Fatal(err)
	}
	controlDB := isolatePrivateIntakeCollector(t, shared)
	previous, assertPreviousEligible := previousPrivateCollectorAttempt(t, ctx, controlDB)
	const bucket = "collector-qualification-fixture"
	const ns = "http://s3.amazonaws.com/doc/2006-03-01/"
	const validPolicy = `<VersioningConfiguration xmlns="` + ns + `"/>`
	const duplicatePolicy = `<VersioningConfiguration xmlns="urn:wrong" xmlns="` + ns + `"/>`
	const validRoot = `<Error>`
	const duplicateRoot = `<Error xmlns="urn:wrong" xmlns="` + ns + `">`
	type reply struct{ body, trailer, value string }
	policy, absence := reply{body: validPolicy}, reply{body: validRoot}
	for _, tc := range []struct {
		name                   string
		before, missing, after reply
		wantCalls              []string
		wantClean              bool
	}{
		{"plain_exact", policy, absence, policy, []string{"before", "delete", "absence", "after"}, true},
		{"matching_vendor_trailer", policy, reply{validRoot, "X-Minio-Error-Code", "NoSuchKey"}, policy, []string{"before", "delete", "absence", "after"}, true},
		{"valid_s3_namespace", policy, reply{body: `<Error xmlns="` + ns + `">`}, policy, []string{"before", "delete", "absence", "after"}, true},
		{"contradictory_vendor_trailer", policy, reply{validRoot, "X-Minio-Error-Code", "NoSuchBucket"}, policy, []string{"before", "delete", "absence"}, false},
		{"absence_marker_trailer", policy, reply{validRoot, "X-Amz-Delete-Marker", "true"}, policy, []string{"before", "delete", "absence"}, false},
		{"absence_version_trailer", policy, reply{validRoot, "X-Amz-Version-Id", "null"}, policy, []string{"before", "delete", "absence"}, false},
		{"absence_age_trailer", policy, reply{validRoot, "Age", "3"}, policy, []string{"before", "delete", "absence"}, false},
		{"absence_conflicting_duplicate_namespace", policy, reply{body: duplicateRoot}, policy, []string{"before", "delete", "absence"}, false},
		{"absence_duplicate_attribute", policy, reply{body: `<Error note="a" note="b">`}, policy, []string{"before", "delete", "absence"}, false},
		{"before_policy_vendor_trailer", reply{validPolicy, "X-Minio-Error-Code", "NoSuchBucket"}, absence, policy, []string{"before"}, false},
		{"after_policy_marker_trailer", policy, absence, reply{validPolicy, "X-Amz-Delete-Marker", "true"}, []string{"before", "delete", "absence", "after"}, false},
		{"before_policy_duplicate_namespace", reply{body: duplicatePolicy}, absence, policy, []string{"before"}, false},
		{"after_policy_duplicate_namespace", policy, absence, reply{body: duplicatePolicy}, []string{"before", "delete", "absence", "after"}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
			defer cancel()
			pg := isolatePrivateIntakeCollector(t, shared)
			owner := seedPrivateImportUser(t, pg, ctx)
			m := stageManifest(owner, []byte("generated stage accounting fixture; no object bytes"))
			in := storedPrivateCollectorAttempt(t, ctx, pg, m, false)
			path := "/" + bucket + "/" + in.ObjectKey()
			previousPath := "/" + bucket + "/" + previous.ObjectKey()
			var mu sync.Mutex
			var calls []string
			wire := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				defer mu.Unlock()
				if r.Proto != "HTTP/1.1" || !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential=fixture-access/") {
					t.Error("expected signed HTTP/1.1 fixture traffic")
					w.WriteHeader(http.StatusUnauthorized)
					return
				}
				fresh := r.Header.Get("Cache-Control") == "no-cache, no-store"
				var output reply
				var status int
				switch {
				case r.Method == http.MethodGet && r.URL.Path == "/"+bucket+"/" && r.URL.RawQuery == "versioning=" && fresh:
					if len(calls) == 0 {
						calls = append(calls, "before")
						output = tc.before
					} else {
						calls = append(calls, "after")
						output = tc.after
					}
					status = http.StatusOK
				case r.Method == http.MethodDelete && r.URL.Path == path && r.URL.RawQuery == "":
					calls = append(calls, "delete")
					w.WriteHeader(http.StatusNoContent)
					return
				case r.Method == http.MethodGet && r.URL.Path == path && r.URL.RawQuery == "" && r.Header.Get("Range") == "bytes=0-0" && fresh:
					calls = append(calls, "absence")
					output, status = tc.missing, http.StatusNotFound
					output.body += `<Code>NoSuchKey</Code><Resource>` + path + `</Resource></Error>`
				case r.URL.Path == previousPath:
					t.Error("previous eligible retiring row reached the current case wire")
					w.WriteHeader(http.StatusBadRequest)
					return
				default:
					t.Error("expected exact bucket or staged-key operation")
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				w.Header().Set("Content-Type", "application/xml")
				if output.trailer != "" {
					w.Header().Add("Trailer", output.trailer)
				}
				w.WriteHeader(status)
				w.(http.Flusher).Flush()
				_, _ = io.WriteString(w, output.body)
				if output.trailer != "" {
					w.Header().Set(output.trailer, output.value)
				}
			}))
			defer wire.Close()
			store, err := storage.New(&storage.Config{Endpoint: wire.URL, Bucket: bucket, AccessKey: "fixture-access", SecretKey: "fixture-secret"})
			if err != nil {
				t.Fatal(err)
			}
			svc := newPrivateIntake(t, pg, stagedFixtureStore{Client: store}, "/unused/ffmpeg")
			assertPreviousEligible(t)
			n, collectErr := svc.Collect(ctx, 1)
			assertPreviousEligible(t)
			mu.Lock()
			observed := append([]string(nil), calls...)
			mu.Unlock()
			var row struct {
				phase      string
				byteLength int64
				backoff    bool
			}
			if err := pg.QueryRowContext(ctx, `SELECT phase,byte_length,cleanup_after>clock_timestamp() FROM private_import_attempts WHERE attempt_id=$1 AND owner_id=$2 AND operation_id=$3`, in.AttemptID, owner, m.OperationID).Scan(&row.phase, &row.byteLength, &row.backoff); err != nil {
				t.Fatal("could not read exact attempt")
			}
			charged := row.phase == "retiring" && row.byteLength == in.ByteLength
			t.Logf("calls=%v collected=%d phase=%s charged=%t backoff=%t", observed, n, row.phase, charged, row.backoff)
			if !reflect.DeepEqual(observed, tc.wantCalls) {
				t.Errorf("requests=%v want=%v", observed, tc.wantCalls)
			}
			if tc.wantClean {
				if n != 1 || collectErr != nil || row.phase != "cleaned" || row.backoff {
					t.Fatal("qualified proof failed to collect exact attempt")
				}
			} else if n != 0 || collectErr == nil || !charged || !row.backoff {
				t.Fatal("unqualified proof released exact charge or lost retry backoff")
			}
		})
	}
}
