package connect

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"
)

func TestConnectReportConflictRaceAgainstRedis(t *testing.T) {
	s, client, owner := redisService(t)
	ctx := context.Background()
	reg := registration()
	d, err := s.Register(ctx, owner, 0, reg)
	if err != nil {
		t.Fatal(err)
	}
	requests := []ReportRequest{{LeaseID: d.LeaseID, WriterSecret: reg.WriterSecret, Sequence: 1, Playback: nil}, {LeaseID: d.LeaseID, WriterSecret: reg.WriterSecret, Sequence: 1, Playback: &Playback{SessionID: "s", Track: Track{Title: "T"}, ProcessingState: "ready"}}}
	var wg sync.WaitGroup
	start := make(chan struct{})
	results := make(chan error, 2)
	for _, req := range requests {
		wg.Add(1)
		go func(req ReportRequest) {
			defer wg.Done()
			<-start
			_, err := s.Report(ctx, owner, 0, d.DeviceID, req)
			results <- err
		}(req)
	}
	close(start)
	wg.Wait()
	close(results)
	wins, conflicts := 0, 0
	for err := range results {
		if err == nil {
			wins++
		} else if errors.Is(err, ErrStale) {
			conflicts++
		} else {
			t.Fatal(err)
		}
	}
	if wins != 1 || conflicts != 1 {
		t.Fatalf("wins=%d conflicts=%d", wins, conflicts)
	}
	// Exact concurrent retries all replay the winner and never extend its expiry.
	devices, _, err := s.List(ctx, owner, 0)
	if err != nil || len(devices) != 1 {
		t.Fatalf("list=%v %v", devices, err)
	}
	winner := requests[0]
	winner.Playback = devices[0].Playback
	expiry := devices[0].LeaseExpiresAt
	results = make(chan error, 16)
	start = make(chan struct{})
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			got, err := s.Report(ctx, owner, 0, d.DeviceID, winner)
			if err == nil && !got.LeaseExpiresAt.Equal(expiry) {
				err = errors.New("replay renewed expiry")
			}
			results <- err
		}()
	}
	close(start)
	wg.Wait()
	close(results)
	for err := range results {
		if err != nil {
			t.Fatal(err)
		}
	}
	// Real Redis expiration, not only logical fixture pruning.
	if err = client.PExpire(ctx, key(owner, 0), 15*time.Millisecond).Err(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(30 * time.Millisecond)
	if _, err = s.Report(ctx, owner, 0, d.DeviceID, winner); !errors.Is(err, ErrGone) {
		t.Fatalf("physical expiry=%v", err)
	}
	if client.Exists(ctx, key(owner, 0)).Val() != 0 {
		t.Fatal("late report recreated key")
	}
}

func TestConnectExpiredSlotRaceAgainstRedis(t *testing.T) {
	s, client, owner := redisService(t)
	ctx := context.Background()
	for i := 0; i < 8; i++ {
		if _, err := s.Register(ctx, owner, 0, registration()); err != nil {
			t.Fatal(err)
		}
	}
	records := map[string]record{}
	if err := json.Unmarshal([]byte(client.Get(ctx, key(owner, 0)).Val()), &records); err != nil {
		t.Fatal(err)
	}
	for id, r := range records {
		r.Device.LeaseExpiresAt = time.Unix(1, 0)
		records[id] = r
		break
	}
	raw, _ := json.Marshal(records)
	if err := client.Set(ctx, key(owner, 0), raw, LeaseTTL).Err(); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, err := s.Register(ctx, owner, 0, registration()); results <- err }()
	}
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
	if wins != 1 {
		t.Fatalf("expired slot winners=%d", wins)
	}
}

func TestConnectRedisFailureIsClosed(t *testing.T) {
	s, client, owner := redisService(t)
	client.Close()
	if _, _, err := s.List(context.Background(), owner, 0); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("list on closed Redis=%v", err)
	}
	var disabled *Service
	if _, _, err := disabled.List(context.Background(), owner, 0); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("disabled=%v", err)
	}
}
