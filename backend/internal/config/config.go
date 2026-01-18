package config

import (
	"crypto/rand"
	"encoding/hex"
	"os"
)

type Config struct {
	ServerAddr string
	DBHost     string
	DBPort     string
	DBUser     string
	DBPassword string
	DBName     string
	JWTSecret  string

	// S3/MinIO storage configuration
	S3Endpoint        string
	S3Region          string
	S3AccessKey       string
	S3SecretKey       string
	S3Bucket          string
	S3UsePathStyle    bool // Required for MinIO
	S3ForcePathStyle  bool // Alias for S3UsePathStyle
}

func Load() *Config {
	return &Config{
		ServerAddr: getEnvOrDefault("SERVER_ADDR", ":8080"),
		DBHost:     getEnvOrDefault("DB_HOST", "localhost"),
		DBPort:     getEnvOrDefault("DB_PORT", "5432"),
		DBUser:     getEnvOrDefault("DB_USER", "omp"),
		DBPassword: getEnvOrDefault("DB_PASSWORD", "omp_dev_password"),
		DBName:     getEnvOrDefault("DB_NAME", "openmusicplayer"),
		JWTSecret:  getEnvOrDefault("JWT_SECRET", generateDefaultSecret()),

		// S3/MinIO configuration
		S3Endpoint:       getEnvOrDefault("MINIO_ENDPOINT", "http://localhost:9000"),
		S3Region:         getEnvOrDefault("S3_REGION", "us-east-1"),
		S3AccessKey:      getEnvOrDefault("MINIO_ACCESS_KEY", "minioadmin"),
		S3SecretKey:      getEnvOrDefault("MINIO_SECRET_KEY", "minioadmin"),
		S3Bucket:         getEnvOrDefault("MINIO_BUCKET", "audio-files"),
		S3UsePathStyle:   getEnvOrDefault("S3_USE_PATH_STYLE", "true") == "true",
		S3ForcePathStyle: getEnvOrDefault("S3_USE_PATH_STYLE", "true") == "true",
	}
}

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func generateDefaultSecret() string {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "dev-secret-change-in-production"
	}
	return hex.EncodeToString(bytes)
}
