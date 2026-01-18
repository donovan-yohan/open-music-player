package auth

import (
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestPasswordHashing(t *testing.T) {
	password := "testpassword123"

	hash, err := bcrypt.GenerateFromPassword([]byte(password), BcryptCost)
	if err != nil {
		t.Fatalf("failed to hash password: %v", err)
	}

	if err := bcrypt.CompareHashAndPassword(hash, []byte(password)); err != nil {
		t.Error("password comparison failed for correct password")
	}

	if err := bcrypt.CompareHashAndPassword(hash, []byte("wrongpassword")); err == nil {
		t.Error("password comparison should fail for wrong password")
	}
}

func TestValidateRegisterRequest(t *testing.T) {
	tests := []struct {
		name    string
		req     *RegisterRequest
		wantErr bool
	}{
		{
			name: "valid request",
			req: &RegisterRequest{
				Email:    "test@example.com",
				Password: "password123",
				Username: "testuser",
			},
			wantErr: false,
		},
		{
			name: "empty email",
			req: &RegisterRequest{
				Email:    "",
				Password: "password123",
				Username: "testuser",
			},
			wantErr: true,
		},
		{
			name: "invalid email format",
			req: &RegisterRequest{
				Email:    "notanemail",
				Password: "password123",
				Username: "testuser",
			},
			wantErr: true,
		},
		{
			name: "password too short",
			req: &RegisterRequest{
				Email:    "test@example.com",
				Password: "short",
				Username: "testuser",
			},
			wantErr: true,
		},
		{
			name: "username too short",
			req: &RegisterRequest{
				Email:    "test@example.com",
				Password: "password123",
				Username: "ab",
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateRegisterRequest(tt.req)
			if (err != nil) != tt.wantErr {
				t.Errorf("validateRegisterRequest() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestHashToken(t *testing.T) {
	token1 := "test-token-1"
	token2 := "test-token-2"

	hash1 := hashToken(token1)
	hash1Again := hashToken(token1)
	hash2 := hashToken(token2)

	if hash1 != hash1Again {
		t.Error("same token should produce same hash")
	}

	if hash1 == hash2 {
		t.Error("different tokens should produce different hashes")
	}

	if len(hash1) != 64 {
		t.Errorf("hash should be 64 characters (SHA-256 hex), got %d", len(hash1))
	}
}

func TestClaims(t *testing.T) {
	claims := &Claims{
		UserID: "test-user-id",
		Email:  "test@example.com",
	}

	if claims.UserID != "test-user-id" {
		t.Error("UserID mismatch")
	}

	if claims.Email != "test@example.com" {
		t.Error("Email mismatch")
	}
}
