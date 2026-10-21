package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/google/uuid"
	"io"
	"net/http"
	"reflect"
	"strings"
	"unicode/utf8"
)

// Local strict boundary; unlike encoding/json alone it rejects duplicate keys,
// case aliases, omitted fields and null scalar values at every object depth.
func jamDecode(w http.ResponseWriter, r *http.Request, out any, limit int64) error {
	b, e := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
	if e != nil {
		return e
	}
	if !utf8.Valid(b) {
		return fmt.Errorf("invalid UTF8")
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	v, e := jamJSONValue(d)
	if e != nil {
		return e
	}
	if _, e = d.Token(); e != io.EOF {
		return fmt.Errorf("trailing JSON")
	}
	if e = jamShape(v, reflect.TypeOf(out).Elem()); e != nil {
		return e
	}
	return json.Unmarshal(b, out)
}
func jamJSONValue(d *json.Decoder) (any, error) {
	t, e := d.Token()
	if e != nil {
		return nil, e
	}
	delim, ok := t.(json.Delim)
	if !ok {
		return t, nil
	}
	switch delim {
	case '{':
		m := map[string]any{}
		for d.More() {
			k, e := d.Token()
			if e != nil {
				return nil, e
			}
			key, ok := k.(string)
			if !ok {
				return nil, fmt.Errorf("key")
			}
			if _, ok = m[key]; ok {
				return nil, fmt.Errorf("duplicate key")
			}
			v, e := jamJSONValue(d)
			if e != nil {
				return nil, e
			}
			m[key] = v
		}
		_, e = d.Token()
		return m, e
	case '[':
		a := []any{}
		for d.More() {
			v, e := jamJSONValue(d)
			if e != nil {
				return nil, e
			}
			a = append(a, v)
		}
		_, e = d.Token()
		return a, e
	}
	return nil, fmt.Errorf("delimiter")
}

type jamField struct {
	T        reflect.Type
	Optional bool
}

func jamFields(t reflect.Type, m map[string]jamField) {
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		if f.Anonymous {
			jamFields(f.Type, m)
			continue
		}
		tag := strings.Split(f.Tag.Get("json"), ",")
		if tag[0] == "-" {
			continue
		}
		name := tag[0]
		if name == "" {
			name = f.Name
		}
		m[name] = jamField{f.Type, len(tag) > 1 && tag[1] == "omitempty"}
	}
}
func jamShape(v any, t reflect.Type) error {
	if t.Kind() == reflect.Pointer {
		if v == nil {
			return nil
		}
		return jamShape(v, t.Elem())
	}
	if v == nil {
		return fmt.Errorf("null")
	}
	if t == reflect.TypeOf(uuid.UUID{}) {
		s, ok := v.(string)
		if !ok || len(s) != 36 {
			return fmt.Errorf("UUID")
		}
		id, e := uuid.Parse(s)
		if e != nil || id.String() != s {
			return fmt.Errorf("UUID")
		}
		return nil
	}
	switch t.Kind() {
	case reflect.Struct:
		m, ok := v.(map[string]any)
		if !ok {
			return fmt.Errorf("object")
		}
		fields := map[string]jamField{}
		jamFields(t, fields)
		for k, x := range m {
			f, ok := fields[k]
			if !ok {
				return fmt.Errorf("unknown field")
			}
			if e := jamShape(x, f.T); e != nil {
				return e
			}
		}
		for k, f := range fields {
			if _, ok := m[k]; !ok && !f.Optional {
				return fmt.Errorf("required field")
			}
		}
	case reflect.Slice:
		a, ok := v.([]any)
		if !ok {
			return fmt.Errorf("array")
		}
		for _, x := range a {
			if e := jamShape(x, t.Elem()); e != nil {
				return e
			}
		}
	case reflect.String:
		if _, ok := v.(string); !ok {
			return fmt.Errorf("string")
		}
	case reflect.Bool:
		if _, ok := v.(bool); !ok {
			return fmt.Errorf("boolean")
		}
	case reflect.Int, reflect.Int64:
		if _, ok := v.(json.Number); !ok {
			return fmt.Errorf("integer")
		}
	default:
		return fmt.Errorf("type")
	}
	return nil
}
