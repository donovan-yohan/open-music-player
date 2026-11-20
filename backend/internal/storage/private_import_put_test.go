package storage

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/minio/minio-go/v7"
)

const (
	putFixtureEndpoint = "private-put-fixture.invalid:8443"
	putFixturePublic   = "public-presign-fixture.invalid:9443"
	putFixtureAccess   = "generated-private-put-access"
	putFixtureSecret   = "generated-private-put-secret"
	putFixtureRegion   = "us-west-2"
	putFixtureBucket   = "generated-fixture"
	putFixtureKey      = "staged/attempt.mp3"
)

type putFixtureRoundTrip func(*http.Request) (*http.Response, error)

func (f putFixtureRoundTrip) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.Body != nil {
		defer req.Body.Close()
	}
	return f(req)
}

// Inject below MinIO's SDK retry loop but above the network. Construct the
// storage Client with the ordinary production New; replacing an already-built
// MinIO client would not prove that New's options reach the staged Put.
// The SDK factory is global; these cases must not run in parallel.
func newPutFixture(t *testing.T, roundTrip putFixtureRoundTrip) *Client {
	t.Helper()
	previous := minio.DefaultTransport
	t.Cleanup(func() { minio.DefaultTransport = previous })
	minio.DefaultTransport = func(secure bool) (*http.Transport, error) {
		if !secure {
			return nil, errors.New("fixture TLS configuration was lost")
		}
		tr := &http.Transport{DialContext: func(context.Context, string, string) (net.Conn, error) {
			return nil, errors.New("private Put test does not permit network dial")
		}}
		tr.RegisterProtocol("https", roundTrip)
		return tr, nil
	}
	client, err := New(&Config{
		Endpoint: "https://" + putFixtureEndpoint, PublicEndpoint: "https://" + putFixturePublic,
		Region: putFixtureRegion, AccessKey: putFixtureAccess, SecretKey: putFixtureSecret, Bucket: putFixtureBucket,
	})
	if err != nil {
		t.Fatal("could not construct production storage client for the fixture")
	}
	return client
}

func putFixtureRequest(t *testing.T, req *http.Request, size int64, conditional bool) {
	t.Helper()
	if req.Method != http.MethodPut || req.URL.Scheme != "https" || req.URL.Host != putFixtureEndpoint ||
		req.URL.Path != "/"+putFixtureBucket+"/"+putFixtureKey || req.URL.RawQuery != "" || req.ContentLength != size {
		t.Fatal("did not send one signed object Put to the intended internal endpoint")
	}
	match := ""
	if conditional {
		match = "*"
	}
	if req.Header.Get("If-None-Match") != match || req.Header.Get("Content-Type") != "audio/mpeg" || req.GetBody != nil {
		t.Fatal("incorrect create-only, content-type, or transport body-replay semantics")
	}
	auth := req.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "AWS4-HMAC-SHA256 Credential="+putFixtureAccess+"/") ||
		!strings.Contains(auth, "/"+putFixtureRegion+"/s3/aws4_request,") || !strings.Contains(auth, "Signature=") || strings.Contains(auth, putFixtureSecret) {
		t.Fatal("configured signature or credential scope was lost")
	}
}

func putFixtureReply(req *http.Request, status int, code string) *http.Response {
	header := make(http.Header)
	header.Set("Content-Type", "application/xml")
	msg := ""
	if code == "" {
		header.Set("ETag", `"generated-fixture-etag"`)
	} else {
		msg = "<Error><Code>" + code + "</Code><Message>synthetic refusal</Message></Error>"
	}
	return &http.Response{StatusCode: status, Header: header, Body: io.NopCloser(strings.NewReader(msg)), Request: req}
}

func putFixtureBody(t *testing.T, req *http.Request, expected []byte) {
	t.Helper()
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(req.Body, int64(len(expected))+1))
	want := sha256.Sum256(expected)
	if err != nil || n != int64(len(expected)) || !bytes.Equal(h.Sum(nil), want[:]) {
		t.Fatalf("transport body was not exact: got %d bytes, expected %d", n, len(expected))
	}
}

func putFixtureNoCredentialError(t *testing.T, err error) {
	t.Helper()
	if err != nil && (strings.Contains(err.Error(), putFixtureAccess) || strings.Contains(err.Error(), putFixtureSecret) || strings.Contains(err.Error(), "X-Amz-Signature")) {
		t.Fatal("private Put error exposed a credential or signed URL")
	}
}

func TestPrivateImportPutErrorContextDoesNotDisplayTransportDetails(t *testing.T) {
	payload := []byte("fixture")
	client := newPutFixture(t, func(req *http.Request) (*http.Response, error) {
		putFixtureRequest(t, req, int64(len(payload)), true)
		reply := putFixtureReply(req, http.StatusPreconditionFailed, "PreconditionFailed")
		reply.Body = io.NopCloser(strings.NewReader(`<Error><Code>PreconditionFailed</Code><Message>` + putFixtureKey + `</Message></Error>`))
		return reply, nil
	})
	err := client.PutPrivateImportObject(putFixtureContext(t), putFixtureKey, bytes.NewReader(payload), int64(len(payload)))
	var response minio.ErrorResponse
	if !errors.As(err, &response) || response.StatusCode != http.StatusPreconditionFailed || err.Error() != "private intake object Put failed" {
		t.Fatalf("want static Put context and typed 412, got %v", err)
	}
}

func putFixtureContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func TestPrivateImportPutDoesNotReplay(t *testing.T) {
	for _, scenario := range []struct {
		name, code string
		consume    bool
	}{
		{"early_slow_down", "SlowDown", false},
		{"slow_down_after_body", "SlowDown", true},
		{"lost_response_after_body", "", true},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			payload := []byte("generated exact-byte fixture")
			reader := bytes.NewReader(payload)
			calls, consumedOnFirst := 0, 0
			client := newPutFixture(t, func(req *http.Request) (*http.Response, error) {
				calls++
				putFixtureRequest(t, req, int64(len(payload)), true)
				if calls > 1 {
					if !scenario.consume {
						// No initial reads: a bogus rewind leaves the full payload
						// available. The second dispatch can return a false ACK.
						putFixtureBody(t, req, payload)
						return putFixtureReply(req, http.StatusOK, ""), nil
					}
					return putFixtureReply(req, http.StatusPreconditionFailed, "PreconditionFailed"), nil
				}
				if scenario.consume {
					putFixtureBody(t, req, payload)
				}
				consumedOnFirst = len(payload) - reader.Len()
				if scenario.code == "" {
					return nil, io.ErrUnexpectedEOF
				}
				return putFixtureReply(req, http.StatusServiceUnavailable, scenario.code), nil
			})
			ctx := putFixtureContext(t)
			err := client.PutPrivateImportObject(ctx, putFixtureKey, reader, int64(len(payload)))
			putFixtureNoCredentialError(t, err)
			wantConsumed := 0
			if scenario.consume {
				wantConsumed = len(payload)
			}
			if consumedOnFirst != wantConsumed || ctx.Err() != nil {
				t.Fatalf("fixture did not hit the expected transport boundary: consumed=%d want=%d deadline=%t", consumedOnFirst, wantConsumed, ctx.Err() != nil)
			}
			if calls != 1 || err == nil {
				t.Fatalf("private Put must dispatch once without a positive ACK: requests=%d acknowledged=%t first_body_bytes=%d", calls, err == nil, consumedOnFirst)
			}
			var response minio.ErrorResponse
			if scenario.code == "" {
				// The pinned SDK rewrites transport EOF to a new url.Error;
				// retain that transport cause, not a fabricated S3 code.
				var transportErr *url.Error
				if !errors.As(err, &transportErr) || errors.As(err, &response) {
					t.Fatal("private Put did not preserve the transport failure")
				}
			} else if !errors.As(err, &response) || response.Code != scenario.code {
				t.Fatal("private Put did not preserve the initial service failure")
			}
			t.Logf("requests=%d acknowledged=false first_body_bytes=%d", calls, consumedOnFirst)
		})
	}
}

func TestPrivateImportPutExactSinglePartAndOverwriteRefusal(t *testing.T) {
	// Cross the pinned SDK's 16 MiB default multipart threshold.
	payload := bytes.Repeat([]byte{0x45, 0x72, 0x7a, 0xd2}, (4<<20)+1)
	calls := 0
	client := newPutFixture(t, func(req *http.Request) (*http.Response, error) {
		calls++
		putFixtureRequest(t, req, int64(len(payload)), true)
		if calls == 1 {
			putFixtureBody(t, req, payload)
			return putFixtureReply(req, http.StatusOK, ""), nil
		}
		return putFixtureReply(req, http.StatusPreconditionFailed, "PreconditionFailed"), nil
	})
	ctx := putFixtureContext(t)
	if err := client.PutPrivateImportObject(ctx, putFixtureKey, bytes.NewReader(payload), int64(len(payload))); err != nil || calls != 1 {
		t.Fatalf("private single-part Put did not acknowledge exactly one request: requests=%d", calls)
	}
	var response minio.ErrorResponse
	if err := client.PutPrivateImportObject(ctx, putFixtureKey, bytes.NewReader(payload), int64(len(payload))); !errors.As(err, &response) || response.StatusCode != http.StatusPreconditionFailed || calls != 2 {
		t.Fatalf("conditional overwrite was not refused once: requests=%d", calls)
	} else {
		putFixtureNoCredentialError(t, err)
	}
}

func TestPrivateImportPutRefusesRedirect(t *testing.T) {
	payload := []byte("fixture")
	calls := 0
	client := newPutFixture(t, func(req *http.Request) (*http.Response, error) {
		calls++
		putFixtureRequest(t, req, int64(len(payload)), true)
		// 303 would follow with a GET even though there is no GetBody.
		res := putFixtureReply(req, http.StatusSeeOther, "")
		res.Header.Set("Location", "https://"+putFixturePublic+"/should-not-follow")
		return res, nil
	})
	err := client.PutPrivateImportObject(putFixtureContext(t), putFixtureKey, bytes.NewReader(payload), int64(len(payload)))
	putFixtureNoCredentialError(t, err)
	if err == nil || calls != 1 {
		t.Fatalf("redirect was not rejected after one dispatch: requests=%d acknowledged=%t", calls, err == nil)
	}
}

func TestPrivateImportPutKeepsOrdinaryRetriesAndPublicPresign(t *testing.T) {
	payload := []byte("ordinary generated fixture")
	calls := 0
	client := newPutFixture(t, func(req *http.Request) (*http.Response, error) {
		calls++
		putFixtureRequest(t, req, int64(len(payload)), false)
		putFixtureBody(t, req, payload) // Ordinary Put retries can rewind.
		if calls == 1 {
			return putFixtureReply(req, http.StatusServiceUnavailable, "SlowDown"), nil
		}
		return putFixtureReply(req, http.StatusOK, ""), nil
	})
	ctx := putFixtureContext(t)
	if err := client.PutObject(ctx, putFixtureKey, bytes.NewReader(payload), int64(len(payload)), "audio/mpeg"); err != nil || calls != 2 {
		t.Fatalf("ordinary storage retry path changed: requests=%d", calls)
	}
	link, err := client.PresignGetObject(ctx, putFixtureKey, time.Minute)
	if err != nil {
		t.Fatal("presign with public endpoint failed")
	}
	u, err := url.Parse(link)
	if err != nil || u.Scheme != "https" || u.Host != putFixturePublic || u.Path != "/"+putFixtureBucket+"/"+putFixtureKey || calls != 2 {
		t.Fatal("presign endpoint changed or presign unexpectedly sent a request")
	}
	query := u.Query()
	if credential := query.Get("X-Amz-Credential"); !strings.HasPrefix(credential, putFixtureAccess+"/") ||
		!strings.HasSuffix(credential, "/"+putFixtureRegion+"/s3/aws4_request") || len(query.Get("X-Amz-Signature")) != 64 || strings.Contains(link, putFixtureSecret) {
		t.Fatal("configured presign signature or region was lost")
	}
}
