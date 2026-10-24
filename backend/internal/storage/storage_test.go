package storage

import (
	"context"
	"net/url"
	"strings"
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

func TestMalformedEndpointErrorsNeverLeakUserinfo(t *testing.T) {
	for _, endpoint := range []string{
		"https://user:private-password@media.example.test:invalid",
		"https://user:private-password@media.example.test/%xx",
		"https://user:private-password@media.example.test/\x00",
	} {
		for _, public := range []bool{false, true} {
			cfg := &Config{Endpoint: endpoint, AccessKey: "fixture", SecretKey: "fixture", Bucket: "audio-files"}
			if public {
				cfg.Endpoint, cfg.PublicEndpoint = "minio:9000", endpoint
			}
			_, err := New(cfg)
			if err == nil {
				t.Fatal("malformed endpoint accepted")
			}
			if strings.Contains(err.Error(), "user") || strings.Contains(err.Error(), "private-password") {
				t.Fatal("malformed endpoint leaked userinfo")
			}
		}
	}
}

func TestPublicEndpointRejectsCredentialsAndAmbiguousURLs(t *testing.T) {
	for _, endpoint := range []string{
		"https://user:pass@media.example.test", "https://media.example.test?",
		"https://user:pass@media.example.test/prefix",
		"https://media.example.test#", "https://media.example.test/prefix",
		"ftp://media.example.test", "https://media.example.test:99999",
	} {
		t.Run(endpoint, func(t *testing.T) {
			_, err := New(&Config{Endpoint: "minio:9000", PublicEndpoint: endpoint,
				AccessKey: "fixture", SecretKey: "fixture", Bucket: "audio-files"})
			if err == nil {
				t.Fatal("unsafe public endpoint accepted")
			}
			if strings.Contains(err.Error(), "user:pass") {
				t.Fatal("endpoint validation leaked userinfo in error")
			}
		})
	}
}
