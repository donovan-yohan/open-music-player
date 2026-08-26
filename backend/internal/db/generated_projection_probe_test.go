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
//
// The type is matched generically (any uppercase SQL type, with an optional
// precision/length modifier and an optional array suffix) and the expression is
// captured up to its matching `) STORED` rather than being restricted to a single
// unnested omp_ call, so unusual-but-legal declarations are parsed instead of
// skipped. looseGeneratedColumnPattern below is the fail-closed backstop for
// anything this still cannot parse.
var generatedColumnPattern = regexp.MustCompile(
	`([a-z_][a-z0-9_]*)\s+[A-Z][A-Z0-9_ ]*(?:\([^()]*\))?(?:\s*\[\])?\s+GENERATED ALWAYS AS \((.*?)\)\s+STORED`,
)

// looseGeneratedColumnPattern is a deliberately permissive detector for the
// declaration keyword alone, independent of column type and expression shape.
// generatedColumnPattern must find exactly as many declarations as this one does;
// see countGeneratedColumnDeclarations.
var looseGeneratedColumnPattern = regexp.MustCompile(`\bGENERATED ALWAYS AS \(`)

// countGeneratedColumnDeclarations counts every GENERATED ALWAYS AS ( occurrence in
// db.go that is real schema rather than prose, and returns the offending source
// lines for the failure message. Lines whose first non-space characters are an SQL
// (`--`) or Go (`//`) comment marker are skipped: the FROZEN PROJECTION INTERFACE
// block deliberately illustrates the very syntax it governs.
func countGeneratedColumnDeclarations(source string) (int, []string) {
	var declarations []string
	for _, line := range strings.Split(source, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "--") || strings.HasPrefix(trimmed, "//") {
			continue
		}
		for range looseGeneratedColumnPattern.FindAllString(line, -1) {
			declarations = append(declarations, trimmed)
		}
	}
	return len(declarations), declarations
}

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

	// Fail closed. A fixed floor (there are four declarations today: two in
	// CREATE TABLE track_analysis, two in the ALTER TABLE ... ADD COLUMN upgrades)
	// only catches the pattern matching nothing at all -- a new column whose type or
	// expression the pattern cannot parse would leave the count at four and sail
	// through every assertion below, unprobed. Deriving the expected count from a
	// detector that cannot go stale with the type list makes that impossible.
	declared, declarations := countGeneratedColumnDeclarations(source)
	if declared != len(matches) {
		t.Fatalf("db.go declares %d GENERATED ALWAYS ... STORED columns but generatedColumnPattern parsed only %d; widen generatedColumnPattern (a new column type or expression shape it cannot read) so this guard keeps covering every projection.\ndeclarations found:\n\t%s",
			declared, len(matches), strings.Join(declarations, "\n\t"))
	}
	if declared == 0 {
		t.Fatalf("db.go declares no GENERATED ALWAYS ... STORED columns at all; the schema moved and this test is no longer guarding anything")
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
