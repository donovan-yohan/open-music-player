package storage

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestPrivateImportCollectionWireQualification(t *testing.T) {
	const open = `<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">`
	const closeTag = `</VersioningConfiguration>`
	const empty = open + closeTag
	const bucket = "/" + putFixtureBucket + "/"
	const key = bucket + putFixtureKey
	const noKey = `<Error><Code>NoSuchKey</Code><Resource>` + key + `</Resource></Error>`
	for _, tc := range []struct {
		name, op, body, header, value string
		status                        int
		want                          bool
	}{
		{"never_versioned", "policy", `<?xml version="1.0" encoding="UTF-8"?>` + "\n" + open + "\n " + closeTag + "\n", "", "", 200, true},
		{"self_closing", "policy", `<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"/>`, "", "", 200, true},
		{"enabled", "policy", open + "<Status>Enabled</Status>" + closeTag, "", "", 200, false},
		{"suspended", "policy", open + "<Status>Suspended</Status>" + closeTag, "", "", 200, false},
		{"disabled_not_never_versioned", "policy", open + "<Status>Disabled</Status>" + closeTag, "", "", 200, false},
		{"blank_status", "policy", open + "<Status/>" + closeTag, "", "", 200, false},
		{"unknown_extension", "policy", open + "<Policy>unknown</Policy>" + closeTag, "", "", 200, false},
		{"enabled_exclusion", "policy", open + "<Status>Enabled</Status><ExcludedPrefixes><Prefix>private/*</Prefix></ExcludedPrefixes>" + closeTag, "", "", 200, false},
		{"contradictory_second_root", "policy", empty + open + "<Status>Enabled</Status>" + closeTag, "", "", 200, false},
		{"trailing_junk", "policy", empty + "unexpected", "", "", 200, false},
		{"invalid_declaration", "policy", `<?xml unknown?>` + empty, "", "", 200, false},
		{"bare", "policy", "", "", "", 200, false},
		{"html", "policy", "<html>not the bucket policy</html>", "", "", 200, false},
		{"missing_namespace", "policy", "<VersioningConfiguration/>", "", "", 200, false},
		{"truncated", "policy", open, "", "", 200, false},
		{"oversized", "policy", open + strings.Repeat(" ", 4096) + closeTag, "", "", 200, false},
		{"cached_policy", "policy", empty, "Age", "3", 200, false},
		{"contradictory_policy", "policy", empty, "X-Minio-Error-Code", "NoSuchBucket", 200, false},
		{"policy_redirect", "policy", "", "Location", "https://redirect.invalid/wrong-bucket", 307, false},
		{"missing_bucket", "policy", `<Error><Code>NoSuchBucket</Code></Error>`, "", "", 404, false},
		{"denied", "policy", `<Error><Code>AccessDenied</Code></Error>`, "", "", 403, false},
		{"transient_policy", "policy", `<Error><Code>SlowDown</Code></Error>`, "", "", 503, false},
		{"delete_ack", "delete", "", "", "", 204, true},
		{"delete_marker_ack", "delete", "", "X-Amz-Delete-Marker", "true", 204, false},
		{"delete_version_ack", "delete", "", "X-Amz-Version-Id", "null", 204, false},
		{"delete_contradictory_ack", "delete", "", "X-Minio-Error-Code", "NoSuchBucket", 204, false},
		{"delete_redirect", "delete", "", "Location", "https://redirect.invalid/wrong-key", 307, false},
		{"transient_delete", "delete", "", "", "", 503, false},
		{"absence_delete_marker", "absence", noKey, "X-Amz-Delete-Marker", "true", 404, false},
		{"absence_version_id", "absence", noKey, "X-Amz-Version-Id", "null", 404, false},
		{"cached_absence", "absence", noKey, "Age", "3", 404, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			client := newPutFixture(t, func(req *http.Request) (*http.Response, error) {
				calls++
				if req.URL.Host != putFixtureEndpoint || !strings.HasPrefix(req.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential="+putFixtureAccess+"/") {
					t.Fatal("request did not sign the configured internal endpoint")
				}
				switch tc.op {
				case "policy":
					if req.Method != http.MethodGet || req.URL.Path != bucket || req.URL.RawQuery != "versioning=" || req.Header.Get("Cache-Control") != "no-cache, no-store" {
						t.Fatal("expected a fresh read of the configured bucket's versioning policy")
					}
				case "delete":
					if req.Method != http.MethodDelete || req.URL.Path != key || req.URL.RawQuery != "" {
						t.Fatal("delete did not address the exact internal key")
					}
				case "absence":
					if req.Method != http.MethodGet || req.URL.Path != key || req.URL.RawQuery != "" || req.Header.Get("Range") != "bytes=0-0" || req.Header.Get("Cache-Control") != "no-cache, no-store" {
						t.Fatal("expected a fresh ranged GET on the exact internal key")
					}
				}
				res := putFixtureReply(req, tc.status, "")
				res.Body = io.NopCloser(strings.NewReader(tc.body))
				if tc.header != "" {
					res.Header.Set(tc.header, tc.value)
				}
				return res, nil
			})
			ctx := putFixtureContext(t)
			var got bool
			switch tc.op {
			case "policy":
				got = client.VerifyPrivateImportCollectionUnversioned(ctx)
			case "delete":
				got = client.DeletePrivateImportObject(ctx, putFixtureKey) == nil
			case "absence":
				got = client.VerifyPrivateImportObjectAbsent(ctx, putFixtureKey)
			}
			if got != tc.want || calls != 1 {
				t.Fatalf("qualified=%t, want %t, dispatches=%d", got, tc.want, calls)
			}
		})
	}
}
