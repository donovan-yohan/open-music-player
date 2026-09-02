package api

import (
	"math"
	"regexp"
	"strconv"
	"strings"
)

var autoBlendCamelotPattern = regexp.MustCompile(`^(\d{1,2})\s*([AaBb])$`)

// autoBlendParseCamelot normalizes the label format consumed by every
// harmonic-mixing seam. Nearby search uses this parser and the distance function
// below so it cannot drift from auto-blend and smart-reorder compatibility.
func autoBlendParseCamelot(label string) (int, byte, bool) {
	m := autoBlendCamelotPattern.FindStringSubmatch(strings.TrimSpace(label))
	if m == nil {
		return 0, 0, false
	}
	num, err := strconv.Atoi(m[1])
	if err != nil || num < 1 || num > 12 {
		return 0, 0, false
	}
	return num, strings.ToUpper(m[2])[0], true
}

// autoBlendCamelotDistance is the canonical compatibility rule: same-letter
// keys may be one number apart (including 12<->1), while opposite letters must
// have the same number. The boolean reports compatibility; the distance is the
// shortest cyclic number distance for callers that need to rank candidates.
func autoBlendCamelotDistance(
	aNumber int,
	aLetter byte,
	hasA bool,
	bNumber int,
	bLetter byte,
	hasB bool,
) (bool, int) {
	if !hasA || !hasB {
		return false, math.MaxInt
	}
	direct := aNumber - bNumber
	if direct < 0 {
		direct = -direct
	}
	numberDistance := direct
	if wrapped := 12 - direct; wrapped < numberDistance {
		numberDistance = wrapped
	}
	keyMatch := (aLetter == bLetter && numberDistance <= 1) ||
		(aLetter != bLetter && numberDistance == 0)
	return keyMatch, numberDistance
}
