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

type privateAbsenceProbe struct {
	bucket, key       string
	exact404, tainted bool
}
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
		// Trailers are separate from headers and populated only after wire EOF.
		versioning.unversioned = readErr == nil && closeErr == nil && len(body) <= maxVersioningXML &&
			!hasUnqualifiedPolicyMetadata(resp.Header) && !hasUnqualifiedPolicyMetadata(resp.Trailer) && isNeverVersionedXML(body)
	}
	if probe, _ := req.Context().Value(privateDeleteProbe{}).(*privateDeleteProbe); probe != nil {
		// RemoveObject drops these headers on success. A delete marker (or
		// any version identity) cannot acknowledge an unversioned removal.
		probe.unversioned = resp.StatusCode == http.StatusNoContent && !hasVersionHeaders(resp.Header) && !hasS3ErrorHeaders(resp.Header)
	}
	if absence != nil {
		absence.observe(resp)
	}
	return resp, nil
}

func (p *privateAbsenceProbe) observe(resp *http.Response) {
	p.exact404 = false
	wireBody := resp.Body
	resp.Body = http.NoBody
	if resp.StatusCode/100 == 2 {
		// MinIO v7.0.98 can drain a 2xx response with bad object metadata
		// or an unexpected status. Never expose a potential object payload.
		p.tainted = true
		_ = wireBody.Close()
		return
	}

	// MinIO consumes and drains non-success bodies before deciding whether
	// to retry. Own EOF here, including intermediate responses, so late
	// trailers cannot disappear and the SDK can only drain bounded memory.
	const maxAbsenceError = 4096
	body, readErr := io.ReadAll(io.LimitReader(wireBody, maxAbsenceError+1))
	closeErr := wireBody.Close()
	if readErr != nil || closeErr != nil || len(body) > maxAbsenceError ||
		hasStaleOrVersionMetadata(resp.Header) || hasStaleOrVersionMetadata(resp.Trailer) {
		p.tainted = true
		return
	}
	fields, ok := parseS3ProofError(body)
	code := fields["Code"]
	resource := "/" + p.bucket + "/" + p.key
	if !ok || !matchesVendorCode(resp.Header, code) || !matchesVendorCode(resp.Trailer, code) ||
		contradictsS3Field(fields, "Resource", resource) || contradictsS3Field(fields, "BucketName", p.bucket) || contradictsS3Field(fields, "Key", p.key) {
		p.tainted = true
		return
	}
	if resp.StatusCode == http.StatusNotFound {
		if code != "NoSuchKey" || (fields["Resource"] != resource && (fields["BucketName"] != p.bucket || fields["Key"] != p.key)) {
			p.tainted = true
			return
		}
		p.exact404 = true
	}
	// Retain the SDK's interpretation and retry behavior for clean errors;
	// it can never make a tainted probe qualify with a subsequent response.
	resp.Body = io.NopCloser(bytes.NewReader(body))
}

func contradictsS3Field(fields map[string]string, field, want string) bool {
	value, present := fields[field]
	return present && value != want
}

func matchesVendorCode(h http.Header, code string) bool {
	for _, value := range h.Values("X-Minio-Error-Code") {
		if value != code {
			return false
		}
	}
	return true
}

// Read one complete S3 Error document. RawToken preserves lexical prefixes:
// Token resolves a bound prefix but silently leaves an unbound one in Space.
// The only allowed binding is a single root declaration of the S3 namespace.
// Check all raw names (even diagnostic descendants) and exact tag pairing.
func parseS3ProofError(body []byte) (map[string]string, bool) {
	d := xml.NewDecoder(bytes.NewReader(body))
	var prefix, field string
	var text bytes.Buffer
	fields := make(map[string]string, 4)
	var open []xml.Name
	found := false
	for {
		offset := d.InputOffset()
		token, err := d.RawToken()
		if err != nil {
			return fields, err == io.EOF && found && len(open) == 0 && isS3ProofName(fields["Code"])
		}
		depth := len(open)
		switch v := token.(type) {
		case xml.StartElement:
			if depth == 0 {
				if found || !isS3ProofErrorRoot(v) {
					return nil, false
				}
				found, prefix = true, v.Name.Space
			} else if len(v.Attr) != 0 || !isS3ProofName(v.Name.Local) || (v.Name.Space != "" && v.Name.Space != prefix) || field != "" {
				// No descendant declarations or attributes. Binding fields are
				// scalar; even ignored elements cannot introduce an unknown QName.
				return nil, false
			} else if depth == 1 {
				switch v.Name.Local {
				case "Code", "Resource", "BucketName", "Key":
					// Unprefixed diagnostics are allowed under a prefixed root, but
					// evidence fields must be in the same namespace as the root.
					if _, duplicate := fields[v.Name.Local]; duplicate || v.Name.Space != prefix {
						return nil, false
					}
					field = v.Name.Local
				}
			}
			open = append(open, v.Name)
		case xml.EndElement:
			if depth == 0 || open[depth-1] != v.Name {
				return nil, false
			}
			open = open[:depth-1]
			if field != "" {
				fields[field], field = text.String(), ""
				text.Reset()
			}
		case xml.CharData:
			if field != "" {
				_, _ = text.Write(v)
			} else if depth <= 1 && len(bytes.Trim(body[offset:d.InputOffset()], " 	\r\n")) != 0 {
				return nil, false
			}
		case xml.Comment:
			// Comments are valid XML document content and not evidence.
		case xml.ProcInst:
			if offset != 0 || v.Target != "xml" || !isKnownS3XMLDeclaration(v.Inst) {
				return nil, false
			}
		default:
			return nil, false
		}
	}
}

func isS3ProofErrorRoot(root xml.StartElement) bool {
	const ns = "http://s3.amazonaws.com/doc/2006-03-01/"
	prefix := root.Name.Space
	if root.Name.Local != "Error" {
		return false
	}
	if len(root.Attr) == 0 {
		return prefix == ""
	}
	if len(root.Attr) != 1 || root.Attr[0].Value != ns {
		return false
	}
	if prefix == "" {
		return root.Attr[0].Name == (xml.Name{Local: "xmlns"})
	}
	return prefix != "xml" && prefix != "xmlns" && isS3ProofName(prefix) &&
		root.Attr[0].Name == (xml.Name{Space: "xmlns", Local: prefix})
}

// The supported provider grammar uses ASCII NCNames, including in ignored
// diagnostics. RawToken checks the XML Name as a whole, not each QName part.
func isS3ProofName(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !('A' <= c && c <= 'Z' || 'a' <= c && c <= 'z' || c == '_' ||
			i > 0 && ('0' <= c && c <= '9' || c == '-' || c == '.')) {
			return false
		}
	}
	return len(s) != 0
}

func hasStaleOrVersionMetadata(h http.Header) bool {
	return hasVersionHeaders(h) || len(h.Values("Age")) != 0
}

func hasUnqualifiedPolicyMetadata(h http.Header) bool {
	return hasStaleOrVersionMetadata(h) || hasS3ErrorHeaders(h)
}

func hasVersionHeaders(h http.Header) bool {
	return len(h.Values("X-Amz-Delete-Marker")) != 0 || len(h.Values("X-Amz-Version-Id")) != 0
}

func hasS3ErrorHeaders(h http.Header) bool {
	return len(h.Values("X-Minio-Error-Code")) != 0 || len(h.Values("X-Minio-Error-Desc")) != 0
}

func isKnownS3XMLDeclaration(inst []byte) bool {
	switch string(inst) {
	case `version="1.0"`, `version="1.0" encoding="UTF-8"`, `version="1.0" encoding="utf-8"`:
		return true
	default:
		return false
	}
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
			if started || declaration || v.Target != "xml" || !isKnownS3XMLDeclaration(v.Inst) {
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
	if err != nil {
		return &privateDeleteError{err}
	}
	if !probe.unversioned {
		return errors.New("private intake unversioned delete not acknowledged")
	}
	return nil
}

// The SDK cause can contain a key, endpoint, or vendor message. It is for
// errors.Is/As, not logs (including Go-syntax formatting).
type privateDeleteError struct{ cause error }

func (e *privateDeleteError) Error() string    { return "private intake object delete failed" }
func (e *privateDeleteError) GoString() string { return e.Error() }
func (e *privateDeleteError) Unwrap() error    { return e.cause }

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
	probe := privateAbsenceProbe{bucket: c.bucket, key: key}
	body, _, _, err := (minio.Core{Client: c.client}).GetObject(context.WithValue(ctx, privateAbsenceProbe{}, &probe), c.bucket, key, opts)
	if err == nil {
		_ = body.Close()
		return false
	}
	var response minio.ErrorResponse
	return ctx.Err() == nil && probe.exact404 && !probe.tainted && errors.As(err, &response) &&
		response.StatusCode == http.StatusNotFound && response.Code == "NoSuchKey"
}
