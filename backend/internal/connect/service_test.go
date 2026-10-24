package connect

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

func redisService(t *testing.T) (*Service, *redis.Client, uuid.UUID) {
	t.Helper()
	addr := os.Getenv("OMP_CONNECT_REDIS_ADDR")
	if addr == "" {
		t.Skip("OMP_CONNECT_REDIS_ADDR not set")
	}
	client := redis.NewClient(&redis.Options{Addr: addr})
	t.Cleanup(func() { client.Close() })
	if err := client.Ping(context.Background()).Err(); err != nil {
		t.Fatal(err)
	}
	owner := uuid.New()
	t.Cleanup(func() { client.Del(context.Background(), key(owner, 0), key(owner, 1)) })
	return NewService(client), client, owner
}
func registration() RegisterRequest {
	return RegisterRequest{DeviceID: uuid.NewString(), Label: "Laptop", Platform: "macos", WriterSecret: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))}
}

func TestConnectRegisterListAgainstRedis(t *testing.T) {
	s, client, owner := redisService(t)
	ctx := context.Background()
	req := registration()
	device, err := s.Register(ctx, owner, 0, req)
	if err != nil {
		t.Fatal(err)
	}
	if device.DeviceID != req.DeviceID || device.LeaseID == "" || device.Sequence != 0 || device.Playback != nil {
		t.Fatalf("device=%+v", device)
	}
	ttl, err := client.PTTL(ctx, key(owner, 0)).Result()
	if err != nil || ttl <= 0 || ttl > 90*time.Second {
		t.Fatalf("ttl=%v %v", ttl, err)
	}
	time.Sleep(15 * time.Millisecond)
	retry, err := s.Register(ctx, owner, 0, req)
	if err != nil || retry != device {
		t.Fatalf("retry=%+v %v", retry, err)
	}
	after := client.PTTL(ctx, key(owner, 0)).Val()
	if after >= ttl {
		t.Fatalf("registration retry renewed TTL %v -> %v", ttl, after)
	}
	devices, _, err := s.List(ctx, owner, 0)
	if err != nil || len(devices) != 1 {
		t.Fatalf("list=%v %v", devices, err)
	}
	other, _, err := s.List(ctx, uuid.New(), 0)
	if err != nil || len(other) != 0 {
		t.Fatalf("cross-account=%v %v", other, err)
	}
	other, _, err = s.List(ctx, owner, 1)
	if err != nil || len(other) != 0 {
		t.Fatalf("cross-generation=%v %v", other, err)
	}
	changed := req
	changed.Label = "Other"
	if _, err = s.Register(ctx, owner, 0, changed); !errors.Is(err, ErrConflict) {
		t.Fatalf("conflict=%v", err)
	}
	raw := client.Get(ctx, key(owner, 0)).Val()
	if raw == "" {
		t.Fatal("no persisted map")
	}
}
func TestConnectCapRaceAgainstRedis(t *testing.T) {
	s, _, owner := redisService(t)
	ctx := context.Background()
	var wg sync.WaitGroup
	results := make(chan error, 24)
	start := make(chan struct{})
	for i := 0; i < 24; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); <-start; _, err := s.Register(ctx, owner, 0, registration()); results <- err }()
	}
	close(start)
	wg.Wait()
	close(results)
	wins := 0
	for err := range results {
		if err == nil {
			wins++
		} else if !errors.Is(err, ErrCapacity) {
			t.Fatal(err)
		}
	}
	if wins != 8 {
		t.Fatalf("cap winners=%d", wins)
	}
	devices, _, err := s.List(ctx, owner, 0)
	if err != nil || len(devices) != 8 {
		t.Fatalf("devices=%d err=%v", len(devices), err)
	}
}

func TestConnectReportFencingExpiryAgainstRedis(t *testing.T) {
	s, client, owner := redisService(t)
	ctx := context.Background()
	reg := registration()
	d, err := s.Register(ctx, owner, 0, reg)
	if err != nil {
		t.Fatal(err)
	}
	p := &Playback{SessionID: "session", Track: Track{Title: "Track", Artist: "Artist"}, Playing: true, ProcessingState: "ready", PositionMs: 125, DurationMs: 5000, ActiveVoiceCount: 1}
	report := ReportRequest{LeaseID: d.LeaseID, WriterSecret: reg.WriterSecret, Sequence: 1, Playback: p}
	accepted, err := s.Report(ctx, owner, 0, d.DeviceID, report)
	if err != nil {
		t.Fatal(err)
	}
	raw := client.Get(ctx, key(owner, 0)).Val()
	if strings.Contains(raw, reg.WriterSecret) {
		t.Fatal("plaintext writer persisted")
	}
	before := client.PTTL(ctx, key(owner, 0)).Val()
	time.Sleep(10 * time.Millisecond)
	duplicate, err := s.Report(ctx, owner, 0, d.DeviceID, report)
	if err != nil || !reflect.DeepEqual(duplicate, accepted) {
		t.Fatalf("duplicate=%+v err=%v", duplicate, err)
	}
	if after := client.PTTL(ctx, key(owner, 0)).Val(); after >= before {
		t.Fatal("duplicate renewed TTL")
	}
	changed := report
	changed.Playback = nil
	if _, err = s.Report(ctx, owner, 0, d.DeviceID, changed); !errors.Is(err, ErrStale) {
		t.Fatalf("changed duplicate=%v", err)
	}
	newer := report
	newer.Sequence = 2
	if _, err = s.Report(ctx, owner, 0, d.DeviceID, newer); !errors.Is(err, ErrRate) {
		t.Fatalf("rate=%v", err)
	}
	wrong := report
	wrong.LeaseID = uuid.NewString()
	if _, err = s.Report(ctx, owner, 0, d.DeviceID, wrong); !errors.Is(err, ErrGone) {
		t.Fatalf("incarnation=%v", err)
	}
	wrong = report
	wrong.WriterSecret = base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	if _, err = s.Report(ctx, owner, 0, d.DeviceID, wrong); !errors.Is(err, ErrWriter) {
		t.Fatalf("writer=%v", err)
	}
	// Move only this fixture's report time backwards to exercise newer-sequence acceptance without a wall-clock sleep.
	records := map[string]record{}
	if err = json.Unmarshal([]byte(raw), &records); err != nil {
		t.Fatal(err)
	}
	r := records[d.DeviceID]
	r.Device.LastSeenAt = r.Device.LastSeenAt.Add(-2 * time.Second)
	records[d.DeviceID] = r
	data, _ := json.Marshal(records)
	client.Set(ctx, key(owner, 0), data, LeaseTTL)
	accepted, err = s.Report(ctx, owner, 0, d.DeviceID, newer)
	if err != nil || accepted.Sequence != 2 {
		t.Fatalf("newer=%+v %v", accepted, err)
	}
	if _, err = s.Report(ctx, owner, 0, d.DeviceID, report); !errors.Is(err, ErrStale) {
		t.Fatalf("lower=%v", err)
	}
	// Independent record expiry is enforced even while the account map survives.
	raw = client.Get(ctx, key(owner, 0)).Val()
	json.Unmarshal([]byte(raw), &records)
	r = records[d.DeviceID]
	r.Device.LeaseExpiresAt = time.Unix(1, 0)
	records[d.DeviceID] = r
	data, _ = json.Marshal(records)
	client.Set(ctx, key(owner, 0), data, LeaseTTL)
	devices, _, err := s.List(ctx, owner, 0)
	if err != nil || len(devices) != 0 {
		t.Fatalf("expired=%v %v", devices, err)
	}
	if _, err = s.Report(ctx, owner, 0, d.DeviceID, newer); !errors.Is(err, ErrGone) {
		t.Fatalf("expired report=%v", err)
	}
	next, err := s.Register(ctx, owner, 0, reg)
	if err != nil || next.LeaseID == d.LeaseID {
		t.Fatalf("reregister=%v %v", next, err)
	}
	if err = s.Remove(ctx, owner, 0, d.DeviceID, Proof{LeaseID: d.LeaseID, WriterSecret: reg.WriterSecret}); !errors.Is(err, ErrGone) {
		t.Fatalf("late remove=%v", err)
	}
	if err = s.Remove(ctx, owner, 0, d.DeviceID, Proof{LeaseID: next.LeaseID, WriterSecret: wrong.WriterSecret}); !errors.Is(err, ErrWriter) {
		t.Fatalf("viewer remove=%v", err)
	}
	proof := Proof{LeaseID: next.LeaseID, WriterSecret: reg.WriterSecret}
	if err = s.Remove(ctx, owner, 0, d.DeviceID, proof); err != nil {
		t.Fatal(err)
	}
	if err = s.Remove(ctx, owner, 0, d.DeviceID, proof); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Report(ctx, owner, 0, d.DeviceID, newer); !errors.Is(err, ErrGone) {
		t.Fatalf("deleted report resurrected=%v", err)
	}
}
