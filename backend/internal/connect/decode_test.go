package connect

import (
	"strings"
	"testing"
)

func TestConnectStrictDTOBoundary(t *testing.T) {
	id := "c8a6d5cb-685e-4407-b08d-30b9044ebd57"
	secret := registration().WriterSecret
	valid := `{"deviceId":"` + id + `","label":"Laptop","platform":"macos","writerSecret":"` + secret + `"}`
	if _, err := DecodeRegister([]byte(valid)); err != nil {
		t.Fatal(err)
	}
	for _, raw := range []string{
		strings.Replace(valid, `"label":"Laptop"`, `"label":null`, 1),
		strings.Replace(valid, `"label":"Laptop"`, `"Label":"Laptop"`, 1),
		strings.Replace(valid, `"label":"Laptop"`, `"label":"Laptop","label":"Other"`, 1),
		strings.Replace(valid, `"label":"Laptop"`, `"label":"Laptop","audioUri":"file:///private"`, 1),
		strings.Replace(valid, `"label":"Laptop"`, `"label":"Laptop","labe\u006c":"Other"`, 1),
		valid + ` {}`, `null`, `[]`, strings.Replace(valid, id, strings.ToUpper(id), 1),
	} {
		if _, err := DecodeRegister([]byte(raw)); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	report := `{"leaseId":"` + id + `","writerSecret":"` + secret + `","sequence":1,"playback":{"sessionId":"s","queueItemId":null,"track":{"trackId":null,"title":"T","artist":"A"},"playing":false,"processingState":"ready","positionMs":0,"durationMs":0,"activeVoiceCount":1}}`
	if _, err := DecodeReport([]byte(report)); err != nil {
		t.Fatal(err)
	}
	for _, raw := range []string{
		strings.Replace(report, `"playing":false`, `"playing":null`, 1),
		strings.Replace(report, `"playing":false,`, ``, 1),
		strings.Replace(report, `"sequence":1`, `"sequence":1.5`, 1),
		strings.Replace(report, `"sequence":1`, `"sequence":9007199254740992`, 1),
		strings.Replace(report, `"durationMs":0`, `"durationMs":-1`, 1),
		strings.Replace(report, `"activeVoiceCount":1`, `"activeVoiceCount":5`, 1),
		strings.Replace(report, `"title":"T"`, `"title":"T","artwork":"https://example.test"`, 1),
		strings.Replace(report, `"trackId":null`, `"trackId":0`, 1),
		strings.Replace(report, `"positionMs":0`, `"positionMs":0,"positionMs":1`, 1),
		strings.Replace(report, `"queueItemId":null`, `"queueItemId":""`, 1),
	} {
		if _, err := DecodeReport([]byte(raw)); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	if _, err := DecodeReport([]byte(`{"leaseId":"` + id + `","writerSecret":"` + secret + `","sequence":1,"playback":null}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeProof([]byte(`{"leaseId":"` + id + `","writerSecret":"` + secret + `"}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeProof([]byte(`{"leaseId":"` + id + `","writerSecret":null}`)); err == nil {
		t.Fatal("null writer")
	}
}
