package storage

import (
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
)

func writeChunkedQualificationFixture(w http.ResponseWriter, status int, body string, header, trailer http.Header) {
	w.Header().Set("Content-Type", "application/xml")
	for name, values := range header {
		w.Header()[name] = values
	}
	for name := range trailer {
		w.Header().Add("Trailer", name)
	}
	w.WriteHeader(status)
	w.(http.Flusher).Flush() // Actual HTTP/1.1 chunking, including the terminal trailer block.
	_, _ = io.WriteString(w, body)
	for name, values := range trailer {
		w.Header()[name] = values
	}
}

func TestPrivateImportQualificationHTTP11(t *testing.T) {
	const resource = "/" + putFixtureBucket + "/" + putFixtureKey
	const ns = "http://s3.amazonaws.com/doc/2006-03-01/"
	const fields = `<Code>NoSuchKey</Code><Resource>` + resource + `</Resource>`
	const plain = `<Error>` + fields + `</Error>`
	const policy = `<VersioningConfiguration xmlns="` + ns + `"/>`
	field := func(name, value string) http.Header { return http.Header{http.CanonicalHeaderKey(name): {value}} }
	matching := field("X-Minio-Error-Code", "NoSuchKey")
	conflicting := field("X-Minio-Error-Code", "NoSuchBucket")
	for _, tc := range []struct {
		name, body      string
		header, trailer http.Header
		policy, want    bool
	}{
		{name: "absence_plain", body: plain, want: true},
		{name: "absence_matching_code_trailer", body: plain, trailer: matching, want: true},
		{name: "absence_other_trailer", body: plain, trailer: field("X-Amz-Request-Id", "fixture-request"), want: true},
		{name: "absence_conflicting_code_trailer", body: plain, trailer: conflicting},
		{name: "absence_matching_header_conflicting_trailer", body: plain, header: matching, trailer: conflicting},
		{name: "absence_mixed_codes_trailer", body: plain, trailer: http.Header{"X-Minio-Error-Code": {"NoSuchKey", "NoSuchBucket"}}},
		{name: "absence_marker_trailer", body: plain, trailer: field("X-Amz-Delete-Marker", "true")},
		{name: "absence_version_trailer", body: plain, trailer: field("X-Amz-Version-Id", "null")},
		{name: "absence_age_trailer", body: plain, trailer: field("Age", "0")},
		{name: "absence_default_namespace", body: `<Error xmlns="` + ns + `">` + fields + `</Error>`, want: true},
		{name: "absence_prefixed_namespace", body: `<s:Error xmlns:s="` + ns + `"><s:Code>NoSuchKey</s:Code><s:Resource>` + resource + `</s:Resource></s:Error>`, want: true},
		{name: "absence_duplicate_default_same", body: `<Error xmlns="` + ns + `" xmlns="` + ns + `">` + fields + `</Error>`},
		{name: "absence_conflicting_default_then_exact", body: `<Error xmlns="urn:wrong" xmlns="` + ns + `">` + fields + `</Error>`},
		{name: "absence_conflicting_prefix_then_exact", body: `<s:Error xmlns:s="urn:wrong" xmlns:s="` + ns + `"><s:Code>NoSuchKey</s:Code><s:Resource>` + resource + `</s:Resource></s:Error>`},
		{name: "absence_duplicate_default_on_binding", body: `<Error>` + `<Code xmlns="urn:wrong" xmlns="">NoSuchKey</Code><Resource>` + resource + `</Resource></Error>`},
		{name: "absence_duplicate_namespace_in_ignored_detail", body: `<Error>` + fields + `<Message><Detail xmlns="urn:wrong" xmlns="">irrelevant</Detail></Message></Error>`},
		{name: "absence_duplicate_attribute", body: `<Error note="a" note="b">` + fields + `</Error>`},
		{name: "absence_undeclared_attribute_prefix", body: `<Error junk:note="a">` + fields + `</Error>`},
		{name: "absence_unquoted_attribute", body: `<Error note=unquoted>` + fields + `</Error>`},
		{name: "policy_plain", body: policy, policy: true, want: true},
		{name: "policy_unrelated_trailer", body: policy, trailer: field("X-Amz-Request-Id", "fixture-request"), policy: true, want: true},
		{name: "policy_error_code_trailer", body: policy, trailer: conflicting, policy: true},
		{name: "policy_error_description_trailer", body: policy, trailer: field("X-Minio-Error-Desc", "synthetic error"), policy: true},
		{name: "policy_marker_trailer", body: policy, trailer: field("X-Amz-Delete-Marker", "true"), policy: true},
		{name: "policy_version_trailer", body: policy, trailer: field("X-Amz-Version-Id", "null"), policy: true},
		{name: "policy_age_trailer", body: policy, trailer: field("Age", "0"), policy: true},
		{name: "policy_duplicate_default_same", body: `<VersioningConfiguration xmlns="` + ns + `" xmlns="` + ns + `"/>`, policy: true},
		{name: "policy_conflicting_default_then_exact", body: `<VersioningConfiguration xmlns="urn:wrong" xmlns="` + ns + `"/>`, policy: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls atomic.Int32
			wire := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				if r.Proto != "HTTP/1.1" || r.Method != http.MethodGet || r.Header.Get("Cache-Control") != "no-cache, no-store" ||
					!strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential="+putFixtureAccess+"/") {
					t.Error("expected a fresh signed HTTP/1.1 GET")
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				status, exact := http.StatusNotFound, r.URL.Path == resource && r.URL.RawQuery == "" && r.Header.Get("Range") == "bytes=0-0"
				if tc.policy {
					status, exact = http.StatusOK, r.URL.Path == "/"+putFixtureBucket+"/" && r.URL.RawQuery == "versioning="
				}
				if !exact {
					t.Error("wrong proof target")
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				writeChunkedQualificationFixture(w, status, tc.body, tc.header, tc.trailer)
			}))
			defer wire.Close()
			store, err := New(&Config{Endpoint: wire.URL, AccessKey: putFixtureAccess, SecretKey: putFixtureSecret, Bucket: putFixtureBucket, Region: putFixtureRegion})
			if err != nil {
				t.Fatal(err)
			}
			ctx := putFixtureContext(t)
			var got bool
			if tc.policy {
				got = store.VerifyPrivateImportCollectionUnversioned(ctx)
			} else {
				got = store.VerifyPrivateImportObjectAbsent(ctx, putFixtureKey)
			}
			if got != tc.want || calls.Load() != 1 {
				t.Fatalf("qualified=%t requests=%d; want %t and one exact request", got, calls.Load(), tc.want)
			}
		})
	}
}

func TestQualificationFixtureTrailersArriveOnlyAtEOF(t *testing.T) {
	const code = "X-Minio-Error-Code"
	wire := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeChunkedQualificationFixture(w, http.StatusNotFound, `<Error/>`, nil, http.Header{code: {"NoSuchBucket"}})
	}))
	defer wire.Close()
	req, err := http.NewRequestWithContext(putFixtureContext(t), http.MethodGet, wire.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := wire.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.Proto != "HTTP/1.1" || !reflect.DeepEqual(resp.TransferEncoding, []string{"chunked"}) || resp.Header.Get(code) != "" || resp.Trailer.Get(code) != "" {
		t.Fatal("fixture moved metadata ahead of the chunked body")
	}
	if body, err := io.ReadAll(resp.Body); err != nil || string(body) != `<Error/>` {
		t.Fatalf("fixture did not deliver a complete body: %v", err)
	}
	if resp.Header.Get(code) != "" || resp.Trailer.Get(code) != "NoSuchBucket" {
		t.Fatal("fixture did not deliver separate metadata at EOF")
	}
}
