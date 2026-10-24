package api

// Read-only playback qualification: synthetic repos, real handlers/storage SDK,
// and worker-owned loopback HTTP only. These tests do not qualify native audio,
// MinIO authorization, deployment routing, or real object-store throughput.
import (
	"bytes"
	"context"
	"database/sql"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/middleware"
	"github.com/openmusicplayer/backend/internal/storage"
)

var playbackProbeOwner = uuid.MustParse("11111111-1111-1111-1111-111111111111")

// Each dependency operation shares one counter so concurrency is observed across
// dependency families, not inferred from elapsed time. Waits honor real contexts.
type playbackProbeDeps struct {
	mu           sync.Mutex
	calls        map[string]int
	active, peak int
	delay        time.Duration
	blockStage   string
	entered      chan struct{}
	enterOnce    sync.Once
	failStage    string
	failure      error
	deniedID     int64
	noKeyID      int64
}

func (p *playbackProbeDeps) operation(ctx context.Context, stage string) error {
	p.mu.Lock()
	if p.calls == nil {
		p.calls = make(map[string]int)
	}
	p.calls[stage]++
	p.active++
	if p.active > p.peak {
		p.peak = p.active
	}
	p.mu.Unlock()
	defer func() { p.mu.Lock(); p.active--; p.mu.Unlock() }()
	if stage == p.blockStage {
		p.enterOnce.Do(func() { close(p.entered) })
		<-ctx.Done()
		return ctx.Err()
	}
	if p.delay > 0 {
		timer := time.NewTimer(p.delay)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
		}
	}
	if stage == p.failStage {
		return p.failure
	}
	return nil
}
func (p *playbackProbeDeps) IsTrackInLibrary(ctx context.Context, user uuid.UUID, id int64) (bool, error) {
	if err := p.operation(ctx, "owner"); err != nil {
		return false, err
	}
	return user == playbackProbeOwner && id != p.deniedID, nil
}
func (p *playbackProbeDeps) GetByID(ctx context.Context, id int64) (*db.Track, error) {
	if err := p.operation(ctx, "track"); err != nil {
		return nil, err
	}
	return &db.Track{ID: id, StorageKey: sql.NullString{String: fmt.Sprintf("audio/%d.wav", id), Valid: id != p.noKeyID}, Version: sql.NullString{String: "probe-v1", Valid: true}, Codec: sql.NullString{String: "pcm_s16le", Valid: true}, SampleRateHz: sql.NullInt32{Int32: 8000, Valid: true}, Channels: sql.NullInt32{Int32: 1, Valid: true}}, nil
}
func (p *playbackProbeDeps) StatObject(ctx context.Context, key string) (*storage.ObjectInfo, error) {
	if err := p.operation(ctx, "stat"); err != nil {
		return nil, err
	}
	return &storage.ObjectInfo{Size: 300, ContentType: "audio/wav", ETag: "probe-etag"}, nil
}
func (p *playbackProbeDeps) PresignGetObject(ctx context.Context, key string, ttl time.Duration) (string, error) {
	if err := p.operation(ctx, "sign"); err != nil {
		return "", err
	}
	return "https://synthetic.invalid/" + key, nil
}
func (p *playbackProbeDeps) snapshot() (map[string]int, int, int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := map[string]int{}
	for k, v := range p.calls {
		out[k] = v
	}
	return out, p.peak, p.active
}
func playbackProbeBody(n int) string {
	ids := make([]int64, n)
	for i := range ids {
		ids[i] = int64(i + 1)
	}
	b, _ := json.Marshal(PlaybackURLRequest{TrackIDs: ids})
	return string(b)
}
func playbackProbeAssertCalls(t *testing.T, p *playbackProbeDeps, want map[string]int) {
	t.Helper()
	got, peak, active := p.snapshot()
	if !reflect.DeepEqual(got, want) || active != 0 || peak > 1 {
		t.Fatalf("calls=%v peak=%d active=%d, want=%v serial settled", got, peak, active, want)
	}
}

func TestPlaybackSupportProbeBoundedBatch(t *testing.T) {
	for _, n := range []int{1, 10, 50, 51} {
		t.Run(strconv.Itoa(n), func(t *testing.T) {
			p := &playbackProbeDeps{}
			h := NewPlaybackHandlers(p, p, p)
			r := playbackRequest(t, h.CreatePlaybackURLs, playbackProbeBody(n))
			want := map[string]int{}
			if n <= 50 {
				if r.Code != 200 {
					t.Fatalf("status=%d body=%s", r.Code, r.Body)
				}
				var body PlaybackURLResponse
				if err := json.Unmarshal(r.Body.Bytes(), &body); err != nil || len(body.URLs) != n {
					t.Fatalf("decode=%v urls=%d", err, len(body.URLs))
				}
				for i, item := range body.URLs {
					if item.TrackID != int64(i+1) {
						t.Fatal("request order lost")
					}
				}
				want = map[string]int{"owner": n, "track": n, "stat": n, "sign": n}
			} else if r.Code != 400 {
				t.Fatalf("51 unique status=%d", r.Code)
			}
			playbackProbeAssertCalls(t, p, want)
		})
	}
	t.Run("duplicates_do_not_repeat_work", func(t *testing.T) {
		p := &playbackProbeDeps{}
		h := NewPlaybackHandlers(p, p, p)
		body := `{"trackIds":[` + strings.Repeat("1,", 9999) + `1]}`
		r := playbackRequest(t, h.CreatePlaybackURLs, body)
		if r.Code != 200 {
			t.Fatalf("duplicate status=%d", r.Code)
		}
		playbackProbeAssertCalls(t, p, map[string]int{"owner": 1, "track": 1, "stat": 1, "sign": 1})
		t.Logf("raw_ids=10000 distinct_ids=1 body_bytes=%d status=%d; 50 is a distinct-ID work cap, not a body cap", len(body), r.Code)
	})
}

func TestPlaybackSupportProbeErrorBoundaries(t *testing.T) {
	cases := []struct {
		name, stage string
		err         error
		status      int
		calls       map[string]int
	}{
		{"owner_failure", "owner", errors.New("synthetic database failure"), 500, map[string]int{"owner": 1}},
		{"track_failure", "track", errors.New("synthetic database failure"), 500, map[string]int{"owner": 1, "track": 1}},
		{"track_missing", "track", db.ErrTrackNotFound, 404, map[string]int{"owner": 1, "track": 1}},
		{"stat_failure_service_unavailable", "stat", errors.New("synthetic upstream 500"), 503, map[string]int{"owner": 1, "track": 1, "stat": 1}},
		{"sign_failure", "sign", errors.New("synthetic signing failure"), 500, map[string]int{"owner": 1, "track": 1, "stat": 1, "sign": 1}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := &playbackProbeDeps{failStage: tc.stage, failure: tc.err}
			h := NewPlaybackHandlers(p, p, p)
			r := playbackRequest(t, h.CreatePlaybackURLs, `{"trackIds":[1,2]}`)
			if r.Code != tc.status {
				t.Fatalf("status=%d want=%d body=%s", r.Code, tc.status, r.Body)
			}
			want := tc.calls
			if tc.stage == "stat" {
				if r.Body.String() != "{\"code\":\"SERVICE_UNAVAILABLE\",\"message\":\"playback URL issuance is unavailable\"}\n" {
					t.Fatalf("unexpected service-error envelope=%s", r.Body)
				}
			}
			if strings.Contains(r.Body.String(), "synthetic database") || strings.Contains(r.Body.String(), "synthetic signing") {
				t.Fatal("dependency details leaked")
			}
			playbackProbeAssertCalls(t, p, want)
		})
	}
	t.Run("late_unowned_discards_partial_results", func(t *testing.T) {
		p := &playbackProbeDeps{deniedID: 2}
		h := NewPlaybackHandlers(p, p, p)
		r := playbackRequest(t, h.CreatePlaybackURLs, `{"trackIds":[1,2,3]}`)
		if r.Code != 404 || strings.Contains(r.Body.String(), "synthetic.invalid") {
			t.Fatalf("status=%d body=%s", r.Code, r.Body)
		}
		playbackProbeAssertCalls(t, p, map[string]int{"owner": 2, "track": 1, "stat": 1, "sign": 1})
	})
	t.Run("mixed_missing_key_preserves_available", func(t *testing.T) {
		p := &playbackProbeDeps{noKeyID: 2}
		h := NewPlaybackHandlers(p, p, p)
		r := playbackRequest(t, h.CreatePlaybackURLs, `{"trackIds":[1,2,3]}`)
		var b PlaybackURLResponse
		err := json.Unmarshal(r.Body.Bytes(), &b)
		if err != nil || r.Code != 200 || len(b.URLs) != 2 || b.URLs[0].TrackID != 1 || b.URLs[1].TrackID != 3 || len(b.Unavailable) != 1 || b.Unavailable[0].Code != "audio_unavailable" {
			t.Fatalf("status=%d decode=%v body=%s", r.Code, err, r.Body)
		}
		playbackProbeAssertCalls(t, p, map[string]int{"owner": 3, "track": 3, "stat": 2, "sign": 2})
	})
}

const playbackProbeSecret = "synthetic-playback-probe-only-not-a-real-secret"

func playbackProbeToken(t *testing.T, user uuid.UUID) string {
	t.Helper()
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"user_id": user.String(), "email": "probe@example.invalid", "exp": time.Now().Add(time.Hour).Unix()}).SignedString([]byte(playbackProbeSecret))
	if err != nil {
		t.Fatal(err)
	}
	return token
}
func playbackProbeServer(t *testing.T, h *PlaybackHandlers, done chan struct{}) *httptest.Server {
	t.Helper()
	svc := auth.NewService(nil, nil, playbackProbeSecret)
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(svc), AuthService: svc, PlaybackHandlers: h})
	var handler http.Handler = middleware.Timing(middleware.Gzip(middleware.ETag(router)))
	if done != nil {
		next := handler
		handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { defer close(done); next.ServeHTTP(w, r) })
	}
	s := httptest.NewServer(handler)
	t.Cleanup(s.Close)
	return s
}
func playbackProbePost(t *testing.T, s *httptest.Server, body, token string) (int, http.Header, []byte) {
	t.Helper()
	r, err := http.NewRequestWithContext(context.Background(), http.MethodPost, s.URL+"/api/v1/playback/urls", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Content-Type", "application/json")
	client := s.Client()
	client.Timeout = 3 * time.Second
	resp, err := client.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, resp.Header, b
}
func TestPlaybackSupportProbeWireAccountIsolation(t *testing.T) {
	p := &playbackProbeDeps{}
	s := playbackProbeServer(t, NewPlaybackHandlers(p, p, p), nil)
	status, _, b := playbackProbePost(t, s, `{"trackIds":[1]}`, playbackProbeToken(t, uuid.MustParse("22222222-2222-2222-2222-222222222222")))
	if status != 404 || strings.Contains(string(b), "url") {
		t.Fatalf("status=%d body=%s", status, b)
	}
	playbackProbeAssertCalls(t, p, map[string]int{"owner": 1})
	status, headers, _ := playbackProbePost(t, s, `{"trackIds":[1]}`, "invalid-synthetic-token")
	// Authentication middleware intentionally uses http.Error, not the
	// playback handler's JSON envelope. This assertion qualifies rejection and
	// zero additional dependency work, not an invented JSON auth contract.
	if status != 401 || headers.Get("Content-Type") != "text/plain; charset=utf-8" {
		t.Fatalf("unauthorized status=%d headers=%v", status, headers)
	}
	playbackProbeAssertCalls(t, p, map[string]int{"owner": 1})
}

// A tiny valid PCM WAV, not a private fixture or proof of native decoding.
func playbackProbeWAV() []byte {
	b := make([]byte, 300)
	copy(b, "RIFF")
	binary.LittleEndian.PutUint32(b[4:], 292)
	copy(b[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(b[16:], 16)
	binary.LittleEndian.PutUint16(b[20:], 1)
	binary.LittleEndian.PutUint16(b[22:], 1)
	binary.LittleEndian.PutUint32(b[24:], 8000)
	binary.LittleEndian.PutUint32(b[28:], 16000)
	binary.LittleEndian.PutUint16(b[32:], 2)
	binary.LittleEndian.PutUint16(b[34:], 16)
	copy(b[36:], "data")
	binary.LittleEndian.PutUint32(b[40:], 256)
	return b
}
func playbackProbeStorage(t *testing.T, internal, public string) *storage.Client {
	t.Helper()
	c, err := storage.New(&storage.Config{Endpoint: internal, PublicEndpoint: public, Region: "us-east-1", AccessKey: "synthetic-probe", SecretKey: "synthetic-probe-secret", Bucket: "probe-audio"})
	if err != nil {
		t.Fatal(err)
	}
	return c
}
func TestPlaybackSupportProbeWireMedia(t *testing.T) {
	wav := playbackProbeWAV()
	var headCount, mediaCount int
	var mu sync.Mutex
	internal := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		headCount++
		mu.Unlock()
		if r.Method != "HEAD" || r.URL.Path != "/probe-audio/audio/1.wav" || !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 ") {
			t.Errorf("unexpected metadata request: %s %s", r.Method, r.URL.Path)
			http.Error(w, "bad metadata request", 400)
			return
		}
		w.Header().Set("Content-Length", strconv.Itoa(len(wav)))
		w.Header().Set("Content-Type", "audio/wav")
		w.Header().Set("ETag", `"probe-etag"`)
		w.Header().Set("Last-Modified", time.Unix(0, 0).UTC().Format(http.TimeFormat))
	}))
	defer internal.Close()
	media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		mediaCount++
		mu.Unlock()
		if r.URL.Path != "/probe-audio/audio/1.wav" || r.URL.Query().Get("X-Amz-Expires") != "300" || r.URL.Query().Get("X-Amz-Signature") == "" || r.Header.Get("Authorization") != "" {
			t.Error("bad signed-read shape (query deliberately not printed)")
			http.Error(w, "bad signed read", 400)
			return
		}
		w.Header().Set("Content-Type", "audio/wav")
		w.Header().Set("ETag", `"probe-etag"`)
		http.ServeContent(w, r, "1.wav", time.Unix(0, 0), bytes.NewReader(wav))
	}))
	defer media.Close()
	p := &playbackProbeDeps{}
	h := NewPlaybackHandlers(p, p, playbackProbeStorage(t, internal.URL, media.URL))
	s := playbackProbeServer(t, h, nil)
	status, headers, b := playbackProbePost(t, s, `{"trackIds":[1],"ttlSeconds":300}`, playbackProbeToken(t, playbackProbeOwner))
	if status != 200 || headers.Get("Cache-Control") != "no-store" || headers.Get("ETag") != "" {
		t.Fatalf("status=%d cache=%q etag=%q", status, headers.Get("Cache-Control"), headers.Get("ETag"))
	}
	var desc PlaybackURLResponse
	if err := json.Unmarshal(b, &desc); err != nil || len(desc.URLs) != 1 {
		t.Fatalf("decode=%v descriptors=%d", err, len(desc.URLs))
	}
	item := desc.URLs[0]
	parsed, err := url.Parse(item.URL)
	if err != nil {
		t.Fatal("signed URL parse failed")
	}
	public, _ := url.Parse(media.URL)
	if parsed.Host != public.Host || item.SizeBytes != 300 || item.ContentType != "audio/wav" || item.Codec != "pcm_s16le" || item.ETag != "probe-etag" || item.StorageKeyVersion != "probe-v1" || item.SampleRateHz != 8000 || item.Channels != 1 {
		t.Fatal("metadata/public endpoint mismatch; signed URL not printed")
	}
	for _, tc := range []struct {
		name, method, rangeHeader string
		status                    int
		expected                  []byte
		contentRange              string
	}{
		{"all_bytes", "GET", "", 200, wav, ""},
		{"first_26_bytes", "GET", "bytes=0-25", 206, wav[:26], "bytes 0-25/300"},
		{"suffix", "GET", "bytes=-10", 206, wav[290:], "bytes 290-299/300"},
		{"head", "HEAD", "", 200, []byte{}, ""},
		{"unsatisfiable", "GET", "bytes=300-", 416, nil, "bytes */300"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := http.NewRequestWithContext(context.Background(), tc.method, item.URL, nil)
			if tc.rangeHeader != "" {
				r.Header.Set("Range", tc.rangeHeader)
			}
			client := media.Client()
			client.Timeout = 3 * time.Second
			resp, err := client.Do(r)
			if err != nil {
				t.Fatal("media request failed")
			}
			defer resp.Body.Close()
			got, err := io.ReadAll(resp.Body)
			if err != nil || resp.StatusCode != tc.status || resp.Header.Get("Content-Range") != tc.contentRange {
				t.Fatalf("status=%d range=%q read=%v", resp.StatusCode, resp.Header.Get("Content-Range"), err)
			}
			if tc.expected != nil && !bytes.Equal(got, tc.expected) {
				t.Fatalf("bytes=%d want=%d", len(got), len(tc.expected))
			}
			if tc.status != 416 && (resp.Header.Get("Content-Type") != "audio/wav" || resp.Header.Get("Accept-Ranges") != "bytes" || resp.Header.Get("ETag") != `"probe-etag"`) {
				t.Fatal("media support headers mismatch")
			}
			wantLen := len(tc.expected)
			if tc.method == "HEAD" {
				wantLen = len(wav)
			}
			if tc.status != 416 && resp.ContentLength != int64(wantLen) {
				t.Fatalf("length=%d want=%d", resp.ContentLength, wantLen)
			}
		})
	}
	mu.Lock()
	defer mu.Unlock()
	if headCount != 1 || mediaCount != 5 {
		t.Fatalf("metadata=%d media=%d", headCount, mediaCount)
	}
	t.Log("real storage SDK metadata+signing; loopback ServeContent all=300 range=26 suffix=10 HEAD=0 416; not real MinIO/signature verification/native decoding")
}

func TestPlaybackSupportProbeWireCancellation(t *testing.T) {
	for _, stage := range []string{"owner", "track", "stat", "sign"} {
		t.Run(stage, func(t *testing.T) {
			p := &playbackProbeDeps{blockStage: stage, entered: make(chan struct{})}
			done := make(chan struct{})
			s := playbackProbeServer(t, NewPlaybackHandlers(p, p, p), done)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			r, _ := http.NewRequestWithContext(ctx, "POST", s.URL+"/api/v1/playback/urls", strings.NewReader(`{"trackIds":[1,2]}`))
			r.Header.Set("Authorization", "Bearer "+playbackProbeToken(t, playbackProbeOwner))
			result := make(chan error, 1)
			go func() {
				resp, err := s.Client().Do(r)
				if resp != nil {
					resp.Body.Close()
				}
				result <- err
			}()
			select {
			case <-p.entered:
			case <-time.After(3 * time.Second):
				t.Fatal("dependency not entered")
			}
			start := time.Now()
			cancel()
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("handler failed to settle after cancellation")
			}
			select {
			case err := <-result:
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("client error=%v", err)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("client cancellation did not settle")
			}
			calls, peak, active := p.snapshot()
			want := map[string]int{}
			for _, s := range []string{"owner", "track", "stat", "sign"} {
				want[s] = 1
				if s == stage {
					break
				}
			}
			if !reflect.DeepEqual(calls, want) || peak != 1 || active != 0 {
				t.Fatalf("calls=%v peak=%d active=%d want=%v", calls, peak, active, want)
			}
			t.Logf("cancel_stage=%s observed_settlement=%s calls=%v (failure deadline=3s, not performance SLA)", stage, time.Since(start), calls)
		})
	}
}

func TestPlaybackSupportProbeStorageHTTPCancellation(t *testing.T) {
	entered := make(chan struct{})
	storageDone := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodHead {
			t.Errorf("storage method=%s", r.Method)
		}
		close(entered)
		<-r.Context().Done()
		close(storageDone)
	}))
	defer upstream.Close()
	p := &playbackProbeDeps{}
	done := make(chan struct{})
	s := playbackProbeServer(t, NewPlaybackHandlers(p, p, playbackProbeStorage(t, upstream.URL, "")), done)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r, _ := http.NewRequestWithContext(ctx, "POST", s.URL+"/api/v1/playback/urls", strings.NewReader(`{"trackIds":[1,2]}`))
	r.Header.Set("Authorization", "Bearer "+playbackProbeToken(t, playbackProbeOwner))
	clientDone := make(chan error, 1)
	go func() {
		resp, err := s.Client().Do(r)
		if resp != nil {
			resp.Body.Close()
		}
		clientDone <- err
	}()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("real SDK HEAD not entered")
	}
	cancel()
	for name, barrier := range map[string]<-chan struct{}{"storage HTTP context": storageDone, "API handler": done} {
		select {
		case <-barrier:
		case <-time.After(3 * time.Second):
			t.Fatalf("%s did not cancel", name)
		}
	}
	select {
	case err := <-clientDone:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("client error=%v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("client did not cancel")
	}
	playbackProbeAssertCalls(t, p, map[string]int{"owner": 1, "track": 1})
	t.Log("client cancellation propagated through composed API and real MinIO SDK to loopback HEAD request context; no second track")
}

func TestPlaybackSupportProbeContentTypes(t *testing.T) {
	for _, tc := range []struct{ key, stored, want string }{
		{"audio/1.mp3", "", "audio/mpeg"},
		{"audio/1.m4a", "application/octet-stream", "audio/mp4"},
		{"audio/1.ogg", "", "audio/ogg"},
		{"audio/1.opus", "", "audio/opus"},
		{"audio/1.flac", "", "audio/flac"},
		{"audio/1.wav", "", "audio/wav"},
		{"audio/1.webm", "", "audio/webm"},
		{"audio/1.aac", "audio/aac", "audio/aac"},
	} {
		if got := playbackContentType(tc.key, tc.stored); got != tc.want {
			t.Errorf("key=%s got=%s want=%s", tc.key, got, tc.want)
		}
	}
}

// Real installed SDK + authenticated loopback API, not a fake storage interface.
// The original identical-200 characterization is retained in the handoff evidence;
// these regressions now require missing-object and service-error separation.
func playbackProbeStatFailure(t *testing.T, httpStatus int) (int, []byte, int) {
	t.Helper()
	var mu sync.Mutex
	calls := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		calls++
		mu.Unlock()
		if r.Method != "HEAD" {
			t.Errorf("method=%s want HEAD", r.Method)
		}
		code := "AccessDenied"
		if httpStatus == 404 {
			code = "NoSuchKey"
		}
		w.Header().Set("X-Amz-Error-Code", code)
		w.Header().Set("X-Amz-Error-Message", "synthetic-only")
		w.WriteHeader(httpStatus)
	}))
	defer upstream.Close()
	p := &playbackProbeDeps{}
	s := playbackProbeServer(t, NewPlaybackHandlers(p, p, playbackProbeStorage(t, upstream.URL, "")), nil)
	status, _, body := playbackProbePost(t, s, `{"trackIds":[1]}`, playbackProbeToken(t, playbackProbeOwner))
	mu.Lock()
	n := calls
	mu.Unlock()
	return status, body, n
}
func TestPlaybackSupportProbeStatErrorClassification(t *testing.T) {
	for _, tc := range []struct {
		upstream, want int
		body           string
	}{
		{404, 200, "{\"urls\":[],\"unavailable\":[{\"trackId\":1,\"code\":\"artifact_missing\",\"message\":\"stored audio object is unavailable\"}]}\n"},
		{403, 503, "{\"code\":\"SERVICE_UNAVAILABLE\",\"message\":\"playback URL issuance is unavailable\"}\n"},
	} {
		t.Run(strconv.Itoa(tc.upstream), func(t *testing.T) {
			status, body, calls := playbackProbeStatFailure(t, tc.upstream)
			if status != tc.want || calls != 1 || string(body) != tc.body {
				t.Fatalf("upstream=%d returned=%d want=%d calls=%d body=%s", tc.upstream, status, tc.want, calls, body)
			}
			t.Logf("real_SDK_HEAD=%d API=%d operations=%d body=%s", tc.upstream, status, calls, body)
		})
	}
}
func TestPlaybackSupportProbeREDStatAccessDeniedIsServiceError(t *testing.T) {
	// Keep the original RED assertion/name; it is now an ordinary regression.
	status, body, calls := playbackProbeStatFailure(t, 403)
	if status != http.StatusServiceUnavailable {
		t.Fatalf("upstream HEAD AccessDenied: status=%d want=503 calls=%d body=%s; infrastructure denial must not masquerade as missing artifact", status, calls, body)
	}
}

func TestPlaybackSupportProbeStatFailuresDiscardPartialURLs(t *testing.T) {
	var mu sync.Mutex
	var paths []string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		paths = append(paths, r.URL.Path)
		mu.Unlock()
		if r.Method != http.MethodHead {
			t.Errorf("method=%s want HEAD", r.Method)
		}
		if r.URL.Path == "/probe-audio/audio/1.wav" {
			w.Header().Set("Content-Length", "300")
			w.Header().Set("Content-Type", "audio/wav")
			w.Header().Set("ETag", `"probe-etag"`)
			w.Header().Set("Last-Modified", time.Unix(0, 0).UTC().Format(http.TimeFormat))
			return
		}
		w.Header().Set("X-Minio-Error-Code", "AccessDenied")
		w.Header().Set("X-Minio-Error-Desc", "private synthetic upstream detail")
		w.WriteHeader(http.StatusForbidden)
	}))
	defer upstream.Close()
	p := &playbackProbeDeps{}
	s := playbackProbeServer(t, NewPlaybackHandlers(p, p, playbackProbeStorage(t, upstream.URL, "")), nil)
	status, headers, body := playbackProbePost(t, s, `{"trackIds":[1,2,3]}`, playbackProbeToken(t, playbackProbeOwner))
	want := "{\"code\":\"SERVICE_UNAVAILABLE\",\"message\":\"playback URL issuance is unavailable\"}\n"
	if status != 503 || string(body) != want || headers.Get("Cache-Control") != "no-store" || headers.Get("ETag") != "" {
		t.Fatalf("status=%d want=503 generic envelope; body=%s", status, body)
	}
	mu.Lock()
	gotPaths := append([]string(nil), paths...)
	mu.Unlock()
	if !reflect.DeepEqual(gotPaths, []string{"/probe-audio/audio/1.wav", "/probe-audio/audio/2.wav"}) {
		t.Fatalf("HEAD paths=%v", gotPaths)
	}
	playbackProbeAssertCalls(t, p, map[string]int{"owner": 2, "track": 2})
	t.Log("real SDK first object stat+sign succeeded; second HEAD AccessDenied discarded earlier URL and stopped before third track")
}

func BenchmarkPlaybackSupportProbeRequestEnvelope(b *testing.B) {
	for _, delay := range []time.Duration{0, time.Millisecond} {
		for _, n := range []int{1, 10, 50} {
			b.Run(fmt.Sprintf("tracks=%d/stage_delay=%s", n, delay), func(b *testing.B) {
				p := &playbackProbeDeps{delay: delay}
				h := NewPlaybackHandlers(p, p, p)
				body := playbackProbeBody(n)
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					r := httptest.NewRequest("POST", "/api/v1/playback/urls", strings.NewReader(body))
					r = r.WithContext(context.WithValue(r.Context(), auth.UserContextKey, &auth.UserContext{UserID: playbackProbeOwner}))
					w := httptest.NewRecorder()
					h.CreatePlaybackURLs(w, r)
					if w.Code != 200 {
						b.Fatalf("status=%d", w.Code)
					}
				}
				b.StopTimer()
				calls, peak, active := p.snapshot()
				for _, stage := range []string{"owner", "track", "stat", "sign"} {
					if calls[stage] != b.N*n {
						b.Fatalf("stage=%s calls=%d want=%d", stage, calls[stage], b.N*n)
					}
				}
				if active != 0 || peak != 1 {
					b.Fatalf("active=%d peak=%d", active, peak)
				}
				b.ReportMetric(float64(n*4), "dependency_calls/op")
				b.ReportMetric(float64(n)*4*float64(delay)/float64(time.Millisecond), "injected_ms/op")
				b.ReportMetric(float64(peak), "peak_dependency_ops")
			})
		}
	}
}
