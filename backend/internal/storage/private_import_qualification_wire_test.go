package storage

import (
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
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
		{name: "absence_undeclared_detail_prefix", body: `<Error>` + fields + `<Message><junk:Detail/></Message></Error>`},
		{name: "absence_undeclared_different_prefix", body: `<s:Error xmlns:s="` + ns + `"><s:Code>NoSuchKey</s:Code><s:Resource>` + resource + `</s:Resource><s:Message><other:Detail/></s:Message></s:Error>`},
		{name: "absence_bound_detail_prefix", body: `<s:Error xmlns:s="` + ns + `"><s:Code>NoSuchKey</s:Code><s:Resource>` + resource + `</s:Resource><s:Message><s:Detail/></s:Message><Unprefixed/></s:Error>`, want: true},
		{name: "absence_unprefixed_binding_under_prefixed_root", body: `<s:Error xmlns:s="` + ns + `">` + fields + `</s:Error>`},
		{name: "absence_xml_reserved_prefix", body: `<Error>` + fields + `<xml:Detail/></Error>`},
		{name: "absence_xmlns_reserved_prefix", body: `<Error>` + fields + `<xmlns:Detail/></Error>`},
		{name: "absence_empty_prefix", body: `<Error>` + fields + `<:Detail/></Error>`},
		{name: "absence_empty_local_name", body: `<Error>` + fields + `<Detail:/></Error>`},
		{name: "absence_invalid_bound_local_name", body: `<s:Error xmlns:s="` + ns + `"><s:Code>NoSuchKey</s:Code><s:Resource>` + resource + `</s:Resource><s:1Detail/></s:Error>`},
		{name: "absence_mismatched_raw_end", body: `<Error xmlns="` + ns + `">` + fields + `<Detail></other:Detail></Error>`},
		{name: "absence_undeclared_prefix_not_s3_namespace", body: `<s3:Error xmlns="` + ns + `">` + fields + `</s3:Error>`},
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

func TestPrivateImportQualificationRetryHTTP11(t *testing.T) {
	const path = "/" + putFixtureBucket + "/" + putFixtureKey
	const policyPath = "/" + putFixtureBucket + "/"
	const notFound = `<Error><Code>NoSuchKey</Code><Resource>` + path + `</Resource></Error>`
	const policy = `<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"/>`
	const slowDown = `<Error><Code>SlowDown</Code></Error>`
	const capBytes = 4096
	field := func(name, value string) http.Header { return http.Header{http.CanonicalHeaderKey(name): {value}} }
	for _, tc := range []struct {
		name, intermediate string
		header, trailer    http.Header
		intermediateStatus int
		truncated, policy  bool
		want               bool
	}{
		{name: "clean_retry", intermediate: slowDown, want: true},
		{name: "clean_retry_exact_cap", intermediate: slowDown + strings.Repeat(" ", capBytes-len(slowDown)), want: true},
		{name: "clean_retry_matching_vendor_code", intermediate: slowDown, header: field("X-Minio-Error-Code", "SlowDown"), trailer: field("X-Minio-Error-Code", "SlowDown"), want: true},
		{name: "clean_retry_unrelated_trailer", intermediate: slowDown, trailer: field("X-Amz-Request-Id", "fixture-request"), want: true},
		{name: "retry_marker_header", intermediate: slowDown, header: field("X-Amz-Delete-Marker", "true")},
		{name: "retry_marker_trailer", intermediate: slowDown, trailer: field("X-Amz-Delete-Marker", "true")},
		{name: "retry_version_trailer", intermediate: slowDown, trailer: field("X-Amz-Version-Id", "null")},
		{name: "retry_age_trailer", intermediate: slowDown, trailer: field("Age", "0")},
		{name: "retry_conflicting_vendor_code", intermediate: slowDown, trailer: field("X-Minio-Error-Code", "NoSuchBucket")},
		{name: "retry_wrong_target", intermediate: `<Error><Code>SlowDown</Code><Key>wrong-key</Key></Error>`},
		{name: "retry_bare_error"},
		{name: "retry_invalid_xml", intermediate: slowDown + `<Error/>`},
		{name: "retry_over_cap", intermediate: slowDown + strings.Repeat(" ", capBytes+1-len(slowDown))},
		{name: "retry_framing_error_after_complete_xml", intermediate: slowDown, truncated: true},
		{name: "unexpected_success_cannot_be_laundered", intermediate: slowDown, intermediateStatus: http.StatusNonAuthoritativeInfo, header: field("X-Minio-Error-Code", "SlowDown")},
		{name: "policy_no_clean_retry", intermediate: slowDown, policy: true},
		{name: "policy_no_retry_after_trailer", intermediate: slowDown, trailer: field("X-Amz-Version-Id", "null"), policy: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			wantCalls := int32(2)
			status := tc.intermediateStatus
			if status == 0 {
				status = http.StatusServiceUnavailable
			}
			target, query, byteRange, finalBody, finalStatus := path, "", "bytes=0-0", notFound, http.StatusNotFound
			if tc.policy {
				wantCalls = 1
				target, query, byteRange, finalBody, finalStatus = policyPath, "versioning=", "", policy, http.StatusOK
			}
			var calls atomic.Int32
			wire := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				attempt := calls.Add(1)
				if r.Proto != "HTTP/1.1" || r.Method != http.MethodGet || r.URL.Path != target || r.URL.RawQuery != query || r.Header.Get("Range") != byteRange ||
					r.Header.Get("Cache-Control") != "no-cache, no-store" || !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential="+putFixtureAccess+"/") {
					t.Error("expected a fresh signed HTTP/1.1 GET of the same exact target")
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				if attempt != 1 {
					writeChunkedQualificationFixture(w, finalStatus, finalBody, nil, nil)
					return
				}
				if tc.truncated {
					w.Header().Set("Content-Length", strconv.Itoa(len(tc.intermediate)+1))
					w.WriteHeader(status)
					_, _ = io.WriteString(w, tc.intermediate)
					return
				}
				writeChunkedQualificationFixture(w, status, tc.intermediate, tc.header, tc.trailer)
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
			// A premature wire close used to be fatal in the SDK itself. Do not
			// require it to retry, but must never let a later 404 clear the failure.
			if tc.truncated && calls.Load() == 1 && !got {
				return
			}
			if got != tc.want || calls.Load() != wantCalls {
				t.Fatalf("qualified=%t requests=%d; want %t and %d exact request(s)", got, calls.Load(), tc.want, wantCalls)
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
