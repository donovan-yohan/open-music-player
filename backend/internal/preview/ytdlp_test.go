package preview

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"testing/synctest"
	"time"

	"github.com/openmusicplayer/backend/internal/validators"
)

func TestYTDLPRejectsNoncanonicalSourcesBeforeStarting(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "spawned")
	tool := previewShim(t, `printf started > '`+marker+`'; exit 9`)
	adapter := ytdlpPreview{executable: tool, ffmpeg: tool, timeout: acquisitionTimeout}
	for _, key := range []string{
		"", "--config-location", "file:///my/file", "http://www.youtube.com/watch?v=abcdefghijk",
		"https://www.youtube.com/watch?v=abcdefghijk&list=PL123", "https://www.youtube.com/watch?v=abcdefghijk&v=mnopqrstuvw",
		"https://www.youtube.com/playlist?list=PL123", "https://youtu.be/abcdefghijk", "https://www.youtube.com:443/watch?v=abcdefghijk",
		"https://www.youtube.com.evil.example/watch?v=abcdefghijk", "https://www.youtube.com@evil.example/watch?v=abcdefghijk",
		"https://music.youtube.com/watch?v=abcdefghijk#anything", "https://www.youtube.com/watch?v=abcdefghijk\n",
		"https://soundcloud.com/artist/sets/album", "https://soundcloud.com/artist/song?si=extra",
		"https://soundcloud.com/artist/song/password", "https://api.soundcloud.com/tracks/01",
		"https://api.soundcloud.com/tracks/123?secret_token=hidden", "https://localhost:12345/audio.mp3",
	} {
		if data, err := adapter.fetch(context.Background(), key); data != nil || !errors.Is(err, errPreviewSource) {
			t.Errorf("%q: got %d bytes, %v", key, len(data), err)
		}
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("rejected source launched the downloader: %v", err)
	}
	// The same executable is reachable by a legitimate key.
	if _, err := adapter.fetch(context.Background(), "https://www.youtube.com/watch?v=abcdefghijk"); !errors.Is(err, errPreviewAcquisition) {
		t.Fatalf("canonical source did not reach downloader: %v", err)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("canonical source did not launch the downloader")
	}
}

func previewShim(t *testing.T, script string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fixture-ytdlp")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+script+"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestYTDLPRemovesFailedWork(t *testing.T) {
	for name, script := range map[string]string{
		"provider failed":    `printf 'work' > clip.mp3; printf 'https://secret.invalid/diagnostics' >&2; exit 1`,
		"different identity": `printf 'work' > clip.mp3; printf '{"extractor_key":"Youtube","id":"mnopqrstuvw"}'`,
		"oversize result":    `dd if=/dev/zero of=clip.mp3 bs=1048576 count=3 2>/dev/null; printf '{"extractor_key":"Youtube","id":"abcdefghijk"}'`,
		"oversize receipt":   `dd if=/dev/zero bs=4096 count=4 2>/dev/null; exec sleep 20`,
		"nonregular output":  `mkfifo clip.mp3; printf '{"extractor_key":"Youtube","id":"abcdefghijk"}'`,
	} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			t.Setenv("TMPDIR", root)
			tool := previewShim(t, script)
			start := time.Now()
			data, err := (ytdlpPreview{executable: tool, ffmpeg: tool, timeout: 5 * time.Second}).fetch(context.Background(), "https://www.youtube.com/watch?v=abcdefghijk")
			if data != nil || !errors.Is(err, errPreviewAcquisition) || time.Since(start) > 3*time.Second {
				t.Fatalf("failed work was not promptly refused: %d bytes, %v, %s", len(data), err, time.Since(start))
			}
			assertNoPreviewWork(t, root)
		})
	}
}

func TestYTDLPRequiresAbsoluteInstalledToolsAndPassesLocalRuntimes(t *testing.T) {
	path := t.TempDir()
	t.Setenv("PATH", path)
	if _, err := newYTDLPFetcher(); !errors.Is(err, exec.ErrNotFound) || !strings.Contains(err.Error(), "yt-dlp") {
		t.Fatalf("missing extractor reason: %v", err)
	}
	argsFile := filepath.Join(t.TempDir(), "args")
	for _, name := range []string{"yt-dlp", "ffmpeg", "deno", "node"} {
		script := "#!/bin/sh\nexit 1\n"
		if name == "yt-dlp" {
			script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '" + argsFile + "'\nexit 1\n"
		}
		if err := os.WriteFile(filepath.Join(path, name), []byte(script), 0700); err != nil {
			t.Fatal(err)
		}
		if name == "yt-dlp" {
			if _, err := newYTDLPFetcher(); !errors.Is(err, exec.ErrNotFound) || !strings.Contains(err.Error(), "ffmpeg") {
				t.Fatalf("missing FFmpeg reason: %v", err)
			}
		}
	}
	fetch, err := newYTDLPFetcher()
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		key      string
		runtimes []string
	}{
		{"https://www.youtube.com/watch?v=abcdefghijk", []string{"deno:" + filepath.Join(path, "deno"), "node:" + filepath.Join(path, "node")}},
		{"https://soundcloud.com/artist/track", nil},
	} {
		_, err := fetch(context.Background(), tc.key)
		if !errors.Is(err, errPreviewAcquisition) {
			t.Fatal(err)
		}
		data, err := os.ReadFile(argsFile)
		if err != nil {
			t.Fatal(err)
		}
		args := strings.Split(strings.TrimSpace(string(data)), "\n")
		var runtimes []string
		for i, arg := range args[:len(args)-1] {
			if arg == "--js-runtimes" {
				runtimes = append(runtimes, args[i+1])
			}
		}
		if !slices.Equal(runtimes, tc.runtimes) || !slices.Contains(args, "--no-remote-components") {
			t.Fatalf("wrong runtime admission for %s: %v", tc.key, runtimes)
		}
	}
}

func TestYTDLPStopsLeafWhenExtractorExitsFirst(t *testing.T) {
	for _, code := range []string{"0", "9"} {
		t.Run(code, func(t *testing.T) {
			root := t.TempDir()
			t.Setenv("TMPDIR", root)
			pidFile := filepath.Join(t.TempDir(), "leaf-pid")
			tool := previewShim(t, `sleep 20 </dev/null >/dev/null 2>&1 & child=$!; kill -0 "$child" || exit 98; printf '%s\n' "$child" > '`+pidFile+`'
printf 'owned bytes' > clip.mp3
printf '{"extractor_key":"Youtube","id":"abcdefghijk"}'
exit `+code)
			data, err := (ytdlpPreview{executable: tool, ffmpeg: tool, timeout: acquisitionTimeout}).fetch(context.Background(), "https://www.youtube.com/watch?v=abcdefghijk")
			raw, readErr := os.ReadFile(pidFile)
			pid, parseErr := strconv.Atoi(strings.TrimSpace(string(raw)))
			if readErr != nil || parseErr != nil || pid <= 0 {
				t.Fatalf("missing launched leaf: %v / %v", readErr, parseErr)
			}
			t.Cleanup(func() {
				if !previewLeafStopped(pid, false) {
					_ = syscall.Kill(pid, syscall.SIGKILL)
				}
			})
			assertPreviewLeafStopped(t, pid)
			assertNoPreviewWork(t, root)
			if code == "0" && (err != nil || string(data) != "owned bytes") {
				t.Fatalf("successful extractor lost its result: %d bytes, %v", len(data), err)
			}
			if code != "0" && (data != nil || !errors.Is(err, errPreviewAcquisition)) {
				t.Fatalf("failed extractor published a result: %d bytes, %v", len(data), err)
			}
		})
	}
}

func TestYTDLPStopsLeafOnCancellationAndDeadline(t *testing.T) {
	for _, mode := range []string{"cancel", "deadline"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			t.Setenv("TMPDIR", root)
			pidFile := filepath.Join(t.TempDir(), "leaf-pid")
			tool := previewShim(t, `printf 'partial' > clip.mp3; sleep 20 & child=$!; printf '%s\n' "$child" > '`+pidFile+`'; wait "$child"`)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			limit, want := 5*time.Second, context.Canceled
			if mode == "deadline" {
				limit, want = time.Second, context.DeadlineExceeded
			}
			done := make(chan error, 1)
			go func() {
				data, err := (ytdlpPreview{executable: tool, ffmpeg: tool, timeout: limit}).fetch(ctx, "https://www.youtube.com/watch?v=abcdefghijk")
				if data != nil {
					done <- errors.New("partial clip escaped")
					return
				}
				done <- err
			}()
			var pid int
			for deadline := time.Now().Add(time.Second); time.Now().Before(deadline); time.Sleep(5 * time.Millisecond) {
				if raw, err := os.ReadFile(pidFile); err == nil {
					pid, _ = strconv.Atoi(strings.TrimSpace(string(raw)))
					if pid > 0 && syscall.Kill(pid, 0) == nil {
						break
					}
				}
			}
			if pid <= 0 || syscall.Kill(pid, 0) != nil {
				t.Fatal("fixture leaf did not reach the running boundary")
			}
			if mode == "cancel" {
				cancel()
			}
			select {
			case err := <-done:
				if !errors.Is(err, want) {
					t.Fatalf("got %v, want %v", err, want)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("canceled acquisition did not settle")
			}
			assertPreviewLeafStopped(t, pid)
			assertNoPreviewWork(t, root)
		})
	}
}

func assertPreviewLeafStopped(t *testing.T, pid int) {
	t.Helper()
	requireReap := os.Getenv("SOUNDQ_TEST_PREVIEW_REQUIRE_REAP") == "1"
	for deadline := time.Now().Add(time.Second); time.Now().Before(deadline); time.Sleep(5 * time.Millisecond) {
		if previewLeafStopped(pid, requireReap) {
			return
		}
	}
	t.Fatalf("acquisition left a leaf behind (require reaping: %v)", requireReap)
}

func previewLeafStopped(pid int, requireReap bool) bool {
	if errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) {
		return true
	}
	if runtime.GOOS != "linux" || requireReap {
		return false
	}
	// An arbitrary test host may not reap orphans promptly. A stopped zombie
	// cannot execute; the packaged Tini assay separately requires ESRCH.
	data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	i := strings.LastIndex(string(data), ") ")
	return err == nil && i >= 0 && len(data) > i+2 && data[i+2] == 'Z'
}

func assertNoPreviewWork(t *testing.T, root string) {
	t.Helper()
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 0 {
		t.Fatalf("left temporary work: %v, %v", entries, err)
	}
}

func TestYTDLPEgressByteCeiling(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	originDone := make(chan struct{})
	const limit = 32 * 1024
	proxy := &previewEgress{ctx: ctx, cancel: cancel, source: validators.SourceYouTube, available: limit,
		dial: func(_ context.Context, host string) (net.Conn, error) {
			if host != "fixture.googlevideo.com" {
				return nil, errors.New("wrong origin reached the dial seam")
			}
			proxyConn, originConn := net.Pipe()
			go func() {
				defer close(originDone)
				defer originConn.Close()
				_, _ = originConn.Write(bytes.Repeat([]byte{'x'}, 2*limit))
			}()
			return proxyConn, nil
		},
	}
	listener := httptest.NewServer(proxy)
	defer listener.Close()
	client, err := (&net.Dialer{}).DialContext(ctx, "tcp", listener.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = client.SetDeadline(deadline)
	}
	if _, err := io.WriteString(client, "CONNECT fixture.googlevideo.com:443 HTTP/1.1\r\nHost: fixture.googlevideo.com:443\r\n\r\n"); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(client)
	response, err := reader.ReadString('\n')
	if err != nil || response != "HTTP/1.1 200 Connection Established\r\n" {
		t.Fatalf("CONNECT not established: %q %v", response, err)
	}
	blank, err := reader.ReadString('\n')
	if err != nil || blank != "\r\n" {
		t.Fatal("invalid CONNECT response framing")
	}
	data, err := io.ReadAll(reader)
	if err != nil || len(data) != limit || !proxy.refused.Load() || ctx.Err() != context.Canceled {
		t.Fatalf("upstream did not stop at the exact ceiling: %d bytes, refusal=%v, context=%v, read=%v", len(data), proxy.refused.Load(), ctx.Err(), err)
	}
	select {
	case <-originDone:
	case <-time.After(time.Second):
		t.Fatal("budget refusal left origin open")
	}
}

type previewReadFunc func([]byte) (int, error)

func (f previewReadFunc) Read(b []byte) (int, error) { return f(b) }

func TestYTDLPEgressWaitsForOutstandingReservations(t *testing.T) {
	for _, mode := range []string{"refund", "spent", "cancel"} {
		t.Run(mode, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				p := &previewEgress{ctx: ctx, cancel: cancel, available: 4}
				settle := make(chan struct{})
				a := previewBudgetReader{p, previewReadFunc(func(b []byte) (int, error) {
					<-settle
					if mode == "spent" {
						return copy(b, "four"), nil
					}
					return copy(b, "a"), io.EOF
				})}
				firstDone := make(chan struct{})
				go func() {
					defer close(firstDone)
					_, _ = a.Read(make([]byte, 4))
				}()
				synctest.Wait() // first tunnel has reserved the entire remaining budget
				b := previewBudgetReader{p, strings.NewReader("abc")}
				type outcome struct {
					n   int
					err error
				}
				second := make(chan outcome, 1)
				go func() { n, err := b.Read(make([]byte, 4)); second <- outcome{n, err} }()
				synctest.Wait()
				if len(second) != 0 || ctx.Err() != nil || p.refused.Load() {
					t.Error("an outstanding reservation was treated as consumed")
				}
				if mode == "cancel" {
					cancel()
					synctest.Wait()
					if len(second) != 1 {
						t.Error("pending reader did not retire on cancellation")
					}
				}
				close(settle)
				<-firstDone
				result := <-second
				switch mode {
				case "refund":
					if result.n != 3 || result.err != nil || p.refused.Load() {
						t.Fatalf("refunded bytes not admitted: %+v", result)
					}
				case "spent":
					if result.n != 0 || !errors.Is(result.err, errPreviewAcquisition) || !p.refused.Load() {
						t.Fatalf("hard ceiling not enforced: %+v", result)
					}
				case "cancel":
					if result.n != 0 || !errors.Is(result.err, context.Canceled) || p.refused.Load() {
						t.Fatalf("cancellation was mistaken for budget exhaustion: %+v", result)
					}
				}
			})
		})
	}
}

func TestYTDLPProviderOriginRules(t *testing.T) {
	for _, host := range []string{"www.youtube.com", "music.youtube.com", "rr5.googlevideo.com", "youtubei.googleapis.com"} {
		if !previewOrigin(validators.SourceYouTube, host) {
			t.Errorf("expected YouTube origin %s", host)
		}
	}
	for _, host := range []string{"soundcloud.com", "api-v2.soundcloud.com", "playback.media-streaming.soundcloud.cloud", "a-v2.sndcdn.com"} {
		if !previewOrigin(validators.SourceSoundCloud, host) || previewOrigin(validators.SourceYouTube, host) {
			t.Errorf("expected SoundCloud-only origin %s", host)
		}
	}
	for _, host := range []string{"evilgooglevideo.com", "googlevideo.com.evil.invalid", "evil.invalid@x.googlevideo.com", "127.0.0.1", "[::1]"} {
		if previewOrigin(validators.SourceYouTube, host) || previewOrigin(validators.SourceSoundCloud, host) {
			t.Errorf("unexpected allowed origin %s", host)
		}
	}
	for _, address := range []string{"10.0.0.1", "127.0.0.1", "169.254.169.254", "100.64.0.1", "198.18.0.1", "::1", "fe80::1", "64:ff9b::a00:1", "::ffff:127.0.0.1"} {
		if routablePreviewIP(netip.MustParseAddr(address).Unmap()) {
			t.Errorf("unexpected allowed address %s", address)
		}
	}
	for _, address := range []string{"8.8.8.8", "2607:f8b0:4005:80a::200e"} {
		if !routablePreviewIP(netip.MustParseAddr(address)) {
			t.Errorf("expected public address %s", address)
		}
	}
}

func TestYTDLPRealToolsBoundedFirstSection(t *testing.T) {
	tool := os.Getenv("SOUNDQ_TEST_YTDLP")
	if tool == "" {
		t.Skip("set SOUNDQ_TEST_YTDLP to the absolute path of an installed yt-dlp console script")
	}
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Fatal(err)
	}
	installed, err := os.ReadFile(tool)
	first, _, _ := strings.Cut(string(installed), "\n")
	python, ok := strings.CutPrefix(first, "#!")
	if err != nil || !filepath.IsAbs(tool) || !ok || !filepath.IsAbs(python) || strings.ContainsAny(python, "\r\n	 ") {
		t.Fatal("expected an absolute yt-dlp console script with an absolute Python shebang")
	}
	hls := t.TempDir()
	fixture := exec.Command(ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=523:sample_rate=48000",
		"-t", "60", "-c:a", "aac", "-b:a", "96k", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4", "audio.m3u8")
	fixture.Dir = hls
	if output, err := fixture.CombinedOutput(); err != nil {
		t.Fatalf("generate audio: %v: %s", err, output)
	}
	files, err := os.ReadDir(hls)
	if err != nil {
		t.Fatal(err)
	}
	var fullBytes int64
	for _, entry := range files {
		info, err := entry.Info()
		if err != nil {
			t.Fatal(err)
		}
		fullBytes += info.Size()
	}
	playlist, err := os.ReadFile(filepath.Join(hls, "audio.m3u8"))
	if err != nil || !bytes.Contains(playlist, []byte("audio0.m4s")) {
		t.Fatalf("expected a generated segmented playlist: %v", err)
	}
	if err := os.WriteFile(filepath.Join(hls, "foreign.m3u8"), bytes.Replace(playlist, []byte("audio0.m4s"), []byte("https://blocked.invalid/audio0.m4s"), 1), 0600); err != nil {
		t.Fatal(err)
	}
	shortFixture := exec.Command(ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=619:sample_rate=48000:duration=0.3",
		"-f", "lavfi", "-i", "color=c=black:size=320x180:r=8:d=0.3", "-ac", "2", "-c:a", "alac", "-c:v", "mpeg4", "-movflags", "+faststart", filepath.Join(hls, "short.mp4"))
	if output, err := shortFixture.CombinedOutput(); err != nil {
		t.Fatalf("generate short stereo control: %v: %s", err, output)
	}
	var mu sync.Mutex
	var transferred int64
	hits := map[string]int{}
	fileServer := http.FileServer(http.Dir(hls))
	local := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Host {
		case "soundcloud.com":
			_, _ = w.Write([]byte(`<script src="https://fixture.sndcdn.com/client.js"></script>`))
			return
		case "fixture.sndcdn.com":
			_, _ = w.Write([]byte(`client_id:"12345678901234567890123456789012"`))
			return
		case "api-v2.soundcloud.com":
			w.Header().Set("Content-Type", "application/json")
			switch r.URL.Path {
			case "/resolve", "/tracks/12345":
				if r.URL.Path == "/resolve" && r.URL.Query().Get("url") != "https://soundcloud.com/artist/track" {
					w.WriteHeader(http.StatusNotFound)
					return
				}
				_, _ = w.Write([]byte(`{"id":12345,"permalink_url":"https://soundcloud.com/artist/track","title":"Synthetic tone","duration":60000,"media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/transcode/hls","preset":"aac_96k","format":{"protocol":"hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""}}]}}`))
				return
			case "/transcode/hls":
				_, _ = w.Write([]byte(`{"url":"https://fixture.media-streaming.soundcloud.cloud/audio.m3u8"}`))
				return
			}
			w.WriteHeader(http.StatusNotFound)
			return
		}
		counter := &previewByteCounter{ResponseWriter: w}
		fileServer.ServeHTTP(counter, r)
		mu.Lock()
		hits[r.URL.Path]++
		transferred += counter.n
		mu.Unlock()
	}))
	certificate, cert := previewFixtureCertificate(t)
	local.TLS = &tls.Config{Certificates: []tls.Certificate{certificate}}
	local.StartTLS()
	defer local.Close()

	// SoundCloud uses the unmodified extractor and fixture HTTPS replies.
	// YouTube uses real dispatch but an injected extraction result. Both
	// keep yt-dlp's flags, format selector, and external FFmpeg downloader.
	fixtureLog := filepath.Join(t.TempDir(), "fixture-stderr")
	tool = previewPythonShim(t, python, "fixture-ytdlp", `
import os
os.environ['SSL_CERT_FILE'] = `+strconv.Quote(cert)+`
with open(`+strconv.Quote(fixtureLog)+`, 'wb') as log:
    os.dup2(log.fileno(), 2)
from yt_dlp import main
from yt_dlp.extractor.youtube import YoutubeIE
def fixture(self, url):
    if url not in ('https://music.youtube.com/watch?v=abcdefghijk', 'https://www.youtube.com/watch?v=abcdefghijk', 'https://www.youtube.com/watch?v=blocked0001', 'https://www.youtube.com/watch?v=short000001'):
        raise AssertionError('the adapter substituted the selected source')
    id = url[-11:]
    if id == 'short000001':
        return dict(id=id, title='Synthetic short muxed stereo tone', duration=.3, is_live=False,
                    formats=[dict(format_id='muxed', url='https://fixture.googlevideo.com/short.mp4',
                                  protocol='https', ext='mp4', acodec='alac', vcodec='mp4v', height=180, abr=96)])
    path = 'foreign.m3u8' if id == 'blocked0001' else 'audio.m3u8'
    return dict(id=id, title='Synthetic tone', duration=60, is_live=False,
                formats=[dict(format_id='hls-low', url='https://fixture.googlevideo.com/' + path,
                              protocol='m3u8_native', ext='m4a', acodec='mp4a.40.2', vcodec='none', abr=96),
                         dict(format_id='hls-high', url='https://fixture.googlevideo.com/wrong-bitrate.m3u8',
                              protocol='m3u8_native', ext='m4a', acodec='mp4a.40.2', vcodec='none', abr=160)])
YoutubeIE._real_extract = fixture
main()
`)
	ffmpegShim := previewPythonShim(t, python, "ffmpeg", `
import os, sys
args = sys.argv[1:]
if '-loglevel' in args:
    args[args.index('-loglevel') + 1] = 'error'
os.execv(`+strconv.Quote(ffmpeg)+`, [`+strconv.Quote(ffmpeg)+`, *args])
`)
	for _, tc := range []struct{ name, key string }{
		{"YouTubeMusic", "https://music.youtube.com/watch?v=abcdefghijk"},
		{"YouTube", "https://www.youtube.com/watch?v=abcdefghijk"},
		{"SoundCloudPermalink", "https://soundcloud.com/artist/track"},
		{"SoundCloudTrackAPI", "https://api.soundcloud.com/tracks/12345"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			mu.Lock()
			hits, transferred = map[string]int{}, 0
			mu.Unlock()
			t.Setenv("TMPDIR", t.TempDir())
			adapter := ytdlpPreview{executable: tool, ffmpeg: ffmpegShim, timeout: 5 * time.Second,
				dial: func(ctx context.Context, _ string) (net.Conn, error) {
					return (&net.Dialer{}).DialContext(ctx, "tcp", local.Listener.Addr().String())
				},
			}
			start := time.Now()
			data, err := adapter.fetch(context.Background(), tc.key)
			wall := time.Since(start)
			if err != nil {
				fixtureDiagnostics, _ := os.ReadFile(fixtureLog)
				t.Fatalf("real CLI did not produce a synthetic clip: %v: %s", err, fixtureDiagnostics)
			}
			frames := mp3Frames(data, 48000)
			if frames != 15*48000 || len(data) > 200*1024 || !validMP3(data, 48000, frames) {
				t.Fatalf("unexpected MP3 envelope: frames=%d bytes=%d", frames, len(data))
			}
			encoded := filepath.Join(t.TempDir(), "measured.mp3")
			if err := os.WriteFile(encoded, data, 0600); err != nil {
				t.Fatal(err)
			}
			decode := exec.Command(ffmpeg, "-hide_banner", "-loglevel", "error", "-i", encoded, "-f", "s16le", "pipe:1")
			pcm, err := decode.Output()
			if err != nil || len(pcm) != 2*frames || bytes.Count(pcm, []byte{0}) == len(pcm) {
				t.Fatalf("clip did not decode to the actual nonzero mono samples: %d bytes, %v", len(pcm), err)
			}
			mu.Lock()
			defer mu.Unlock()
			if hits["/audio.m3u8"] == 0 || hits["/init.mp4"] == 0 || hits["/audio0.m4s"] == 0 || hits["/audio15.m4s"] != 0 || transferred >= fullBytes/2 {
				t.Fatalf("unexpected upstream transfer: bytes=%d/%d, hits=%v", transferred, fullBytes, hits)
			}
			assertNoPreviewWork(t, os.Getenv("TMPDIR"))
			t.Logf("actual CLI+FFmpeg wall=%s, upstream=%d/%d B, MP3=%d B, decoded=%d frames, requests=%v", wall, transferred, fullBytes, len(data), frames, hits)
		})
	}
	t.Run("ShortMuxedStereoFallbackWithoutPadding", func(t *testing.T) {
		root := t.TempDir()
		t.Setenv("TMPDIR", root)
		adapter := ytdlpPreview{executable: tool, ffmpeg: ffmpegShim, timeout: 5 * time.Second,
			dial: func(ctx context.Context, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "tcp", local.Listener.Addr().String())
			},
		}
		data, err := adapter.fetch(context.Background(), "https://www.youtube.com/watch?v=short000001")
		_, channels := mp3Packet(data, 48000)
		if err != nil || channels != 2 || mp3Frames(data, 48000) != 14400 || !validMP3(data, 48000, 14400) {
			fixtureDiagnostics, _ := os.ReadFile(fixtureLog)
			t.Fatalf("short stereo media did not preserve its exact 14400 frames: %d bytes, %d channels, %v: %s", len(data), channels, err, fixtureDiagnostics)
		}
		mu.Lock()
		defer mu.Unlock()
		if hits["/short.mp4"] == 0 {
			t.Fatal("short muxed fallback did not reach FFmpeg")
		}
		assertNoPreviewWork(t, root)
	})
	t.Run("RejectForeignHLSSegment", func(t *testing.T) {
		root := t.TempDir()
		t.Setenv("TMPDIR", root)
		adapter := ytdlpPreview{executable: tool, ffmpeg: ffmpegShim, timeout: 5 * time.Second,
			dial: func(ctx context.Context, host string) (net.Conn, error) {
				mu.Lock()
				hits["dial:"+host]++
				mu.Unlock()
				return (&net.Dialer{}).DialContext(ctx, "tcp", local.Listener.Addr().String())
			},
		}
		data, err := adapter.fetch(context.Background(), "https://www.youtube.com/watch?v=blocked0001")
		if data != nil || !errors.Is(err, errPreviewAcquisition) {
			t.Fatalf("foreign HLS segment accepted: %d bytes, %v", len(data), err)
		}
		assertNoPreviewWork(t, root)
		mu.Lock()
		defer mu.Unlock()
		if hits["/foreign.m3u8"] != 1 || hits["dial:blocked.invalid"] != 0 {
			t.Fatalf("did not block at the nested provider boundary: %v", hits)
		}
	})
}

func previewFixtureCertificate(t *testing.T) (tls.Certificate, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cert := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		DNSNames: []string{"soundcloud.com", "fixture.sndcdn.com", "api-v2.soundcloud.com", "fixture.googlevideo.com", "fixture.media-streaming.soundcloud.cloud"},
		KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IsCA: true, BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, path
}

func previewPythonShim(t *testing.T, python, name, body string) string {
	t.Helper()
	filename := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(filename, []byte("#!"+python+"\n"+body), 0700); err != nil {
		t.Fatal(err)
	}
	return filename
}

type previewByteCounter struct {
	http.ResponseWriter
	n int64
}

func (w *previewByteCounter) Write(p []byte) (int, error) {
	n, err := w.ResponseWriter.Write(p)
	w.n += int64(n)
	return n, err
}
