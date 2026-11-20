package storage

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"io"
	"net/http"

	"github.com/minio/minio-go/v7"
)

type privateAbsenceProbe struct{ unqualified bool }
type privateVersioningProbe struct{ unversioned bool }
type privateDeleteProbe struct{ unversioned bool }
type privateImportTransport struct{ http.RoundTripper }

func (t privateImportTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	versioning, _ := req.Context().Value(privateVersioningProbe{}).(*privateVersioningProbe)
	absence, _ := req.Context().Value(privateAbsenceProbe{}).(*privateAbsenceProbe)
	if versioning != nil || absence != nil {
		req = req.Clone(req.Context())
		req.Header.Set("Cache-Control", "no-cache, no-store")
	}
	resp, err := t.RoundTripper.RoundTrip(req)
	if err != nil {
		return resp, err
	}
	if versioning != nil && resp.StatusCode == http.StatusOK {
		// The SDK decoder ignores unknown fields and does not require EOF.
		// Keep the raw response as well, so only a proven empty configuration
		// is accepted, never an unknown, partial or extended policy document.
		const maxVersioningXML = 4096
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, maxVersioningXML+1))
		closeErr := resp.Body.Close()
		resp.Body = io.NopCloser(bytes.NewReader(body))
		versioning.unversioned = readErr == nil && closeErr == nil && len(body) <= maxVersioningXML &&
			!hasVersionHeaders(resp.Header) && !hasS3ErrorHeaders(resp.Header) && len(resp.Header.Values("Age")) == 0 && isNeverVersionedXML(body)
	}
	if probe, _ := req.Context().Value(privateDeleteProbe{}).(*privateDeleteProbe); probe != nil {
		// RemoveObject drops these headers on success. A delete marker (or
		// any version identity) cannot acknowledge an unversioned removal.
		probe.unversioned = resp.StatusCode == http.StatusNoContent && !hasVersionHeaders(resp.Header) && !hasS3ErrorHeaders(resp.Header)
	}
	if absence != nil {
		absence.unqualified = absence.unqualified || hasVersionHeaders(resp.Header) || len(resp.Header.Values("Age")) != 0
		if resp.StatusCode == http.StatusNotFound {
			// The pinned SDK lets this header override a structured XML Code.
			// For this probe only, decide by the exact-key XML, not that override.
			resp.Header = resp.Header.Clone()
			resp.Header.Del("X-Minio-Error-Code")
		}
	}
	return resp, nil
}

func hasVersionHeaders(h http.Header) bool {
	return len(h.Values("X-Amz-Delete-Marker")) != 0 || len(h.Values("X-Amz-Version-Id")) != 0
}

func hasS3ErrorHeaders(h http.Header) bool {
	return len(h.Values("X-Minio-Error-Code")) != 0 || len(h.Values("X-Minio-Error-Desc")) != 0
}

// An S3 bucket that has never been versioned returns the empty configuration
// document. Suspended still has history; Enabled with exclusions is also not
// supported. Accept only the standard S3 XML shape, not a zero-value decode.
func isNeverVersionedXML(body []byte) bool {
	const ns = "http://s3.amazonaws.com/doc/2006-03-01/"
	d := xml.NewDecoder(bytes.NewReader(body))
	var started, ended, declaration bool
	for {
		token, err := d.Token()
		if err != nil {
			return err == io.EOF && ended
		}
		switch v := token.(type) {
		case xml.StartElement:
			if started || v.Name != (xml.Name{Space: ns, Local: "VersioningConfiguration"}) ||
				len(v.Attr) != 1 || v.Attr[0].Name != (xml.Name{Local: "xmlns"}) || v.Attr[0].Value != ns {
				return false
			}
			started = true
		case xml.EndElement:
			ended = true
		case xml.CharData:
			if len(bytes.Trim(v, " 	\r\n")) != 0 {
				return false
			}
		case xml.ProcInst:
			if started || declaration || v.Target != "xml" {
				return false
			}
			switch string(v.Inst) {
			case `version="1.0"`, `version="1.0" encoding="UTF-8"`, `version="1.0" encoding="utf-8"`:
			default:
				return false
			}
			declaration = true
		default:
			return false
		}
	}
}

// VerifyPrivateImportCollectionUnversioned asks the configured internal S3
// endpoint for a fresh affirmative never-versioned result. This is not an
// atomic condition on DeleteObject: activation still requires exclusive
// custody and immutable bucket versioning for the entire staged key lifetime.
func (c *Client) VerifyPrivateImportCollectionUnversioned(ctx context.Context) bool {
	var probe privateVersioningProbe
	_, err := c.privateImportClient.GetBucketVersioning(context.WithValue(ctx, privateVersioningProbe{}, &probe), c.bucket)
	return err == nil && ctx.Err() == nil && probe.unversioned
}

// DeletePrivateImportObject issues a single exact-key delete. It is only for
// the staged collector, bracketed by fresh policy checks and exact absence.
func (c *Client) DeletePrivateImportObject(ctx context.Context, key string) error {
	var probe privateDeleteProbe
	err := c.privateImportClient.RemoveObject(context.WithValue(ctx, privateDeleteProbe{}, &probe), c.bucket, key, minio.RemoveObjectOptions{})
	if err != nil || !probe.unversioned {
		return errors.New("private intake unversioned delete not acknowledged")
	}
	return nil
}

// VerifyPrivateImportObjectAbsent only trusts an explicit NoSuchKey response
// bound to the requested bucket and key over the configured internal S3
// endpoint. Bare/HTML 404s (including synthetic SDK NoSuchKey), version
// metadata, bucket errors and present-but-unreadable objects fail closed.
func (c *Client) VerifyPrivateImportObjectAbsent(ctx context.Context, key string) bool {
	opts := minio.GetObjectOptions{}
	if err := opts.SetRange(0, 0); err != nil {
		return false
	}
	// Core performs an eager GET: the ordinary GetObject/Stat path uses HEAD
	// and loses the response body. Never download a present object to prove
	// absence; read no payload and close the response if the object is there.
	var probe privateAbsenceProbe
	body, _, _, err := (minio.Core{Client: c.client}).GetObject(context.WithValue(ctx, privateAbsenceProbe{}, &probe), c.bucket, key, opts)
	if err == nil {
		_ = body.Close()
		return false
	}
	var response minio.ErrorResponse
	if probe.unqualified || !errors.As(err, &response) || response.StatusCode != http.StatusNotFound || response.XMLName.Local != "Error" || response.Code != "NoSuchKey" {
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
