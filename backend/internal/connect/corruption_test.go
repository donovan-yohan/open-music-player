package connect

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
)

func TestConnectCorruptStoreFailsClosedAgainstRedis(t *testing.T) {
	s, client, owner := redisService(t)
	ctx := context.Background()
	for _, raw := range []string{`null`, `[]`, `not-json`} {
		if err := client.Set(ctx, key(owner, 0), raw, LeaseTTL).Err(); err != nil {
			t.Fatal(err)
		}
		if _, err := s.Register(ctx, owner, 0, registration()); !errors.Is(err, ErrUnavailable) {
			t.Fatalf("corrupt %q error=%v", raw, err)
		}
	}
}
func TestConnectFullUUIDOwnerIsolationAgainstRedis(t *testing.T) {
	s, client, owner := redisService(t)
	ctx := context.Background()
	other := owner
	other[15] ^= 1
	t.Cleanup(func() { client.Del(ctx, key(other, 0)) })
	reg := registration()
	if _, err := s.Register(ctx, owner, 0, reg); err != nil {
		t.Fatal(err)
	}
	if devices, _, err := s.List(ctx, other, 0); err != nil || len(devices) != 0 {
		t.Fatalf("UUID prefix alias=%v %v", devices, err)
	}
	reg.DeviceID = uuid.NewString()
	if _, err := s.Register(ctx, other, 0, reg); err != nil {
		t.Fatal(err)
	}
	if key(owner, 0) == key(other, 0) {
		t.Fatal("full UUID lost")
	}
}
