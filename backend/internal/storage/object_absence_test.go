package storage

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"testing"

	"github.com/minio/minio-go/v7"
)

func TestIsObjectNotFound(t *testing.T) {
	missing := minio.ErrorResponse{Code: "NoSuchKey", StatusCode: http.StatusNotFound}
	bucket := minio.ErrorResponse{Code: "NoSuchBucket", StatusCode: http.StatusNotFound}
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"object_value", missing, true},
		{"object_pointer", &missing, true},
		{"wrapped_object_404", fmt.Errorf("stat: %w", missing), true},
		{"nested_object_pointer", fmt.Errorf("outer: %w", fmt.Errorf("stat: %w", &missing)), true},
		{"wrapped_access_403", fmt.Errorf("stat: %w", minio.ErrorResponse{Code: "AccessDenied", StatusCode: 403}), false},
		{"wrapped_service_503", fmt.Errorf("stat: %w", minio.ErrorResponse{Code: "ServiceUnavailable", StatusCode: 503}), false},
		{"wrapped_bucket_404", fmt.Errorf("stat: %w", bucket), false},
		{"wrapped_bucket_pointer", fmt.Errorf("stat: %w", &bucket), false},
		{"unknown_404", minio.ErrorResponse{Code: "UnknownError", StatusCode: 404}, false},
		{"status_only_404", minio.ErrorResponse{StatusCode: 404}, false},
		{"network", fmt.Errorf("stat: %w", &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connection refused")}), false},
		{"canceled", fmt.Errorf("stat: %w", context.Canceled), false},
		{"deadline", fmt.Errorf("stat: %w", context.DeadlineExceeded), false},
		{"unknown_text_not_absence", errors.New("NoSuchKey not found 404"), false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := IsObjectNotFound(tc.err); got != tc.want {
				t.Fatalf("IsObjectNotFound(%T) = %t, want %t", tc.err, got, tc.want)
			}
		})
	}
}
