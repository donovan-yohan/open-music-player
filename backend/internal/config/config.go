package config

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"strconv"
)

type Config struct {
	ServerAddr  string
	DBHost      string
	DBPort      string
	DBUser      string
	DBPassword  string
	DBName      string
	JWTSecret   string
	RedisURL    string
	WorkerCount int
}

func Load() *Config {
	workerCount, _ := strconv.Atoi(getEnvOrDefault("WORKER_COUNT", "3"))
	if workerCount <= 0 {
		workerCount = 3
	}

	return &Config{
		ServerAddr:  getEnvOrDefault("SERVER_ADDR", ":8080"),
		DBHost:      getEnvOrDefault("DB_HOST", "localhost"),
		DBPort:      getEnvOrDefault("DB_PORT", "5432"),
		DBUser:      getEnvOrDefault("DB_USER", "omp"),
		DBPassword:  getEnvOrDefault("DB_PASSWORD", "omp_dev_password"),
		DBName:      getEnvOrDefault("DB_NAME", "openmusicplayer"),
		JWTSecret:   getEnvOrDefault("JWT_SECRET", generateDefaultSecret()),
		RedisURL:    getEnvOrDefault("REDIS_URL", "redis://localhost:6380"),
		WorkerCount: workerCount,
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
