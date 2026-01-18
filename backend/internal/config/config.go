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
