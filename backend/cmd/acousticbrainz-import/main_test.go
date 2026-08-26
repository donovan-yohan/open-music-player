package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

func TestParseRhythmRowAcceptsAndRejects(t *testing.T) {
	mbid := "d3f4a1e2-1111-4222-8333-444455556666"
	entry, ok := parseRhythmRow([]string{mbid, "128.5"})
	if !ok {
		t.Fatalf("valid rhythm row rejected")
	}
	if entry.RecordingMBID.String() != mbid || entry.BPM == nil || *entry.BPM != 128.5 {
		t.Fatalf("entry = %+v, want mbid %s bpm 128.5", entry, mbid)
	}

	for name, record := range map[string][]string{
		"bad uuid":    {"not-a-uuid", "120"},
		"bad bpm":     {mbid, "abc"},
		"bpm too low": {mbid, "29"},
		"bpm too hi":  {mbid, "301"},
		"short":       {mbid},
	} {
		if _, ok := parseRhythmRow(record); ok {
			t.Fatalf("%s row accepted", name)
		}
	}
}

func TestCamelotFromKeyMapping(t *testing.T) {
	cases := []struct {
		key, scale, want string
	}{
		{"C", "major", "7B"},
		{"A", "minor", "8A"},
		{"F#", "minor", "11A"},
		{"C#", "major", "12B"},
		{"Db", "major", "12B"},
		{"G#", "minor", "1A"},
		{"H", "major", ""},  // invalid key dropped
		{"C", "dorian", ""}, // unknown scale dropped
		{"", "major", ""},   // empty key dropped
	}
	for _, tc := range cases {
		if got := camelotFromKey(tc.key, tc.scale); got != tc.want {
			t.Fatalf("camelotFromKey(%q, %q) = %q, want %q", tc.key, tc.scale, got, tc.want)
		}
	}
}

// recordingSink records upserts so run() can be exercised without Postgres.
type recordingSink struct {
	entries []db.AcousticBrainzEntry
}

func (f *recordingSink) UpsertAcousticBrainz(_ context.Context, entry db.AcousticBrainzEntry) error {
	f.entries = append(f.entries, entry)
	return nil
}

func writeTempCSV(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// failingSink fails on a chosen MBID to exercise the batch-boundary error path.
type failingSink struct {
	failOn uuid.UUID
	calls  int
}

func (f *failingSink) UpsertAcousticBrainz(_ context.Context, entry db.AcousticBrainzEntry) error {
	f.calls++
	if entry.RecordingMBID == f.failOn {
		return errors.New("boom")
	}
	return nil
}

func TestRunSurfacesFlushErrorInsteadOfPanicking(t *testing.T) {
	mbidA := "d3f4a1e2-1111-4222-8333-444455556666"
	mbidB := "d3f4a1e2-3333-4222-8333-444455556666"
	rhythm := writeTempCSV(t, "rhythm.csv",
		"mbid,bpm\n"+
			mbidA+",128.5\n"+
			mbidB+",140\n")

	sink := &failingSink{failOn: uuid.MustParse(mbidB)}
	if _, err := run(context.Background(), sink, rhythm, "", 1); err == nil {
		t.Fatalf("run succeeded, want upsert failure surfaced at batch boundary")
	} else if !strings.Contains(err.Error(), "upsert "+mbidB) || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("err = %v, want wrapped cause naming mbid %s", err, mbidB)
	}
}

func TestRunImportsRhythmAndTonalDeterministically(t *testing.T) {
	mbidA := "d3f4a1e2-1111-4222-8333-444455556666"
	mbidB := "d3f4a1e2-3333-4222-8333-444455556666"
	rhythm := writeTempCSV(t, "rhythm.csv",
		"mbid,bpm\n"+
			mbidA+",128.5\n"+
			"not-a-uuid,100\n"+ // rejected: bad MBID
			mbidB+",25\n"+ // rejected: BPM out of range
			mbidB+",140\n") // duplicate MBID: last row wins
	tonal := writeTempCSV(t, "tonal.csv",
		"mbid,key,scale\n"+
			mbidA+",c,major\n"+
			mbidB+",a,minor\n")

	sink := &recordingSink{}
	stats, err := run(context.Background(), sink, rhythm, tonal, 2)
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if stats.Rejected != 2 {
		t.Fatalf("rejected = %d, want 2 (bad uuid + out-of-range bpm)", stats.Rejected)
	}
	if len(sink.entries) != 2 {
		t.Fatalf("imported entries = %d, want 2", len(sink.entries))
	}

	byID := make(map[uuid.UUID]db.AcousticBrainzEntry, len(sink.entries))
	for _, entry := range sink.entries {
		byID[entry.RecordingMBID] = entry
	}
	a := byID[uuid.MustParse(mbidA)]
	b := byID[uuid.MustParse(mbidB)]

	if a.BPM == nil || *a.BPM != 128.5 || a.Camelot.String != "7B" {
		t.Fatalf("entry A = %+v, want bpm 128.5 camelot 7B", a)
	}
	// Duplicate rhythm rows resolve last-row-wins deterministically.
	if b.BPM == nil || *b.BPM != 140 || b.Camelot.String != "8A" {
		t.Fatalf("entry B = %+v, want bpm 140 (last-row-wins) camelot 8A", b)
	}
	for _, entry := range []db.AcousticBrainzEntry{a, b} {
		if entry.DumpRevision != PinnedAcousticBrainzDumpRevision {
			t.Fatalf("dump revision %q, want pinned %s", entry.DumpRevision, PinnedAcousticBrainzDumpRevision)
		}
		if !entry.Key.Valid || !entry.KeyScale.Valid {
			t.Fatalf("entry %s missing key/scale passthrough", entry.RecordingMBID)
		}
	}
	if stats.Total != 2 || stats.Imported != 2 || stats.CamelotMapped != 2 {
		t.Fatalf("stats = %+v, want total=2 imported=2 camelot_mapped=2", stats)
	}
}

// TestParseRhythmRowRejectsRawDumpLayout pins the contract between the published
// AcousticBrainz dump layout and the CSV this loader actually consumes.
//
// The real rhythm.csv shipped in
// acousticbrainz-lowlevel-features-20220623-rhythm.tar.zst has this header:
//
//	mbid,submission_offset,bpm,bpm_histogram_first_peak_bpm_mean,bpm_histogram_first_peak_bpm_median,bpm_histogram_second_peak_bpm_mean,bpm_histogram_second_peak_bpm_median,danceability,onset_rate
//
// parseRhythmRow reads record[1] as BPM, which on a raw dump row is
// submission_offset -- so every raw row is rejected. Operators must project the
// dump down to "mbid,bpm" first. See docs/ACOUSTICBRAINZ_IMPORT.md
// ("Dump layout vs loader input").
func TestParseRhythmRowRejectsRawDumpLayout(t *testing.T) {
	mbid := "0e11c0fd-a1da-4b88-a438-7ef55c5809ec"
	raw := []string{mbid, "0", "120.763885498", "120", "120", "133", "133", "0.996203362942", "2.86757659912"}

	if entry, ok := parseRhythmRow(raw); ok {
		t.Fatalf("raw dump row accepted (entry = %+v); record[1] is submission_offset, not bpm", entry)
	}

	projected := []string{mbid, "120.763885498"}
	entry, ok := parseRhythmRow(projected)
	if !ok {
		t.Fatalf("projected row (mbid,bpm) rejected, want accepted")
	}
	if entry.RecordingMBID.String() != mbid {
		t.Fatalf("mbid = %s, want %s", entry.RecordingMBID, mbid)
	}
	if entry.BPM == nil || *entry.BPM != 120.763885498 {
		t.Fatalf("entry = %+v, want bpm 120.763885498", entry)
	}
}

// TestParseTonalRowRejectsRawDumpLayout pins the same contract for the tonal
// dump. The real tonal.csv header is:
//
//	mbid,submission_offset,key_key,key_scale,tuning_frequency,tuning_equal_tempered_deviation
//
// parseTonalRow reads record[1]/record[2] as key/scale, which on a raw dump row
// are submission_offset/key_key -- it "succeeds" with garbage that camelotFromKey
// then silently drops. Operators must project to "mbid,key,scale" first. See
// docs/ACOUSTICBRAINZ_IMPORT.md ("Dump layout vs loader input").
func TestParseTonalRowRejectsRawDumpLayout(t *testing.T) {
	mbid := "0e11c0fd-a1da-4b88-a438-7ef55c5809ec"
	raw := []string{mbid, "0", "A", "major", "434.193115234", "0.141633972526"}

	row, ok := parseTonalRow(raw)
	if !ok {
		t.Fatalf("raw dump row unexpectedly rejected outright; want silent garbage passthrough")
	}
	if row.key != "0" || row.scale != "A" {
		t.Fatalf("raw row parsed key=%q scale=%q, want the wrong pair key=\"0\" scale=\"A\"", row.key, row.scale)
	}
	if got := camelotFromKey(row.key, row.scale); got != "" {
		t.Fatalf("camelotFromKey(%q, %q) = %q, want \"\" (unmappable garbage)", row.key, row.scale, got)
	}

	projected := []string{mbid, "A", "major"}
	row, ok = parseTonalRow(projected)
	if !ok {
		t.Fatalf("projected row (mbid,key,scale) rejected, want accepted")
	}
	if row.key != "A" || row.scale != "major" {
		t.Fatalf("projected row parsed key=%q scale=%q, want key=\"A\" scale=\"major\"", row.key, row.scale)
	}
	if got := camelotFromKey(row.key, row.scale); got != "10B" {
		t.Fatalf("camelotFromKey(%q, %q) = %q, want \"10B\"", row.key, row.scale, got)
	}
}
