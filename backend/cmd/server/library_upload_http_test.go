package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/textproto"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/config"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/storage"
)

// Re-exec the actual cmd/server main in a separate process. This guard exists
// only in the test executable and the child has an explicit empty-derived env.
func TestPrivateLibraryUploadServerChild(t *testing.T) {
	if os.Getenv("OMP_LIBRARY_UPLOAD_SERVER_CHILD") != "owned-private-import-fixture" {
		return
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		if !fixtureLoopbackAddress(address) {
			fmt.Fprintln(os.Stderr, "private-upload-fixture: refused unexpected outbound HTTP")
			return nil, fmt.Errorf("fixture forbids outbound HTTP")
		}
		return (&net.Dialer{}).DialContext(ctx, network, address)
	}
	http.DefaultTransport = transport
	runPrivateLibraryChild(t)
}

func TestPrivateLibraryUploadHTTPRestartLostACK(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	pg := openPrivateImportFixtureDB(t, ctx)
	endpoint, key, secret := os.Getenv("OMP_PRIVATE_IMPORT_S3"), os.Getenv("OMP_PRIVATE_IMPORT_S3_ID"), os.Getenv("OMP_PRIVATE_IMPORT_S3_SECRET")
	if endpoint == "" {
		t.Skip("requires an owned disposable S3 fixture")
	}
	if !fixtureLoopbackAddress(endpoint) || len(key) != 32 || strings.Trim(key, "0123456789abcdef") != "" || !privateLibraryMarker.MatchString(secret) {
		t.Fatal("refusing non-disposable object fixture")
	}
	bucket := "soundq-fixture-" + uuid.NewString()
	admin, err := minio.New(endpoint, &minio.Options{Creds: credentials.NewStaticV4(key, secret, ""), Region: "us-east-1"})
	if err != nil {
		t.Fatal("create fixture S3 client")
	}
	if err := admin.MakeBucket(ctx, bucket, minio.MakeBucketOptions{Region: "us-east-1"}); err != nil {
		t.Fatal("create exact fixture bucket")
	}
	store, err := storage.New(&storage.Config{Endpoint: endpoint, AccessKey: key, SecretKey: secret, Bucket: bucket, Region: "us-east-1"})
	if err != nil {
		t.Fatal("create fixture object reader")
	}
	a := privateImportMP3(t, ctx, 547)
	var puts, droppedPuts, blockedReads atomic.Int32
	var dropStoreACK, refuseStoreRead atomic.Bool
	s3Target := &url.URL{Scheme: "http", Host: endpoint}
	s3Proxy := httputil.NewSingleHostReverseProxy(s3Target)
	s3Proxy.ModifyResponse = func(resp *http.Response) error {
		if resp.Request.Method != http.MethodPut || resp.StatusCode != http.StatusOK || !dropStoreACK.CompareAndSwap(true, false) {
			return nil
		}
		object := strings.TrimPrefix(resp.Request.URL.Path, "/"+bucket+"/")
		bytesAtStore, e := fixtureReadObject(ctx, store, object)
		if e != nil || !bytes.Equal(bytesAtStore, a.data) {
			t.Error("the S3 ACK cannot be dropped before independent exact object readback")
		} else {
			droppedPuts.Add(1)
		}
		return fmt.Errorf("drop fixture S3 ACK")
	}
	s3Proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, _ error) {
		conn, _, e := http.NewResponseController(w).Hijack()
		if e == nil {
			_ = conn.Close()
		}
	}
	s3 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead && refuseStoreRead.Load() && strings.HasPrefix(r.URL.Path, "/"+bucket+"/private-import/v1/") {
			blockedReads.Add(1)
			w.WriteHeader(http.StatusForbidden)
			return
		}
		if r.Method == http.MethodPut {
			if !strings.HasPrefix(r.URL.Path, "/"+bucket+"/private-import/v1/") || r.Header.Get("If-None-Match") != "*" || !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 ") {
				t.Error("object PUT is not an exact signed create-only attempt")
				http.Error(w, "unexpected object request", http.StatusBadRequest)
				return
			}
			puts.Add(1)
		}
		s3Proxy.ServeHTTP(w, r)
	}))
	defer s3.Close()
	type analyzerObservation struct {
		track     int64
		key, hash string
		length    int
	}
	var analyzeCount atomic.Int32
	analyzed := make(chan analyzerObservation, 4)
	analyzerServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.Method + " " + r.URL.Path {
		case "GET /health":
			writePrivateAnalysisHealth(w, "fixture", "upload-http-v1")
		case "POST /analyze":
			analyzeCount.Add(1)
			var wire map[string]json.RawMessage
			if json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&wire) != nil || len(wire) != 6 {
				t.Error("unexpected analysis wire envelope")
				w.WriteHeader(400)
				return
			}
			var id int64
			var object string
			if json.Unmarshal(wire["track_id"], &id) != nil || id <= 0 || json.Unmarshal(wire["storage_key"], &object) != nil ||
				string(wire["expected_analyzer"]) != `"fixture"` || string(wire["expected_analyzer_version"]) != `"upload-http-v1"` ||
				wire["duration_ms"] == nil || wire["schema_version"] == nil {
				t.Error("analysis wire disagrees with private-source contract")
				w.WriteHeader(400)
				return
			}
			raw, err := fixtureReadObject(r.Context(), store, object)
			if err != nil {
				t.Error("analyzer could not open wire-named canonical object")
				w.WriteHeader(502)
				return
			}
			observed := analyzerObservation{id, object, fixtureSHA256(raw), len(raw)}
			select {
			case analyzed <- observed:
			default:
				t.Error("unexpected excess analysis runs")
				w.WriteHeader(400)
				return
			}
			_, _ = io.WriteString(w, `{"schema_version":1,"summary":{"bpm":123},"artifacts":{},"provenance":{"analyzer":"fixture","analyzer_version":"upload-http-v1"}}`)
		default:
			t.Error("unexpected analyzer route")
			w.WriteHeader(404)
		}
	}))
	defer analyzerServer.Close()

	dsn, err := url.Parse(os.Getenv("OMP_PRIVATE_FENCE_TEST_DSN"))
	if err != nil {
		t.Fatal("invalid fixture DSN")
	}
	password, _ := dsn.User.Password()
	jwtKey := uuid.NewString() + uuid.NewString()
	home := t.TempDir()
	grant := fixtureBucketGrant{Endpoint: strings.TrimPrefix(s3.URL, "http://"), Bucket: bucket}
	childEnv := func(mode, analyzerURL string) []string {
		return []string{
			"HOME=" + home, "TMPDIR=" + home, "PATH=" + os.Getenv("PATH"), "GOMAXPROCS=2",
			"OMP_LIBRARY_UPLOAD_SERVER_CHILD=owned-private-import-fixture", "PRIVATE_LIBRARY_UPLOAD_MODE=" + mode,
			"OMP_PRIVATE_FENCE_TEST_MARKER=" + os.Getenv("OMP_PRIVATE_FENCE_TEST_MARKER"),
			"OMP_PROTECTED_DB_PORTS=" + os.Getenv("OMP_PROTECTED_DB_PORTS"),
			"DB_HOST=127.0.0.1", "DB_PORT=" + dsn.Port(), "DB_NAME=" + strings.TrimPrefix(dsn.Path, "/"), "DB_USER=" + dsn.User.Username(), "DB_PASSWORD=" + password,
			"JWT_SECRET=" + jwtKey, "REDIS_ENABLED=false", "MINIO_ENDPOINT=" + strings.TrimPrefix(s3.URL, "http://"), "MINIO_BUCKET=" + bucket,
			"MINIO_ACCESS_KEY=" + key, "MINIO_SECRET_KEY=" + secret, "ANALYZER_BASE_URL=" + analyzerURL,
		}
	}
	launch := func(mode, analyzerURL string) (string, func()) {
		t.Helper()
		return startPrivateLibraryHTTPChild(t, ctx, childEnv(mode, analyzerURL), grant)
	}
	f := &durableImportFixtures{operations: make(map[durableImportOperation]struct{})}
	t.Cleanup(func() {
		cleanup, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		if err := attestPrivateLibraryFixture(pg, &config.Config{DBName: dsn.User.Username()}, os.Getenv("OMP_PRIVATE_FENCE_TEST_MARKER")); err != nil {
			t.Error("fixture marker changed before exact-attempt cleanup")
			return
		}
		for op := range f.operations {
			if _, err := pg.ExecContext(cleanup, `DELETE FROM private_import_attempts WHERE owner_id=$1 AND operation_id=$2`, op.owner, op.operation); err != nil {
				t.Error("could not remove exact owned staged row")
				continue
			}
			var exists bool
			if err := pg.QueryRowContext(cleanup, `SELECT EXISTS (SELECT 1 FROM private_import_attempts WHERE owner_id=$1 AND operation_id=$2)`, op.owner, op.operation).Scan(&exists); err != nil || exists {
				t.Error("exact owned staged row not absent after cleanup")
			}
		}
		if err := f.remove(cleanup, pg); err != nil {
			t.Errorf("remove and verify exact committed fixture rows: %v", err)
		}
	})
	baseline, stopBaseline := launch("", "")
	c := &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	call := func(method, base, path, token, op, media string, body io.Reader) (int, []byte, http.Header, error) {
		req, e := http.NewRequestWithContext(ctx, method, base+path, body)
		if e != nil {
			return 0, nil, nil, e
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		if op != "" {
			req.Header.Set("Idempotency-Key", op)
		}
		if media != "" {
			req.Header.Set("Content-Type", media)
		}
		if method == http.MethodGet {
			req.Header.Set("If-None-Match", "*")
		}
		req.Header.Set("Accept-Encoding", "identity") // Compare raw upstream and recovered JSON bytes.
		req.Close = true
		resp, e := c.Do(req)
		if e != nil {
			return 0, nil, nil, e
		}
		defer resp.Body.Close()
		data, e := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
		return resp.StatusCode, data, resp.Header, e
	}
	const uploads = "/api/v1/library/uploads"
	if status, _, _, _ := call(http.MethodPost, baseline, uploads, "", "", "", nil); status != 404 {
		t.Fatalf("default POST status=%d", status)
	}
	stopBaseline()
	base, stop := launch(privateLibraryFixtureMode, "")
	owner, other := f.newOwner(t, ctx, pg), f.newOwner(t, ctx, pg)
	token := func(id uuid.UUID) string {
		credential, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: id.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte(jwtKey))
		if err != nil {
			t.Fatal("mint disposable bearer")
		}
		return credential
	}
	ownerToken, otherToken := token(owner), token(other)
	op := uuid.New()
	f.operations[durableImportOperation{owner, op}] = struct{}{}
	const title = "Managed only by fixture"
	manifest := fmt.Sprintf(`{"title":%q,"artist":"Generated artist","album":"Generated album","sha256":%q,"byte_length":%d}`, title, a.hash, len(a.data))
	body, media := privateLibraryMultipart(t, manifest, a.data, nil)
	request := func(t testing.TB, method, where, path, bearer, operation, ctype string, input io.Reader, want int) []byte {
		t.Helper()
		code, raw, headers, err := call(method, where, path, bearer, operation, ctype, input)
		if err != nil || code != want {
			t.Fatalf("%s HTTP status=%d want=%d; body=%s, err=%v", method, code, want, raw, err)
		}
		mediaType := "application/json"
		if want == http.StatusUnauthorized {
			mediaType = "text/plain"
		} // Shared Auth middleware's JSON-text error.
		if headers.Get("Cache-Control") != "private, no-store" || headers.Get("ETag") != "" || !strings.HasPrefix(headers.Get("Content-Type"), mediaType) || !json.Valid(raw) {
			t.Fatalf("private response cache/media headers incorrect: status=%d headers=%v", code, headers)
		}
		return raw
	}
	request(t, http.MethodPost, base, uploads, "", op.String(), media, bytes.NewReader(body), 401)
	for _, row := range []struct {
		name, manifest string
		extra          []byte
		want           int
		staged         bool
	}{
		{"duplicate JSON", strings.Replace(manifest, `"title":`, `"title":"other","title":`, 1), nil, 400, false},
		{"manifest length", strings.Replace(manifest, strconv.Itoa(len(a.data)), "67108865", 1), nil, 413, false},
		{"manifest over 8KiB", strings.Replace(manifest, title, strings.Repeat("x", 8192), 1), nil, 413, false},
		{"same length wrong hash", strings.Replace(manifest, a.hash, "sha256:"+strings.Repeat("d", 64), 1), nil, 400, true},
		{"short original", manifest, nil, 400, true},
		{"surplus original", manifest, nil, 400, true},
		{"extra part", manifest, []byte("unexpected"), 400, true},
		{"epilogue", manifest, []byte("after close"), 400, true},
		{"unsupported bytes", fmt.Sprintf(`{"title":"unsupported","sha256":%q,"byte_length":3}`, fixtureSHA256([]byte("mp3"))), nil, 415, true},
	} {
		t.Run(row.name, func(t *testing.T) {
			id := uuid.New()
			f.operations[durableImportOperation{owner, id}] = struct{}{}
			input := a.data
			if row.name == "unsupported bytes" {
				input = []byte("mp3")
			}
			if row.name == "short original" {
				input = input[:len(input)-1]
			}
			if row.name == "surplus original" {
				input = append(bytes.Clone(input), 0)
			}
			form, typ := privateLibraryMultipart(t, row.manifest, input, nil)
			if row.name == "extra part" {
				form, typ = privateLibraryMultipart(t, row.manifest, input, row.extra)
			}
			if row.name == "epilogue" {
				form = append(form, row.extra...)
			}
			// Reader wrapper deliberately hides Content-Length: this is real chunked HTTP.
			request(t, http.MethodPost, base, uploads, ownerToken, id.String(), typ, struct{ io.Reader }{bytes.NewReader(form)}, row.want)
			statusCode := 404
			if row.staged {
				statusCode = 200
			}
			raw := request(t, http.MethodGet, base, uploads+"/"+id.String(), ownerToken, "", "", nil, statusCode)
			if row.staged && !bytes.Contains(raw, []byte(`"status":"closed"`)) {
				t.Fatal("unpublished attempt not closed")
			}
			if puts.Load() != 0 {
				t.Fatal("refused body reached object PUT")
			}
		})
	}

	// A client closes a chunked upload while the real owner is waiting for its
	// original. Require a positive reserved read before cancel, then exact closure.
	interrupted := uuid.New()
	f.operations[durableImportOperation{owner, interrupted}] = struct{}{}
	reader, writer := io.Pipe()
	defer writer.Close()
	sendCtx, sendCancel := context.WithCancel(ctx)
	defer sendCancel()
	req, _ := http.NewRequestWithContext(sendCtx, http.MethodPost, base+uploads, reader)
	req.Header.Set("Authorization", "Bearer "+ownerToken)
	req.Header.Set("Idempotency-Key", interrupted.String())
	req.Header.Set("Content-Type", media)
	sent := make(chan error, 1)
	go func() {
		resp, e := c.Do(req)
		if resp != nil {
			resp.Body.Close()
		}
		sent <- e
	}()
	prefix := bytes.Index(body, a.data)
	if prefix <= 0 {
		t.Fatal("cannot locate audio part in generated body")
	}
	if _, err := writer.Write(body[:prefix+8]); err != nil {
		t.Fatal("interrupted upload did not start")
	}
	statusPath := uploads + "/" + interrupted.String()
	requireUploadEventually(t, ctx, "reserved interrupted body", func() bool {
		code, raw, _, _ := call(http.MethodGet, base, statusPath, ownerToken, "", "", nil)
		return code == 200 && bytes.Contains(raw, []byte(`"status":"pending"`))
	})
	// Replaying a manifest while the original is held must not read its body.
	duplicateBody := append(bytes.Clone(body[:prefix]), []byte("not the original")...)
	request(t, http.MethodPost, base, uploads, ownerToken, interrupted.String(), media, bytes.NewReader(duplicateBody), 202)
	sendCancel()
	_ = writer.CloseWithError(context.Canceled)
	if err := <-sent; err == nil {
		t.Fatal("canceled sender got an ACK")
	}
	requireUploadEventually(t, ctx, "closed interrupted body", func() bool {
		code, raw, _, _ := call(http.MethodGet, base, statusPath, ownerToken, "", "", nil)
		return code == 200 && bytes.Contains(raw, []byte(`"status":"closed"`))
	})
	if puts.Load() != 0 {
		t.Fatal("partial original reached storage")
	}

	// Lose the ACK over a real socket after the producer emitted it and an
	// independent SQL read has certified the exact committed operation.
	var trackID int64
	var objectKey string
	type lostUploadACK struct {
		trackID int64
		wire    []byte
	}
	ackWitness := make(chan lostUploadACK, 1)
	var journeyPosts atomic.Int32
	upstream, _ := url.Parse(base)
	drop := httputil.NewSingleHostReverseProxy(upstream)
	drop.ModifyResponse = func(resp *http.Response) error {
		if resp.StatusCode == 201 {
			wire, readErr := io.ReadAll(io.LimitReader(resp.Body, 4096))
			receipt, e := db.NewTrackRepository(pg).GetPrivateImportReceipt(ctx, owner, op)
			if e == nil && receipt.TrackID > 0 && receipt.SHA256 == a.hash && receipt.ByteLength == int64(len(a.data)) && readErr == nil {
				var member bool
				member, e = db.NewLibraryRepository(pg).IsTrackInLibrary(ctx, owner, receipt.TrackID)
				if e == nil && member {
					ackWitness <- lostUploadACK{receipt.TrackID, wire}
					return fmt.Errorf("drop observed ACK")
				}
			}
			return fmt.Errorf("fixture did not certify successful ACK")
		}
		return nil
	}
	drop.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, _ error) {
		conn, _, e := http.NewResponseController(w).Hijack()
		if e == nil {
			_ = conn.Close()
		}
	}
	lost := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == uploads {
			journeyPosts.Add(1)
		}
		drop.ServeHTTP(w, r)
	}))
	status, _, _, e := call(http.MethodPost, lost.URL, uploads, ownerToken, op.String(), media, bytes.NewReader(body))
	lost.Close()
	if e == nil || status != 0 {
		t.Fatalf("fixture did not lose the upload ACK: status=%d", status)
	}
	var originalReceipt []byte
	select {
	case witness := <-ackWitness:
		trackID, originalReceipt = witness.trackID, witness.wire
	default:
		t.Fatal("commit not independently observed before lost ACK")
	}
	if puts.Load() != 1 {
		t.Fatalf("expected one PUT; got %d", puts.Load())
	}
	var trackRows, receiptRows, membershipRows, analysisRows int
	if err := pg.QueryRowContext(ctx, `SELECT
		(SELECT count(*) FROM tracks WHERE private_owner_id=$1),
		(SELECT count(*) FROM private_import_receipts WHERE owner_id=$1),
		(SELECT count(*) FROM user_library WHERE user_id=$1),
		(SELECT count(*) FROM track_analysis WHERE track_id=$2 AND status='stale' AND provenance_json->>'trigger'='post_library_upload')`, owner, trackID).
		Scan(&trackRows, &receiptRows, &membershipRows, &analysisRows); err != nil || trackRows != 1 || receiptRows != 1 || membershipRows != 1 || analysisRows != 1 {
		t.Fatalf("owned SQL cardinality after lost ACK: track=%d receipt=%d membership=%d scheduled=%d err=%v", trackRows, receiptRows, membershipRows, analysisRows, err)
	}
	if err := pg.QueryRowContext(ctx, `SELECT storage_key FROM tracks WHERE id=$1 AND private_owner_id=$2`, trackID, owner).Scan(&objectKey); err != nil {
		t.Fatal("canonical key unavailable")
	}
	requireIntakeObject(t, ctx, store, objectKey, a.data)

	stop()

	readback, stopReadback := launch(privateLibraryFixtureReadback, analyzerServer.URL)
	// No recovery request triggers analysis: the next production startup drains
	// the durable obligation on the ordinary queue before the first status GET.
	select {
	case observed := <-analyzed:
		if observed != (analyzerObservation{trackID, objectKey, a.hash, len(a.data)}) {
			t.Fatal("analyzer did not open exact committed bytes")
		}
	case <-ctx.Done():
		t.Fatal("private startup did not dispatch persisted analysis")
	case <-time.After(10 * time.Second):
		t.Fatal("no automatic analysis dispatch after server restart")
	}
	if status, _, _, _ := call(http.MethodPost, readback, uploads, ownerToken, op.String(), media, bytes.NewReader(body)); status != 404 {
		t.Fatalf("readback-only server admits POST: %d", status)
	}
	request(t, http.MethodGet, readback, uploads+"/"+op.String(), "", "", "", nil, 401)
	recovered := request(t, http.MethodGet, readback, uploads+"/"+op.String(), ownerToken, "", "", nil, 200)
	expected := fmt.Sprintf(`{"operation_id":%q,"account_id":%q,"status":"committed","track_id":%d,"sha256":%q,"byte_length":%d}`+"\n", op, owner, trackID, a.hash, len(a.data))
	if string(recovered) != expected || !bytes.Equal(recovered, originalReceipt) {
		t.Fatal("recovered wire receipt disagrees with historical outcome")
	}
	foreign := request(t, http.MethodGet, readback, uploads+"/"+op.String(), otherToken, "", "", nil, 404)
	unknown := request(t, http.MethodGet, readback, uploads+"/"+uuid.NewString(), otherToken, "", "", nil, 404)
	if !bytes.Equal(unknown, foreign) {
		t.Fatal("foreign receipt is distinguishable from unknown")
	}
	exactPath := fmt.Sprintf("/api/v1/library/tracks/%d", trackID)
	exact := request(t, http.MethodGet, readback, exactPath, ownerToken, "", "", nil, 200)
	var source struct {
		Account              uuid.UUID `json:"account_id"`
		ID                   int64
		SHA256               string
		Bytes                int64 `json:"byte_length"`
		Title, Artist, Album string
		Duration             int32 `json:"duration_ms"`
	}
	if json.Unmarshal(exact, &source) != nil || source.Account != owner || source.ID != trackID || source.SHA256 != a.hash || source.Bytes != int64(len(a.data)) || source.Title != title || source.Artist != "Generated artist" || source.Album != "Generated album" || source.Duration <= 0 || bytes.Contains(exact, []byte(objectKey)) {
		t.Fatal("exact membership/byte proof incorrect")
	}
	if !bytes.Equal(request(t, http.MethodGet, readback, exactPath, otherToken, "", "", nil, 404), request(t, http.MethodGet, readback, "/api/v1/library/tracks/999999999", otherToken, "", "", nil, 404)) {
		t.Fatal("foreign membership is distinguishable from missing")
	}
	code, raw, _, e := call(http.MethodGet, readback, "/api/v1/library", ownerToken, "", "", nil)
	var list struct {
		Tracks []struct{ ID int64 }
		Total  int
	}
	if e != nil || code != 200 || json.Unmarshal(raw, &list) != nil || list.Total != 1 || len(list.Tracks) != 1 || list.Tracks[0].ID != trackID {
		t.Fatal("ordinary Library does not acknowledge exactly one row")
	}
	requireUploadEventually(t, ctx, "ordinary analysis readback", func() bool {
		code, raw, _, _ := call(http.MethodGet, readback, fmt.Sprintf("/api/v1/tracks/%d/analysis", trackID), ownerToken, "", "", nil)
		return code == 200 && bytes.Contains(raw, []byte(`"status":"analyzed"`)) && bytes.Contains(raw, []byte(`"bpm":123`))
	})
	if code, _, _, _ := call(http.MethodDelete, readback, exactPath, ownerToken, "", "", nil); code != 200 && code != 204 {
		t.Fatalf("remove fixture membership: %d", code)
	}
	request(t, http.MethodGet, readback, exactPath, ownerToken, "", "", nil, 404)
	if historical := request(t, http.MethodGet, readback, uploads+"/"+op.String(), ownerToken, "", "", nil, 200); !bytes.Equal(historical, recovered) {
		t.Fatal("membership removal changed historical receipt")
	}
	stopReadback()
	if journeyPosts.Load() != 1 || analyzeCount.Load() != 1 || puts.Load() != 1 {
		t.Fatalf("unexpected journey dispatch counts: POST=%d analysis=%d PUT=%d", journeyPosts.Load(), analyzeCount.Load(), puts.Load())
	}
	t.Log("real server restarts: lost committed HTTP ACK → exact owner receipt, one POST, one signed PUT, one canonical object, one automatic analyzer dispatch/result, exact Library membership; writer off preserves readback")

	// Separate contract controls after the one-POST journey. Replay lacks even
	// the audio headers; it must not re-add removed membership or issue a PUT.
	replayBase, stopReplay := launch(privateLibraryFixtureMode, "")
	replay := request(t, http.MethodPost, replayBase, uploads, ownerToken, op.String(), media, bytes.NewReader(body[:prefix]), 200)
	if !bytes.Equal(replay, recovered) {
		t.Fatal("committed replay disagrees with durable receipt")
	}
	changed, changedMedia := privateLibraryMultipart(t, strings.Replace(manifest, title, "changed intent", 1), a.data, nil)
	request(t, http.MethodPost, replayBase, uploads, ownerToken, op.String(), changedMedia, bytes.NewReader(changed), 409)
	request(t, http.MethodGet, replayBase, exactPath, ownerToken, "", "", nil, 404)
	if puts.Load() != 1 {
		t.Fatal("replay or changed manifest repeated the PUT")
	}

	// Independent fault: signed object PUT is present but unacknowledged. Only
	// the status GET can finalize it on the new process, without object write.
	uncertain := uuid.New()
	f.operations[durableImportOperation{other, uncertain}] = struct{}{}
	dropStoreACK.Store(true)
	pending := request(t, http.MethodPost, replayBase, uploads, otherToken, uncertain.String(), media, bytes.NewReader(body), 202)
	if droppedPuts.Load() != 1 || puts.Load() != 2 || !bytes.Contains(pending, []byte(`"status":"pending"`)) {
		t.Fatal("did not retain one unknown PUT before restart")
	}
	if _, err := db.NewTrackRepository(pg).GetPrivateImportReceipt(ctx, other, uncertain); !errors.Is(err, db.ErrPrivateImportNotFound) {
		t.Fatal("unacknowledged PUT prematurely committed")
	}
	stopReplay()
	checking, stopChecking := launch(privateLibraryFixtureReadback, "")
	uncertainPath := uploads + "/" + uncertain.String()
	if code, _, _, _ := call(http.MethodHead, checking, uncertainPath, otherToken, "", "", nil); code != 405 {
		t.Fatalf("HEAD adopted recovery: %d", code)
	}
	if _, err := db.NewTrackRepository(pg).GetPrivateImportReceipt(ctx, other, uncertain); !errors.Is(err, db.ErrPrivateImportNotFound) {
		t.Fatal("HEAD committed staged bytes")
	}
	resolved := request(t, http.MethodGet, checking, uncertainPath, otherToken, "", "", nil, 200)
	var receipt struct {
		TrackID        int64     `json:"track_id"`
		OperationID    uuid.UUID `json:"operation_id"`
		AccountID      uuid.UUID `json:"account_id"`
		Status, SHA256 string
		ByteLength     int64 `json:"byte_length"`
	}
	if json.Unmarshal(resolved, &receipt) != nil || receipt.TrackID <= 0 || receipt.TrackID == trackID || receipt.OperationID != uncertain || receipt.AccountID != other || receipt.Status != "committed" || receipt.SHA256 != a.hash || receipt.ByteLength != int64(len(a.data)) {
		t.Fatal("recovered stage has wrong independent account source or receipt")
	}
	var secondKey string
	if err := pg.QueryRowContext(ctx, `SELECT storage_key FROM tracks WHERE id=$1 AND private_owner_id=$2`, receipt.TrackID, other).Scan(&secondKey); err != nil || secondKey == objectKey {
		t.Fatal("cross-account upload did not get its own canonical object")
	}
	requireIntakeObject(t, ctx, store, secondKey, a.data)
	stopChecking()
	if puts.Load() != 2 {
		t.Fatal("status recovery issued another PUT")
	}
	t.Log("separate fault: signed S3 success with its ACK dropped; HEAD left it uncommitted; GET after restart verified bytes and committed without a second PUT")

	t.Run("stored_verification_is_not_ingress", func(t *testing.T) {
		base, stop := launch(privateLibraryFixtureMode, "")
		defer stop()
		user, id := f.newOwner(t, ctx, pg), uuid.New()
		bearer := token(user)
		f.operations[durableImportOperation{user, id}] = struct{}{}
		baseline := puts.Load()
		refuseStoreRead.Store(true)
		defer refuseStoreRead.Store(false)
		code, raw, _, e := call(http.MethodPost, base, uploads, bearer, id.String(), media, bytes.NewReader(body))
		key := requireIntakeAttempt(t, ctx, pg, db.PrivateImportManifest{OwnerID: user, OperationID: id}, "stored")
		requireIntakeObject(t, ctx, store, key, a.data)
		if blockedReads.Load() == 0 || puts.Load() != baseline+1 || e != nil {
			t.Fatal("signed Put success and refused read were not both observed")
		}
		if code != 202 || !bytes.Contains(raw, []byte(`"status":"pending"`)) {
			t.Errorf("post-PUT status=%d; want 202 pending for acknowledged stage", code)
		}
		request(t, http.MethodGet, base, uploads+"/"+id.String(), bearer, "", "", nil, 503)
		refuseStoreRead.Store(false)
		resolved := request(t, http.MethodGet, base, uploads+"/"+id.String(), bearer, "", "", nil, 200)
		got, e := db.NewTrackRepository(pg).GetPrivateImportReceipt(ctx, user, id)
		if e != nil || got.TrackID <= 0 || got.SHA256 != a.hash || got.ByteLength != int64(len(a.data)) || string(resolved) != fmt.Sprintf(`{"operation_id":%q,"account_id":%q,"status":"committed","track_id":%d,"sha256":%q,"byte_length":%d}`+"\n", id, user, got.TrackID, a.hash, len(a.data)) || puts.Load() != baseline+1 {
			t.Fatal("read recovery failed to preserve exact one-PUT receipt")
		}
	})

	for _, mode := range []string{privateLibraryFixtureMode, privateLibraryFixtureReadback} {
		t.Run(mode+"_environment_cannot_grant_bucket", func(t *testing.T) {
			requireUnboundLibraryRefusal(t, childEnv(mode, ""))
		})
		t.Run(mode+"_different_bucket_cannot_use_grant", func(t *testing.T) {
			wrong := grant
			wrong.Bucket = "soundq-fixture-" + uuid.NewString()
			requireUnboundLibraryRefusal(t, childEnv(mode, ""), wrong)
		})
		t.Run(mode+"_analyzer_refuses_redirect", func(t *testing.T) {
			hits := make(chan struct{}, 4)
			sink := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				select {
				case hits <- struct{}{}:
				default:
				}
				writePrivateAnalysisHealth(w, "fixture", "upload-http-v1")
			}))
			defer sink.Close()
			var offered atomic.Int32
			origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				offered.Add(1)
				http.Redirect(w, r, sink.URL, http.StatusTemporaryRedirect)
			}))
			defer origin.Close()
			_, stop := launch(mode, origin.URL)
			defer stop()
			requireUploadEventually(t, ctx, "both real startup analyzer probes offered redirect", func() bool { return offered.Load() >= 2 })
			select {
			case <-hits:
				t.Error("runtime analyzer followed a redirect to independent local observer")
			case <-time.After(350 * time.Millisecond):
			}
		})
	}

	t.Run("process_exit_releases_only_expired_reserved", func(t *testing.T) {
		var kill func()
		base, stop := startPrivateLibraryHTTPChild(t, ctx, childEnv(privateLibraryFixtureMode, ""), grant, &kill)
		defer stop()
		baseline := puts.Load()
		peer, peerOp := f.newOwner(t, ctx, pg), uuid.New()
		f.operations[durableImportOperation{peer, peerOp}] = struct{}{}
		dropStoreACK.Store(true)
		request(t, http.MethodPost, base, uploads, token(peer), peerOp.String(), media, bytes.NewReader(body), 202)
		requireIntakeAttempt(t, ctx, pg, db.PrivateImportManifest{OwnerID: peer, OperationID: peerOp}, "putting")
		var held []durableImportOperation
		var keys []string
		for range 3 {
			user, id := f.newOwner(t, ctx, pg), uuid.New()
			op := durableImportOperation{user, id}
			held = append(held, op)
			f.operations[op] = struct{}{}
			reader, writer := io.Pipe()
			req, _ := http.NewRequestWithContext(ctx, http.MethodPost, base+uploads, reader)
			req.Header.Set("Authorization", "Bearer "+token(user))
			req.Header.Set("Idempotency-Key", id.String())
			req.Header.Set("Content-Type", media)
			finished := make(chan struct{})
			go func() {
				defer close(finished)
				if res, _ := c.Do(req); res != nil {
					_ = res.Body.Close()
				}
			}()
			defer func() { _ = writer.Close(); <-finished }()
			if _, e := writer.Write(body[:prefix+8]); e != nil {
				t.Fatal("held original could not reach child")
			}
			requireUploadEventually(t, ctx, "held upload reservation", func() bool {
				code, raw, _, _ := call(http.MethodGet, base, uploads+"/"+id.String(), token(user), "", "", nil)
				return code == 200 && bytes.Contains(raw, []byte(`"status":"pending"`))
			})
			keys = append(keys, requireIntakeAttempt(t, ctx, pg, db.PrivateImportManifest{OwnerID: user, OperationID: id}, "reserved"))
		}
		kill()
		for i, op := range held {
			if requireIntakeAttempt(t, ctx, pg, db.PrivateImportManifest{OwnerID: op.owner, OperationID: op.operation}, "reserved") != keys[i] {
				t.Fatal("reservation identity changed on child exit")
			}
		}
		for _, op := range append(append([]durableImportOperation{}, held...), durableImportOperation{peer, peerOp}) {
			res, e := pg.ExecContext(ctx, `UPDATE private_import_attempts SET expires_at=clock_timestamp()-interval '1 second' WHERE owner_id=$1 AND operation_id=$2`, op.owner, op.operation)
			if e != nil {
				t.Fatal("fixture could not advance exact expiry")
			}
			if n, _ := res.RowsAffected(); n != 1 {
				t.Fatal("expiry did not name exactly one attempt")
			}
		}
		next, stopNext := launch(privateLibraryFixtureMode, "")
		defer stopNext()
		after := func(method string, i int) (int, []byte) {
			op := held[i]
			if method == http.MethodPost {
				code, raw, _, _ := call(method, next, uploads, token(op.owner), op.operation.String(), media, bytes.NewReader(body[:prefix]))
				return code, raw
			}
			code, raw, _, _ := call(method, next, uploads+"/"+op.operation.String(), token(op.owner), "", "", nil)
			return code, raw
		}
		if code, _ := after(http.MethodPost, 0); code != 409 {
			t.Errorf("expired matching POST status=%d; want closed 409", code)
		}
		if code, raw := after(http.MethodGet, 0); code != 200 || !bytes.Contains(raw, []byte(`"status":"closed"`)) {
			t.Errorf("expired matching GET status=%d; want closed 200", code)
		}
		if code, raw := after(http.MethodGet, 1); code != 200 || !bytes.Contains(raw, []byte(`"status":"closed"`)) {
			t.Errorf("expired exact GET did not close: %d", code)
		}
		if code, _ := after(http.MethodPost, 1); code != 409 {
			t.Errorf("expired POST after GET status=%d", code)
		}
		slot := durableImportOperation{held[2].owner, uuid.New()}
		f.operations[slot] = struct{}{}
		code, _, _, _ := call(http.MethodPost, next, uploads, token(slot.owner), slot.operation.String(), media, bytes.NewReader(body))
		if code != 201 {
			t.Errorf("fresh upload against untouched expired owner slot status=%d; want 201", code)
		}
		for i, op := range held {
			var phase, title string
			if e := pg.QueryRowContext(ctx, `SELECT phase,title FROM private_import_attempts WHERE owner_id=$1 AND operation_id=$2`, op.owner, op.operation).Scan(&phase, &title); e != nil || phase != "refused" || title != "" {
				t.Errorf("expired never-authorized attempt %d did not settle: phase=%s", i, phase)
			}
		}
		requireIntakeAttempt(t, ctx, pg, db.PrivateImportManifest{OwnerID: peer, OperationID: peerOp}, "putting")
		blocked := durableImportOperation{peer, uuid.New()}
		f.operations[blocked] = struct{}{}
		code, raw, _, _ := call(http.MethodPost, next, uploads, token(peer), blocked.operation.String(), media, bytes.NewReader(body))
		if code != 503 || !bytes.Contains(raw, []byte("UPLOAD_CAPACITY")) {
			t.Error("dispatched unknown peer no longer charged")
		}
		if puts.Load() != baseline+2 {
			t.Errorf("expected only unknown peer and fresh control Put; observed %d", puts.Load()-baseline)
		}
	})
}

func requireUploadEventually(t *testing.T, ctx context.Context, description string, ready func() bool) {
	t.Helper()
	tick := time.NewTicker(25 * time.Millisecond)
	defer tick.Stop()
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	for !ready() {
		select {
		case <-ctx.Done():
			t.Fatalf("fixture canceled: %s", description)
		case <-deadline.C:
			t.Fatalf("fixture timed out: %s", description)
		case <-tick.C:
		}
	}
}

type fixtureBucketGrant struct {
	Endpoint string `json:"endpoint"`
	Bucket   string `json:"bucket"`
}

func requireUnboundLibraryRefusal(t *testing.T, env []string, optionalGrant ...fixtureBucketGrant) {
	t.Helper()
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal("reserve unbound control socket")
	}
	addr := l.Addr().String()
	_ = l.Close()
	health, err := http.NewRequestWithContext(t.Context(), http.MethodGet, "http://"+addr+"/health/live", nil)
	if err != nil {
		t.Fatal("build unbound control health request")
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal("resolve fixture binary")
	}
	child := exec.Command(exe, "-test.run=^TestPrivateLibraryUploadServerChild$")
	child.Env = append(append([]string{}, env...), "SERVER_ADDR="+addr)
	if len(optionalGrant) == 1 {
		defer attachFixtureBucketGrant(t, child, optionalGrant[0])()
	}
	if err := child.Start(); err != nil {
		t.Fatal("start unbound control child")
	}
	result := make(chan error, 1)
	go func() { result <- child.Wait() }()
	client := &http.Client{Timeout: 200 * time.Millisecond}
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(25 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case err := <-result:
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 1 {
				t.Fatal("unbound mode did not refuse with startup exit 1")
			}
			return
		case <-deadline.C:
			_ = child.Process.Kill()
			<-result
			t.Fatal("unbound mode did not settle")
		case <-tick.C:
			if resp, err := client.Do(health); err == nil {
				_ = resp.Body.Close()
				_ = child.Process.Kill()
				<-result
				t.Fatal("mode activated from environment and a bucket name, without a provisioner binding")
			}
		}
	}
}

func startPrivateLibraryHTTPChild(t *testing.T, ctx context.Context, env []string, grant fixtureBucketGrant, captureKill ...*func()) (string, func()) {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal("reserve child address")
	}
	addr := listener.Addr().String()
	_ = listener.Close()
	base := "http://" + addr
	health, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/health/live", nil)
	if err != nil {
		t.Fatal("build real server health request")
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal("resolve test executable")
	}
	child := exec.Command(exe, "-test.run=^TestPrivateLibraryUploadServerChild$")
	child.Env = append(append([]string{}, env...), "SERVER_ADDR="+addr)
	closeGrant := attachFixtureBucketGrant(t, child, grant)
	defer closeGrant()
	var logs bytes.Buffer
	child.Stdout, child.Stderr = &logs, &logs
	if err := child.Start(); err != nil {
		t.Fatal("start real server child")
	}
	var once sync.Once
	result := make(chan error, 1)
	go func() { result <- child.Wait() }()
	for _, capture := range captureKill {
		*capture = func() {
			once.Do(func() {
				if err := child.Process.Kill(); err != nil {
					t.Fatal("kill held server process")
				}
				var exit *exec.ExitError
				if err := <-result; !errors.As(err, &exit) || exit.Sys().(syscall.WaitStatus).Signal() != syscall.SIGKILL {
					t.Fatal("held server did not exit via SIGKILL")
				}
			})
		}
	}
	stop := func() {
		once.Do(func() {
			_ = child.Process.Signal(os.Interrupt)
			var err error
			select {
			case err = <-result:
			case <-time.After(6 * time.Second):
				_ = child.Process.Kill()
				err = <-result
			}
			if err != nil {
				t.Errorf("real server process failed: %v\n%s", err, logs.String())
			}
			if strings.Contains(logs.String(), "refused unexpected outbound HTTP") {
				t.Error("server attempted unexpected outbound HTTP")
			}
		})
	}
	t.Cleanup(stop)
	poll := &http.Client{Timeout: 250 * time.Millisecond}
	requireUploadEventually(t, ctx, "real server health", func() bool {
		res, e := poll.Do(health)
		if e != nil {
			return false
		}
		defer res.Body.Close()
		return res.StatusCode == 200
	})
	return base, stop
}

func privateLibraryMultipart(t *testing.T, manifest string, audio, extra []byte) ([]byte, string) {
	t.Helper()
	var b bytes.Buffer
	form := multipart.NewWriter(&b)
	part := func(name, media string, data []byte) {
		header := make(textproto.MIMEHeader)
		header.Set("Content-Disposition", fmt.Sprintf(`form-data; name=%q`, name))
		header.Set("Content-Type", media)
		w, err := form.CreatePart(header)
		if err != nil {
			t.Fatal("form header serialization failed")
		}
		if _, err := w.Write(data); err != nil {
			t.Fatal("form body serialization failed")
		}
	}
	part("manifest", "application/json", []byte(manifest))
	part("audio", "audio/mpeg", audio)
	if extra != nil {
		part("extra", "application/octet-stream", extra)
	}
	if err := form.Close(); err != nil {
		t.Fatal("form closing serialization failed")
	}
	return b.Bytes(), form.FormDataContentType()
}
