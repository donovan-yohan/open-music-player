package storage

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// Client provides access to S3-compatible object storage (MinIO).
type Client struct {
	client *minio.Client
	bucket string
}

// Config holds the configuration for the storage client.
type Config struct {
	Endpoint  string
	AccessKey string
	SecretKey string
	Bucket    string
	UseSSL    bool
}

// New creates a new storage client.
func New(cfg *Config) (*Client, error) {
	// Strip protocol prefix if present (minio-go expects host:port)
	endpoint := cfg.Endpoint
	endpoint = strings.TrimPrefix(endpoint, "http://")
	endpoint = strings.TrimPrefix(endpoint, "https://")

	client, err := minio.New(endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(cfg.AccessKey, cfg.SecretKey, ""),
		Secure: cfg.UseSSL,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to create minio client: %w", err)
	}

	return &Client{
		client: client,
		bucket: cfg.Bucket,
	}, nil
}

// ObjectInfo contains metadata about a stored object.
type ObjectInfo struct {
	Size        int64
	ContentType string
	ETag        string
}

// StatObject returns metadata about an object without downloading it.
func (c *Client) StatObject(ctx context.Context, key string) (*ObjectInfo, error) {
	info, err := c.client.StatObject(ctx, c.bucket, key, minio.StatObjectOptions{})
	if err != nil {
		return nil, fmt.Errorf("failed to stat object %s: %w", key, err)
	}

	return &ObjectInfo{
		Size:        info.Size,
		ContentType: info.ContentType,
		ETag:        info.ETag,
	}, nil
}

// GetObject retrieves an entire object from storage.
func (c *Client) GetObject(ctx context.Context, key string) (io.ReadCloser, *ObjectInfo, error) {
	obj, err := c.client.GetObject(ctx, c.bucket, key, minio.GetObjectOptions{})
	if err != nil {
		return nil, nil, fmt.Errorf("failed to get object %s: %w", key, err)
	}

	info, err := obj.Stat()
	if err != nil {
		obj.Close()
		return nil, nil, fmt.Errorf("failed to stat object %s: %w", key, err)
	}

	return obj, &ObjectInfo{
		Size:        info.Size,
		ContentType: info.ContentType,
		ETag:        info.ETag,
	}, nil
}

// GetObjectRange retrieves a byte range from an object.
// start and end are inclusive byte positions (e.g., bytes 0-499 gets first 500 bytes).
func (c *Client) GetObjectRange(ctx context.Context, key string, start, end int64) (io.ReadCloser, error) {
	opts := minio.GetObjectOptions{}
	if err := opts.SetRange(start, end); err != nil {
		return nil, fmt.Errorf("invalid range %d-%d: %w", start, end, err)
	}

	obj, err := c.client.GetObject(ctx, c.bucket, key, opts)
	if err != nil {
		return nil, fmt.Errorf("failed to get object range %s [%d-%d]: %w", key, start, end, err)
	}

	return obj, nil
}

// ObjectExists checks if an object exists in storage.
func (c *Client) ObjectExists(ctx context.Context, key string) (bool, error) {
	_, err := c.client.StatObject(ctx, c.bucket, key, minio.StatObjectOptions{})
	if err != nil {
		errResp := minio.ToErrorResponse(err)
		if errResp.Code == "NoSuchKey" {
			return false, nil
		}
		return false, fmt.Errorf("failed to check object existence %s: %w", key, err)
	}
	return true, nil
}

// PutObject uploads an object to storage.
func (c *Client) PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string) error {
	opts := minio.PutObjectOptions{
		ContentType: contentType,
	}

	_, err := c.client.PutObject(ctx, c.bucket, key, reader, size, opts)
	if err != nil {
		return fmt.Errorf("failed to put object %s: %w", key, err)
	}

	return nil
}

// DeleteObject removes an object from storage.
func (c *Client) DeleteObject(ctx context.Context, key string) error {
	err := c.client.RemoveObject(ctx, c.bucket, key, minio.RemoveObjectOptions{})
	if err != nil {
		return fmt.Errorf("failed to delete object %s: %w", key, err)
	}
	return nil
}

// EnsureBucket creates the bucket if it doesn't exist.
func (c *Client) EnsureBucket(ctx context.Context) error {
	exists, err := c.client.BucketExists(ctx, c.bucket)
	if err != nil {
		return fmt.Errorf("failed to check bucket existence: %w", err)
	}

	if !exists {
		err = c.client.MakeBucket(ctx, c.bucket, minio.MakeBucketOptions{})
		if err != nil {
			return fmt.Errorf("failed to create bucket %s: %w", c.bucket, err)
		}
	}

	return nil
}

// Bucket returns the bucket name.
func (c *Client) Bucket() string {
	return c.bucket
}
