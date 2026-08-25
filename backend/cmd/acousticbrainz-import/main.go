// Command acousticbrainz-import loads the frozen CC0 AcousticBrainz CSV dump
// (rhythm.bpm, tonal.key_key/key_scale) into the mb_acousticbrainz cache table
// keyed by MusicBrainz recording MBID.
//
// Dataset: https://acousticbrainz.org/download — submissions ended 2022; the
// final dumps are from June 2022 (~7M recordings, ~29.4M rows across the
// rhythm/tonal CSVs, a few GB compressed). License: CC0 (no rights reserved).
//
// Merge policy: this loader NEVER touches track_analysis. The values it loads
// are external coverage references that BackfillAcousticBrainzSummary projects
// only where local analyzer output and user overrides are entirely absent
// (docs/AUDIO_MIR_EVALS.md external_reference class).
//
// Tie-breaking and validation contract:
//   - Rows with an unparseable MBID or BPM are rejected (counted, not fatal).
//     Duplicate MBIDs WITHIN one import resolve last-row-wins via the upsert;
//     re-running over the same dump is idempotent because each row upserts to
//     the same values deterministically.
//   - BPM outside [30, 300] is rejected, matching the compact analysis
//     validator's "out of range decodes as absent" behavior.
//   - Key + scale are converted to Camelot at load time; unparseable keys are
//     dropped rather than guessed.
package main

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/csv"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

// PinnedAcousticBrainzDumpRevision identifies the dataset revision this loader
// targets. The final AcousticBrainz dumps were published June 2022; see
// https://acousticbrainz.org/download for checksums.
const PinnedAcousticBrainzDumpRevision = "acousticbrainz-dump-2022-06"

func main() {
	log.SetFlags(0)
	var (
		rhythmPath = flag.String("rhythm", "", "path to acousticbrainz rhythm CSV (mbid,bpm); required")
		tonalPath  = flag.String("tonal", "", "optional path to acousticbrainz tonal CSV (mbid,key,scale)")
		dbHost     = flag.String("db-host", envDefault("OMP_AB_DB_HOST", "localhost"), "PostgreSQL host")
		dbPort     = flag.String("db-port", envDefault("OMP_AB_DB_PORT", "5434"), "PostgreSQL port")
		dbUser     = flag.String("db-user", envDefault("OMP_AB_DB_USER", "omp"), "PostgreSQL user")
		dbPassword = flag.String("db-password", envDefault("OMP_AB_DB_PASSWORD", "omp_dev_password"), "PostgreSQL password")
		dbName     = flag.String("db-name", envDefault("OMP_AB_DB_NAME", "openmusicplayer"), "PostgreSQL database")
		batchSize  = flag.Int("batch-size", 500, "rows per transaction batch")
	)
	flag.Parse()
	if *rhythmPath == "" {
		log.Fatalf("acousticbrainz-import: -rhythm is required")
	}
	if *batchSize <= 0 {
		log.Fatalf("acousticbrainz-import: -batch-size must be positive")
	}

	database, err := db.New(*dbHost, *dbPort, *dbUser, *dbPassword, *dbName)
	if err != nil {
		log.Fatalf("acousticbrainz-import: connect postgres: %v", err)
	}
	defer database.Close()
	if err := database.Migrate(); err != nil {
		log.Fatalf("acousticbrainz-import: migrate: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Hour)
	defer cancel()

	repo := db.NewAnalysisRepository(database)
	stats, err := run(ctx, repo, *rhythmPath, *tonalPath, *batchSize)
	if err != nil {
		log.Fatalf("acousticbrainz-import: FAIL: %v", err)
	}
	fmt.Printf("imported=%d rejected=%d camelot_mapped=%d total=%d\n",
		stats.Imported, stats.Rejected, stats.CamelotMapped, stats.Total)
	fmt.Println("acousticbrainz-import: ok")
	fmt.Printf("pinned_dump_revision=%s license=CC0 source=https://acousticbrainz.org/download\n",
		PinnedAcousticBrainzDumpRevision)
}

type importStats struct {
	Imported      int64
	Rejected      int64
	CamelotMapped int64
	Total         int64
}

type tonalRow struct {
	mbid   uuid.UUID
	key    string
	scale  string
	reject bool
}

type rowSink interface {
	UpsertAcousticBrainz(ctx context.Context, entry db.AcousticBrainzEntry) error
}

func run(ctx context.Context, sink rowSink, rhythmPath, tonalPath string, batchSize int) (importStats, error) {
	var stats importStats

	tonalByKey := make(map[uuid.UUID]tonalRow)
	if tonalPath != "" {
		err := readCSV(tonalPath, func(record []string) (uuid.UUID, bool) {
			row, ok := parseTonalRow(record)
			if !ok || row.reject {
				return uuid.Nil, false
			}
			return row.mbid, true
		}, func(mbid uuid.UUID, record []string) {
			row, _ := parseTonalRow(record)
			tonalByKey[mbid] = row
		})
		if err != nil {
			return stats, fmt.Errorf("read tonal csv: %w", err)
		}
	}

	batch := make([]db.AcousticBrainzEntry, 0, batchSize)
	flush := func() error {
		for _, entry := range batch {
			if err := sink.UpsertAcousticBrainz(ctx, entry); err != nil {
				return fmt.Errorf("upsert %s: %w", entry.RecordingMBID, err)
			}
			stats.Imported++
			if entry.HasCamelot() {
				stats.CamelotMapped++
			}
		}
		batch = batch[:0]
		return nil
	}

	err := readCSV(rhythmPath,
		func(record []string) (uuid.UUID, bool) {
			entry, ok := parseRhythmRow(record)
			if !ok {
				stats.Rejected++
				return uuid.Nil, false
			}
			stats.Total++
			return entry.RecordingMBID, true
		},
		func(_ uuid.UUID, record []string) {
			entry, _ := parseRhythmRow(record)
			if tonal, ok := tonalByKey[entry.RecordingMBID]; ok {
				entry.Key = sqlString(tonal.key)
				entry.KeyScale = sqlString(tonal.scale)
				entry.Camelot = sqlString(camelotFromKey(tonal.key, tonal.scale))
				entry.DumpRevision = PinnedAcousticBrainzDumpRevision
			} else if entry.DumpRevision == "" {
				entry.DumpRevision = PinnedAcousticBrainzDumpRevision
			}
			batch = append(batch, entry)
			if len(batch) >= batchSize {
				if err := flush(); err != nil {
					halt(err)
				}
			}
		},
	)
	if err != nil {
		return stats, fmt.Errorf("read rhythm csv: %w", err)
	}
	if err := flush(); err != nil {
		return stats, err
	}
	return stats, nil
}

var errHalt = errors.New("halted")

func halt(err error) { panic(errHalt) }

// readCSV streams a UTF-8 CSV whose first row may be a header. keyOf decides
// whether the record participates (and under which MBID); consume receives only
// accepted records.
func readCSV(path string, keyOf func([]string) (uuid.UUID, bool), consume func(uuid.UUID, []string)) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	reader := csv.NewReader(bufio.NewReader(f))
	reader.FieldsPerRecord = -1 // AB CSVs vary; parse defensively by position
	first := true
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		if first {
			first = false
			if isHeaderRow(record) {
				continue
			}
		}
		mbid, ok := keyOf(record)
		if !ok {
			continue
		}
		consume(mbid, record)
	}
}

// parseRhythmRow accepts either "mbid,bpm" or a headerless positional pair.
func parseRhythmRow(record []string) (db.AcousticBrainzEntry, bool) {
	if len(record) < 2 {
		return db.AcousticBrainzEntry{}, false
	}
	mbid, err := uuid.Parse(strings.TrimSpace(record[0]))
	if err != nil {
		return db.AcousticBrainzEntry{}, false
	}
	bpm, err := strconv.ParseFloat(strings.TrimSpace(record[1]), 64)
	if err != nil || bpm < 30 || bpm > 300 {
		return db.AcousticBrainzEntry{}, false
	}
	return db.AcousticBrainzEntry{RecordingMBID: mbid, BPM: &bpm}, true
}

// parseTonalRow expects "mbid,key,scale".
func parseTonalRow(record []string) (tonalRow, bool) {
	if len(record) < 3 {
		return tonalRow{}, false
	}
	mbid, err := uuid.Parse(strings.TrimSpace(record[0]))
	if err != nil {
		return tonalRow{}, false
	}
	key := strings.TrimSpace(record[1])
	scale := strings.TrimSpace(record[2])
	if key == "" || scale == "" {
		return tonalRow{mbid: mbid, reject: true}, false
	}
	return tonalRow{mbid: mbid, key: key, scale: scale}, true
}

func isHeaderRow(record []string) bool {
	if len(record) == 0 {
		return false
	}
	_, err := uuid.Parse(strings.TrimSpace(record[0]))
	return err != nil
}

// camelotFromKey maps a tonal key/scale pair onto its Camelot wheel label using
// the inverse of the analyzer-side projection pinned in
// evals/audio_mir/src/audio_mir_eval/vdj_export.py (_CAMELOT), so loader output
// cannot drift from the rest of the pipeline.
func camelotFromKey(key, scale string) string {
	switch strings.ToLower(scale) {
	case "major":
		number, ok := camelotMajorNumberByKey[normalizeKeyName(key)]
		if !ok {
			return ""
		}
		return strconv.Itoa(number) + "B"
	case "minor":
		number, ok := camelotNumberByKey[normalizeKeyName(key)]
		if !ok {
			return ""
		}
		return strconv.Itoa(number) + "A"
	default:
		return ""
	}
}

func normalizeKeyName(key string) string {
	name := strings.ToUpper(strings.TrimSpace(key))
	// Canonicalize enharmonic spellings onto one entry each.
	replacements := map[string]string{
		"DB": "C#", "EB": "D#", "GB": "F#", "AB": "G#", "BB": "A#",
	}
	if replaced, ok := replacements[name]; ok {
		return replaced
	}
	return name
}

var camelotNumberByKey = map[string]int{
	// Minors (A wheel): inverse of vdj_export _CAMELOT (n, "A") rows.
	"G#": 1, "D#": 2, "A#": 3, "F": 4, "C": 5, "G": 6,
	"D": 7, "A": 8, "E": 9, "B": 10, "F#": 11, "C#": 12,
}

// camelotMajorNumberByKey holds majors (B wheel): inverse of vdj_export
// _CAMELOT (n, "B") rows.
var camelotMajorNumberByKey = map[string]int{
	"B": 1, "F#": 2, "D#": 3, "G#": 4, "A#": 5, "F": 6,
	"C": 7, "G": 8, "D": 9, "A": 10, "E": 11, "C#": 12,
}

func sqlString(value string) sql.NullString {
	return sql.NullString{String: value, Valid: value != ""}
}

func envDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
