package preview

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/openmusicplayer/backend/internal/validators"
)

var (
	errPreviewSource      = errors.New("invalid preview source")
	errPreviewAcquisition = errors.New("preview acquisition failed")
)

const (
	previewSectionSeconds = 15
	previewFilename       = "clip.mp3"
	previewReceiptLimit   = 2*maxURLBytes + 512
	previewNetworkBytes   = 12 * 1024 * 1024 // Includes extractor metadata and encrypted TLS overhead.
)

type ytdlpPreview struct {
	executable, ffmpeg string
	jsRuntime          string
	timeout            time.Duration
	dial               func(context.Context, string) (net.Conn, error) // nil uses public DNS/IP only
}

func newYTDLPFetcher() (func(context.Context, string) ([]byte, error), error) {
	ytdlp, err := exec.LookPath("yt-dlp")
	if err != nil || !filepath.IsAbs(ytdlp) {
		return nil, errors.New("preview requires yt-dlp on an absolute PATH")
	}
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil || !filepath.IsAbs(ffmpeg) {
		return nil, errors.New("preview requires ffmpeg on an absolute PATH")
	}
	p := ytdlpPreview{executable: ytdlp, ffmpeg: ffmpeg, timeout: acquisitionTimeout}
	// Use only a locally installed signature runtime, never download one or
	// remote components as part of a request. SoundCloud does not need it.
	for _, name := range []string{"deno", "node"} {
		if path, err := exec.LookPath(name); err == nil && filepath.IsAbs(path) {
			p.jsRuntime = name + ":" + path
			break
		}
	}
	return p.fetch, nil
}

func (p ytdlpPreview) fetch(ctx context.Context, key string) ([]byte, error) {
	u := parseSource(key)
	source := canonicalSource(u)
	if source != validators.SourceYouTube && source != validators.SourceSoundCloud {
		return nil, errPreviewSource
	}
	ctx, cancel := context.WithTimeout(ctx, p.timeout)
	defer cancel()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	dir, err := os.MkdirTemp("", "soundq-preview-*")
	if err != nil {
		return nil, errPreviewAcquisition
	}
	defer os.RemoveAll(dir)

	selection := previewSelection(u, source)
	dial := p.dial
	if dial == nil {
		dial = dialPreviewOrigin
	}
	egress := previewEgress{ctx: ctx, cancel: cancel, source: source, dial: dial}
	egress.remaining.Store(previewNetworkBytes)
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, errPreviewAcquisition
	}
	proxy := &http.Server{Handler: &egress, ReadHeaderTimeout: time.Second, MaxHeaderBytes: 4096}
	go func() { _ = proxy.Serve(listener) }()
	defer func() {
		egress.mu.Lock()
		egress.closing = true // Seal Add before draining the hijacked tunnels.
		egress.mu.Unlock()
		cancel()
		_ = listener.Close()
		_ = proxy.Close()
		egress.active.Wait()
	}()
	cmd := exec.CommandContext(ctx, p.executable, p.args(selection, source, key, "http://"+listener.Addr().String())...)
	cmd.Dir = dir
	cmd.Env = []string{
		"HOME=" + dir, "XDG_CONFIG_HOME=" + dir, "XDG_CACHE_HOME=" + dir, "TMPDIR=" + dir,
		"PATH=" + strings.Join([]string{filepath.Dir(p.executable), filepath.Dir(p.ffmpeg), "/usr/bin", "/bin"}, string(os.PathListSeparator)),
		"PYTHONNOUSERSITE=1", "PYTHONUTF8=1", "LC_ALL=C",
	}
	// yt-dlp starts FFmpeg for the range. Cancel the group, not just the
	// extractor, before cleaning the private output directory. WaitDelay
	// also bounds an inherited stdout pipe if a helper outlives its parent.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 250 * time.Millisecond
	receipt := previewReceipt{cancel: cancel}
	cmd.Stdout = &receipt // stderr goes to the null device; never surface diagnostics.
	runErr := cmd.Run()
	if receipt.overflow || egress.refused.Load() {
		return nil, errPreviewAcquisition
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if runErr != nil || !selection.matches(receipt.data.Bytes()) {
		return nil, errPreviewAcquisition
	}
	data, err := readLocal(ctx, dir, previewFilename, maxClipBytes, 0)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err != nil {
		return nil, errPreviewAcquisition
	}
	return data, nil
}

type ytdlpSelection struct {
	name, key, field, value, mediaHosts string
}

func previewSelection(u *url.URL, source validators.SourceType) ytdlpSelection {
	if source == validators.SourceYouTube {
		return ytdlpSelection{"youtube", "Youtube", "id", u.Query().Get("v"), `googlevideo\.com`}
	}
	s := ytdlpSelection{"soundcloud", "Soundcloud", "webpage_url", u.String(), `(?:sndcdn\.com|media-streaming\.soundcloud\.cloud)`}
	if u.Host == "api.soundcloud.com" {
		s.field, s.value = "id", strings.TrimPrefix(u.Path, "/tracks/")
	}
	return s
}

func (s ytdlpSelection) matches(data []byte) bool {
	var got struct {
		Extractor string `json:"extractor_key"`
		ID        string `json:"id"`
		Permalink string `json:"webpage_url"`
	}
	if json.Unmarshal(data, &got) != nil || got.Extractor != s.key || got.ID == "" {
		return false
	}
	if s.field == "id" {
		return got.ID == s.value
	}
	return got.Permalink == s.value
}

func (p ytdlpPreview) args(s ytdlpSelection, source validators.SourceType, key, proxy string) []string {
	// A single provider-owned HTTPS audio rendition. yt-dlp also labels
	// SoundCloud progressive HTTPS formats as protocol "http".
	filter := `[protocol~='^(https?|m3u8(_native)?)$'][format_id!*='preview']` +
		`[url~='^https://(?:[a-z0-9-]+\.)*` + s.mediaHosts + `/']`
	selector := "bestaudio" + filter
	if source == validators.SourceYouTube {
		// Some anonymous YouTube clients expose only a low-resolution muxed
		// rendition. Keep the same exact video and byte/time/range budget;
		// FFmpeg maps its audio only. No retry or alternate track is admitted.
		selector += "/best[height<=360]" + filter
	}
	section := fmt.Sprintf("*0-%d", previewSectionSeconds)
	// Let yt-dlp's section downloader start FFmpeg once, and override its
	// normal remux in that same FFmpeg process. A seekable output is needed to
	// write the final Xing/Info byte and packet counts and encoder trim.
	ffmpegOut := fmt.Sprintf("ffmpeg_o:-xerror -t %d -map 0:a:0 -vn -sn -dn -map_metadata -1 -map_chapters -1 -c:a libmp3lame -b:a 96k -ar %d -write_xing 1 -id3v2_version 0 -write_id3v1 0 -fs %d -f mp3",
		previewSectionSeconds, onDemandRate, maxClipBytes-64*1024) // FFmpeg -fs can overshoot by a packet.
	args := []string{
		"--ignore-config", "--no-plugin-dirs", "--no-remote-components", "--no-js-runtimes",
		"--no-cache-dir", "--no-cookies", "--no-cookies-from-browser", "--proxy", proxy,
		"--default-search", "error", "--use-extractors", s.name, "--no-playlist", "--playlist-items", "1",
		"--socket-timeout", "4", "--retries", "0", "--fragment-retries", "0", "--extractor-retries", "0",
		"--no-progress", "--no-simulate", "--no-part", "--no-mtime", "--fixup", "never",
		"--match-filter", fmt.Sprintf("!is_live & !is_upcoming & %s = '%s'", s.field, s.value),
		"--format", selector, "--format-sort-force", "--format-sort", "+abr",
		"--download-sections", section, "--downloader", "ffmpeg", "--ffmpeg-location", p.ffmpeg,
		"--downloader-args", "ffmpeg_i:-nostdin -protocol_whitelist https,tls,tcp,crypto,httpproxy -tls_verify 1 -rw_timeout 4000000 -probesize 131072 -analyzeduration 1000000",
		"--downloader-args", ffmpegOut,
		"--print", "after_move:%(.{extractor_key,id,webpage_url})j", "--output", previewFilename,
	}
	if source == validators.SourceYouTube && p.jsRuntime != "" {
		args = append(args, "--js-runtimes", p.jsRuntime)
	}
	return append(args, "--", key)
}

type previewReceipt struct {
	data     bytes.Buffer // Do not promote ReadFrom: os/exec copies to Write.
	cancel   context.CancelFunc
	overflow bool
}

func (b *previewReceipt) Write(p []byte) (int, error) {
	if len(p) > previewReceiptLimit-b.data.Len() {
		b.overflow = true
		b.cancel()
		return 0, errPreviewAcquisition
	}
	return b.data.Write(p)
}

// yt-dlp forwards the explicit proxy to its FFmpeg child via http_proxy.
// HTTPS stays end-to-end: this only admits provider-owned CONNECT targets and
// limits aggregate reads across extractor, redirects, playlists and segments.
// Format URL matching alone cannot constrain redirects or HLS nested fetches.
type previewEgress struct {
	ctx       context.Context
	cancel    context.CancelFunc
	source    validators.SourceType
	dial      func(context.Context, string) (net.Conn, error)
	remaining atomic.Int64
	refused   atomic.Bool
	mu        sync.Mutex
	active    sync.WaitGroup
	count     int  // under mu
	closing   bool // under mu
}

func (p *previewEgress) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	host, port, err := net.SplitHostPort(r.Host)
	if err != nil || r.Method != http.MethodConnect || port != "443" || !previewOrigin(p.source, host) {
		w.WriteHeader(http.StatusForbidden)
		p.refused.Store(true)
		p.cancel()
		return
	}
	p.mu.Lock()
	if p.closing || p.ctx.Err() != nil || p.count >= 12 {
		p.mu.Unlock()
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	p.active.Add(1)
	p.count++
	p.mu.Unlock()
	defer func() {
		p.mu.Lock()
		p.count--
		p.mu.Unlock()
		p.active.Done()
	}()
	upstream, err := p.dial(p.ctx, host)
	if err != nil {
		w.WriteHeader(http.StatusBadGateway)
		return
	}
	defer upstream.Close()
	client, rw, err := http.NewResponseController(w).Hijack()
	if err != nil {
		return
	}
	defer client.Close()
	stop := context.AfterFunc(p.ctx, func() { _ = upstream.Close(); _ = client.Close() })
	defer stop()
	if _, err := rw.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil || rw.Flush() != nil {
		return
	}
	sent := make(chan struct{})
	go func() {
		defer close(sent)
		_, _ = io.Copy(upstream, rw.Reader)
		_ = upstream.Close()
	}()
	_, _ = io.Copy(client, previewBudgetReader{p, upstream})
	_ = client.Close()
	_ = upstream.Close()
	<-sent
}

type previewBudgetReader struct {
	budget *previewEgress
	read   io.Reader
}

func (r previewBudgetReader) Read(b []byte) (int, error) {
	for {
		left := r.budget.remaining.Load()
		if left <= 0 {
			r.budget.refused.Store(true)
			r.budget.cancel()
			return 0, errPreviewAcquisition
		}
		limit := min(int64(len(b)), left)
		if r.budget.remaining.CompareAndSwap(left, left-limit) {
			n, err := r.read.Read(b[:limit])
			r.budget.remaining.Add(limit - int64(n))
			return n, err
		}
	}
}

func previewOrigin(source validators.SourceType, host string) bool {
	host = strings.ToLower(host)
	if !previewDNSName.MatchString(host) || strings.Contains(host, "..") {
		return false
	}
	within := func(domain string) bool { return host == domain || strings.HasSuffix(host, "."+domain) }
	if source == validators.SourceYouTube {
		return within("youtube.com") || within("googlevideo.com") || within("ytimg.com") || host == "youtubei.googleapis.com"
	}
	return source == validators.SourceSoundCloud && (within("soundcloud.com") || within("sndcdn.com") || within("media-streaming.soundcloud.cloud"))
}

func dialPreviewOrigin(ctx context.Context, host string) (net.Conn, error) {
	addresses, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return nil, errPreviewAcquisition
	}
	dialer := net.Dialer{Timeout: 2 * time.Second}
	for _, addr := range addresses {
		addr = addr.Unmap()
		if !routablePreviewIP(addr) {
			continue
		}
		if connection, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(addr.String(), "443")); err == nil {
			return connection, nil
		}
	}
	return nil, errPreviewAcquisition
}

func routablePreviewIP(ip netip.Addr) bool {
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || (ip.Is6() && !globalIPv6.Contains(ip)) {
		return false
	}
	for _, prefix := range specialPreviewIPs {
		if prefix.Contains(ip) {
			return false
		}
	}
	return true
}

var (
	previewDNSName = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$`)
	globalIPv6     = netip.MustParsePrefix("2000::/3")
	// IsGlobalUnicast includes shared, benchmark, documentation and transition
	// ranges. Never dial one of those from a provider-origin DNS result.
	specialPreviewIPs = []netip.Prefix{
		netip.MustParsePrefix("0.0.0.0/8"), netip.MustParsePrefix("100.64.0.0/10"),
		netip.MustParsePrefix("192.0.0.0/24"), netip.MustParsePrefix("192.0.2.0/24"),
		netip.MustParsePrefix("198.18.0.0/15"), netip.MustParsePrefix("198.51.100.0/24"),
		netip.MustParsePrefix("203.0.113.0/24"), netip.MustParsePrefix("240.0.0.0/4"),
		netip.MustParsePrefix("2001::/23"), netip.MustParsePrefix("2001:db8::/32"),
		netip.MustParsePrefix("2002::/16"), netip.MustParsePrefix("3fff::/20"),
	}
)
