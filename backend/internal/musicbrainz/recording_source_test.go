package musicbrainz

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

const fixtureRecordingID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const soundCloudRecording = "https://soundcloud.com/fixture/exact-track"

func sourceRelation(link string) string {
	return fmt.Sprintf(`{"type":"free streaming","type-id":"7e41ef12-a124-4324-afdb-fdbae687a89c","target-type":"url","direction":"forward","attributes":[],"ended":false,"url":{"resource":%q}}`, link)
}

func sourceRecording(relations ...string) string {
	return `{"id":"` + fixtureRecordingID + `","video":false,"relations":[` + strings.Join(relations, ",") + `]}`
}

func TestRecordingSourceSelectsOnlyUniqueDirectAudio(t *testing.T) {
	qualified := sourceRelation(soundCloudRecording)
	for _, tc := range []struct {
		name, body, want string
		unavailable      bool
	}{
		{"exact SoundCloud track", sourceRecording(qualified), soundCloudRecording, false},
		{"canonical duplicates", sourceRecording(sourceRelation("http://www.soundcloud.com/fixture/exact-track?utm_source=test"), qualified), soundCloudRecording, false},
		{"YouTube Music on audio recording", sourceRecording(sourceRelation("https://music.youtube.com/watch?v=Fixture1234")), "https://www.youtube.com/watch?v=Fixture1234", false},
		{"distinct qualified links", sourceRecording(qualified, sourceRelation("https://soundcloud.com/fixture/other-track")), "", false},
		{"distinct links across providers", sourceRecording(sourceRelation("https://music.youtube.com/watch?v=Fixture1234"), qualified), "", false},
		{"ignored link does not make ambiguity", sourceRecording(sourceRelation("https://www.youtube.com/watch?v=Fixture1234"), qualified), soundCloudRecording, false},
		{"no URL relations", sourceRecording(), "", false},
		{"missing URL relations", `{"id":"` + fixtureRecordingID + `","video":false}`, "", true},
		{"null URL relations", `{"id":"` + fixtureRecordingID + `","video":false,"relations":null}`, "", true},
		{"unqualified generic relationship", sourceRecording(strings.Replace(qualified, "7e41ef12-a124-4324-afdb-fdbae687a89c", "08445ccf-7b99-4438-9f9a-fb9ac18099ee", 1)), "", false},
		{"backward relationship", sourceRecording(strings.Replace(qualified, `"forward"`, `"backward"`, 1)), "", false},
		{"ended relationship", sourceRecording(strings.Replace(qualified, `"ended":false`, `"ended":true`, 1)), "", false},
		{"video relationship", sourceRecording(strings.Replace(sourceRelation("https://music.youtube.com/watch?v=Fixture1234"), `"attributes":[]`, `"attributes":["video"]`, 1)), "", false},
		{"video recording", strings.Replace(sourceRecording(qualified), `"video":false`, `"video":true`, 1), "", false},
		{"no audio evidence", strings.Replace(sourceRecording(qualified), `"video":false,`, "", 1), "", false},
		{"related cover/remix not direct", sourceRecording(`{"type":"remix","target-type":"recording","recording":` + sourceRecording(qualified) + `}`), "", false},
		{"mismatched ID even with a source", strings.Replace(sourceRecording(qualified), fixtureRecordingID, "cccccccc-cccc-4ccc-8ccc-cccccccccccc", 1), "", true},
		{"noncanonical upstream ID", strings.Replace(sourceRecording(qualified), fixtureRecordingID, strings.ToUpper(fixtureRecordingID), 1), "", true},
		{"missing upstream ID", strings.Replace(sourceRecording(qualified), `"id":"`+fixtureRecordingID+`",`, "", 1), "", true},
		{"malformed metadata", sourceRecording(qualified) + ` trailing`, "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := selectRecordingSource([]byte(tc.body), fixtureRecordingID)
			if (err != nil) != tc.unavailable || (got == nil) != (tc.want == "") || got != nil && *got != tc.want {
				t.Fatalf("source=%v, error=%v, want %q (unavailable=%v)", got, err, tc.want, tc.unavailable)
			}
		})
	}
}

func TestRecordingSourceRejectsNonTrackURLShapes(t *testing.T) {
	for _, link := range []string{
		"https://music.example.invalid/direct-track",
		"https://soundcloud.com/fixture",
		"https://soundcloud.com/fixture/likes",
		"https://soundcloud.com/fixture/popular-tracks",
		"https://soundcloud.com/search/sounds",
		"https://soundcloud.com/pages/privacy",
		"https://soundcloud.com/fixture/" + strings.Repeat("a", 2048),
		"https://soundcloud.com/fixture/sets/playlist",
		"https://soundcloud.com/fixture/exact-track/s-private",
		"https://soundcloud.com/fixture/exact-track?secret_token=private",
		"https://on.soundcloud.com/fixture",
		"https://soundcloud.com.evil.invalid/fixture/exact-track",
		"https://fixture@soundcloud.com/fixture/exact-track",
		"https://www.youtube.com/watch?v=Fixture1234",
		"https://youtu.be/Fixture1234",
		"https://music.youtube.com/playlist?list=PLfixture",
		"https://music.youtube.com/watch?v=Fixture1234&list=PLfixture",
		"https://music.youtube.com/watch?v=Fixture1234&v=Different12",
		"https://music.youtube.com/watch-extra?v=Fixture1234",
		"https://music.youtube.com/watch?v=Fixture1234%2Fextra",
		"https://music.youtube.com/watch?v=wronglength01",
	} {
		t.Run(link[:min(len(link), 96)], func(t *testing.T) {
			got, err := selectRecordingSource([]byte(sourceRecording(sourceRelation(link))), fixtureRecordingID)
			if got != nil || err != nil {
				t.Fatalf("non-track URL accepted: %v, %v", got, err)
			}
		})
	}
}

func TestRecordingSourceUsesBoundedSharedClient(t *testing.T) {
	isolateFixtureBudgets(t)
	ctx := context.Background()
	store := fixturePublicCache(t)
	c := NewClient(store)
	id := uuid.MustParse(fixtureRecordingID)
	// This existing metadata cache key is not exact relationship evidence.
	if err := store.Set(ctx, "mb:recording:"+fixtureRecordingID, `{"id":"`+fixtureRecordingID+`"}`, time.Minute); err != nil {
		t.Fatal(err)
	}
	calls := 0
	c.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.String() != baseURL+"/recording/"+fixtureRecordingID+"?fmt=json&inc=url-rels" || r.Header.Get("User-Agent") != userAgent {
			return nil, fmt.Errorf("unexpected provider request: %s", r.URL)
		}
		deadline, ok := r.Context().Deadline()
		if !ok || time.Until(deadline) > recordingSourceTimeout {
			return nil, fmt.Errorf("missing recording lookup deadline")
		}
		return fixtureResponse(http.StatusOK, sourceRecording(sourceRelation(soundCloudRecording))), nil
	})
	for i := 1; i <= 2; i++ {
		got, err := c.GetRecordingSource(ctx, id)
		if err != nil || got == nil || *got != soundCloudRecording || calls != i {
			t.Fatalf("exact lookup: %v, %v, calls=%d, want %d", got, err, calls, i)
		}
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := c.GetRecordingSource(canceled, id); !errors.Is(err, context.Canceled) || calls != 2 {
		t.Fatalf("canceled read: %v, calls=%d", err, calls)
	}
}

func TestRecordingSourceBypassesStalledCache(t *testing.T) {
	for _, command := range []string{"get", "set"} {
		t.Run(command, func(t *testing.T) {
			isolateFixtureBudgets(t)
			var touched atomic.Bool
			release := make(chan struct{})
			store := fixturePublicCacheWithCommand(t, func(got string) {
				if got == command {
					touched.Store(true)
					<-release
				}
			})
			c := NewClient(store)
			c.httpClient.Transport = fixtureTransport(func(*http.Request) (*http.Response, error) {
				return fixtureResponse(http.StatusOK, sourceRecording(sourceRelation(soundCloudRecording))), nil
			})
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			type result struct {
				source *string
				err    error
			}
			done := make(chan result, 1)
			go func() {
				source, err := c.GetRecordingSource(ctx, uuid.MustParse(fixtureRecordingID))
				done <- result{source, err}
			}()
			select {
			case r := <-done:
				close(release)
				if r.err != nil || r.source == nil || *r.source != soundCloudRecording || touched.Load() {
					t.Fatalf("lookup depended on cache %s: source=%v err=%v entered=%v", command, r.source, r.err, touched.Load())
				}
			case <-ctx.Done():
				close(release)
				<-done
				t.Fatalf("lookup failed to finish with cache %s held: entered=%v", command, touched.Load())
			}
		})
	}
}

func TestRecordingSourceRejectsUnboundedOrRedirectedLookup(t *testing.T) {
	id := uuid.MustParse(fixtureRecordingID)
	for _, tc := range []struct {
		name     string
		response func() *http.Response
	}{
		{"oversized body with valid prefix", func() *http.Response {
			body := sourceRecording(sourceRelation(soundCloudRecording))
			return fixtureResponse(http.StatusOK, body+strings.Repeat(" ", recordingSourceMaxBytes+1-len(body)))
		}},
		{"redirect to another recording", func() *http.Response {
			r := fixtureResponse(http.StatusMovedPermanently, "")
			r.Header.Set("Location", "/ws/2/recording/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb?fmt=json&inc=url-rels")
			return r
		}},
		{"redirect to relationship host", func() *http.Response {
			r := fixtureResponse(http.StatusFound, "")
			r.Header.Set("Location", soundCloudRecording)
			return r
		}},
		{"retryable provider failure", func() *http.Response { return fixtureResponse(http.StatusServiceUnavailable, "not public") }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			withFixtureClock(t, func(t *testing.T) {
				c := NewClient(nil)
				calls := 0
				c.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
					calls++
					if calls != 1 {
						return nil, fmt.Errorf("unexpected followup: %s", r.URL)
					}
					return tc.response(), nil
				})
				got, err := c.GetRecordingSource(context.Background(), id)
				if got != nil || err == nil || calls != 1 {
					t.Fatalf("bounded lookup source=%v, error=%v, calls=%d", got, err, calls)
				}
			})
		})
	}
}
