// Package preview serves only explicitly cleared, locally mounted Discover clips.
package preview

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
	"unicode"

	"github.com/openmusicplayer/backend/internal/validators"
)

const (
	maxClipBytes     = 2 * 1024 * 1024
	maxManifestBytes = 256 * 1024
	maxEntries       = 256
	maxURLBytes      = 4096
	maxSeconds       = 30
	maxConcurrent    = 4
)

var (
	clipName    = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}\.mp3$`)
	apiTrack    = regexp.MustCompile(`^/tracks/[1-9][0-9]*$`)
	errManifest = errors.New("invalid preview manifest")
	errFile     = errors.New("invalid preview file")
)

type clip struct {
	filename     string
	length       int
	digest       [sha256.Size]byte
	rate, frames int
	expiresAt    time.Time
}

// Catalog is a startup snapshot of an operator-controlled allowlist. It has no
// provider, persistence, or import dependency. A nil Catalog is disabled.
type Catalog struct {
	dir    string
	clips  map[string]clip
	active chan struct{}
}

// Load reads manifest.json once from an absolute, trusted local mount (empty
// disables preview). A malformed manifest admits nothing. Error text never
// includes config paths, source identities or rights records.
func Load(dir string) (*Catalog, error) {
	if dir == "" {
		return nil, nil
	}
	if !filepath.IsAbs(dir) || filepath.Clean(dir) != dir {
		return nil, errors.New("preview directory must be a clean absolute path")
	}
	data, err := readLocal(context.Background(), dir, "manifest.json", maxManifestBytes, 0)
	if err != nil {
		return nil, errors.New("preview manifest cannot be read within bounds")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	if token, err := dec.Token(); err != nil || token != json.Delim('[') {
		return nil, errManifest
	}
	clips := make(map[string]clip)
	for dec.More() {
		if len(clips) == maxEntries {
			return nil, errManifest
		}
		key, c, err := decodeClip(dec)
		if _, duplicate := clips[key]; err != nil || duplicate {
			return nil, fmt.Errorf("invalid preview manifest entry %d", len(clips)+1)
		}
		clips[key] = c
	}
	if token, err := dec.Token(); err != nil || token != json.Delim(']') || !atEOF(dec) {
		return nil, errManifest
	}
	return &Catalog{dir: dir, clips: clips, active: make(chan struct{}, maxConcurrent)}, nil
}

func decodeClip(dec *json.Decoder) (string, clip, error) {
	var c clip
	var key, digest, rightsRef, attribution string
	// A JSON null is not a valid offset, including for a clip starting at zero.
	var offset *int64
	if !decodeObject(dec, map[string]any{
		"url": &key, "file": &c.filename, "length": &c.length, "sha256": &digest,
		"sampleRate": &c.rate, "frames": &c.frames, "excerptStartFrames": &offset,
		"rightsRef": &rightsRef, "attribution": &attribution, "expiresAt": &c.expiresAt,
	}) || !canonicalSource(key) || !clipName.MatchString(c.filename) ||
		c.length < 1 || c.length > maxClipBytes || (c.rate != 44100 && c.rate != 48000) ||
		c.frames < 1 || c.frames > maxSeconds*c.rate || offset == nil || *offset < 0 ||
		!validProvenance(rightsRef) || !validProvenance(attribution) || c.expiresAt.IsZero() ||
		len(digest) != hex.EncodedLen(len(c.digest)) {
		return "", clip{}, errManifest
	}
	if _, err := hex.Decode(c.digest[:], []byte(digest)); err != nil {
		return "", clip{}, errManifest
	}
	return key, c, nil
}

func validProvenance(s string) bool {
	return len(s) <= 512 && strings.TrimSpace(s) != "" && strings.IndexFunc(s, unicode.IsControl) < 0
}

func canonicalSource(raw string) bool {
	if len(raw) > maxURLBytes || strings.IndexFunc(raw, func(r rune) bool {
		return unicode.IsSpace(r) || unicode.IsControl(r) || r == '\\' || r == '#'
	}) >= 0 {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || u.String() != raw {
		return false
	}
	result := validators.DefaultRegistry().Validate(raw)
	if !result.Valid {
		return false
	}
	switch u.Host {
	case "www.youtube.com":
		return result.MediaType == "video" && raw == result.Canonical
	case "music.youtube.com":
		return result.MediaType == "video" && raw == strings.Replace(result.Canonical, "www.youtube.com", "music.youtube.com", 1)
	case "soundcloud.com":
		return result.MediaType == "track" && raw == result.Canonical
	case "api.soundcloud.com":
		return result.MediaType == "track" && !u.ForceQuery && u.RawQuery == "" && u.RawPath == "" && apiTrack.MatchString(u.Path)
	default:
		return false
	}
}

// decodeObject requires each declared field exactly once, with no case folding.
// The map is local to this decode and is consumed as fields arrive.
func decodeObject(dec *json.Decoder, fields map[string]any) bool {
	if token, err := dec.Token(); err != nil || token != json.Delim('{') {
		return false
	}
	for dec.More() {
		token, err := dec.Token()
		name, ok := token.(string)
		if err != nil || !ok || fields[name] == nil || dec.Decode(fields[name]) != nil {
			return false
		}
		delete(fields, name)
	}
	token, err := dec.Token()
	return err == nil && token == json.Delim('}') && len(fields) == 0
}

func atEOF(dec *json.Decoder) bool {
	_, err := dec.Token()
	return err == io.EOF
}

// readLocal takes only fixed or manifest-admitted basenames. Root confines
// resolution even if a leaf changes between checks. O_NONBLOCK prevents a
// swapped FIFO from blocking open; fstat checks the file actually opened.
// Operators must supply a trusted local filesystem, not special mounts.
func readLocal(ctx context.Context, dir, name string, max, exact int) ([]byte, error) {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	before, err := root.Lstat(name)
	if err != nil || !before.Mode().IsRegular() || ctx.Err() != nil {
		return nil, errFile
	}
	f, err := root.OpenFile(name, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || !os.SameFile(before, info) ||
		info.Size() < 1 || info.Size() > int64(max) || (exact > 0 && info.Size() != int64(exact)) {
		return nil, errFile
	}
	// Check EOF without reading an unbounded file, even if the mount changes.
	data := make([]byte, int(info.Size())+1)
	for off := 0; off < len(data); {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		n, err := f.Read(data[off:min(off+32*1024, len(data))])
		off += n
		if err == io.EOF && off == len(data)-1 {
			return data[:off], nil
		}
		if err != nil || n == 0 {
			return nil, errFile
		}
	}
	return nil, errFile
}
