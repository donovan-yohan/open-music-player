package connect

import (
	"bytes"
	"encoding/json"
	"io"
	"unicode/utf8"
)

// strictValue rejects duplicate decoded keys before unmarshalling into typed DTOs.
// This is feature-local: legacy JSON decoding deliberately remains unchanged.
func strictValue(d *json.Decoder) (any, error) {
	token, err := d.Token()
	if err != nil {
		return nil, ErrInvalid
	}
	delimiter, ok := token.(json.Delim)
	if !ok {
		return token, nil
	}
	if delimiter != '{' {
		return nil, ErrInvalid
	}
	object := map[string]any{}
	for d.More() {
		name, err := d.Token()
		if err != nil {
			return nil, ErrInvalid
		}
		key, ok := name.(string)
		if !ok {
			return nil, ErrInvalid
		}
		if _, exists := object[key]; exists {
			return nil, ErrInvalid
		}
		v, err := strictValue(d)
		if err != nil {
			return nil, err
		}
		object[key] = v
	}
	if end, err := d.Token(); err != nil || end != json.Delim('}') {
		return nil, ErrInvalid
	}
	return object, nil
}
func object(raw []byte) (map[string]any, error) {
	if len(raw) > 4096 || !utf8.Valid(raw) {
		return nil, ErrInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	value, err := strictValue(decoder)
	if err != nil {
		return nil, err
	}
	if _, err = decoder.Token(); err != io.EOF {
		return nil, ErrInvalid
	}
	m, ok := value.(map[string]any)
	if !ok {
		return nil, ErrInvalid
	}
	return m, nil
}
func exact(m map[string]any, keys ...string) bool {
	if len(m) != len(keys) {
		return false
	}
	for _, key := range keys {
		if _, ok := m[key]; !ok {
			return false
		}
	}
	return true
}
func stringsRequired(m map[string]any, keys ...string) bool {
	for _, key := range keys {
		if _, ok := m[key].(string); !ok {
			return false
		}
	}
	return true
}
func integer(m map[string]any, key string) bool {
	n, ok := m[key].(json.Number)
	if !ok {
		return false
	}
	v, err := n.Int64()
	return err == nil && v >= 0 && v <= MaxInteger
}
func DecodeRegister(raw []byte) (RegisterRequest, error) {
	var req RegisterRequest
	m, err := object(raw)
	if err != nil || !exact(m, "deviceId", "label", "platform", "writerSecret") || !stringsRequired(m, "deviceId", "label", "platform", "writerSecret") {
		return req, ErrInvalid
	}
	if err = json.Unmarshal(raw, &req); err != nil {
		return req, ErrInvalid
	}
	if !ValidID(req.DeviceID) || !validText(req.Label, 1, 64) {
		return req, ErrInvalid
	}
	if _, err = writerHash(req.WriterSecret); err != nil {
		return req, err
	}
	switch req.Platform {
	case "android", "ios", "macos", "windows", "linux", "web":
		return req, nil
	}
	return req, ErrInvalid
}
func DecodeProof(raw []byte) (Proof, error) {
	var req Proof
	m, err := object(raw)
	if err != nil || !exact(m, "leaseId", "writerSecret") || !stringsRequired(m, "leaseId", "writerSecret") {
		return req, ErrInvalid
	}
	if err = json.Unmarshal(raw, &req); err != nil || !ValidID(req.LeaseID) {
		return req, ErrInvalid
	}
	_, err = writerHash(req.WriterSecret)
	return req, err
}
func DecodeReport(raw []byte) (ReportRequest, error) {
	var req ReportRequest
	m, err := object(raw)
	if err != nil || !exact(m, "leaseId", "writerSecret", "sequence", "playback") || !stringsRequired(m, "leaseId", "writerSecret") || !integer(m, "sequence") {
		return req, ErrInvalid
	}
	if m["playback"] != nil {
		p, ok := m["playback"].(map[string]any)
		if !ok || !exact(p, "sessionId", "queueItemId", "track", "playing", "processingState", "positionMs", "durationMs", "activeVoiceCount") || !stringsRequired(p, "sessionId", "processingState") {
			return req, ErrInvalid
		}
		if _, ok = p["playing"].(bool); !ok {
			return req, ErrInvalid
		}
		if p["queueItemId"] != nil && !stringsRequired(p, "queueItemId") {
			return req, ErrInvalid
		}
		for _, key := range []string{"positionMs", "durationMs", "activeVoiceCount"} {
			if !integer(p, key) {
				return req, ErrInvalid
			}
		}
		track, ok := p["track"].(map[string]any)
		if !ok || !exact(track, "trackId", "title", "artist") || !stringsRequired(track, "title", "artist") {
			return req, ErrInvalid
		}
		if track["trackId"] != nil && !integer(track, "trackId") {
			return req, ErrInvalid
		}
	}
	if err = json.Unmarshal(raw, &req); err != nil || !ValidID(req.LeaseID) || req.Sequence < 1 {
		return req, ErrInvalid
	}
	if _, err = writerHash(req.WriterSecret); err != nil {
		return req, err
	}
	return req, validatePlayback(req.Playback)
}
