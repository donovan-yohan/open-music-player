package storage

import (
	"context"
	"errors"
	"net/http"

	"github.com/minio/minio-go/v7"
)

type privateAbsenceProbe struct{}
type privateAbsenceTransport struct{ http.RoundTripper }

func (t privateAbsenceTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := t.RoundTripper.RoundTrip(req)
	if err == nil && resp.StatusCode == http.StatusNotFound && req.Context().Value(privateAbsenceProbe{}) != nil {
		// The pinned SDK lets this header override a structured XML Code.
		// For this probe only, decide by the exact-key XML, not that override.
		resp.Header = resp.Header.Clone()
		resp.Header.Del("X-Minio-Error-Code")
	}
	return resp, err
}

// VerifyPrivateImportObjectAbsent only trusts an explicit NoSuchKey response
// bound to the requested bucket and key over the configured internal S3
// endpoint. A bare/HTML 404 (including the SDK's synthetic NoSuchKey),
// bucket errors and present-but-unreadable objects all fail closed.
func (c *Client) VerifyPrivateImportObjectAbsent(ctx context.Context, key string) bool {
	opts := minio.GetObjectOptions{}
	if err := opts.SetRange(0, 0); err != nil {
		return false
	}
	// Core performs an eager GET: the ordinary GetObject/Stat path uses HEAD
	// and loses the response body. Never download a present object to prove
	// absence; read no payload and close the response if the object is there.
	body, _, _, err := (minio.Core{Client: c.client}).GetObject(context.WithValue(ctx, privateAbsenceProbe{}, true), c.bucket, key, opts)
	if err == nil {
		_ = body.Close()
		return false
	}
	var response minio.ErrorResponse
	if !errors.As(err, &response) || response.StatusCode != http.StatusNotFound || response.XMLName.Local != "Error" || response.Code != "NoSuchKey" {
		return false
	}
	if (response.BucketName != "" && response.BucketName != c.bucket) || (response.Key != "" && response.Key != key) {
		return false
	}
	if response.Resource != "" {
		return response.Resource == "/"+c.bucket+"/"+key
	}
	return response.BucketName == c.bucket && response.Key == key
}
