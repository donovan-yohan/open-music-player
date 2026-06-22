package config

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	ServerAddr         string
	DBHost             string
	DBPort             string
	DBUser             string
	DBPassword         string
	DBName             string
	JWTSecret          string
	CORSAllowedOrigins []string
	RedisEnabled       bool
	RedisAddr          string
	RedisURL           string
	WorkerCount        int

	// S3/MinIO storage configuration
	S3Endpoint       string
	S3Region         string
	S3AccessKey      string
	S3SecretKey      string
	S3Bucket         string
	S3UsePathStyle   bool // Required for MinIO
	S3ForcePathStyle bool // Alias for S3UsePathStyle

	// MinIO/S3 streaming configuration
	MinioEndpoint       string
	MinioPublicEndpoint string
	MinioAccessKey      string
	MinioSecretKey      string
	MinioBucket         string
	MinioUseSSL         bool

	// AI assist (OpenAI-compatible) configuration for the grounded search assist
	// endpoint. Disabled unless fully configured; absence must never break normal
	// discovery search or direct URL resolution. The API key is a secret and must
	// never be logged.
	AIAssistEnabled bool
	AIAssistBaseURL string
	AIAssistAPIKey  string
	AIAssistModel   string
	AIAssistTimeout time.Duration
}

func Load() *Config {
	workerCount := parseWorkerCount()

	minioUseSSL, _ := strconv.ParseBool(getEnvOrDefault("MINIO_USE_SSL", "false"))
	redisEnabled := parseBoolEnv("REDIS_ENABLED", true)

	aiBaseURL := strings.TrimSpace(os.Getenv("AI_ASSIST_BASE_URL"))
	aiAPIKey := strings.TrimSpace(os.Getenv("AI_ASSIST_API_KEY"))
	aiModel := strings.TrimSpace(os.Getenv("AI_ASSIST_MODEL"))
	// Default-enabled only when fully configured; an operator can force it off
	// with AI_ASSIST_ENABLED=false. A partial config stays disabled.
	aiEnabled := parseBoolEnv("AI_ASSIST_ENABLED", aiBaseURL != "" && aiAPIKey != "" && aiModel != "")

	return &Config{
		ServerAddr:         getEnvOrDefault("SERVER_ADDR", ":8080"),
		DBHost:             getEnvOrDefault("DB_HOST", "localhost"),
		DBPort:             getEnvOrDefault("DB_PORT", "5432"),
		DBUser:             getEnvOrDefault("DB_USER", "omp"),
		DBPassword:         getEnvOrDefault("DB_PASSWORD", "omp_dev_password"),
		DBName:             getEnvOrDefault("DB_NAME", "openmusicplayer"),
		JWTSecret:          getEnvOrDefault("JWT_SECRET", generateDefaultSecret()),
		CORSAllowedOrigins: parseCORSAllowedOrigins(),
		RedisEnabled:       redisEnabled,
		RedisAddr:          getEnvOrDefault("REDIS_ADDR", "localhost:6380"),
		RedisURL:           getEnvOrDefault("REDIS_URL", "redis://localhost:6380"),
		WorkerCount:        workerCount,

		// S3/MinIO configuration
		S3Endpoint:       getEnvOrDefault("MINIO_ENDPOINT", "http://localhost:9000"),
		S3Region:         getEnvOrDefault("S3_REGION", "us-east-1"),
		S3AccessKey:      getEnvOrDefault("MINIO_ACCESS_KEY", "minioadmin"),
		S3SecretKey:      getEnvOrDefault("MINIO_SECRET_KEY", "minioadmin"),
		S3Bucket:         getEnvOrDefault("MINIO_BUCKET", "audio-files"),
		S3UsePathStyle:   getEnvOrDefault("S3_USE_PATH_STYLE", "true") == "true",
		S3ForcePathStyle: getEnvOrDefault("S3_USE_PATH_STYLE", "true") == "true",

		// MinIO streaming configuration
		MinioEndpoint:       getEnvOrDefault("MINIO_ENDPOINT", "localhost:9000"),
		MinioPublicEndpoint: getEnvOrDefault("MINIO_PUBLIC_ENDPOINT", ""),
		MinioAccessKey:      getEnvOrDefault("MINIO_ACCESS_KEY", "minioadmin"),
		MinioSecretKey:      getEnvOrDefault("MINIO_SECRET_KEY", "minioadmin"),
		MinioBucket:         getEnvOrDefault("MINIO_BUCKET", "audio-files"),
		MinioUseSSL:         minioUseSSL,

		// AI assist configuration
		AIAssistEnabled: aiEnabled,
		AIAssistBaseURL: aiBaseURL,
		AIAssistAPIKey:  aiAPIKey,
		AIAssistModel:   aiModel,
		AIAssistTimeout: parseDurationMsEnv("AI_ASSIST_TIMEOUT_MS", 8*time.Second),
	}
}

// parseDurationMsEnv reads a millisecond integer env var into a Duration,
// falling back to defaultValue when unset, malformed, or non-positive.
func parseDurationMsEnv(key string, defaultValue time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return defaultValue
	}
	ms, err := strconv.Atoi(value)
	if err != nil || ms <= 0 {
		return defaultValue
	}
	return time.Duration(ms) * time.Millisecond
}

func parseCORSAllowedOrigins() []string {
	value, ok := os.LookupEnv("OMP_CORS_ALLOWED_ORIGINS")
	if !ok {
		value, ok = os.LookupEnv("CORS_ALLOWED_ORIGINS")
	}
	if !ok {
		return nil
	}
	if value == "" {
		return []string{}
	}

	parts := strings.Split(value, ",")
	origins := make([]string, 0, len(parts))
	for _, part := range parts {
		origin := strings.TrimSpace(part)
		if origin != "" {
			origins = append(origins, origin)
		}
	}
	return origins
}

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func parseWorkerCount() int {
	value := os.Getenv("WORKER_COUNT")
	if value == "" {
		return 1
	}

	workerCount, err := strconv.Atoi(value)
	if err != nil || workerCount < 0 {
		return 1
	}
	return workerCount
}

func parseBoolEnv(key string, defaultValue bool) bool {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}

	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return defaultValue
	}
	return parsed
}

func generateDefaultSecret() string {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "dev-secret-change-in-production"
	}
	return hex.EncodeToString(bytes)
}
