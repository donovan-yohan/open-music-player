package auth

import (
	"encoding/json"
	"errors"
	"net/http"
	"regexp"

	"github.com/openmusicplayer/backend/internal/db"
	apperrors "github.com/openmusicplayer/backend/internal/errors"
)

var emailRegex = regexp.MustCompile(`^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$`)

type RegisterRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	Username string `json:"username"`
}

type LoginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type RefreshRequest struct {
	RefreshToken string `json:"refreshToken"`
}

type ErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type Handlers struct {
	authService *Service
}

func NewHandlers(authService *Service) *Handlers {
	return &Handlers{authService: authService}
}

func (h *Handlers) Register(w http.ResponseWriter, r *http.Request) {
	requestID := apperrors.GetRequestID(r.Context())

	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apperrors.WriteError(w, requestID, apperrors.BadRequest("invalid request body"))
		return
	}

	if err := validateRegisterRequest(&req); err != nil {
		apperrors.WriteError(w, requestID, apperrors.ValidationError(err.Error()))
		return
	}

	resp, err := h.authService.Register(r.Context(), req.Email, req.Password, req.Username)
	if err != nil {
		if errors.Is(err, db.ErrEmailExists) {
			apperrors.WriteError(w, requestID, apperrors.EmailExists())
			return
		}
		apperrors.WriteError(w, requestID, apperrors.InternalError("failed to create user").WithCause(err))
		return
	}

	apperrors.WriteJSON(w, requestID, http.StatusCreated, resp)
}

func (h *Handlers) Login(w http.ResponseWriter, r *http.Request) {
	requestID := apperrors.GetRequestID(r.Context())

	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apperrors.WriteError(w, requestID, apperrors.BadRequest("invalid request body"))
		return
	}

	if req.Email == "" || req.Password == "" {
		apperrors.WriteError(w, requestID, apperrors.ValidationError("email and password are required"))
		return
	}

	resp, err := h.authService.Login(r.Context(), req.Email, req.Password)
	if err != nil {
		if errors.Is(err, ErrInvalidCredentials) {
			apperrors.WriteError(w, requestID, apperrors.InvalidCredentials())
			return
		}
		apperrors.WriteError(w, requestID, apperrors.InternalError("login failed").WithCause(err))
		return
	}

	apperrors.WriteJSON(w, requestID, http.StatusOK, resp)
}

func (h *Handlers) Refresh(w http.ResponseWriter, r *http.Request) {
	requestID := apperrors.GetRequestID(r.Context())

	var req RefreshRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apperrors.WriteError(w, requestID, apperrors.BadRequest("invalid request body"))
		return
	}

	if req.RefreshToken == "" {
		apperrors.WriteError(w, requestID, apperrors.ValidationError("refresh token is required"))
		return
	}

	resp, err := h.authService.Refresh(r.Context(), req.RefreshToken)
	if err != nil {
		if errors.Is(err, ErrInvalidToken) {
			apperrors.WriteError(w, requestID, apperrors.InvalidToken("invalid or expired refresh token"))
			return
		}
		if errors.Is(err, ErrTokenExpired) {
			apperrors.WriteError(w, requestID, apperrors.TokenExpired())
			return
		}
		apperrors.WriteError(w, requestID, apperrors.InternalError("token refresh failed").WithCause(err))
		return
	}

	apperrors.WriteJSON(w, requestID, http.StatusOK, resp)
}

func (h *Handlers) Logout(w http.ResponseWriter, r *http.Request) {
	requestID := apperrors.GetRequestID(r.Context())

	userCtx := GetUserFromContext(r.Context())
	if userCtx == nil {
		apperrors.WriteError(w, requestID, apperrors.Unauthorized("not authenticated"))
		return
	}

	if err := h.authService.Logout(r.Context(), userCtx.UserID); err != nil {
		apperrors.WriteError(w, requestID, apperrors.InternalError("logout failed").WithCause(err))
		return
	}

	w.Header().Set("X-Request-ID", requestID)
	w.WriteHeader(http.StatusNoContent)
}

func validateRegisterRequest(req *RegisterRequest) error {
	if req.Email == "" {
		return errors.New("email is required")
	}
	if !emailRegex.MatchString(req.Email) {
		return errors.New("invalid email format")
	}
	if req.Password == "" {
		return errors.New("password is required")
	}
	if len(req.Password) < 8 {
		return errors.New("password must be at least 8 characters")
	}
	if req.Username == "" {
		return errors.New("username is required")
	}
	if len(req.Username) < 3 {
		return errors.New("username must be at least 3 characters")
	}
	if len(req.Username) > 50 {
		return errors.New("username must be at most 50 characters")
	}
	return nil
}
