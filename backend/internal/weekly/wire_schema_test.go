package weekly

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// The schema is generated from the same concrete Go DTOs used by the router.
// Constraint additions here describe the public boundary, not alternate types.
func wireSchema(t reflect.Type) map[string]any {
	if t.Kind() == reflect.Pointer {
		return map[string]any{"anyOf": []any{wireSchema(t.Elem()), map[string]any{"type": "null"}}}
	}
	if t == reflect.TypeOf(time.Time{}) {
		return map[string]any{"type": "string", "format": "date-time"}
	}
	switch t.Kind() {
	case reflect.Struct:
		props := map[string]any{}
		required := []string{}
		for n := 0; n < t.NumField(); n++ {
			f := t.Field(n)
			if f.Anonymous {
				inner := wireSchema(f.Type)
				for k, v := range inner["properties"].(map[string]any) {
					props[k] = v
				}
				required = append(required, inner["required"].([]string)...)
				continue
			}
			tag := strings.Split(f.Tag.Get("json"), ",")
			if len(tag) == 0 || tag[0] == "" || tag[0] == "-" {
				continue
			}
			props[tag[0]] = wireSchema(f.Type)
			if tag[0] == "affinity" {
				props[tag[0]].(map[string]any)["minimum"] = -3
				props[tag[0]].(map[string]any)["maximum"] = 3
			}
			if !strings.Contains(f.Tag.Get("json"), "omitempty") {
				required = append(required, tag[0])
			}
		}
		return map[string]any{"type": "object", "properties": props, "required": required, "additionalProperties": false}
	case reflect.Slice:
		return map[string]any{"type": "array", "items": wireSchema(t.Elem()), "maxItems": 2000}
	case reflect.Map:
		return map[string]any{"type": "object", "additionalProperties": wireSchema(t.Elem()), "maxProperties": 1000}
	case reflect.String:
		return map[string]any{"type": "string", "maxLength": 8192}
	case reflect.Int, reflect.Int64:
		return map[string]any{"type": "integer", "minimum": 0, "maximum": int64(9223372036854775807)}
	case reflect.Float64:
		return map[string]any{"type": "number"}
	case reflect.Bool:
		return map[string]any{"type": "boolean"}
	case reflect.Interface:
		return map[string]any{}
	}
	panic(t.String())
}
func TestWeeklyExportWireSchema(t *testing.T) {
	defs := map[string]any{}
	types := map[string]any{"WeeklyPage": Page{}, "PreferencesPage": PreferencesPage{}, "Feedback": Feedback{}, "FeedbackWrite": FeedbackWrite{}, "FeedbackAck": FeedbackAck{}, "PreferenceWrite": PreferenceWrite{}, "PreferenceAck": PreferenceAck{}, "ResetWrite": ResetWrite{}, "ResetAck": ResetAck{}, "Conflict": Conflict{}, "Export": Export{}, "Artist": Artist{}, "PermissionResource": PermissionResource{}}
	for name, v := range types {
		defs[name] = wireSchema(reflect.TypeOf(v))
	}
	page := defs["WeeklyPage"].(map[string]any)["properties"].(map[string]any)
	page["status"].(map[string]any)["enum"] = []string{"ready", "partial", "empty", "needs_preferences", "consent_required", "pending", "unavailable", "stale"}
	page["items"].(map[string]any)["maxItems"] = 20
	for _, v := range defs {
		props := v.(map[string]any)["properties"].(map[string]any)
		if x, ok := props["contractVersion"]; ok {
			x.(map[string]any)["const"] = ContractVersion
		}
	}
	for _, name := range []string{"Feedback", "FeedbackWrite"} {
		props := defs[name].(map[string]any)["properties"].(map[string]any)
		props["vote"].(map[string]any)["enum"] = []string{"up", "down", "none"}
	}
	defs["Error"] = map[string]any{"type": "object", "properties": map[string]any{"code": map[string]any{"type": "string"}, "message": map[string]any{"type": "string"}}, "required": []string{"code", "message"}, "additionalProperties": false}
	pref := defs["PreferenceWrite"].(map[string]any)
	pref["oneOf"] = []any{
		map[string]any{"properties": map[string]any{"resource": map[string]any{"const": "permission"}, "permission": map[string]any{"enum": []string{"learningFromServerHistory", "externalCatalogQueries", "similarArtistQueries"}}, "enabled": map[string]any{"type": "boolean"}}, "required": []string{"permission", "enabled"}, "not": map[string]any{"anyOf": []any{map[string]any{"required": []string{"artistMbid"}}, map[string]any{"required": []string{"interested"}}, map[string]any{"required": []string{"blocked"}}}}},
		map[string]any{"properties": map[string]any{"resource": map[string]any{"const": "artist"}, "artistMbid": map[string]any{"type": "string", "format": "uuid"}, "interested": map[string]any{"type": "boolean"}, "blocked": map[string]any{"type": "boolean"}}, "required": []string{"artistMbid", "interested", "blocked"}, "not": map[string]any{"anyOf": []any{map[string]any{"required": []string{"permission"}}, map[string]any{"required": []string{"enabled"}}}}},
	}
	defs["Conflict"].(map[string]any)["properties"].(map[string]any)["current"] = map[string]any{"anyOf": []any{map[string]any{"$ref": "#/$defs/Feedback"}, map[string]any{"$ref": "#/$defs/Artist"}, map[string]any{"$ref": "#/$defs/PermissionResource"}, map[string]any{"type": "null"}}}
	schema := map[string]any{"$schema": "https://json-schema.org/draft/2020-12/schema", "$id": "https://soundq.invalid/schemas/weekly-v1", "$defs": defs, "description": "weekly-v1 DTOs. Each $defs entry is an independently selectable schema. Enum and structural validation is in authenticated Go handlers. FeedbackWrite.batchId is required but nullable. PreferenceWrite variants are discriminated by resource."}
	b, e := json.MarshalIndent(schema, "", "  ")
	if e != nil {
		t.Fatal(e)
	}
	if dir := os.Getenv("SOUNDQ_WEEKLY_WIRE_DIR"); dir != "" {
		if e = os.WriteFile(filepath.Join(dir, "schema.json"), append(b, '\n'), 0600); e != nil {
			t.Fatal(e)
		}
	}
	t.Logf("Go-produced schema bytes=%d definitions=%d", len(b), len(defs))
}
