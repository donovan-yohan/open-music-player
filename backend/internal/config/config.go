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

	// Optional local Ollama metadata disambiguator. Disabled by default; when
	// enabled it only selects among existing MusicBrainz candidates.
	MetadataLLMEnabled bool
	MetadataLLMBaseURL string
	MetadataLLMModel   string
	MetadataLLMTimeout time.Duration

	// Optional Ollama source-quality judge. Disabled by default; discovery keeps
	// deterministic ranking when it is disabled or returns an error. APIKey is a
	// secret and must never be logged or returned to callers.
	SourceQualityLLMEnabled bool
	SourceQualityLLMBaseURL string
	SourceQualityLLMModel   string
	SourceQualityLLMTimeout time.Duration
	SourceQualityLLMAPIKey  string

	// Optional out-of-process audio analyzer. Disabled unless configured so the
	// processor never creates unserviceable pending analysis rows by default.
	AnalyzerEnabled     bool
	AnalyzerBaseURL     string
	AnalyzerAuthToken   string
	AnalyzerTimeout     time.Duration
	AnalyzerConcurrency int

	// Optional "save playlist as mix" seam. Disabled by default; when enabled,
	// POST /api/v1/playlists/{id}/mix creates a mix_plan from a playlist's
	// ordered tracks. Backend seam only (no DJ/waveform UI or mixing logic).
	EnablePlaylistMix bool
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
	metadataLLMBaseURL := strings.TrimSpace(getEnvOrDefault("METADATA_LLM_BASE_URL", getEnvOrDefault("OLLAMA_BASE_URL", "http://localhost:11434")))
	metadataLLMModel := strings.TrimSpace(getEnvOrDefault("METADATA_LLM_MODEL", os.Getenv("OLLAMA_MODEL")))
	metadataLLMEnabled := parseBoolEnv("METADATA_LLM_ENABLED", false)
	sourceQualityLLMBaseURL := strings.TrimSpace(os.Getenv("SOURCE_QUALITY_LLM_BASE_URL"))
	if sourceQualityLLMBaseURL == "" {
		sourceQualityLLMBaseURL = strings.TrimSpace(os.Getenv("OLLAMA_BASE_URL"))
	}
	if sourceQualityLLMBaseURL == "" {
		sourceQualityLLMBaseURL = "http://localhost:11434"
	}
	sourceQualityLLMModel := strings.TrimSpace(os.Getenv("SOURCE_QUALITY_LLM_MODEL"))
	if sourceQualityLLMModel == "" {
		sourceQualityLLMModel = strings.TrimSpace(os.Getenv("OLLAMA_MODEL"))
	}
	if sourceQualityLLMModel == "" {
		sourceQualityLLMModel = "source-quality-judge"
	}
	analyzerBaseURL := strings.TrimSpace(os.Getenv("ANALYZER_BASE_URL"))
	analyzerEnabled := parseBoolEnv("ANALYZER_ENABLED", analyzerBaseURL != "")

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

		// Metadata LLM disambiguator configuration
		MetadataLLMEnabled: metadataLLMEnabled,
		MetadataLLMBaseURL: metadataLLMBaseURL,
		MetadataLLMModel:   metadataLLMModel,
		MetadataLLMTimeout: parseDurationMsEnv("METADATA_LLM_TIMEOUT_MS", 5*time.Second),

		// Source-quality LLM configuration
		SourceQualityLLMEnabled: parseBoolEnv("SOURCE_QUALITY_LLM_ENABLED", false),
		SourceQualityLLMBaseURL: sourceQualityLLMBaseURL,
		SourceQualityLLMModel:   sourceQualityLLMModel,
		SourceQualityLLMTimeout: parseDurationMsEnv("SOURCE_QUALITY_LLM_TIMEOUT_MS", 1500*time.Millisecond),
		SourceQualityLLMAPIKey:  strings.TrimSpace(os.Getenv("OLLAMA_API_KEY")),

		// Audio analyzer service configuration
		AnalyzerEnabled:     analyzerEnabled,
		AnalyzerBaseURL:     analyzerBaseURL,
		AnalyzerAuthToken:   strings.TrimSpace(os.Getenv("ANALYZER_AUTH_TOKEN")),
		AnalyzerTimeout:     parseDurationMsEnv("ANALYZER_TIMEOUT_MS", 90*time.Second),
		AnalyzerConcurrency: parseBoundedIntEnv("ANALYZER_CONCURRENCY", 1, 1, 4),

		// Save-playlist-as-mix seam (default OFF)
		EnablePlaylistMix: parseBoolEnv("ENABLE_PLAYLIST_MIX", false),
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

func parseBoundedIntEnv(key string, defaultValue, minimum, maximum int) int {
	value := strings.TrimSpace(os.Getenv(key))
	parsed, err := strconv.Atoi(value)
	if value == "" || err != nil || parsed < minimum {
		return defaultValue
	}
	if parsed > maximum {
		return maximum
	}
	return parsed
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
