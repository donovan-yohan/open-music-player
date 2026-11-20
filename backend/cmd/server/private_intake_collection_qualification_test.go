package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/storage"
)

// Real collector and PostgreSQL custody transaction; only the S3 peer is
// synthetic. The pinned SDK and production net/http transport see real HTTP/1.1.
func TestPrivateIntakeCollectionRejectsLateMetadataAndMalformedAbsence(t *testing.T) {
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
			ctx := t.Context()
			pg := openPrivateImportFixtureDB(t, ctx)
			if err := pg.Migrate(); err != nil {
				t.Fatal(err)
			}
			owner := seedPrivateStageUser(t, pg, ctx)
			m := stageManifest(owner, []byte("generated stage accounting fixture; no object bytes"))
			repo := db.NewTrackRepository(pg)
			reservation, receipt, err := repo.ReservePrivateImportStage(ctx, m)
			if err != nil || receipt != nil || reservation == nil {
				t.Fatalf("could not reserve exact fixture attempt: %v", err)
			}
			in, err := reservation.AuthorizePut(ctx, 1000)
			if err != nil {
				t.Fatal(err)
			}
			if err := repo.AcknowledgePrivateImportPut(ctx, in); err != nil {
				t.Fatal(err)
			}
			expirePrivateIntakeFixture(t, ctx, pg, m)
			path := "/" + bucket + "/" + in.ObjectKey()
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
			n, collectErr := svc.Collect(ctx, 1)
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
