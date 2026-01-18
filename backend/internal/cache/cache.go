package cache

import (
	"context"
	"log"
	"time"

	"github.com/redis/go-redis/v9"
)

type Cache struct {
	client *redis.Client
}

func New(addr string) (*Cache, error) {
	client := redis.NewClient(&redis.Options{
		Addr: addr,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := client.Ping(ctx).Err(); err != nil {
		return nil, err
	}

	log.Printf("Connected to Redis at %s", addr)
	return &Cache{client: client}, nil
}

func (c *Cache) Close() error {
	return c.client.Close()
}

func (c *Cache) Get(ctx context.Context, key string) (string, bool) {
	val, err := c.client.Get(ctx, key).Result()
	if err == redis.Nil {
		log.Printf("[CACHE MISS] %s", key)
		return "", false
	}
	if err != nil {
		log.Printf("[CACHE ERROR] %s: %v", key, err)
		return "", false
	}
	log.Printf("[CACHE HIT] %s", key)
	return val, true
}

func (c *Cache) Set(ctx context.Context, key string, value string, ttl time.Duration) error {
	err := c.client.Set(ctx, key, value, ttl).Err()
	if err != nil {
		log.Printf("[CACHE SET ERROR] %s: %v", key, err)
		return err
	}
	log.Printf("[CACHE SET] %s (TTL: %v)", key, ttl)
	return nil
}
