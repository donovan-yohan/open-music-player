package auth

import (
	"context"
	"testing"
)

func TestConnectRealLoginRefreshCarryCurrentGenerationAgainstPostgres(t *testing.T) {
	_, s, _ := connectAuthDB(t)
	ctx := context.Background()
	registered, err := s.Register(ctx, "real-login@example.test", "test-password-only", "connect")
	if err != nil {
		t.Fatal(err)
	}
	claims, err := s.ValidateAccessToken(registered.AccessToken)
	if err != nil || claims.ConnectGeneration != 0 {
		t.Fatalf("register generation=%v %v", claims, err)
	}
	user, err := s.userRepo.GetByEmail(ctx, "real-login@example.test")
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Logout(ctx, user.ID); err != nil {
		t.Fatal(err)
	}
	login, err := s.Login(ctx, "real-login@example.test", "test-password-only")
	if err != nil {
		t.Fatal(err)
	}
	claims, err = s.ValidateAccessToken(login.AccessToken)
	if err != nil || claims.ConnectGeneration != 1 {
		t.Fatalf("login generation=%v %v", claims, err)
	}
	refreshed, err := s.Refresh(ctx, login.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	claims, err = s.ValidateAccessToken(refreshed.AccessToken)
	if err != nil || claims.ConnectGeneration != 1 {
		t.Fatalf("refresh generation=%v %v", claims, err)
	}
}
