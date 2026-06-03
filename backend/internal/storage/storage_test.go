package storage

import (
	"context"
	"net/url"
	"testing"
	"time"
)

func TestPresignGetObjectUsesPublicEndpointWhenConfigured(t *testing.T) {
	client, err := New(&Config{
		Endpoint:       "minio:9000",
		PublicEndpoint: "http://localhost:9000",
		AccessKey:      "minioadmin",
		SecretKey:      "minioadmin",
		Bucket:         "audio-files",
		UseSSL:         false,
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	rawURL, err := client.PresignGetObject(context.Background(), "qa/pr46-seed.mp3", 10*time.Minute)
	if err != nil {
		t.Fatalf("PresignGetObject() error = %v", err)
	}

	parsed, err := url.Parse(rawURL)
	if err != nil {
		t.Fatalf("presigned URL did not parse: %v", err)
	}
	if parsed.Scheme != "http" || parsed.Host != "localhost:9000" {
		t.Fatalf("presigned URL endpoint = %s://%s, want http://localhost:9000; url=%s", parsed.Scheme, parsed.Host, rawURL)
	}
}

func TestPresignGetObjectDefaultsToInternalEndpoint(t *testing.T) {
	client, err := New(&Config{
		Endpoint:  "minio:9000",
		AccessKey: "minioadmin",
		SecretKey: "minioadmin",
		Bucket:    "audio-files",
		UseSSL:    false,
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	rawURL, err := client.PresignGetObject(context.Background(), "audio/track.mp3", 10*time.Minute)
	if err != nil {
		t.Fatalf("PresignGetObject() error = %v", err)
	}

	parsed, err := url.Parse(rawURL)
	if err != nil {
		t.Fatalf("presigned URL did not parse: %v", err)
	}
	if parsed.Scheme != "http" || parsed.Host != "minio:9000" {
		t.Fatalf("presigned URL endpoint = %s://%s, want http://minio:9000; url=%s", parsed.Scheme, parsed.Host, rawURL)
	}
}
