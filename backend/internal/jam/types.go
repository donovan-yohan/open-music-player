// Package jam implements bounded host-only music requests. It never plays,
// acquires or grants access to audio. Public projections are explicit DTOs.
package jam

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
)

const (
	MaxCatalog    = 20
	MaxMembers    = 16
	MaxJoins      = 64
	MaxRequests   = 50
	MaxStateBytes = 65536
)

var (
	ErrDenied      = errors.New("jam unavailable")
	ErrConflict    = errors.New("jam conflict")
	ErrInvalid     = errors.New("invalid jam input")
	ErrCapacity    = errors.New("jam capacity")
	ErrLimited     = errors.New("jam rate limited")
	ErrUnavailable = errors.New("jam service unavailable")
)

type Owner struct {
	UserID     uuid.UUID
	Generation int64
}
type Proof struct {
	HostDeviceID uuid.UUID `json:"hostDeviceId"`
	LeaseID      uuid.UUID `json:"leaseId"`
	WriterSecret string    `json:"writerSecret"`
}
type CreateInput struct {
	JamID uuid.UUID `json:"jamId"`
	Proof
	TrackIDs []int64 `json:"trackIds"`
}
type CatalogItem struct {
	CatalogItemID uuid.UUID `json:"catalogItemId"`
	Title         string    `json:"title"`
	Artist        string    `json:"artist"`
	DurationMS    int64     `json:"durationMs"`
}
type NowPlaying struct {
	Title      string `json:"title"`
	Artist     string `json:"artist"`
	Playing    bool   `json:"playing"`
	PositionMS int64  `json:"positionMs"`
	DurationMS int64  `json:"durationMs"`
}
type Request struct {
	RequestID     uuid.UUID `json:"requestId"`
	CatalogItemID uuid.UUID `json:"catalogItemId"`
	DisplayName   string    `json:"displayName"`
	Status        string    `json:"status"`
}
type Snapshot struct {
	JamID      uuid.UUID     `json:"jamId"`
	Version    int64         `json:"version"`
	State      string        `json:"state"`
	ServerTime time.Time     `json:"serverTime"`
	ExpiresAt  time.Time     `json:"expiresAt"`
	HostSeenAt time.Time     `json:"hostSeenAt"`
	NowPlaying *NowPlaying   `json:"nowPlaying"`
	Catalog    []CatalogItem `json:"catalog"`
	Requests   []Request     `json:"requests"`
}
type HostRequest struct {
	Request
	TrackID int64             `json:"trackId"`
	Receipt *AdmissionReceipt `json:"receipt,omitempty"`
}
type HostView struct {
	Snapshot
	HostRequests []HostRequest `json:"hostRequests"`
	MemberCount  int           `json:"memberCount"`
}
type Invite struct {
	JoinToken       string    `json:"joinToken"`
	InviteExpiresAt time.Time `json:"inviteExpiresAt"`
}
type JoinInput struct {
	JoinToken    string    `json:"joinToken"`
	RequestID    uuid.UUID `json:"requestId"`
	DisplayName  string    `json:"displayName"`
	MemberSecret string    `json:"memberSecret"`
}
type JoinResult struct {
	MemberID        uuid.UUID `json:"memberId"`
	MemberExpiresAt time.Time `json:"memberExpiresAt"`
	Snapshot        Snapshot  `json:"snapshot"`
}
type RequestInput struct {
	RequestID       uuid.UUID `json:"requestId"`
	CatalogItemID   uuid.UUID `json:"catalogItemId"`
	ExpectedVersion int64     `json:"expectedVersion"`
}

// Receipt is a designated host's explicit statement of canonical local admission,
// NOT server-side playback or crash-safe exactly-once proof.
type AdmissionReceipt struct {
	RequestID    uuid.UUID `json:"requestId"`
	SessionID    string    `json:"sessionId"`
	OccurrenceID string    `json:"occurrenceId"`
}
type DecisionInput struct {
	ExpectedVersion int64             `json:"expectedVersion"`
	Status          string            `json:"status"`
	Receipt         *AdmissionReceipt `json:"receipt,omitempty"`
}
type HeartbeatInput struct {
	Proof
	HostSequence int64       `json:"hostSequence"`
	NowPlaying   *NowPlaying `json:"nowPlaying"`
}

func NewSecret() string {
	var b [32]byte
	if _, e := rand.Read(b[:]); e != nil {
		panic(e)
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}
func ValidSecret(s string) bool {
	b, e := base64.RawURLEncoding.DecodeString(s)
	return e == nil && len(b) == 32 && base64.RawURLEncoding.EncodeToString(b) == s
}
func hash(s string) string        { b := sha256.Sum256([]byte(s)); return hex.EncodeToString(b[:]) }
func equalHash(a, b string) bool  { return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }
func digest(v any) string         { b, _ := json.Marshal(v); return hash(string(b)) }
func text(s string, max int) bool { return utf8.ValidString(s) && len(s) <= max }
func validProof(p Proof) bool {
	return p.HostDeviceID != uuid.Nil && p.LeaseID != uuid.Nil && ValidSecret(p.WriterSecret)
}
func validPlaying(p *NowPlaying) bool {
	return p == nil || (text(p.Title, 200) && text(p.Artist, 200) && p.PositionMS >= 0 && p.DurationMS >= 0 && p.PositionMS <= 86400000 && p.DurationMS <= 86400000)
}
