package db

import (
	"regexp"
	"strings"
)

// tsqueryTokenPattern matches runs of Unicode letters or digits. Every other
// character — whitespace and tsquery-significant punctuation such as & | ! : ( ) * / '
// — is treated as a token separator, so the lexemes it yields can never form invalid
// to_tsquery syntax.
var tsqueryTokenPattern = regexp.MustCompile(`[\p{L}\p{N}]+`)

// buildPrefixTSQuery converts free-form user input into a safe prefix-matching
// to_tsquery string, e.g. "AC/DC" -> "AC:* & DC:*". It extracts alphanumeric lexemes,
// suffixes each with ":*" for prefix matching, and joins them with " & ".
//
// Punctuation that would otherwise raise "syntax error in tsquery" (and surface as a
// 500) — inputs like "AC/DC", a trailing "&", ":", "!", or "(" — is treated purely as a
// separator. Returns "" when the input yields no lexemes; callers should short-circuit to
// an empty result in that case rather than passing "" to to_tsquery.
func buildPrefixTSQuery(query string) string {
	tokens := tsqueryTokenPattern.FindAllString(query, -1)
	if len(tokens) == 0 {
		return ""
	}
	for i, tok := range tokens {
		tokens[i] = tok + ":*"
	}
	return strings.Join(tokens, " & ")
}
