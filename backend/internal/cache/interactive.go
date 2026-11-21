package cache

import (
	"context"
	"time"

	"github.com/redis/go-redis/v9"
)

const interactiveBudget = 125 * time.Millisecond

// InteractiveCache shares the ordinary Redis keyspace with a separate, short
// pool and socket deadline. Cache failure must not exhaust a provider budget.
type InteractiveCache struct{ client *redis.Client }

func (c *Cache) Interactive() InteractiveCache { return InteractiveCache{client: c.interactive} }

func (c InteractiveCache) Get(ctx context.Context, key string) (string, bool) {
	ctx, cancel := context.WithTimeout(ctx, interactiveBudget)
	defer cancel()
	value, err := c.client.Get(ctx, key).Result()
	return value, err == nil
}

func (c InteractiveCache) Set(ctx context.Context, key, value string, ttl time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, interactiveBudget)
	defer cancel()
	return c.client.Set(ctx, key, value, ttl).Err()
}
