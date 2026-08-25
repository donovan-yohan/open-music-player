package main

import (
	"context"
	"os"
	"path/filepath"
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
