package auth

import (
	"errors"
	"regexp"
	"strings"
)

var (
	ErrInvalidEmail    = errors.New("invalid email format")
	ErrPasswordTooShort = errors.New("password must be at least 8 characters")
)

var emailRegex = regexp.MustCompile(`^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$`)

func ValidateEmail(email string) error {
	email = strings.TrimSpace(email)
	if !emailRegex.MatchString(email) {
		return ErrInvalidEmail
	}
	return nil
}

func ValidatePassword(password string) error {
	if len(password) < 8 {
		return ErrPasswordTooShort
	}
	return nil
}
