package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/storage"
)

// PostgreSQL is disposable and real. S3 behavior is simulated on loopback;
// the application and historical read use the real pinned SDK, not a storage facade.
func TestPrivateIntakeCollectionRefusesVersionHistory(t *testing.T) {
	for _, tc := range []struct {
		name, initial string
		hideFirst     bool
		change        bool
		wantCalls     []string
	}{
		{"enabled_with_hidden_bytes", "Enabled", true, false, []string{"policy"}},
		{"suspended_with_hidden_bytes", "Suspended", true, false, []string{"policy"}},
		{"policy_access_denied", "denied", false, false, []string{"policy"}},
		{"policy_changed_during_delete", "", false, true, []string{"policy", "delete", "latest", "policy"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := t.Context()
			pg := openPrivateImportFixtureDB(t, ctx)
			if err := pg.Migrate(); err != nil {
				t.Fatal(err)
			}
			owner := seedPrivateStageUser(t, pg, ctx)
			a := privateImportMP3(t, ctx, 659)
			m := stageManifest(owner, a.data)
			repo := db.NewTrackRepository(pg)
			reservation, receipt, err := repo.ReservePrivateImportStage(ctx, m)
			if err != nil || receipt != nil || reservation == nil {
				t.Fatalf("could not reserve exact attempt: %v", err)
			}
			in, err := reservation.AuthorizePut(ctx, a.ms)
			if err != nil {
				t.Fatal(err)
			}

			const bucket, v1 = "exact-stage-versions-fixture", "staged-v1"
			path := "/" + bucket + "/" + in.ObjectKey()
			var mu sync.Mutex
			var calls []string
			var stored []byte
			var hidden bool
			policy := tc.initial
			if tc.initial == "Suspended" {
				policy = "Enabled" // The existing non-null version predates suspension.
			}
			fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				defer mu.Unlock()
				if !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential=fixture-access/") {
					t.Error("expected a signed request on the internal endpoint")
					w.WriteHeader(http.StatusUnauthorized)
					return
				}
				if r.Method == http.MethodGet && r.URL.Path == "/"+bucket+"/" && r.URL.RawQuery == "versioning=" {
					calls = append(calls, "policy")
					if policy == "denied" {
						w.WriteHeader(http.StatusForbidden)
						_, _ = io.WriteString(w, `<Error><Code>AccessDenied</Code></Error>`)
						return
					}
					w.Header().Set("Content-Type", "application/xml")
					_, _ = io.WriteString(w, `<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">`)
					if policy != "" {
						_, _ = fmt.Fprintf(w, "<Status>%s</Status>", policy)
					}
					_, _ = io.WriteString(w, `</VersioningConfiguration>`)
					return
				}
				if r.URL.Path != path {
					t.Error("attempted a non-exact object operation")
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				switch {
				case r.Method == http.MethodPut && r.URL.RawQuery == "":
					// The seeded object is the version that becomes noncurrent.
					var payload io.Reader = r.Body
					if r.Header.Get("Content-Encoding") == "aws-chunked" || strings.HasPrefix(r.Header.Get("X-Amz-Content-Sha256"), "STREAMING-") {
						payload = httputil.NewChunkedReader(payload)
					}
					stored, _ = io.ReadAll(io.LimitReader(payload, int64(len(a.data))+1))
					if !bytes.Equal(stored, a.data) {
						t.Error("fixture Put did not send the generated audio")
					}
					w.Header().Set("ETag", `"fixture"`)
				case r.Method == http.MethodDelete && r.URL.RawQuery == "":
					calls = append(calls, "delete")
					hidden = true
					if tc.change {
						// The proxy withholds marker headers; the final policy read must still detect drift.
						policy = "Enabled"
					} else {
						w.Header().Set("X-Amz-Delete-Marker", "true")
						version := "fixture-marker"
						if policy == "Suspended" {
							version = "null"
						}
						w.Header().Set("X-Amz-Version-Id", version)
					}
					w.WriteHeader(http.StatusNoContent)
				case r.Method == http.MethodGet && (r.URL.RawQuery == "versionId="+v1 || r.URL.RawQuery == ""):
					if r.URL.RawQuery == "" {
						calls = append(calls, "latest")
						if hidden {
							if !tc.change {
								w.Header().Set("X-Amz-Delete-Marker", "true")
							}
							w.WriteHeader(http.StatusNotFound)
							_, _ = fmt.Fprintf(w, "<Error><Code>NoSuchKey</Code><Resource>%s</Resource></Error>", path)
							return
						}
					}
					w.Header().Set("Content-Length", strconv.Itoa(len(stored)))
					w.Header().Set("Content-Type", "audio/mpeg")
					w.Header().Set("Last-Modified", time.Now().UTC().Format(http.TimeFormat))
					_, _ = w.Write(stored)
				default:
					t.Error("unexpected verb, version operation or query")
					w.WriteHeader(http.StatusBadRequest)
				}
			}))
			defer fixture.Close()
			endpoint := strings.TrimPrefix(fixture.URL, "http://")
			store, err := storage.New(&storage.Config{Endpoint: endpoint, Bucket: bucket, AccessKey: "fixture-access", SecretKey: "fixture-secret"})
			if err != nil {
				t.Fatal(err)
			}
			client, err := minio.New(endpoint, &minio.Options{Creds: credentials.NewStaticV4("fixture-access", "fixture-secret", ""), Region: "us-east-1"})
			if err != nil {
				t.Fatal(err)
			}
			core := minio.Core{Client: client}
			if err := store.PutPrivateImportObject(ctx, in.ObjectKey(), bytes.NewReader(a.data), in.ByteLength); err != nil {
				t.Fatal(err)
			}
			if err := repo.AcknowledgePrivateImportPut(ctx, in); err != nil {
				t.Fatal(err)
			}
			if tc.initial == "Suspended" {
				mu.Lock()
				policy = tc.initial
				mu.Unlock()
			}
			expirePrivateIntakeFixture(t, ctx, pg, m)
			if tc.hideFirst {
				// This is the legacy defect witness, performed only on the isolated fixture.
				if err := store.DeleteObject(ctx, in.ObjectKey()); err != nil {
					t.Fatal(err)
				}
			}
			checkMaskedBytes := func() {
				t.Helper()
				latest, _, _, err := core.GetObject(ctx, bucket, in.ObjectKey(), minio.GetObjectOptions{})
				if latest != nil {
					latest.Close()
				}
				if response := minio.ToErrorResponse(err); response.StatusCode != http.StatusNotFound || response.Code != "NoSuchKey" || response.Resource != path {
					t.Fatalf("expected exact latest absence, got %v", err)
				}
				body, _, _, err := core.GetObject(ctx, bucket, in.ObjectKey(), minio.GetObjectOptions{VersionID: v1})
				if err != nil {
					t.Fatalf("read noncurrent exact version: %v", err)
				}
				defer body.Close()
				got, err := io.ReadAll(io.LimitReader(body, in.ByteLength+1))
				if err != nil || !bytes.Equal(got, a.data) {
					t.Fatalf("unexpected noncurrent bytes: size=%d err=%v", len(got), err)
				}
				t.Logf("exact latest returned NoSuchKey; noncurrent SHA-256 %s (%d bytes)", fixtureSHA256(got), len(got))
			}
			if tc.hideFirst {
				checkMaskedBytes()
			}
			mu.Lock()
			calls = nil
			mu.Unlock()
			svc := newPrivateIntake(t, pg, stagedFixtureStore{Client: store}, "/unused/ffmpeg")
			if n, err := svc.Collect(ctx, 1); n != 0 || err == nil {
				t.Fatalf("unqualified storage released custody: collected=%d err=%v", n, err)
			}
			mu.Lock()
			observed := append([]string(nil), calls...)
			mu.Unlock()
			if !reflect.DeepEqual(observed, tc.wantCalls) {
				t.Fatalf("storage calls %v, want %v", observed, tc.wantCalls)
			}
			requireIntakeAttempt(t, ctx, pg, m, "retiring")
			var charged int64
			var backoff bool
			if err := pg.QueryRowContext(ctx, `SELECT byte_length,cleanup_after>clock_timestamp() FROM private_import_attempts WHERE owner_id=$1 AND operation_id=$2 AND phase='retiring'`, owner, m.OperationID).Scan(&charged, &backoff); err != nil || charged != in.ByteLength || !backoff {
				t.Fatalf("exact attempt lost byte charge or retry backoff: charged=%d backoff=%v err=%v", charged, backoff, err)
			}
			if tc.hideFirst || tc.change {
				checkMaskedBytes()
			}
		})
	}
}
