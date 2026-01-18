package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/db"
	"golang.org/x/crypto/bcrypt"
)

const (
	AccessTokenExpiry  = 15 * time.Minute
	RefreshTokenExpiry = 7 * 24 * time.Hour
	BcryptCost         = 12
)

var (
	ErrInvalidCredentials = errors.New("invalid credentials")
	ErrInvalidToken       = errors.New("invalid token")
	ErrTokenExpired       = errors.New("token expired")
)

type Claims struct {
	UserID string `json:"user_id"`
	Email  string `json:"email"`
	jwt.RegisteredClaims
}

type AuthResponse struct {
	AccessToken  string    `json:"accessToken"`
	RefreshToken string    `json:"refreshToken"`
	ExpiresIn    int       `json:"expiresIn"`
	User         *UserInfo `json:"user"`
}

type UserInfo struct {
	ID        string    `json:"id"`
	Email     string    `json:"email"`
	Username  string    `json:"username"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt,omitempty"`
}

type Service struct {
	userRepo  *db.UserRepository
	tokenRepo *db.TokenRepository
	jwtSecret []byte
}

func NewService(userRepo *db.UserRepository, tokenRepo *db.TokenRepository, jwtSecret string) *Service {
	return &Service{
		userRepo:  userRepo,
		tokenRepo: tokenRepo,
		jwtSecret: []byte(jwtSecret),
	}
}

func (s *Service) Register(ctx context.Context, email, password, username string) (*AuthResponse, error) {
	passwordHash, err := bcrypt.GenerateFromPassword([]byte(password), BcryptCost)
	if err != nil {
		return nil, err
	}

	now := time.Now()
	user := &db.User{
		ID:           uuid.New(),
		Email:        email,
		Username:     username,
		PasswordHash: string(passwordHash),
		CreatedAt:    now,
		UpdatedAt:    now,
	}

	if err := s.userRepo.Create(ctx, user); err != nil {
		return nil, err
	}

	return s.generateTokens(ctx, user)
}

func (s *Service) Login(ctx context.Context, email, password string) (*AuthResponse, error) {
	user, err := s.userRepo.GetByEmail(ctx, email)
	if err != nil {
		if errors.Is(err, db.ErrUserNotFound) {
			return nil, ErrInvalidCredentials
		}
		return nil, err
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password)); err != nil {
		return nil, ErrInvalidCredentials
	}

	return s.generateTokens(ctx, user)
}

func (s *Service) Refresh(ctx context.Context, refreshToken string) (*AuthResponse, error) {
	tokenHash := hashToken(refreshToken)

	storedToken, err := s.tokenRepo.GetByHash(ctx, tokenHash)
	if err != nil {
		if errors.Is(err, db.ErrTokenNotFound) {
			return nil, ErrInvalidToken
		}
		return nil, err
	}

	if storedToken.Revoked {
		return nil, ErrInvalidToken
	}

	if time.Now().After(storedToken.ExpiresAt) {
		return nil, ErrTokenExpired
	}

	// Revoke the old token (rotation)
	if err := s.tokenRepo.Revoke(ctx, storedToken.ID); err != nil {
		return nil, err
	}

	user, err := s.userRepo.GetByID(ctx, storedToken.UserID)
	if err != nil {
		return nil, err
	}

	return s.generateTokens(ctx, user)
}

func (s *Service) Logout(ctx context.Context, userID uuid.UUID) error {
	return s.tokenRepo.RevokeAllForUser(ctx, userID)
}

func (s *Service) ValidateAccessToken(tokenString string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenString, &Claims{}, func(token *jwt.Token) (interface{}, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, ErrInvalidToken
		}
		return s.jwtSecret, nil
	})

	if err != nil {
		if errors.Is(err, jwt.ErrTokenExpired) {
			return nil, ErrTokenExpired
		}
		return nil, ErrInvalidToken
	}

	claims, ok := token.Claims.(*Claims)
	if !ok || !token.Valid {
		return nil, ErrInvalidToken
	}

	return claims, nil
}

func (s *Service) GetUserByID(ctx context.Context, id uuid.UUID) (*db.User, error) {
	return s.userRepo.GetByID(ctx, id)
}

func (s *Service) generateTokens(ctx context.Context, user *db.User) (*AuthResponse, error) {
	// Generate access token
	accessToken, err := s.generateAccessToken(user)
	if err != nil {
		return nil, err
	}

	// Generate refresh token
	refreshToken, err := s.generateRefreshToken(ctx, user.ID)
	if err != nil {
		return nil, err
	}

	return &AuthResponse{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresIn:    int(AccessTokenExpiry.Seconds()),
		User: &UserInfo{
			ID:        user.ID.String(),
			Email:     user.Email,
			Username:  user.Username,
			CreatedAt: user.CreatedAt,
			UpdatedAt: user.UpdatedAt,
		},
	}, nil
}

func (s *Service) generateAccessToken(user *db.User) (string, error) {
	claims := &Claims{
		UserID: user.ID.String(),
		Email:  user.Email,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(AccessTokenExpiry)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			Issuer:    "openmusicplayer",
		},
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(s.jwtSecret)
}

func (s *Service) generateRefreshToken(ctx context.Context, userID uuid.UUID) (string, error) {
	// Generate secure random token
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		return "", err
	}
	tokenString := hex.EncodeToString(tokenBytes)

	// Store hashed version in database
	tokenHash := hashToken(tokenString)
	refreshToken := &db.RefreshToken{
		ID:        uuid.New(),
		UserID:    userID,
		TokenHash: tokenHash,
		ExpiresAt: time.Now().Add(RefreshTokenExpiry),
		CreatedAt: time.Now(),
		Revoked:   false,
	}

	if err := s.tokenRepo.Create(ctx, refreshToken); err != nil {
		return "", err
	}

	return tokenString, nil
}

func hashToken(token string) string {
	hash := sha256.Sum256([]byte(token))
	return hex.EncodeToString(hash[:])
}
