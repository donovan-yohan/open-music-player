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
	bucket, key            string
	qualified, unqualified bool
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
		absence.qualified = false
		absence.unqualified = absence.unqualified || hasStaleOrVersionMetadata(resp.Header)
		if resp.StatusCode == http.StatusNotFound {
			// MinIO v7.0.98 can synthesize NoSuchKey, override the XML Code
			// from a header, and decode only the first XML element. Qualify
			// the original response before the SDK parses and drains it.
			const maxAbsenceXML = 4096
			body, readErr := io.ReadAll(io.LimitReader(resp.Body, maxAbsenceXML+1))
			closeErr := resp.Body.Close()
			resp.Body = http.NoBody
			// Inspect all proof-conflicting metadata, including trailers from the
			// original body, before handing a buffered response to the SDK.
			if readErr == nil && closeErr == nil && len(body) <= maxAbsenceXML &&
				!absence.unqualified && !hasStaleOrVersionMetadata(resp.Trailer) &&
				matchesAbsenceVendorCode(resp.Header) && matchesAbsenceVendorCode(resp.Trailer) && isExactAbsenceXML(body, absence.bucket, absence.key) {
				absence.qualified = true
				resp.Body = io.NopCloser(bytes.NewReader(body))
			}
		}
	}
	return resp, nil
}

func matchesAbsenceVendorCode(h http.Header) bool {
	for _, code := range h.Values("X-Minio-Error-Code") {
		if code != "NoSuchKey" {
			return false
		}
	}
	return true
}

// Qualification uses XML from the wire, not the SDK's fallback or last-field
// wins. Only a single Error root with unambiguous scalar binding fields counts.
func isExactAbsenceXML(body []byte, bucket, key string) bool {
	d := xml.NewDecoder(bytes.NewReader(body))
	var namespace, field string
	var text bytes.Buffer
	fields := make(map[string]string, 4)
	depth := 0
	found := false
	for {
		offset := d.InputOffset()
		token, err := d.Token()
		if err != nil {
			if err != io.EOF || !found || depth != 0 || fields["Code"] != "NoSuchKey" {
				return false
			}
			if b, ok := fields["BucketName"]; ok && b != bucket {
				return false
			}
			if k, ok := fields["Key"]; ok && k != key {
				return false
			}
			if resource, ok := fields["Resource"]; ok {
				return resource == "/"+bucket+"/"+key
			}
			return fields["BucketName"] == bucket && fields["Key"] == key
		}
		switch v := token.(type) {
		case xml.StartElement:
			// encoding/xml translates namespaces but does not reject duplicate
			// declarations or attributes. Allow only one S3 namespace declaration
			// on the root, and no attributes anywhere else, including details.
			if len(v.Attr) != 0 && (depth != 0 || !isS3AbsenceRootDeclaration(v)) {
				return false
			}
			switch {
			case depth == 0:
				if found || v.Name.Local != "Error" || (v.Name.Space != "" && v.Name.Space != s3AbsenceNamespace) {
					return false
				}
				found, namespace = true, v.Name.Space
			case depth == 1:
				switch v.Name.Local {
				case "Code", "Resource", "BucketName", "Key":
					if _, duplicate := fields[v.Name.Local]; duplicate || v.Name.Space != namespace {
						return false
					}
					field = v.Name.Local
				}
			case field != "":
				// Binding fields are scalar, not mixed-content markup.
				return false
			}
			depth++
		case xml.EndElement:
			depth--
			if field != "" {
				fields[field], field = text.String(), ""
				text.Reset()
			}
		case xml.CharData:
			if field != "" {
				_, _ = text.Write(v)
			} else if depth <= 1 && len(bytes.Trim(body[offset:d.InputOffset()], " 	\r\n")) != 0 {
				return false
			}
		case xml.Comment:
			// Comments are valid XML document content and not evidence.
		case xml.ProcInst:
			if offset != 0 || v.Target != "xml" || !isKnownS3XMLDeclaration(v.Inst) {
				return false
			}
		default:
			return false
		}
	}
}

const s3AbsenceNamespace = "http://s3.amazonaws.com/doc/2006-03-01/"

func isS3AbsenceRootDeclaration(root xml.StartElement) bool {
	if len(root.Attr) != 1 || root.Name.Space != s3AbsenceNamespace || root.Attr[0].Value != s3AbsenceNamespace {
		return false
	}
	name := root.Attr[0].Name
	return name == (xml.Name{Local: "xmlns"}) ||
		(name.Space == "xmlns" && name.Local != "xml" && name.Local != "xmlns")
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
	return ctx.Err() == nil && probe.qualified && errors.As(err, &response) &&
		response.StatusCode == http.StatusNotFound && response.Code == "NoSuchKey"
}
