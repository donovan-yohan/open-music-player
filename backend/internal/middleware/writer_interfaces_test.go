package middleware

import (
	"bufio"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

type minimalWriter struct{ header http.Header }

func (w *minimalWriter) Header() http.Header            { return w.header }
func (w *minimalWriter) Write(data []byte) (int, error) { return len(data), nil }
func (w *minimalWriter) WriteHeader(int)                {}

type capableWriter struct{ *minimalWriter }

func (w *capableWriter) Flush() {}
func (w *capableWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return nil, nil, http.ErrNotSupported
}
func (w *capableWriter) Push(string, *http.PushOptions) error  { return http.ErrNotSupported }
func (w *capableWriter) ReadFrom(src io.Reader) (int64, error) { return io.Copy(io.Discard, src) }

func TestResponseTransformsPreserveOptionalInterfaces(t *testing.T) {
	for _, capable := range []bool{false, true} {
		var writer http.ResponseWriter = &minimalWriter{header: http.Header{}}
		if capable {
			writer = &capableWriter{writer.(*minimalWriter)}
		}
		handler := Timing(Gzip(ETag(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, flush := w.(http.Flusher)
			_, hijack := w.(http.Hijacker)
			_, push := w.(http.Pusher)
			_, read := w.(io.ReaderFrom)
			if flush != capable || hijack != capable || push != capable || read != capable {
				t.Errorf("capable=%v Flush/Hijack/Push/ReadFrom=%v/%v/%v/%v", capable, flush, hijack, push, read)
			}
			if _, ok := w.(interface{ Unwrap() http.ResponseWriter }); !ok {
				t.Error("ResponseController unwrap absent")
			}
		}))))
		req := httptest.NewRequest("GET", "/ordinary", nil)
		req.Header.Set("Accept-Encoding", "gzip")
		handler.ServeHTTP(writer, req)
	}
}
