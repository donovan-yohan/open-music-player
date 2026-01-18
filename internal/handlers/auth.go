package handlers

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/openmusicplayer/openmusicplayer/internal/auth"
	"github.com/openmusicplayer/openmusicplayer/internal/config"
	"github.com/openmusicplayer/openmusicplayer/internal/database"
	"github.com/openmusicplayer/openmusicplayer/internal/middleware"
)

type AuthHandler struct {
	db  *database.DB
	cfg *config.Config
}

func NewAuthHandler(db *database.DB, cfg *config.Config) *AuthHandler {
	return &AuthHandler{db: db, cfg: cfg}
}

type RegisterRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type LoginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type RefreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

type AuthResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

func (h *AuthHandler) Register(w http.ResponseWriter, r *http.Request) {
	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, ErrorResponse{Error: "invalid request body"})
		return
	}

	req.Email = strings.TrimSpace(strings.ToLower(req.Email))

	if err := auth.ValidateEmail(req.Email); err != nil {
		writeJSON(w, http.StatusBadRequest, ErrorResponse{Error: err.Error()})
		return
	}

	if err := auth.ValidatePassword(req.Password); err != nil {
		writeJSON(w, http.StatusBadRequest, ErrorResponse{Error: err.Error()})
		return
	}

	passwordHash, err := auth.HashPassword(req.Password, h.cfg.BcryptCost)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "failed to process password"})
		return
	}

	user, err := h.db.CreateUser(r.Context(), req.Email, passwordHash)
	if err != nil {
		if errors.Is(err, database.ErrDuplicateEmail) {
			writeJSON(w, http.StatusConflict, ErrorResponse{Error: "email already registered"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "failed to create user"})
		return
	}

	tokens, err := h.generateTokens(r, user.ID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "failed to generate tokens"})
		return
	}

	writeJSON(w, http.StatusCreated, tokens)
}

func (h *AuthHandler) Login(w http.ResponseWriter, r *http.Request) {
	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, ErrorResponse{Error: "invalid request body"})
		return
	}

	req.Email = strings.TrimSpace(strings.ToLower(req.Email))

	user, err := h.db.GetUserByEmail(r.Context(), req.Email)
	if err != nil {
		if errors.Is(err, database.ErrUserNotFound) {
			writeJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "invalid credentials"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "failed to authenticate"})
		return
	}

	if !auth.CheckPassword(req.Password, user.PasswordHash) {
		writeJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "invalid credentials"})
		return
	}

	tokens, err := h.generateTokens(r, user.ID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "failed to generate tokens"})
		return
	}

	writeJSON(w, http.StatusOK, tokens)
}

func (h *AuthHandler) Refresh(w http.ResponseWriter, r *http.Request) {
	var req RefreshRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, ErrorResponse{Error: "invalid request body"})
		return
	}

	storedToken, err := h.db.GetRefreshToken(r.Context(), req.RefreshToken)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "failed to validate token"})
		return
	}

	if storedToken == nil {
		writeJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "invalid refresh token"})
		return
	}

	if time.Now().After(storedToken.ExpiresAt) {
		h.db.DeleteRefreshToken(r.Context(), req.RefreshToken)
		writeJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "refresh token expired"})
		return
	}

	// Delete old token (rotation)
	if err := h.db.DeleteRefreshToken(r.Context(), req.RefreshToken); err != nil {
		writeJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "failed to rotate token"})
		return
	}

	tokens, err := h.generateTokens(r, storedToken.UserID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "failed to generate tokens"})
		return
	}

	writeJSON(w, http.StatusOK, tokens)
}

func (h *AuthHandler) Logout(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.GetUserID(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
		return
	}

	if err := h.db.DeleteUserRefreshTokens(r.Context(), userID); err != nil {
		writeJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "failed to logout"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"message": "logged out successfully"})
}

func (h *AuthHandler) generateTokens(r *http.Request, userID int64) (*AuthResponse, error) {
	accessToken, err := auth.GenerateAccessToken(userID, h.cfg.JWTSecret, h.cfg.AccessTokenExpiry)
	if err != nil {
		return nil, err
	}

	refreshToken, err := auth.GenerateRefreshToken()
	if err != nil {
		return nil, err
	}

	expiresAt := time.Now().Add(h.cfg.RefreshTokenExpiry)
	if err := h.db.StoreRefreshToken(r.Context(), userID, refreshToken, expiresAt); err != nil {
		return nil, err
	}

	return &AuthResponse{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresIn:    int(h.cfg.AccessTokenExpiry.Seconds()),
	}, nil
}

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}
