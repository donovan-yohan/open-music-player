package db

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// generatedColumnPattern captures the column name and the projection expression of
// every GENERATED ALWAYS ... STORED declaration in the schema string in db.go,
// both in CREATE TABLE and in ALTER TABLE ... ADD COLUMN IF NOT EXISTS form.
var generatedColumnPattern = regexp.MustCompile(
	`([a-z_]+)\s+(?:DOUBLE PRECISION|TEXT|BIGINT|INTEGER|NUMERIC|BOOLEAN)\s+GENERATED ALWAYS AS \((omp_[a-z_]+\([^()]*\))\)\s+STORED`,
)

const freezeSentinel = "-- FROZEN PROJECTION INTERFACE (omp_* functions)"

func readSchemaSource(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("db.go")
	if err != nil {
		t.Fatalf("read db.go: %v", err)
	}
	return string(raw)
}

// TestGeneratedProjectionProbeCoversEveryGeneratedColumn is the backpressure that
// keeps generatedProjectionProbes honest: a new stored generated projection added
// to the schema without a matching probe entry fails here, so drift detection can
// never silently fall behind the schema.
func TestGeneratedProjectionProbeCoversEveryGeneratedColumn(t *testing.T) {
	source := readSchemaSource(t)

	matches := generatedColumnPattern.FindAllStringSubmatch(source, -1)
	// Guard against the pattern silently matching nothing, which would make every
	// assertion below vacuous. There are four occurrences today (two in
	// CREATE TABLE track_analysis, two in the ALTER TABLE ... ADD COLUMN upgrades).
	if len(matches) < 4 {
		t.Fatalf("generatedColumnPattern matched %d GENERATED ALWAYS ... STORED declarations in db.go, want at least 4; the pattern is stale and this test is not actually guarding anything", len(matches))
	}

	registered := make(map[string]bool, len(generatedProjectionProbes))
	for _, probe := range generatedProjectionProbes {
		registered[probe.Column+" => "+probe.Expression] = true
	}

	found := make(map[string]bool, len(matches))
	for _, match := range matches {
		column, expression := match[1], match[2]
		key := column + " => " + expression
		found[key] = true
		if !registered[key] {
			t.Errorf("schema declares generated column %s as %s but generatedProjectionProbes has no entry for it; register {Table: ..., KeyColumn: ..., Column: %q, Expression: %q} in db.go so the startup drift probe covers it",
				column, expression, column, expression)
		}
	}

	for _, probe := range generatedProjectionProbes {
		key := probe.Column + " => " + probe.Expression
		if !found[key] {
			t.Errorf("generatedProjectionProbes registers %s.%s as %s but db.go declares no such GENERATED ALWAYS ... STORED column; remove the stale probe entry or fix its Expression",
				probe.Table, probe.Column, probe.Expression)
		}
	}
}

// TestGeneratedProjectionFreezeCommentIsPresent fails if the frozen-interface
// contract is deleted or demoted below the functions it governs, so the only
// human-readable warning against an in-place omp_* edit cannot quietly regress.
func TestGeneratedProjectionFreezeCommentIsPresent(t *testing.T) {
	source := readSchemaSource(t)

	if got := strings.Count(source, freezeSentinel); got != 1 {
		t.Fatalf("db.go contains the freeze sentinel %q %d times, want exactly 1", freezeSentinel, got)
	}

	sentinelAt := strings.Index(source, freezeSentinel)
	firstFunctionAt := strings.Index(source, "CREATE OR REPLACE FUNCTION omp_")
	if firstFunctionAt < 0 {
		t.Fatalf("db.go no longer contains any CREATE OR REPLACE FUNCTION omp_ statement")
	}
	if sentinelAt > firstFunctionAt {
		t.Fatalf("the freeze block at offset %d appears after the first CREATE OR REPLACE FUNCTION omp_ at offset %d; it must sit above the frozen functions it governs", sentinelAt, firstFunctionAt)
	}

	block := source[sentinelAt:firstFunctionAt]
	for _, required := range []string{
		// The two operations measured to actually refresh a stale stored value.
		"summary_json = summary_json",
		"DROP COLUMN",
	} {
		if !strings.Contains(block, required) {
			t.Errorf("the freeze block no longer documents %q; it must keep naming both operations that refresh a stale stored generated column", required)
		}
	}

	if !strings.Contains(block, "checkGeneratedProjectionDrift") {
		t.Errorf("the freeze block no longer names checkGeneratedProjectionDrift, the runtime backpressure behind this contract")
	}
}
