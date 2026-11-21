package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/api"
	"github.com/openmusicplayer/backend/internal/config"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/processor"
	"github.com/openmusicplayer/backend/internal/storage"
)

const privateLibraryFixtureMode = "fixture"
const privateLibraryFixtureReadback = "fixture-readback"

var privateLibraryFixtureName = regexp.MustCompile(`^pif_[0-9a-f]{24}$`)
var privateLibraryMarker = regexp.MustCompile(`^[0-9a-f]{64}$`)

// Only the controlled test launcher can pass this capability. Production
// main has no constructor, file parser or environment path to grant it.
type privateLibraryFixtureBinding struct {
	endpoint, bucket string
}

func validatePrivateLibraryFixture(cfg *config.Config, mode, marker string, binding *privateLibraryFixtureBinding) error {
	if mode == "" {
		return nil
	}
	if binding == nil || cfg.MinioEndpoint != binding.endpoint || cfg.MinioBucket != binding.bucket {
		return errors.New("private Library import requires the controlled provisioner's exact S3 fixture binding")
	}
	if (mode != privateLibraryFixtureMode && mode != privateLibraryFixtureReadback) || !privateLibraryMarker.MatchString(marker) ||
		!privateLibraryFixtureName.MatchString(cfg.DBName) || cfg.DBName != cfg.DBUser || cfg.DBHost != "127.0.0.1" ||
		!privateLibraryMarker.MatchString(cfg.DBPassword) ||
		!fixtureLoopbackAddress(net.JoinHostPort(cfg.DBHost, cfg.DBPort)) || !fixtureLoopbackAddress(cfg.ServerAddr) ||
		!fixtureLoopbackAddress(cfg.MinioEndpoint) || cfg.MinioPublicEndpoint != "" || cfg.MinioUseSSL || os.Getenv(db.AllowProtectedDBTestsEnv) != "" {
		return errors.New("private Library import requires an attested loopback-only disposable fixture")
	}
	bucketID, ok := strings.CutPrefix(cfg.MinioBucket, "soundq-fixture-")
	id, err := uuid.Parse(bucketID)
	if !ok || err != nil || id == uuid.Nil || id.String() != bucketID {
		return errors.New("private Library import requires an exclusive fixture bucket")
	}
	dsn := (&url.URL{Scheme: "postgres", User: url.UserPassword(cfg.DBUser, cfg.DBPassword), Host: net.JoinHostPort(cfg.DBHost, cfg.DBPort), Path: "/" + cfg.DBName}).String()
	return db.CheckDSNNotProtected(dsn)
}

type fixtureAnalyzerTransport struct {
	*http.Transport
	scheme, address string
}

func (t fixtureAnalyzerTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.URL.Scheme != t.scheme || r.URL.Host != t.address || r.URL.User != nil || (r.Host != "" && r.Host != t.address) {
		return nil, errors.New("fixture analyzer request escaped its pinned origin")
	}
	response, err := t.Transport.RoundTrip(r)
	if err == nil && response.StatusCode >= 300 && response.StatusCode < 400 {
		// Refuse before the HTTP client parses or reflects Location.
		_ = response.Body.Close()
		return nil, errors.New("fixture analyzer redirects are not allowed")
	}
	return response, err
}

func privateLibraryAnalyzerHTTPClient(cfg *config.Config, mode string) (*http.Client, error) {
	if mode == "" || !cfg.AnalyzerEnabled {
		return nil, nil // The ordinary analyzer keeps its existing client.
	}
	parsed, err := url.Parse(cfg.AnalyzerBaseURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.User != nil || !fixtureLoopbackAddress(parsed.Host) || parsed.RawQuery != "" || parsed.ForceQuery || parsed.Fragment != "" {
		return nil, errors.New("private Library import requires a pinned loopback analyzer origin")
	}
	address := parsed.Host
	dialer := &net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}
	transport := &http.Transport{
		// No environment proxy, even if the caller set one.
		DialContext: func(ctx context.Context, network, candidate string) (net.Conn, error) {
			if candidate != address {
				return nil, errors.New("fixture analyzer dial escaped its pinned socket")
			}
			return dialer.DialContext(ctx, network, address)
		},
		TLSHandshakeTimeout: 5 * time.Second,
		IdleConnTimeout:     30 * time.Second,
	}
	return &http.Client{
		Transport:     fixtureAnalyzerTransport{transport, parsed.Scheme, address},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}, nil
}

func fixtureLoopbackAddress(raw string) bool {
	host, port, e := net.SplitHostPort(raw)
	n, err := strconv.ParseUint(port, 10, 16)
	return e == nil && err == nil && host == "127.0.0.1" && n > 0 && strconv.FormatUint(n, 10) == port
}

func attestPrivateLibraryFixture(dbx *db.DB, cfg *config.Config, marker string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	// A fresh generated database has no protection table before migration.
	// The exact comment marker must positively match even in that case.
	if err := dbx.CheckDatabaseNotProtected(ctx); err != nil {
		return err
	}
	var accepted bool
	err := dbx.QueryRowContext(ctx, `SELECT current_database()=$1 AND current_user=$1 AND shobj_description(oid,'pg_database')=$2 FROM pg_database WHERE datname=current_database()`, cfg.DBName, "private-fence-fixture:"+marker).Scan(&accepted)
	if err != nil || !accepted {
		return errors.New("private Library fixture database attestation failed")
	}
	return nil
}

func newPrivateLibraryUploads(mode string, database *db.DB, tracks *db.TrackRepository, objects *storage.Client) (*api.LibraryUploadHandlers, func(), error) {
	if mode == "" {
		return nil, func() {}, nil
	}
	ffmpeg := "/unused/ffmpeg" // Readback of previously measured bytes never probes.
	if mode == privateLibraryFixtureMode {
		var err error
		ffmpeg, err = exec.LookPath("ffmpeg")
		if err != nil || !filepath.IsAbs(ffmpeg) {
			return nil, func() {}, errors.New("private Library fixture MP3 probe unavailable")
		}
	}
	scratch, err := os.MkdirTemp("", "soundq-private-library-")
	if err != nil {
		return nil, func() {}, fmt.Errorf("private Library fixture scratch unavailable: %w", err)
	}
	cleanup := func() { _ = os.Remove(scratch) }
	intake, err := processor.NewPrivateImportIntake(tracks, objects, scratch, ffmpeg)
	if err != nil {
		cleanup()
		return nil, func() {}, err
	}
	return api.NewLibraryUploadHandlers(database, tracks, intake, mode == privateLibraryFixtureMode), cleanup, nil
}
