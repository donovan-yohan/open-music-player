package storage

import (
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

type absencePresentBody struct{ read, closed bool }

func (b *absencePresentBody) Read([]byte) (int, error) { b.read = true; return 0, io.EOF }
func (b *absencePresentBody) Close() error             { b.closed = true; return nil }

func TestPrivateImportAbsenceRequiresExplicitExactKeyS3Response(t *testing.T) {
	resource := "/" + putFixtureBucket + "/" + putFixtureKey
	for _, tc := range []struct {
		name, body, override string
		status               int
		want                 bool
	}{
		{"bare_intermediary", "", "", 404, false},
		{"html_intermediary", "<html>not found</html>", "", 404, false},
		{"header_only", "", "NoSuchKey", 404, false},
		{"wrong_key", `<Error><Code>NoSuchKey</Code><Resource>/wrong/key.mp3</Resource></Error>`, "", 404, false},
		{"unbound", `<Error><Code>NoSuchKey</Code></Error>`, "", 404, false},
		{"bucket_missing", `<Error><Code>NoSuchBucket</Code><Resource>` + resource + `</Resource></Error>`, "", 404, false},
		{"header_override_of_bucket_error", `<Error><Code>NoSuchBucket</Code><Resource>` + resource + `</Resource></Error>`, "NoSuchKey", 404, false},
		{"contradictory_fields", `<Error><Code>NoSuchKey</Code><Resource>` + resource + `</Resource><Key>wrong.mp3</Key></Error>`, "", 404, false},
		{"explicit_resource", `<Error><Code>NoSuchKey</Code><Resource>` + resource + `</Resource></Error>`, "", 404, true},
		{"explicit_bucket_key", `<Error><Code>NoSuchKey</Code><BucketName>` + putFixtureBucket + `</BucketName><Key>` + putFixtureKey + `</Key></Error>`, "", 404, true},
		{"present", "", "", 206, false},
		{"present_missing_object_metadata", "", "", 200, false},
		{"unexpected_success_can_carry_payload", "", "", 203, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			present := new(absencePresentBody)
			var calls []string
			client := newPutFixture(t, func(req *http.Request) (*http.Response, error) {
				calls = append(calls, req.Method)
				if req.URL.Host != putFixtureEndpoint || req.URL.Path != resource || req.URL.RawQuery != "" ||
					!strings.HasPrefix(req.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential="+putFixtureAccess+"/") {
					t.Fatal("probe did not address and sign the exact internal key")
				}
				if req.Method == http.MethodHead {
					return &http.Response{StatusCode: http.StatusNotFound, Header: make(http.Header), Body: http.NoBody, Request: req}, nil
				}
				if req.Method != http.MethodGet || req.Header.Get("Range") != "bytes=0-0" {
					t.Fatal("absence probe did not issue a bounded exact GET")
				}
				res := putFixtureReply(req, tc.status, "")
				if tc.override != "" {
					res.Header.Set("X-Minio-Error-Code", tc.override)
				}
				if tc.status/100 == 2 {
					res.Body, res.ContentLength = present, 1
					if tc.status == http.StatusPartialContent {
						res.Header.Set("Last-Modified", time.Now().UTC().Format(http.TimeFormat))
						res.Header.Set("Content-Length", "1")
					}
				} else {
					res.Body = io.NopCloser(strings.NewReader(tc.body))
				}
				return res, nil
			})
			ctx := putFixtureContext(t)
			if _, err := client.StatObject(ctx, putFixtureKey); !IsObjectNotFound(err) {
				t.Fatal("pinned SDK no longer synthesizes NoSuchKey from bare HEAD; reassess the fixture")
			}
			if got := client.VerifyPrivateImportObjectAbsent(ctx, putFixtureKey); got != tc.want {
				t.Fatalf("absence proof=%t, want %t", got, tc.want)
			}
			if !reflect.DeepEqual(calls, []string{http.MethodHead, http.MethodGet}) {
				t.Fatalf("unexpected requests: %v", calls)
			}
			if tc.status/100 == 2 && (present.read || !present.closed) {
				t.Fatal("probe read or leaked a present object's body")
			}
		})
	}
}
