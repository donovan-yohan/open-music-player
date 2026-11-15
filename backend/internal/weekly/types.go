// Package weekly owns the versioned discovery policy. Metadata is never audio authority.
package weekly

import (
	"context"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

const ContractVersion = "weekly-v1"
const RankingVersion = "signed-artists-v1"
const ProviderPolicyVersion = "weekly-mb-v1"
const PermissionsVersion = "explicit-default-off-v1"
const MaxFeedback = 2000
const MaxArtists = 1000
const MaxReplays = 128
const MaxResponseBytes = 1800000

type Feedback struct {
	RecordingMbid  string     `json:"recordingMbid"`
	Vote           string     `json:"vote"`
	Revision       int64      `json:"revision"`
	ProfileEpoch   int64      `json:"profileEpoch"`
	UpdatedAt      *time.Time `json:"updatedAt"`
	LastMutationID *string    `json:"lastMutationId"`
}
type FeedbackEntry struct {
	Feedback
	Title             string   `json:"title"`
	Artist            string   `json:"artist"`
	ArtistMbids       []string `json:"artistMbids"`
	PrimaryArtistMbid string   `json:"primaryArtistMbid"`
}
type Artist struct {
	ArtistMbid string `json:"artistMbid"`
	Name       string `json:"name"`
	Revision   int64  `json:"revision"`
	Interested bool   `json:"interested"`
	Blocked    bool   `json:"blocked"`
}
type Affinity struct {
	ArtistMbid        string   `json:"artistMbid"`
	Name              string   `json:"name"`
	Affinity          int      `json:"affinity"`
	ReasonCodes       []string `json:"reasonCodes"`
	ContributingCount int      `json:"contributingCount"`
}
type HistoryCoverage struct {
	Status       string `json:"status"`
	ShortDays    int    `json:"shortDays"`
	LongDays     int    `json:"longDays"`
	ShortArtists int    `json:"shortArtists"`
	LongArtists  int    `json:"longArtists"`
}
type PreferencesPage struct {
	ContractVersion           string           `json:"contractVersion"`
	ProfileEpoch              int64            `json:"profileEpoch"`
	PreferenceRevision        int64            `json:"preferenceRevision"`
	FilterRevision            int64            `json:"filterRevision"`
	PermissionsVersion        string           `json:"permissionsVersion"`
	RankingVersion            string           `json:"rankingVersion"`
	LearningFromServerHistory bool             `json:"learningFromServerHistory"`
	ExternalCatalogQueries    bool             `json:"externalCatalogQueries"`
	SimilarArtistQueries      bool             `json:"similarArtistQueries"`
	SimilarArtistAvailable    bool             `json:"similarArtistAvailable"`
	PermissionRevisions       map[string]int64 `json:"permissionRevisions"`
	InterestedArtists         []Artist         `json:"interestedArtists"`
	BlockedArtists            []Artist         `json:"blockedArtists"`
	RecordingFeedback         []FeedbackEntry  `json:"recordingFeedback"`
	DerivedArtistAffinities   []Affinity       `json:"derivedArtistAffinities"`
	DerivedBuiltAt            *time.Time       `json:"derivedBuiltAt"`
	HistoryCoverage           HistoryCoverage  `json:"historyCoverage"`
	FeedbackCursor            *string          `json:"feedbackCursor"`
	ArtistCursor              *string          `json:"artistCursor"`
}
type Component struct {
	Code      string  `json:"code"`
	Value     float64 `json:"value"`
	Available bool    `json:"available"`
}
type Provenance struct {
	Provider    string    `json:"provider"`
	Algorithm   *string   `json:"algorithm"`
	RetrievedAt time.Time `json:"retrievedAt"`
}
type Item struct {
	RecordingMbid     string       `json:"recordingMbid"`
	Title             string       `json:"title"`
	Artist            string       `json:"artist"`
	ArtistMbids       []string     `json:"artistMbids"`
	PrimaryArtistMbid string       `json:"primaryArtistMbid"`
	OriginalRank      int          `json:"originalRank"`
	ReasonCodes       []string     `json:"reasonCodes"`
	Components        []Component  `json:"components"`
	Provenance        []Provenance `json:"provenance"`
	Feedback          Feedback     `json:"feedback"`
}
type Excluded struct {
	Owned     int `json:"owned"`
	Recent    int `json:"recent"`
	Downvoted int `json:"downvoted"`
	Blocked   int `json:"blocked"`
	Duplicate int `json:"duplicate"`
}
type Coverage struct {
	ProviderRequests     int      `json:"providerRequests"`
	ProviderBodyBytes    int64    `json:"providerBodyBytes"`
	IdentityScope        string   `json:"identityScope"`
	ProviderStatus       string   `json:"providerStatus"`
	SeedsConsidered      int      `json:"seedsConsidered"`
	CandidatesConsidered int      `json:"candidatesConsidered"`
	PagesFetched         int      `json:"pagesFetched"`
	ReasonCodes          []string `json:"reasonCodes"`
	Excluded             Excluded `json:"excluded"`
}
type Page struct {
	ContractVersion                string     `json:"contractVersion"`
	Status                         string     `json:"status"`
	WeekStart                      time.Time  `json:"weekStart"`
	WeekEndExclusive               time.Time  `json:"weekEndExclusive"`
	CalendarZone                   string     `json:"calendarZone"`
	RankingVersion                 string     `json:"rankingVersion"`
	ProviderPolicyVersion          string     `json:"providerPolicyVersion"`
	ProfileEpoch                   int64      `json:"profileEpoch"`
	PreferenceRevisionAtGeneration int64      `json:"preferenceRevisionAtGeneration"`
	FilterRevision                 int64      `json:"filterRevision"`
	Items                          []Item     `json:"items"`
	Coverage                       Coverage   `json:"coverage"`
	BatchID                        *string    `json:"batchId"`
	GeneratedAt                    *time.Time `json:"generatedAt"`
	RetryAfter                     *time.Time `json:"retryAfter"`
	StaleReason                    *string    `json:"staleReason"`
}
type FeedbackWrite struct {
	Vote             string  `json:"vote"`
	MutationID       string  `json:"mutationId"`
	ExpectedRevision int64   `json:"expectedRevision"`
	ProfileEpoch     int64   `json:"profileEpoch"`
	BatchID          *string `json:"batchId"`
}
type FeedbackAck struct {
	ContractVersion    string   `json:"contractVersion"`
	Feedback           Feedback `json:"feedback"`
	PreferenceRevision int64    `json:"preferenceRevision"`
	FilterRevision     int64    `json:"filterRevision"`
	Replayed           bool     `json:"replayed"`
}
type PreferenceWrite struct {
	Resource         string  `json:"resource"`
	MutationID       string  `json:"mutationId"`
	ExpectedRevision int64   `json:"expectedRevision"`
	ProfileEpoch     int64   `json:"profileEpoch"`
	Permission       *string `json:"permission,omitempty"`
	Enabled          *bool   `json:"enabled,omitempty"`
	ArtistMbid       *string `json:"artistMbid,omitempty"`
	Interested       *bool   `json:"interested,omitempty"`
	Blocked          *bool   `json:"blocked,omitempty"`
}
type PermissionResource struct {
	Permission string `json:"permission"`
	Enabled    bool   `json:"enabled"`
	Revision   int64  `json:"revision"`
}
type PreferenceAck struct {
	ContractVersion    string              `json:"contractVersion"`
	ProfileEpoch       int64               `json:"profileEpoch"`
	PreferenceRevision int64               `json:"preferenceRevision"`
	FilterRevision     int64               `json:"filterRevision"`
	ResourceRevision   int64               `json:"resourceRevision"`
	Replayed           bool                `json:"replayed"`
	Permission         *PermissionResource `json:"permission"`
	Artist             *Artist             `json:"artist"`
}
type ResetWrite struct {
	MutationID       string `json:"mutationId"`
	ExpectedRevision int64  `json:"expectedRevision"`
	ProfileEpoch     int64  `json:"profileEpoch"`
	Scope            string `json:"scope"`
}
type ResetAck struct {
	ContractVersion    string `json:"contractVersion"`
	ProfileEpoch       int64  `json:"profileEpoch"`
	PreferenceRevision int64  `json:"preferenceRevision"`
	FilterRevision     int64  `json:"filterRevision"`
	Replayed           bool   `json:"replayed"`
}
type Conflict struct {
	Code               string `json:"code"`
	Detail             string `json:"detail"`
	Current            any    `json:"current"`
	ProfileEpoch       int64  `json:"profileEpoch"`
	PreferenceRevision int64  `json:"preferenceRevision"`
	FilterRevision     int64  `json:"filterRevision"`
}

func (e *Conflict) Error() string { return e.Code }

type Refusal struct {
	Status int
	Code   string
	Detail string
}

func (e *Refusal) Error() string { return e.Code }

type PermissionState struct {
	Enabled  bool
	Revision int64
}
type Replay struct {
	ID      string
	Payload string
	Kind    string
	Ack     []byte
}
type Attempt struct {
	Week                 time.Time
	Token                string
	LeaseUntil           time.Time
	RetryAfter           time.Time
	Epoch                int64
	PermissionGeneration int64
	Phase                string
}
type State struct {
	Epoch                int64
	Revision             int64
	FilterRevision       int64
	PermissionGeneration int64
	Permissions          map[string]PermissionState
	Artists              map[string]Artist
	Feedback             map[string]FeedbackEntry
	Replays              []Replay
	Batches              []Page
	Attempt              *Attempt // Never cleared by profile reset or permission transitions.
}

func NewState() *State {
	return &State{Permissions: map[string]PermissionState{"learningFromServerHistory": {}, "externalCatalogQueries": {}, "similarArtistQueries": {}}, Artists: map[string]Artist{}, Feedback: map[string]FeedbackEntry{}, Replays: []Replay{}, Batches: []Page{}}
}

type History struct {
	Short      map[string]string
	Long       map[string]string
	Unresolved int
}
type Eligibility struct {
	Owned           map[string]bool
	Recent          map[string]bool
	UnresolvedOwned int
}
type Store interface {
	Update(context.Context, uuid.UUID, func(*State) error) error
	ArtistEvidence(context.Context, uuid.UUID, string) (string, error)
	History(context.Context, uuid.UUID, time.Time) (History, error)
	Eligibility(context.Context, uuid.UUID, []string, time.Time) (Eligibility, error)
}
type Catalog interface {
	SearchTracks(context.Context, string, int, int, bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error)
}
type Service struct {
	store   Store
	catalog Catalog
}

func NewService(store Store, catalog Catalog) *Service {
	return &Service{store: store, catalog: catalog}
}
