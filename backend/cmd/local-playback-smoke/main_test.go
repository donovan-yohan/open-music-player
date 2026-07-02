package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestGetSignedRangeRequiresPartialContentAndExactLength(t *testing.T) {
	tests := []struct {
		name       string
		statusCode int
		body       string
		wantErr    bool
	}{
		{
			name:       "accepts exact partial content response",
			statusCode: http.StatusPartialContent,
			body:       strings.Repeat("a", signedRangeBytes),
		},
		{
			name:       "rejects ok status even with bytes",
			statusCode: http.StatusOK,
			body:       strings.Repeat("a", signedRangeBytes),
			wantErr:    true,
		},
		{
			name:       "rejects short partial content body",
			statusCode: http.StatusPartialContent,
			body:       strings.Repeat("a", signedRangeBytes-1),
			wantErr:    true,
		},
		{
			name:       "rejects long partial content body",
			statusCode: http.StatusPartialContent,
			body:       strings.Repeat("a", signedRangeBytes+1),
			wantErr:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rangeHeaders := make(chan string, 1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				rangeHeaders <- r.Header.Get("Range")
				w.Header().Set("Content-Range", "bytes 0-15/108")
				w.WriteHeader(tt.statusCode)
				_, _ = w.Write([]byte(tt.body))
			}))
			defer server.Close()

			statusCode, bodyBytes, contentRange, err := getSignedRange(context.Background(), server.Client(), server.URL)
			if got := <-rangeHeaders; got != signedRangeHeader {
				t.Fatalf("Range header = %q, want %q", got, signedRangeHeader)
			}
			if tt.wantErr && err == nil {
				t.Fatalf("getSignedRange() error = nil, want error")
			}
			if !tt.wantErr && err != nil {
				t.Fatalf("getSignedRange() error = %v, want nil", err)
			}
			if statusCode != tt.statusCode {
				t.Fatalf("statusCode = %d, want %d", statusCode, tt.statusCode)
			}
			if wantBodyBytes := min(len(tt.body), signedRangeBytes+1); bodyBytes != wantBodyBytes {
				t.Fatalf("bodyBytes = %d, want %d", bodyBytes, wantBodyBytes)
			}
			if contentRange != "bytes 0-15/108" {
				t.Fatalf("contentRange = %q, want %q", contentRange, "bytes 0-15/108")
			}
		})
	}
}
