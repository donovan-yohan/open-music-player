package config

import (
	"os"
	"time"
)

type Config struct {
	ServerPort          string
	DatabaseURL         string
	JWTSecret           string
	AccessTokenExpiry   time.Duration
	RefreshTokenExpiry  time.Duration
	BcryptCost          int
}

func Load() *Config {
	return &Config{
		ServerPort:         getEnv("SERVER_PORT", "8080"),
		DatabaseURL:        getEnv("DATABASE_URL", "postgres://localhost:5432/openmusicplayer?sslmode=disable"),
		JWTSecret:          getEnv("JWT_SECRET", "change-me-in-production"),
		AccessTokenExpiry:  15 * time.Minute,
		RefreshTokenExpiry: 7 * 24 * time.Hour,
		BcryptCost:         12,
	}
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
