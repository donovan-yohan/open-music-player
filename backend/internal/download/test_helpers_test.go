package download

import (
	"context"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

const defaultTestRedisDB = "15"

func getTestRedisURL(t testing.TB) string {
	t.Helper()

	if redisURL := os.Getenv("REDIS_TEST_URL"); redisURL != "" {
		return redisURL
	}

	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		redisURL = "redis://localhost:6380"
	}

	testDB := os.Getenv("REDIS_TEST_DB")
	if testDB == "" {
		testDB = defaultTestRedisDB
	}

	parsed, err := url.Parse(redisURL)
	if err != nil {
		return redisURL
	}
	parsed.Path = "/" + strings.TrimPrefix(testDB, "/")
	return parsed.String()
}

func newTestQueue(t testing.TB) *Queue {
	t.Helper()

	queue, err := NewQueue(getTestRedisURL(t))
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := queue.client.FlushDB(ctx).Err(); err != nil {
		queue.Close()
		t.Fatalf("failed to clear isolated Redis test DB: %v", err)
	}

	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = queue.client.FlushDB(ctx).Err()
		_ = queue.Close()
	})

	return queue
}
