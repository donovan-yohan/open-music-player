package auth

import (
	"context"
	"net/http"
	"strings"

	"github.com/google/uuid"
)

type contextKey string

const UserContextKey contextKey = "user"

type UserContext struct {
	UserID uuid.UUID
	Email  string
}

func Middleware(authService *Service) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			authHeader := r.Header.Get("Authorization")
			if authHeader == "" {
				http.Error(w, `{"code":"UNAUTHORIZED","message":"missing authorization header"}`, http.StatusUnauthorized)
				return
			}

			parts := strings.SplitN(authHeader, " ", 2)
			if len(parts) != 2 || strings.ToLower(parts[0]) != "bearer" {
				http.Error(w, `{"code":"UNAUTHORIZED","message":"invalid authorization header format"}`, http.StatusUnauthorized)
				return
			}

			tokenString := parts[1]
			claims, err := authService.ValidateAccessToken(tokenString)
			if err != nil {
				if err == ErrTokenExpired {
					http.Error(w, `{"code":"TOKEN_EXPIRED","message":"access token has expired"}`, http.StatusUnauthorized)
					return
				}
				http.Error(w, `{"code":"UNAUTHORIZED","message":"invalid access token"}`, http.StatusUnauthorized)
				return
			}

			userID, err := uuid.Parse(claims.UserID)
			if err != nil {
				http.Error(w, `{"code":"UNAUTHORIZED","message":"invalid user ID in token"}`, http.StatusUnauthorized)
				return
			}

			userCtx := &UserContext{
				UserID: userID,
				Email:  claims.Email,
			}

			ctx := context.WithValue(r.Context(), UserContextKey, userCtx)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func GetUserFromContext(ctx context.Context) *UserContext {
	user, ok := ctx.Value(UserContextKey).(*UserContext)
	if !ok {
		return nil
	}
	return user
}
