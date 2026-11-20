package processor

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/download"
)

func TestRunYTDLPRequestsFullQualityAudioFromSelectedSource(t *testing.T) {
	tool := writeFakeYTDLP(t, `
set -eu
out=""; format=""; quality=""; sections=""; prev=""; last=""
for arg in "$@"; do
  case "$prev" in
    -o) out="$arg" ;;
    --format) format="$arg" ;;
    --audio-quality) quality="$arg" ;;
  esac
  if [ "$arg" = "--download-sections" ]; then sections=yes; fi
  prev="$arg"; last="$arg"
done
[ "$last" = 'https://www.youtube.com/watch?v=fixedsource' ] || { echo 'selected source changed' >&2; exit 8; }
[ "$format" = 'bestaudio/best' ] && [ "$quality" = 0 ] && [ -z "$sections" ] || { echo 'full-quality audio policy missing' >&2; exit 9; }
printf 'saved audio' > "${out%.*}.mp3"
`)
	path, _, err := runYTDLPCommand(context.Background(), tool, "https://www.youtube.com/watch?v=fixedsource", &TrackMetadata{}, maxYTDLPOutputBytes)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(path) })
}

// The fixture substitutes only provider metadata. Selection, byte transfer,
// conversion, probing, and handing the artifact to storage use the real path.
func TestDownloadAndStoreUsesFullProviderAudioRendition(t *testing.T) {
	tool := os.Getenv("SOUNDQ_TEST_YTDLP")
	if tool == "" {
		t.Skip("set SOUNDQ_TEST_YTDLP to the absolute path of a local yt-dlp executable")
	}
	if !filepath.IsAbs(tool) {
		t.Fatal("SOUNDQ_TEST_YTDLP must be absolute")
	}
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
	defer cancel()
	dir := t.TempDir()
	type rendition struct {
		id, filename        string
		rate, channels, abr int
		muxed               bool
	}
	low := rendition{"low", "low.m4a", 24000, 1, 48, false}
	high := rendition{"high", "high.m4a", 48000, 2, 192, false}
	muxed := rendition{"muxed", "muxed.mp4", 44100, 2, 48, true}
	for _, r := range []rendition{low, high, muxed} {
		args := []string{"-v", "error", "-f", "lavfi", "-i", fmt.Sprintf("anoisesrc=r=%d:d=18:seed=13", r.rate)}
		if r.muxed {
			args = append(args, "-f", "lavfi", "-i", "color=c=black:s=16x16:r=1:d=18", "-c:v", "mpeg4")
		}
		args = append(args, "-ac", fmt.Sprint(r.channels), "-c:a", "aac", "-b:a", fmt.Sprintf("%dk", r.abr), filepath.Join(dir, r.filename))
		out, err := exec.CommandContext(ctx, ffmpeg, args...).CombinedOutput()
		if err != nil {
			t.Fatalf("generate rendition: %v: %s", err, out)
		}
	}
	for _, tc := range []struct {
		name    string
		offered []rendition
		want    rendition
		capMode string
	}{
		{"better rendition available", []rendition{low, high}, high, ""},
		{"only low quality available", []rendition{low}, low, ""},
		{"only muxed audio available", []rendition{muxed}, muxed, ""},
		{"premium encoding exceeds the cap", []rendition{muxed}, muxed, "fallback"},
		{"both encodes exceed the cap", []rendition{muxed}, muxed, "refuse"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			requests := make(chan string, 16)
			peer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				select {
				case requests <- r.URL.Path:
				default:
					t.Error("too many media fetches")
				}
				switch r.URL.Path {
				case "/low.m4a", "/high.m4a", "/muxed.mp4":
					http.ServeFile(w, r, filepath.Join(dir, strings.TrimPrefix(r.URL.Path, "/")))
				default:
					http.NotFound(w, r)
				}
			}))
			defer peer.Close()
			formats := make([]map[string]any, 0, len(tc.offered))
			for _, r := range tc.offered {
				vcodec := "none"
				if r.muxed {
					vcodec = "mpeg4"
				}
				formats = append(formats, map[string]any{"format_id": r.id, "url": peer.URL + "/" + r.filename,
					"ext": strings.TrimPrefix(filepath.Ext(r.filename), "."), "acodec": "mp4a.40.2", "vcodec": vcodec,
					"asr": r.rate, "audio_channels": r.channels, "abr": r.abr})
			}
			const source = "https://www.youtube.com/watch?v=fixedsource"
			info, err := json.Marshal(map[string]any{"id": "fixedsource", "title": "Source fixture", "duration": 18, "webpage_url": source, "formats": formats})
			if err != nil {
				t.Fatal(err)
			}
			bin := t.TempDir()
			infoPath := filepath.Join(bin, "provider.json")
			if err := os.WriteFile(infoPath, info, 0600); err != nil {
				t.Fatal(err)
			}
			shim := writeFakeYTDLP(t, `
set -eu
found=no
for arg do
  shift
  if [ "$arg" = "$SOUNDQ_SAVE_FIXTURE_SOURCE" ]; then found=yes; else set -- "$@" "$arg"; fi
done
[ "$found" = yes ]
exec "$SOUNDQ_TEST_YTDLP" --ignore-config --no-remote-components --proxy '' --load-info-json "$SOUNDQ_SAVE_FIXTURE_INFO" "$@"
`)
			executable := filepath.Join(bin, "yt-dlp")
			if err := os.Symlink(shim, executable); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			t.Setenv("SOUNDQ_SAVE_FIXTURE_SOURCE", source)
			t.Setenv("SOUNDQ_SAVE_FIXTURE_INFO", infoPath)
			if tc.capMode != "" {
				input := filepath.Join(dir, tc.want.filename)
				size := func(path string) int64 {
					t.Helper()
					info, err := os.Stat(path)
					if err != nil {
						t.Fatal(err)
					}
					return info.Size()
				}
				encodedSize := func(quality string) int64 {
					path := filepath.Join(t.TempDir(), "output.mp3")
					out, err := exec.CommandContext(ctx, ffmpeg, "-v", "error", "-i", input, "-vn", "-c:a", "libmp3lame", "-q:a", quality, path).CombinedOutput()
					if err != nil {
						t.Fatalf("encode reference: %v: %s", err, out)
					}
					return size(path)
				}
				inputBytes := size(input)
				priorBytes := encodedSize("5")
				capBytes := max(inputBytes, priorBytes)
				if tc.capMode == "refuse" {
					if inputBytes >= priorBytes {
						t.Fatal("fixture cannot download input below the oversized prior encode")
					}
					capBytes = inputBytes + (priorBytes-inputBytes)/2
				}
				if encodedSize("0") <= capBytes {
					t.Fatal("fixture does not exercise encoding overflow")
				}
				work := t.TempDir()
				t.Setenv("TMPDIR", work)
				path, contentType, err := runYTDLPCommand(ctx, executable, source, &TrackMetadata{}, capBytes)
				if tc.capMode == "refuse" {
					if err == nil || !strings.Contains(err.Error(), "downloaded file too large") || path != "" || contentType != "" {
						t.Fatalf("oversized fallback was not refused: %q %q %v", path, contentType, err)
					}
					if len(requests) != 1 || <-requests != "/"+tc.want.filename {
						t.Fatal("oversized fallback did not reuse the original fetch")
					}
					if entries, err := os.ReadDir(work); err != nil || len(entries) != 0 {
						t.Fatalf("refused import left behind a partial artifact: %v %v", entries, err)
					}
					return
				}
				if err != nil {
					t.Fatalf("same-rendition fallback should save a complete MP3: %v", err)
				}
				t.Cleanup(func() { _ = os.Remove(path) })
				if size(path) > capBytes || contentType != "audio/mpeg" || len(requests) != 1 || <-requests != "/"+tc.want.filename {
					t.Fatalf("fallback did not use the one already-fetched rendition under cap: %q, %d bytes", contentType, size(path))
				}
				pcm, err := exec.CommandContext(ctx, ffmpeg, "-v", "error", "-i", path, "-f", "s16le", "-").Output()
				if err != nil || len(pcm) < 17*tc.want.rate*tc.want.channels*2 {
					t.Fatalf("fallback must not truncate or replace the track: %d decoded bytes: %v", len(pcm), err)
				}
				return
			}
			store := &fakeObjectStorage{}
			metadata, err := (&Processor{storage: store}).downloadAndStore(ctx, &download.DownloadJob{ID: "quality-fixture", URL: source, SourceType: "youtube"})
			if err != nil {
				t.Fatal(err)
			}
			if metadata.SourceURL != source || metadata.Raw["format_id"] != tc.want.id || metadata.StorageKey != store.key {
				t.Fatalf("wrong stored rendition: source=%q format=%v key=%q", metadata.SourceURL, metadata.Raw["format_id"], metadata.StorageKey)
			}
			if count := len(requests); count == 0 {
				t.Fatal("no provider audio was fetched")
			} else {
				for i := 0; i < count; i++ {
					if got := <-requests; got != "/"+tc.want.filename {
						t.Fatalf("downloaded %s, want %s", got, tc.want.filename)
					}
				}
			}
			if q := metadata.AudioQuality; q.Codec != "mp3" || q.SampleRateHz != tc.want.rate || q.Channels != tc.want.channels || store.contentType != "audio/mpeg" {
				t.Fatalf("unexpected stored audio: %+v, type %q", q, store.contentType)
			}
			artifact := filepath.Join(t.TempDir(), "saved.mp3")
			if err := os.WriteFile(artifact, store.data, 0600); err != nil {
				t.Fatal(err)
			}
			pcm, err := exec.CommandContext(ctx, ffmpeg, "-v", "error", "-i", artifact, "-f", "s16le", "-").Output()
			if err != nil {
				t.Fatal(err)
			}
			tail := 15 * tc.want.rate * tc.want.channels * 2
			if len(pcm) < tail+2*tc.want.rate*tc.want.channels*2 || bytes.Count(pcm[tail:], []byte{0}) == len(pcm)-tail {
				t.Fatalf("expected real stored audio beyond the preview, got %d decoded bytes", len(pcm))
			}
		})
	}
}
