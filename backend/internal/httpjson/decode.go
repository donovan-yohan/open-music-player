// Package httpjson decodes JSON request bodies sent by clients.
//
// Client builds ship ahead of the servers they talk to. A phone running
// tomorrow's build sends a field this binary has never heard of, and rejecting
// the whole request over that one key throws away the work the server did
// understand. So unknown top-level keys are ignored rather than fatal.
//
// They are still logged. The strictness this replaces was earning its keep as
// the only way to notice a client sending a key that binds to nothing, and
// silently dropping such a key turns a client bug into a mystery.
//
// The helper lives in its own leaf package because internal/api already imports
// internal/queue, so neither of the two packages that need it can host it
// without an import cycle.
package httpjson

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"reflect"
	"sort"
	"strings"
	"sync"
)

// knownFieldCache memoizes the reflection walk per target type. Request
// decoding is hot enough that re-walking a struct on every call is waste.
var knownFieldCache sync.Map // reflect.Type -> []string

// DecodeRequest reads exactly one JSON value from body into target, ignoring
// top-level keys target has no field for and logging their names against path.
//
// Only the unknown-field rejection is relaxed. Malformed JSON, a wrong type on
// a known field, and content trailing the first JSON value all still fail:
// version skew shows up as an extra key, never as a second document or a string
// where a number belongs.
func DecodeRequest(path string, body io.Reader, target any) error {
	decoder := json.NewDecoder(body)
	var raw json.RawMessage
	if err := decoder.Decode(&raw); err != nil {
		return fmt.Errorf("decode request body: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err != nil {
			return fmt.Errorf("read past first JSON value: %w", err)
		}
		return errors.New("request must contain one JSON value")
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return fmt.Errorf("bind request body: %w", err)
	}
	logUnknownFields(path, raw, target)
	return nil
}

// logUnknownFields reports the top-level keys target had no home for, one line
// per request so a skewed client costs one log entry instead of a burst.
//
// Only top-level keys are compared. Nesting is where encoding/json's own
// leniency already lives (a map[string]any member accepts anything), and
// version skew shows up at the top level in practice, so descending partway
// would report keys inconsistently rather than adding real coverage.
func logUnknownFields(path string, raw json.RawMessage, target any) {
	known := knownFieldsOf(target)
	if known == nil {
		return // target is not a struct, so there is no field set to diff against
	}
	var body map[string]json.RawMessage
	if err := json.Unmarshal(raw, &body); err != nil {
		return // not a JSON object; the bind above already had its say on that
	}
	unknown := make([]string, 0)
	for key := range body {
		if !isKnownField(known, key) {
			unknown = append(unknown, key)
		}
	}
	if len(unknown) == 0 {
		return
	}
	sort.Strings(unknown) // map iteration order would make the line unreadable
	log.Printf("Warning: ignoring unknown JSON fields in request body for %s: %s", path, strings.Join(unknown, ", "))
}

// isKnownField mirrors how encoding/json picks a field: an exact tag match
// first, then a case-insensitive one. Matching any more strictly would report
// keys that actually bound, which is worse than not reporting at all.
func isKnownField(known []string, key string) bool {
	for _, name := range known {
		if name == key {
			return true
		}
	}
	for _, name := range known {
		if strings.EqualFold(name, key) {
			return true
		}
	}
	return false
}

// knownFieldsOf returns the JSON names target binds, or nil when target is not
// a struct and the question does not apply.
func knownFieldsOf(target any) []string {
	structType := reflect.TypeOf(target)
	for structType != nil && structType.Kind() == reflect.Pointer {
		structType = structType.Elem()
	}
	if structType == nil || structType.Kind() != reflect.Struct {
		return nil
	}
	if cached, ok := knownFieldCache.Load(structType); ok {
		return cached.([]string)
	}
	names := collectJSONFieldNames(structType, map[reflect.Type]bool{})
	knownFieldCache.Store(structType, names)
	return names
}

// collectJSONFieldNames flattens a struct's JSON names, following embedded
// structs the way field promotion does. It takes the union rather than
// replaying encoding/json's depth-based conflict rules: a name that loses a
// conflict still bound something, so counting it as known cannot produce a
// false report.
func collectJSONFieldNames(structType reflect.Type, seen map[reflect.Type]bool) []string {
	if seen[structType] {
		return nil // self-referential embedding; these names are already collected
	}
	seen[structType] = true

	names := make([]string, 0, structType.NumField())
	for i := 0; i < structType.NumField(); i++ {
		field := structType.Field(i)
		tag := field.Tag.Get("json")
		if tag == "-" {
			continue // explicitly not on the wire; `json:"-,"` names it "-" instead
		}
		name, _, _ := strings.Cut(tag, ",") // drop options such as ",omitempty"

		if field.Anonymous && name == "" {
			embedded := field.Type
			if embedded.Kind() == reflect.Pointer {
				embedded = embedded.Elem()
			}
			if embedded.Kind() == reflect.Struct {
				names = append(names, collectJSONFieldNames(embedded, seen)...)
				continue
			}
		}
		if field.PkgPath != "" {
			continue // unexported and not a promoted struct, so nothing binds here
		}
		if name == "" {
			name = field.Name
		}
		names = append(names, name)
	}
	return names
}
