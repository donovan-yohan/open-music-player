package jam

import (
	"context"
	"github.com/redis/go-redis/v9"
	"os"
	"sync"
	"testing"
	"time"
)

func TestJamRedisLimiterAtomicBoundedFailClosed(t *testing.T) {
	addr := os.Getenv("JAM_TEST_REDIS")
	if addr == "" {
		t.Skip("JAM_TEST_REDIS required")
	}
	c := redis.NewClient(&redis.Options{Addr: addr})
	defer c.Close()
	ctx := context.Background()
	l := NewRedisLimiter(c)
	l.Prefix = "jam-test:" + NewSecret()
	l.Now = func() time.Time { return time.Unix(123456, 0) }
	l.MaxFields = 8
	l.GlobalBudget = 100
	defer c.Del(ctx, l.Prefix+":123420").Err()
	var wg sync.WaitGroup
	allowed := make(chan bool, 10)
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			e := l.Allow(ctx, LimitInput{Action: "join", RemoteIP: "127.0.0.1", JamID: "same"})
			allowed <- e == nil
		}()
	}
	wg.Wait()
	close(allowed)
	n := 0
	for a := range allowed {
		if a {
			n++
		}
	}
	if n != 5 {
		t.Fatalf("join admitted=%d", n)
	}
	for i := 0; i < 40; i++ {
		_ = l.Allow(ctx, LimitInput{Action: "read", RemoteIP: "x", JamID: NewSecret(), MemberSecret: NewSecret()})
	}
	fields, e := c.HLen(ctx, l.Prefix+":123420").Result()
	if e != nil || fields > 8 {
		t.Fatalf("fields=%d %v", fields, e)
	}
	raw, e := c.HGetAll(ctx, l.Prefix+":123420").Result()
	if e != nil {
		t.Fatal(e)
	}
	for f := range raw {
		if f == "same" || f == "127.0.0.1" {
			t.Fatal("unhashed identifiers")
		}
	}
	if e = l.Allow(ctx, LimitInput{Action: "hostRead", JamID: "owner"}); e == ErrUnavailable {
		t.Fatal("host read budget missing")
	}
	if e = l.Allow(ctx, LimitInput{Action: "hostWrite", JamID: "owner"}); e == ErrUnavailable {
		t.Fatal("host management budget missing")
	}
	c.Close()
	if e = l.Allow(ctx, LimitInput{Action: "read"}); e != ErrUnavailable {
		t.Fatalf("closed redis=%v", e)
	}
}
