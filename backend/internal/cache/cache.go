package cache

import (
	"context"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/openmusicplayer/backend/internal/logger"
)

type Cache struct {
	client *redis.Client
	log    *logger.Logger
}

// CacheConfig holds configuration for the cache
type CacheConfig struct {
	Addr   string
	Logger *logger.Logger
}

// New creates a new cache with the given address
func New(addr string) (*Cache, error) {
	return NewWithConfig(&CacheConfig{
		Addr:   addr,
		Logger: logger.Default(),
	})
}

// NewWithConfig creates a new cache with full configuration
func NewWithConfig(cfg *CacheConfig) (*Cache, error) {
	client := redis.NewClient(&redis.Options{
		Addr: cfg.Addr,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := client.Ping(ctx).Err(); err != nil {
		return nil, err
	}

	log := cfg.Logger
	if log == nil {
		log = logger.Default()
	}

	log.Info(ctx, "Connected to Redis", map[string]interface{}{
		"addr": cfg.Addr,
	})

	return &Cache{client: client, log: log}, nil
}

func (c *Cache) Close() error {
	return c.client.Close()
}

// Client returns the underlying Redis client for health checks and metrics.
func (c *Cache) Client() *redis.Client {
	return c.client
}

func (c *Cache) Get(ctx context.Context, key string) (string, bool) {
	val, err := c.client.Get(ctx, key).Result()
	if err == redis.Nil {
		c.log.Debug(ctx, "Cache miss", map[string]interface{}{
			"key": key,
		})
		return "", false
	}
	if err != nil {
		c.log.Error(ctx, "Cache get error", map[string]interface{}{
			"key": key,
		}, err)
		return "", false
	}
	c.log.Debug(ctx, "Cache hit", map[string]interface{}{
		"key": key,
	})
	return val, true
}

func (c *Cache) Set(ctx context.Context, key string, value string, ttl time.Duration) error {
	err := c.client.Set(ctx, key, value, ttl).Err()
	if err != nil {
		c.log.Error(ctx, "Cache set error", map[string]interface{}{
			"key": key,
			"ttl": ttl.String(),
		}, err)
		return err
	}
	c.log.Debug(ctx, "Cache set", map[string]interface{}{
		"key": key,
		"ttl": ttl.String(),
	})
	return nil
}
