package connect

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestConnectValidateWriterNonRenewingRealRedis(t *testing.T) {
	s, client, owner := redisService(t)
	ctx := context.Background()
	reg := registration()
	d, err := s.Register(ctx, owner, 0, reg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Report(ctx, owner, 0, d.DeviceID, ReportRequest{LeaseID: d.LeaseID, WriterSecret: reg.WriterSecret, Sequence: 1}); err != nil {
		t.Fatal(err)
	}
	before := client.Get(ctx, key(owner, 0)).Val()
	ttl := client.PTTL(ctx, key(owner, 0)).Val()
	time.Sleep(15 * time.Millisecond)
	for i := 0; i < 3; i++ {
		if err = s.ValidateWriter(ctx, owner, 0, d.DeviceID, d.LeaseID, reg.WriterSecret); err != nil {
			t.Fatal(err)
		}
	}
	if after := client.Get(ctx, key(owner, 0)).Val(); after != before {
		t.Fatal("writer validation mutated presence/sequence")
	}
	if after := client.PTTL(ctx, key(owner, 0)).Val(); after >= ttl {
		t.Fatal("writer validation renewed TTL")
	}
	for _, tc := range []struct {
		name, id, lease, secret string
		generation              int64
		want                    error
	}{
		{"writer", d.DeviceID, d.LeaseID, base64.RawURLEncoding.EncodeToString(make([]byte, 32)), 0, ErrWriter},
		{"lease", d.DeviceID, uuid.NewString(), reg.WriterSecret, 0, ErrGone},
		{"device", uuid.NewString(), d.LeaseID, reg.WriterSecret, 0, ErrGone},
		{"generation", d.DeviceID, d.LeaseID, reg.WriterSecret, 1, ErrGone},
		{"invalid", d.DeviceID, d.LeaseID, "bad", 0, ErrInvalid},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := s.ValidateWriter(ctx, owner, tc.generation, tc.id, tc.lease, tc.secret); !errors.Is(got, tc.want) {
				t.Fatalf("got %v want %v", got, tc.want)
			}
		})
	}
	if err = s.ValidateWriter(ctx, uuid.New(), 0, d.DeviceID, d.LeaseID, reg.WriterSecret); !errors.Is(err, ErrGone) {
		t.Fatalf("owner: %v", err)
	}
	// Logical per-record expiry must use Redis TIME even while the key survives.
	records := map[string]record{}
	if err = json.Unmarshal([]byte(before), &records); err != nil {
		t.Fatal(err)
	}
	r := records[d.DeviceID]
	r.Device.LeaseExpiresAt = time.Unix(1, 0)
	records[d.DeviceID] = r
	raw, _ := json.Marshal(records)
	if err = client.Set(ctx, key(owner, 0), raw, LeaseTTL).Err(); err != nil {
		t.Fatal(err)
	}
	if err = s.ValidateWriter(ctx, owner, 0, d.DeviceID, d.LeaseID, reg.WriterSecret); !errors.Is(err, ErrGone) {
		t.Fatalf("expired: %v", err)
	}
	if client.Get(ctx, key(owner, 0)).Val() != string(raw) {
		t.Fatal("expired proof rewrote map")
	}
	client.Close()
	if err = s.ValidateWriter(ctx, owner, 0, d.DeviceID, d.LeaseID, reg.WriterSecret); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("offline: %v", err)
	}
	var absent *Service
	if err = absent.ValidateWriter(ctx, owner, 0, d.DeviceID, d.LeaseID, reg.WriterSecret); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("nil: %v", err)
	}
}
