package logger

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestLogger_BasicLogging(t *testing.T) {
	var buf bytes.Buffer
	log := New(&Config{
		Output: &buf,
		Level:  LevelDebug,
	})

	ctx := context.Background()
	log.Info(ctx, "test message", map[string]interface{}{
		"key": "value",
	})

	var entry Entry
	if err := json.Unmarshal(buf.Bytes(), &entry); err != nil {
		t.Fatalf("failed to parse log entry: %v", err)
	}

	if entry.Level != "info" {
		t.Errorf("expected level info, got %s", entry.Level)
	}
	if entry.Message != "test message" {
		t.Errorf("expected message 'test message', got %s", entry.Message)
	}
	if entry.Fields["key"] != "value" {
		t.Errorf("expected field key=value, got %v", entry.Fields["key"])
	}
}

func TestLogger_RequestIDPropagation(t *testing.T) {
	var buf bytes.Buffer
	log := New(&Config{
		Output: &buf,
		Level:  LevelDebug,
	})

	ctx := WithRequestID(context.Background(), "test-request-id")
	log.Info(ctx, "test message", nil)

	var entry Entry
	if err := json.Unmarshal(buf.Bytes(), &entry); err != nil {
		t.Fatalf("failed to parse log entry: %v", err)
	}

	if entry.RequestID != "test-request-id" {
		t.Errorf("expected request_id 'test-request-id', got %s", entry.RequestID)
	}
}

func TestLogger_LogLevels(t *testing.T) {
	tests := []struct {
		minLevel     Level
		logLevel     string
		shouldOutput bool
	}{
		{LevelInfo, "debug", false},
		{LevelInfo, "info", true},
		{LevelWarn, "info", false},
		{LevelWarn, "warn", true},
		{LevelError, "warn", false},
		{LevelError, "error", true},
	}

	for _, tt := range tests {
		var buf bytes.Buffer
		log := New(&Config{
			Output: &buf,
			Level:  tt.minLevel,
		})

		ctx := context.Background()
		switch tt.logLevel {
		case "debug":
			log.Debug(ctx, "test", nil)
		case "info":
			log.Info(ctx, "test", nil)
		case "warn":
			log.Warn(ctx, "test", nil)
		case "error":
			log.Error(ctx, "test", nil, nil)
		}

		hasOutput := buf.Len() > 0
		if hasOutput != tt.shouldOutput {
			t.Errorf("minLevel=%s, logLevel=%s: expected output=%v, got=%v",
				tt.minLevel, tt.logLevel, tt.shouldOutput, hasOutput)
		}
	}
}

func TestRedactor_SensitiveKeys(t *testing.T) {
	r := DefaultRedactor()

	fields := map[string]interface{}{
		"username": "john",
		"password": "secret123",
		"token":    "abc123",
		"email":    "john@example.com",
	}

	redacted := r.RedactFields(fields)

	if redacted["username"] != "john" {
		t.Errorf("username should not be redacted")
	}
	if redacted["password"] != "[REDACTED]" {
		t.Errorf("password should be redacted, got %v", redacted["password"])
	}
	if redacted["token"] != "[REDACTED]" {
		t.Errorf("token should be redacted, got %v", redacted["token"])
	}
}

func TestRedactor_JWTPattern(t *testing.T) {
	r := DefaultRedactor()

	// Simulated JWT token
	jwt := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
	msg := "User authenticated with token: " + jwt

	redacted := r.Redact(msg)

	if strings.Contains(redacted, jwt) {
		t.Errorf("JWT token should be redacted, got %s", redacted)
	}
	if !strings.Contains(redacted, "[REDACTED]") {
		t.Errorf("redacted message should contain [REDACTED]")
	}
}

func TestParseLevel(t *testing.T) {
	tests := []struct {
		input    string
		expected Level
	}{
		{"debug", LevelDebug},
		{"DEBUG", LevelDebug},
		{"info", LevelInfo},
		{"INFO", LevelInfo},
		{"warn", LevelWarn},
		{"warning", LevelWarn},
		{"error", LevelError},
		{"ERROR", LevelError},
		{"unknown", LevelInfo}, // default
		{"", LevelInfo},        // default
	}

	for _, tt := range tests {
		result := ParseLevel(tt.input)
		if result != tt.expected {
			t.Errorf("ParseLevel(%q) = %v, want %v", tt.input, result, tt.expected)
		}
	}
}
