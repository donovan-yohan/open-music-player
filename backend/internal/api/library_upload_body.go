package api

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/processor"
)

const (
	libraryUploadManifestBytes = 8 << 10
	libraryUploadEnvelopeBytes = 16 << 10
	libraryUploadHeaderBytes   = 1024 // at most three lines per part
)

var (
	uploadHash          = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
	uploadBoundaryToken = regexp.MustCompile(`^[A-Za-z0-9'()+_,./:=?-]{1,70}$`)
	errUploadFraming    = errors.New("invalid upload framing")
	errUploadMedia      = errors.New("invalid upload media")
)

func uploadBoundary(headers http.Header) (string, error) {
	media, params, err := mime.ParseMediaType(headers.Get("Content-Type"))
	boundary := params["boundary"]
	if err != nil || media != "multipart/form-data" || len(headers.Values("Content-Type")) != 1 ||
		len(headers.Values("Content-Encoding")) != 0 || len(params) != 1 || !uploadBoundaryToken.MatchString(boundary) {
		return "", errUploadMedia
	}
	return boundary, nil
}

// This narrow multipart profile requires exact EOF, no preamble/epilogue,
// bounded headers, and the original's declared number of raw bytes. During
// the small prelude, deliberately do not read ahead from the HTTP body;
// turn on block reads only when the durable intake invokes the lazy reader.
func readUploadManifest(body io.Reader, boundary string) (db.PrivateImportManifest, *libraryUploadAudio, error) {
	input := &uploadPreludeReader{body: body}
	reader := bufio.NewReaderSize(input, libraryUploadManifestBytes+2)
	delimiter := "--" + boundary
	if err := requireUploadLine(reader, delimiter); err != nil {
		return db.PrivateImportManifest{}, nil, err
	}
	partLength, err := readUploadPartHeaders(reader, "manifest", "application/json")
	if err != nil {
		return db.PrivateImportManifest{}, nil, err
	}
	var data []byte
	for {
		line, e := reader.ReadSlice('\n')
		if errors.Is(e, bufio.ErrBufferFull) {
			e = processor.ErrPrivateIntakeSize
		}
		if e != nil {
			return db.PrivateImportManifest{}, nil, e
		}
		if bytes.Equal(line, []byte(delimiter+"\r\n")) {
			if !bytes.HasSuffix(data, []byte("\r\n")) {
				return db.PrivateImportManifest{}, nil, errUploadFraming
			}
			data = data[:len(data)-2]
			break
		}
		if len(data)+len(line) > libraryUploadManifestBytes+2 {
			return db.PrivateImportManifest{}, nil, processor.ErrPrivateIntakeSize
		}
		data = append(data, line...)
	}
	if partLength >= 0 && partLength != int64(len(data)) {
		return db.PrivateImportManifest{}, nil, errUploadFraming
	}
	manifest, err := decodeUploadManifest(data)
	if err != nil {
		return db.PrivateImportManifest{}, nil, err
	}
	return manifest, &libraryUploadAudio{source: reader, input: input, length: manifest.ByteLength, remaining: manifest.ByteLength, marker: []byte("\r\n" + delimiter)}, nil
}

type uploadPreludeReader struct {
	body     io.Reader
	admitted bool
}

func (r *uploadPreludeReader) Read(p []byte) (int, error) {
	if !r.admitted && len(p) > 1 {
		p = p[:1]
	}
	return r.body.Read(p)
}

func requireUploadLine(reader *bufio.Reader, expected string) error {
	line, err := reader.ReadSlice('\n')
	if errors.Is(err, bufio.ErrBufferFull) {
		return errUploadFraming
	}
	if err != nil {
		return err
	}
	if !bytes.Equal(line, []byte(expected+"\r\n")) {
		return errUploadFraming
	}
	return nil
}

func readUploadPartHeaders(reader *bufio.Reader, name, media string) (int64, error) {
	var disposition, contentType bool
	size := int64(-1)
	for lineNo := 0; lineNo <= 3; lineNo++ {
		raw, err := reader.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) || len(raw) > libraryUploadHeaderBytes {
			return 0, errUploadFraming
		}
		if err != nil {
			return 0, err
		}
		line, ok := strings.CutSuffix(string(raw), "\r\n")
		if !ok {
			return 0, errUploadFraming
		}
		if line == "" && disposition && contentType {
			return size, nil
		}
		key, v, ok := strings.Cut(line, ":")
		if !ok || lineNo == 3 {
			return 0, errUploadFraming
		}
		v = strings.Trim(v, " \t")
		switch strings.ToLower(key) {
		case "content-disposition":
			kind, params, e := mime.ParseMediaType(v)
			_, param, _ := strings.Cut(v, ";")
			attribute, _, _ := strings.Cut(param, "=")
			if disposition || e != nil || kind != "form-data" || len(params) != 1 || params["name"] != name ||
				strings.Count(v, ";") != 1 || !strings.EqualFold(strings.TrimSpace(attribute), "name") {
				return 0, errUploadFraming
			}
			disposition = true
		case "content-type":
			actual, params, e := mime.ParseMediaType(v)
			if contentType || e != nil || actual != media || (len(params) != 0 &&
				!(media == "application/json" && len(params) == 1 && strings.EqualFold(params["charset"], "utf-8"))) {
				return 0, errUploadMedia
			}
			contentType = true
		case "content-length":
			n, e := strconv.ParseInt(v, 10, 64)
			if size >= 0 || e != nil || n < 0 || strconv.FormatInt(n, 10) != v {
				return 0, errUploadFraming
			}
			size = n
		default:
			return 0, errUploadFraming
		}
	}
	return 0, errUploadFraming
}

func decodeUploadManifest(data []byte) (m db.PrivateImportManifest, err error) {
	if !utf8.Valid(data) {
		return m, errUploadFraming
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	if start, e := decoder.Token(); e != nil || start != json.Delim('{') {
		return m, errUploadFraming
	}
	seen := make(map[string]bool, 5)
	for decoder.More() {
		key, e := decoder.Token()
		field, ok := key.(string)
		if e != nil || !ok || seen[field] {
			return m, errUploadFraming
		}
		seen[field] = true
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil || bytes.Equal(raw, []byte("null")) {
			return m, errUploadFraming
		}
		switch field {
		case "sha256":
			e = json.Unmarshal(raw, &m.SHA256)
		case "byte_length":
			e = json.Unmarshal(raw, &m.ByteLength)
		case "title":
			e = json.Unmarshal(raw, &m.Title)
		case "artist":
			e = json.Unmarshal(raw, &m.Artist)
		case "album":
			e = json.Unmarshal(raw, &m.Album)
		default:
			return m, errUploadFraming
		}
		if e != nil {
			return m, errUploadFraming
		}
	}
	if end, e := decoder.Token(); e != nil || end != json.Delim('}') {
		return m, errUploadFraming
	}
	if _, e := decoder.Token(); e != io.EOF {
		return m, errUploadFraming
	}
	if m.ByteLength > db.PrivateImportMaxBytes {
		return m, processor.ErrPrivateIntakeSize
	}
	m.Title, m.Artist, m.Album = strings.TrimSpace(m.Title), strings.TrimSpace(m.Artist), strings.TrimSpace(m.Album)
	if !uploadHash.MatchString(m.SHA256) || m.ByteLength <= 0 || m.Title == "" {
		return m, errUploadFraming
	}
	for _, v := range []string{m.Title, m.Artist, m.Album} {
		if strings.ContainsRune(v, 0) || utf8.RuneCountInString(v) > 500 {
			return m, errUploadFraming
		}
	}
	return m, nil
}

type libraryUploadAudio struct {
	source            *bufio.Reader
	input             *uploadPreludeReader
	marker            []byte
	length, remaining int64
	tail              [74]byte // longest CRLF--boundary prefix
	tailN             int
	started, complete bool
	err               error
	onEOF             func()
}

func (a *libraryUploadAudio) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if a.complete {
		return 0, io.EOF
	}
	if a.err != nil {
		return 0, a.err
	}
	fail := func(err error) (int, error) {
		if err == io.EOF {
			err = io.ErrUnexpectedEOF
		}
		a.err = err
		return 0, err
	}
	if !a.started {
		a.input.admitted = true
		size, err := readUploadPartHeaders(a.source, "audio", "audio/mpeg")
		if err != nil {
			return fail(err)
		}
		if size >= 0 && size != a.length {
			return fail(errUploadFraming)
		}
		a.started = true
	}
	if a.remaining == 0 {
		// The reader must not return EOF to the processor until we have proved
		// exactly one part boundary and the end of the HTTP message, also for chunked.
		closing := append(append([]byte{}, a.marker...), []byte("--\r\n")...)
		var trailer [78]byte
		if _, err := io.ReadFull(a.source, trailer[:len(closing)]); err != nil {
			return fail(err)
		}
		if !bytes.Equal(trailer[:len(closing)], closing) {
			return fail(errUploadFraming)
		}
		if _, err := a.source.ReadByte(); err != io.EOF {
			if err != nil {
				return fail(err)
			}
			return fail(errUploadFraming)
		}
		a.complete = true
		if a.onEOF != nil {
			a.onEOF()
		}
		return 0, io.EOF
	}
	n, err := a.source.Read(p[:min(int64(len(p)), a.remaining)])
	if err != nil {
		return fail(err)
	}
	// A delimiter is not legal inside an original part. Detect it even when
	// split at a Read boundary so declared length cannot swallow an extra part.
	keep := len(a.marker) - 1
	var join [148]byte
	copied := copy(join[:], a.tail[:a.tailN])
	copied += copy(join[copied:], p[:min(n, keep)])
	if bytes.Contains(p[:n], a.marker) || bytes.Contains(join[:copied], a.marker) {
		return fail(errUploadFraming)
	}
	if n >= keep {
		a.tailN = copy(a.tail[:], p[n-keep:n])
	} else {
		a.tailN = copy(a.tail[:], join[max(0, copied-keep):copied])
	}
	a.remaining -= int64(n)
	return n, nil
}

func writeUploadInputError(w http.ResponseWriter, err error) {
	var limit *http.MaxBytesError
	var timeout net.Error
	switch {
	case errors.Is(err, processor.ErrPrivateIntakeSize), errors.As(err, &limit):
		writeErrorResponse(w, http.StatusRequestEntityTooLarge, "UPLOAD_TOO_LARGE", "Original or multipart manifest exceeds its limit")
	case errors.Is(err, errUploadMedia), errors.Is(err, processor.ErrPrivateIntakeProbe):
		writeErrorResponse(w, http.StatusUnsupportedMediaType, "UPLOAD_MEDIA", "Send one self-contained MP3 and a JSON manifest")
	case errors.As(err, &timeout) && timeout.Timeout():
		writeErrorResponse(w, http.StatusRequestTimeout, "UPLOAD_BODY_TIMEOUT", "Upload body timed out")
	default:
		writeErrorResponse(w, http.StatusBadRequest, "INVALID_UPLOAD", "Upload framing or original bytes do not match")
	}
}
