package storage

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/minio/minio-go/v7"
)

type trackedAbsenceBody struct {
	*strings.Reader
	n, closes         int
	eof               bool
	readErr, closeErr error
}

func (b *trackedAbsenceBody) Read(p []byte) (int, error) {
	n, err := b.Reader.Read(p)
	b.n += n
	if err == io.EOF {
		if b.readErr != nil {
			return n, b.readErr
		}
		b.eof = true
	}
	return n, err
}

func (b *trackedAbsenceBody) Close() error { b.closes++; return b.closeErr }

func TestPrivateImportAbsenceCompleteBoundedWireProof(t *testing.T) {
	const resource = "/" + putFixtureBucket + "/" + putFixtureKey
	const code = `<Code>NoSuchKey</Code>`
	const path = `<Resource>` + resource + `</Resource>`
	const valid = `<Error>` + code + path + `</Error>`
	const maxBytes = 4096
	for _, tc := range []struct {
		name, xml           string
		vendorCodes         []string
		readError, closeErr bool
		want                bool
	}{
		{name: "vendor_missing", xml: valid, want: true},
		{name: "vendor_matching", xml: valid, vendorCodes: []string{"NoSuchKey"}, want: true},
		{name: "vendor_conflicting_bucket", xml: valid, vendorCodes: []string{"NoSuchBucket"}},
		{name: "vendor_conflicting_duplicate", xml: valid, vendorCodes: []string{"NoSuchKey", "NoSuchBucket"}},
		{name: "vendor_missing_body_code", xml: `<Error>` + path + `</Error>`, vendorCodes: []string{"NoSuchKey"}},
		{name: "xml_declaration_and_whitespace", xml: `<?xml version="1.0" encoding="UTF-8"?>` + "\n" + valid + "\r\n	 ", want: true},
		{name: "xml_comments", xml: `<!--before-->` + valid + `<!--after-->`, want: true},
		{name: "s3_namespace", xml: `<Error xmlns="http://s3.amazonaws.com/doc/2006-03-01/">` + code + path + `</Error>`, want: true},
		{name: "matching_all_fields", xml: `<Error>` + code + path + `<BucketName>` + putFixtureBucket + `</BucketName><Key>` + putFixtureKey + `</Key><Message>synthetic detail</Message></Error>`, want: true},
		{name: "conflicting_bucket_field", xml: `<Error>` + code + path + `<BucketName>wrong</BucketName></Error>`},
		{name: "duplicate_code", xml: `<Error><Code>NoSuchBucket</Code>` + code + path + `</Error>`},
		{name: "duplicate_resource", xml: `<Error>` + code + `<Resource>/wrong/key</Resource>` + path + `</Error>`},
		{name: "nested_code", xml: `<Error><Code>NoSuch<Nested/>Key</Code>` + path + `</Error>`},
		{name: "directive_in_root", xml: `<Error>` + code + path + `<!DOCTYPE Error></Error>`},
		{name: "leading_junk", xml: `unexpected` + valid},
		{name: "trailing_junk", xml: valid + `unexpected`},
		{name: "trailing_whitespace_entity", xml: valid + `&#x20;`},
		{name: "trailing_truncated_markup", xml: valid + `<!--`},
		{name: "trailing_second_error", xml: valid + `<Error><Code>NoSuchBucket</Code></Error>`},
		{name: "trailing_second_non_error_root", xml: valid + `<html/>`},
		{name: "truncated_first_root", xml: `<Error>` + code + path},
		{name: "exact_cap", xml: valid + strings.Repeat(" ", maxBytes-len(valid)), want: true},
		{name: "over_cap", xml: valid + strings.Repeat(" ", maxBytes+1-len(valid))},
		{name: "oversized_tail", xml: valid + strings.Repeat(" ", maxBytes*5)},
		{name: "read_error_after_complete_root", xml: valid, readError: true},
		{name: "close_error_after_complete_root", xml: valid, closeErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := &trackedAbsenceBody{Reader: strings.NewReader(tc.xml)}
			if tc.readError {
				body.readErr = errors.New("synthetic interrupted response")
			}
			if tc.closeErr {
				body.closeErr = errors.New("synthetic close failure")
			}
			calls := 0
			client := newPutFixture(t, func(req *http.Request) (*http.Response, error) {
				calls++
				if req.Method != http.MethodGet || req.URL.Host != putFixtureEndpoint || req.URL.Path != resource || req.URL.RawQuery != "" ||
					req.Header.Get("Range") != "bytes=0-0" || req.Header.Get("Cache-Control") != "no-cache, no-store" ||
					!strings.HasPrefix(req.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential="+putFixtureAccess+"/") {
					t.Fatal("expected one fresh signed ranged GET on the exact internal key")
				}
				res := putFixtureReply(req, http.StatusNotFound, "")
				if tc.vendorCodes != nil {
					res.Header["X-Minio-Error-Code"] = tc.vendorCodes
				}
				res.Body = body
				return res, nil
			})
			got := client.VerifyPrivateImportObjectAbsent(putFixtureContext(t), putFixtureKey)
			if got != tc.want {
				t.Errorf("absence proof=%t, want %t", got, tc.want)
			}
			wantBytes, wantEOF := min(maxBytes+1, len(tc.xml)), len(tc.xml) <= maxBytes && !tc.readError
			if calls != 1 || body.n != wantBytes || body.eof != wantEOF || body.closes != 1 {
				t.Errorf("GETs=%d bytes=%d EOF=%t closes=%d, want 1/%d/%t/1", calls, body.n, body.eof, body.closes, wantBytes, wantEOF)
			}
		})
	}
}

func TestPrivateImportRetryErrorBodyCannotEscapeProofBudget(t *testing.T) {
	const maxBytes = 4096
	const slowDown = `<Error><Code>SlowDown</Code></Error>`
	for _, tc := range []struct {
		name, payload     string
		readErr, closeErr error
		wantBytes         int
		wantEOF           bool
	}{
		{name: "over_cap", payload: slowDown + strings.Repeat(" ", maxBytes*8), wantBytes: maxBytes + 1},
		{name: "read_error", payload: slowDown, readErr: errors.New("fixture framing error"), wantBytes: len(slowDown)},
		{name: "close_error", payload: slowDown, closeErr: errors.New("fixture close error"), wantBytes: len(slowDown), wantEOF: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := &trackedAbsenceBody{Reader: strings.NewReader(tc.payload), readErr: tc.readErr, closeErr: tc.closeErr}
			requests := 0
			client := newPutFixture(t, func(req *http.Request) (*http.Response, error) {
				requests++
				if requests == 1 {
					res := putFixtureReply(req, http.StatusServiceUnavailable, "")
					res.Body = body
					return res, nil
				}
				res := putFixtureReply(req, http.StatusNotFound, "")
				res.Body = io.NopCloser(strings.NewReader(`<Error><Code>NoSuchKey</Code><Resource>/` + putFixtureBucket + `/` + putFixtureKey + `</Resource></Error>`))
				return res, nil
			})
			if client.VerifyPrivateImportObjectAbsent(putFixtureContext(t), putFixtureKey) {
				t.Error("clean 404 laundered invalid intermediate response")
			}
			if body.n != tc.wantBytes || body.eof != tc.wantEOF || body.closes != 1 {
				t.Errorf("intermediate bytes=%d EOF=%t closes=%d, want %d/%t/1", body.n, body.eof, body.closes, tc.wantBytes, tc.wantEOF)
			}
		})
	}
}

func TestPrivateImportDeleteRetainsRedactedSDKCause(t *testing.T) {
	const vendorMessage = "synthetic refusal containing " + putFixtureKey + " and " + putFixtureSecret
	transportErr := errors.New("synthetic lost response for " + putFixtureKey)
	for _, tc := range []struct {
		name   string
		status int
	}{
		{"s3_access_denied", http.StatusForbidden},
		{"lost_transport_response", 0},
		{"unqualified_204", http.StatusNoContent},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			client := newPutFixture(t, func(req *http.Request) (*http.Response, error) {
				calls++
				if req.Method != http.MethodDelete || req.URL.Host != putFixtureEndpoint ||
					req.URL.Path != "/"+putFixtureBucket+"/"+putFixtureKey || req.URL.RawQuery != "" ||
					!strings.HasPrefix(req.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential="+putFixtureAccess+"/") {
					t.Fatal("expected one signed exact-key DELETE")
				}
				if tc.status == 0 {
					return nil, transportErr
				}
				res := putFixtureReply(req, tc.status, "")
				if tc.status == http.StatusNoContent {
					res.Header.Set("X-Amz-Delete-Marker", "true")
				} else {
					res.Body = io.NopCloser(strings.NewReader(`<Error><Code>AccessDenied</Code><Message>` + vendorMessage + `</Message></Error>`))
				}
				return res, nil
			})
			err := client.DeletePrivateImportObject(putFixtureContext(t), putFixtureKey)
			if err == nil || calls != 1 {
				t.Fatalf("delete error present=%t, requests=%d; want error and one request", err != nil, calls)
			}
			for _, rendered := range []string{err.Error(), fmt.Sprintf("%v", err), fmt.Sprintf("%+v", err), fmt.Sprintf("%#v", err), fmt.Sprintf("%#v", errors.Join(errors.Join(err)))} {
				if strings.Contains(rendered, putFixtureKey) || strings.Contains(rendered, putFixtureSecret) || strings.Contains(rendered, putFixtureEndpoint) {
					t.Fatal("displayed delete error disclosed fixture data")
				}
			}
			var response minio.ErrorResponse
			switch tc.status {
			case http.StatusForbidden:
				if err.Error() != "private intake object delete failed" || !errors.As(err, &response) || response.StatusCode != tc.status || response.Code != "AccessDenied" || response.Message != vendorMessage {
					t.Fatal("delete result lost the typed SDK refusal")
				}
			case 0:
				if !errors.Is(err, transportErr) {
					t.Fatal("delete result lost the SDK transport cause")
				}
			case http.StatusNoContent:
				if err.Error() != "private intake unversioned delete not acknowledged" || errors.Unwrap(err) != nil || errors.As(err, &response) {
					t.Fatal("unqualified acknowledgement is not an SDK delete failure")
				}
			}
		})
	}
}
