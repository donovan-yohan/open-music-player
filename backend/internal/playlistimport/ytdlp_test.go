package playlistimport

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/openmusicplayer/backend/internal/playlistsync"
)

const completeYTDLPPlaylistFixture = `{
  "_type": "playlist",
  "id": "PLfixture",
  "playlist_count": 2,
  "title": "Fixture mix",
  "entries": [
    {
      "id": "video-one",
      "webpage_url": "https://www.youtube.com/watch?v=video-one",
      "title": "First track",
      "artist": "First artist",
      "duration": 61.5
    },
    {
      "id": "video-two",
      "webpage_url": "https://www.youtube.com/watch?v=video-two",
      "title": "Second track",
      "uploader": "Second uploader",
      "availability": "private",
      "error": "This video is unavailable",
      "duration_ms": 92000
    }
  ]
}`

func fixtureRunner(stdout string, truncated bool, capturedArgs *[]string) ytdlpCommandRunner {
	return func(_ context.Context, _ string, args []string) (ytdlpCommandResult, error) {
		*capturedArgs = append([]string(nil), args...)
		return ytdlpCommandResult{stdout: []byte(stdout), stdoutTruncated: truncated}, nil
	}
}

func TestYTDLPResolveCanonicalizesSourceAndPreservesEntryOrder(t *testing.T) {
	var args []string
	enumerator := &YTDLPEnumerator{run: fixtureRunner(completeYTDLPPlaylistFixture, false, &args)}

	snapshot, err := enumerator.Resolve(context.Background(), "https://music.youtube.com/playlist?list=PLfixture&index=2")
	if err != nil {
		t.Fatalf("Resolve returned error: %v", err)
	}

	wantSource := playlistsync.Source{
		Provider:     "youtube",
		PlaylistID:   "PLfixture",
		CanonicalURL: "https://www.youtube.com/playlist?list=PLfixture",
		Metadata:     playlistsync.SourceMetadata{Title: "Fixture mix"},
	}
	if !reflect.DeepEqual(snapshot.Source, wantSource) {
		t.Fatalf("source = %#v, want %#v", snapshot.Source, wantSource)
	}
	if !snapshot.Complete {
		t.Fatal("snapshot.Complete = false, want true")
	}
	wantIDs := []string{"video-one", "video-two"}
	gotIDs := make([]string, 0, len(snapshot.Entries))
	for _, entry := range snapshot.Entries {
		gotIDs = append(gotIDs, entry.StableID)
	}
	if !reflect.DeepEqual(gotIDs, wantIDs) {
		t.Fatalf("stable IDs = %#v, want %#v", gotIDs, wantIDs)
	}
	if snapshot.Entries[0].SourceURL != "https://www.youtube.com/watch?v=video-one" || snapshot.Entries[1].SourceURL != "https://www.youtube.com/watch?v=video-two" {
		t.Fatalf("entry URLs = %#v, want provider URLs in source order", snapshot.Entries)
	}
	if snapshot.Entries[0].Metadata.DurationMS != 61500 || snapshot.Entries[1].Metadata.DurationMS != 92000 {
		t.Fatalf("entry durations = %d/%d, want 61500/92000", snapshot.Entries[0].Metadata.DurationMS, snapshot.Entries[1].Metadata.DurationMS)
	}
	if !snapshot.Entries[1].Metadata.Unavailable || snapshot.Entries[1].Metadata.Error != "This video is unavailable" {
		t.Fatalf("unavailable entry metadata = %#v, want unavailable with provider error", snapshot.Entries[1].Metadata)
	}
	if !containsArg(args, "--yes-playlist") || containsArg(args, "--playlist-end") {
		t.Fatalf("Resolve args = %#v, want full-playlist resolution without a cap", args)
	}
}

func TestYTDLPResolveRejectsIncompleteAndInvalidFixtures(t *testing.T) {
	tests := []struct {
		name      string
		fixture   string
		truncated bool
		wantErr   error
	}{
		{
			name:    "reported count is incomplete",
			fixture: strings.Replace(completeYTDLPPlaylistFixture, `"playlist_count": 2`, `"playlist_count": 3`, 1),
			wantErr: playlistsync.ErrIncompleteSnapshot,
		},
		{
			name:    "reported count is missing",
			fixture: strings.Replace(completeYTDLPPlaylistFixture, `  "playlist_count": 2,`, "", 1),
			wantErr: playlistsync.ErrIncompleteSnapshot,
		},
		{
			name:      "stdout is truncated",
			fixture:   completeYTDLPPlaylistFixture,
			truncated: true,
			wantErr:   playlistsync.ErrIncompleteSnapshot,
		},
		{
			name: "playlist identity is missing",
			fixture: `{
  "_type": "playlist",
  "title": "Fixture mix",
  "entries": []
}`,
			wantErr: playlistsync.ErrInvalidSnapshot,
		},
		{
			name:    "playlist identity does not match request",
			fixture: strings.Replace(completeYTDLPPlaylistFixture, `"PLfixture"`, `"PLother"`, 1),
			wantErr: playlistsync.ErrInvalidSnapshot,
		},
		{
			name: "entry identity is missing",
			fixture: `{
  "_type": "playlist",
  "id": "PLfixture",
  "title": "Fixture mix",
  "entries": [{"title": "Missing ID"}]
}`,
			wantErr: playlistsync.ErrIncompleteSnapshot,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			enumerator := &YTDLPEnumerator{run: fixtureRunner(tt.fixture, tt.truncated, new([]string))}
			_, err := enumerator.Resolve(context.Background(), "https://www.youtube.com/playlist?list=PLfixture")
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("Resolve error = %v, want errors.Is(..., %v)", err, tt.wantErr)
			}
		})
	}
}

func TestYTDLPEnumeratePreservesCappedJSONAndLineFallbacks(t *testing.T) {
	tests := []struct {
		name       string
		fixture    string
		maxItems   int
		wantTitle  string
		wantIDs    []string
		wantURLs   []string
		wantCapArg string
	}{
		{
			name: "single playlist JSON is capped and uses ID URL fallback",
			fixture: `{
  "title": "Capped mix",
  "entries": [
    {"id": "first", "title": "First"},
    {"id": "second", "webpage_url": "https://www.youtube.com/watch?v=second"}
  ]
}`,
			maxItems:   1,
			wantTitle:  "Capped mix",
			wantIDs:    []string{"first"},
			wantURLs:   []string{"https://www.youtube.com/watch?v=first"},
			wantCapArg: "1",
		},
		{
			name: "line-delimited JSON fallback remains supported",
			fixture: `{"id":"first","title":"First"}
{"id":"second","webpage_url":"/watch?v=second","title":"Second"}`,
			maxItems:   2,
			wantIDs:    []string{"first", "second"},
			wantURLs:   []string{"https://www.youtube.com/watch?v=first", "https://music.youtube.com/watch?v=second"},
			wantCapArg: "2",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var args []string
			enumerator := &YTDLPEnumerator{run: fixtureRunner(tt.fixture, false, &args)}
			metadata, entries, err := enumerator.Enumerate(context.Background(), "https://music.youtube.com/playlist?list=PLfixture", tt.maxItems)
			if err != nil {
				t.Fatalf("Enumerate returned error: %v", err)
			}
			if metadata.Title != tt.wantTitle {
				t.Fatalf("metadata title = %q, want %q", metadata.Title, tt.wantTitle)
			}
			if len(entries) != len(tt.wantIDs) {
				t.Fatalf("entry count = %d, want %d: %#v", len(entries), len(tt.wantIDs), entries)
			}
			for index, entry := range entries {
				if entry.SourceID != tt.wantIDs[index] || entry.SourceURL != tt.wantURLs[index] || entry.Index != index+1 {
					t.Fatalf("entry %d = %#v, want ID %q URL %q index %d", index, entry, tt.wantIDs[index], tt.wantURLs[index], index+1)
				}
			}
			if !containsArgPair(args, "--playlist-end", tt.wantCapArg) || containsArg(args, "--yes-playlist") {
				t.Fatalf("Enumerate args = %#v, want capped legacy invocation", args)
			}
		})
	}
}

func TestYTDLPEnumerateRejectsTruncatedStdout(t *testing.T) {
	enumerator := &YTDLPEnumerator{run: fixtureRunner(completeYTDLPPlaylistFixture, true, new([]string))}
	_, _, err := enumerator.Enumerate(context.Background(), "https://www.youtube.com/playlist?list=PLfixture", 2)
	if !errors.Is(err, playlistsync.ErrIncompleteSnapshot) {
		t.Fatalf("Enumerate error = %v, want ErrIncompleteSnapshot", err)
	}
}

func TestYTDLPEnumerateWrapsLineScannerError(t *testing.T) {
	fixture := strings.Repeat("x", maxEnumeratorOutputBytes+1)
	_, scanErr := parseYTDLPLines([]byte(fixture), "https://www.youtube.com/playlist?list=PLfixture", 2)
	if scanErr == nil {
		t.Fatal("parseYTDLPLines returned nil error for an oversized line")
	}

	enumerator := &YTDLPEnumerator{run: fixtureRunner(fixture, false, new([]string))}
	_, _, err := enumerator.Enumerate(context.Background(), "https://www.youtube.com/playlist?list=PLfixture", 2)
	if !errors.Is(err, scanErr) {
		t.Fatalf("Enumerate error = %v, want wrapped scanner error %v", err, scanErr)
	}
}

func TestIsYouTubeHostAcceptsYouTubeFamilies(t *testing.T) {
	tests := []struct {
		host string
		want bool
	}{
		{host: "youtube.com", want: true},
		{host: "music.youtube.com", want: true},
		{host: "youtube.com.", want: true},
		{host: "youtu.be", want: true},
		{host: "sub.youtu.be", want: true},
		{host: "youtu.be.", want: true},
		{host: "youtube.com.example.test", want: false},
		{host: "example.test", want: false},
	}

	for _, tt := range tests {
		t.Run(tt.host, func(t *testing.T) {
			if got := isYouTubeHost(tt.host); got != tt.want {
				t.Fatalf("isYouTubeHost(%q) = %t, want %t", tt.host, got, tt.want)
			}
		})
	}
}

func containsArg(args []string, want string) bool {
	for _, arg := range args {
		if arg == want {
			return true
		}
	}
	return false
}

func containsArgPair(args []string, key, value string) bool {
	for index := 0; index+1 < len(args); index++ {
		if args[index] == key && args[index+1] == value {
			return true
		}
	}
	return false
}
