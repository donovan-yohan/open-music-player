package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/processor"
)

const libraryUploadsPath = "/api/v1/library/uploads"
const (
	libraryUploadAdmissionDeadline = 3 * time.Second
	libraryUploadBodyDeadline      = 65 * time.Second
)

// LibraryUploadHandlers adapts #582's existing SQL receipt/stage and
// processor intake. It owns no durable state or storage cleanup worker.
// Readback-only mode can recover already staged bytes if given an intake, but
// has no route that could authorize a new upload.
type LibraryUploadHandlers struct {
	database   *db.DB
	tracks     *db.TrackRepository
	intake     *processor.PrivateImportIntake
	writes     bool
	receiving  chan struct{}
	recovering chan struct{}
}

func NewLibraryUploadHandlers(database *db.DB, tracks *db.TrackRepository, intake *processor.PrivateImportIntake, writes bool) *LibraryUploadHandlers {
	return &LibraryUploadHandlers{database: database, tracks: tracks, intake: intake, writes: writes,
		receiving: make(chan struct{}, 4), recovering: make(chan struct{}, 4)}
}

func (h *LibraryUploadHandlers) register(r *Router) {
	if h == nil || r.authService == nil {
		return
	}
	if h.writes && h.intake != nil {
		r.mux.HandleFunc("POST "+libraryUploadsPath, privateLibraryResponse(r.withAuth(h.upload), true))
	}
	r.mux.HandleFunc("GET "+libraryUploadsPath+"/{operation_id}", privateLibraryResponse(r.withAuth(h.status), false))
	r.mux.HandleFunc("GET /api/v1/library/tracks/{track_id}", privateLibraryResponse(r.withAuth(h.exactTrack), false))
}

func privateLibraryResponse(next http.HandlerFunc, upload bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "private, no-store")
		w.Header().Set("Content-Type", "application/json")
		if upload && r.ProtoMajor == 1 {
			// A refusal/replay must not drain an untrusted original to send the ACK.
			w.Header().Set("Connection", "close")
			// net/http can still read during final body close. Bound that work
			// even when auth or admission refuses before the upload handler reads.
			if err := http.NewResponseController(w).SetReadDeadline(time.Now().Add(libraryUploadAdmissionDeadline)); err != nil {
				uploadUnavailable(w)
				return
			}
		}
		next(w, r)
	}
}

type libraryUploadStatus struct {
	OperationID uuid.UUID `json:"operation_id"`
	AccountID   uuid.UUID `json:"account_id"`
	Status      string    `json:"status"`
	TrackID     int64     `json:"track_id,omitempty"`
	SHA256      string    `json:"sha256,omitempty"`
	ByteLength  int64     `json:"byte_length,omitempty"`
}

func uploadJSON(w http.ResponseWriter, code int, v any) {
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func uploadUnavailable(w http.ResponseWriter) {
	writeErrorResponse(w, http.StatusServiceUnavailable, "UPLOAD_UNAVAILABLE", "Import status is unavailable; check the same operation")
}

func uploadNotFound(w http.ResponseWriter) {
	writeErrorResponse(w, http.StatusNotFound, "NOT_FOUND", "Not found")
}

func uploadOperationID(raw string) (uuid.UUID, bool) {
	id, err := uuid.Parse(raw)
	return id, err == nil && id != uuid.Nil && id.String() == raw
}

func (h *LibraryUploadHandlers) upload(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil || user.UserID == uuid.Nil {
		writeErrorResponse(w, http.StatusUnauthorized, "UNAUTHORIZED", "Authentication is required")
		return
	}
	keys := r.Header.Values("Idempotency-Key")
	if len(keys) != 1 || r.URL.RawQuery != "" || r.URL.ForceQuery || r.URL.EscapedPath() != libraryUploadsPath {
		writeErrorResponse(w, http.StatusBadRequest, "INVALID_UPLOAD", "Send one upload operation ID and no URL parameters")
		return
	}
	op, valid := uploadOperationID(keys[0])
	if !valid {
		writeErrorResponse(w, http.StatusBadRequest, "INVALID_UPLOAD", "Send a canonical nonzero operation UUID")
		return
	}
	boundary, err := uploadBoundary(r.Header)
	if err != nil {
		writeUploadInputError(w, err)
		return
	}
	if r.ContentLength > db.PrivateImportMaxBytes+libraryUploadEnvelopeBytes {
		writeUploadInputError(w, processor.ErrPrivateIntakeSize)
		return
	}
	select {
	case h.receiving <- struct{}{}:
		defer func() { <-h.receiving }()
	default:
		writeErrorResponse(w, http.StatusServiceUnavailable, "UPLOAD_CAPACITY", "Upload capacity is unavailable")
		return
	}
	controller := http.NewResponseController(w)
	if err := controller.SetReadDeadline(time.Now().Add(libraryUploadBodyDeadline)); err != nil {
		uploadUnavailable(w)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()
	// The request is bounded before reading even its manifest. Keep a deadline
	// on unfinished bodies through net/http's final close; reset only after EOF.
	body := http.MaxBytesReader(w, r.Body, db.PrivateImportMaxBytes+libraryUploadEnvelopeBytes)
	manifest, audio, err := readUploadManifest(body, boundary)
	if err != nil {
		writeUploadInputError(w, err)
		return
	}
	if r.ContentLength > manifest.ByteLength+libraryUploadEnvelopeBytes {
		writeUploadInputError(w, processor.ErrPrivateIntakeSize)
		return
	}
	manifest.OwnerID, manifest.OperationID = user.UserID, op
	audio.onEOF = func() { _ = controller.SetReadDeadline(time.Time{}) }
	receipt, err := h.intake.Import(ctx, manifest, audio)
	switch {
	case err == nil:
		code := http.StatusOK
		if audio.complete {
			// Winner vs same-owner dedupe is already sealed by the canonical SQL
			// transaction. Never guess based on a preflight read or timestamps.
			var winner bool
			findErr := h.database.QueryRowContext(ctx, `SELECT phase='winner' FROM private_import_attempts WHERE owner_id=$1 AND operation_id=$2`, user.UserID, op).Scan(&winner)
			if findErr != nil {
				uploadUnavailable(w)
				return
			}
			if winner {
				code = http.StatusCreated
			}
		}
		writeUploadReceipt(w, code, user.UserID, op, receipt)
	case errors.Is(err, db.ErrPrivateImportStagePending):
		uploadJSON(w, http.StatusAccepted, libraryUploadStatus{AccountID: user.UserID, OperationID: op, Status: "pending"})
	case errors.Is(err, db.ErrPrivateImportIntentConflict), errors.Is(err, db.ErrPrivateImportMetadataReview):
		writeErrorResponse(w, http.StatusConflict, "UPLOAD_CONFLICT", "Operation or Library metadata differs")
	case errors.Is(err, db.ErrPrivateImportStageClosed):
		writeErrorResponse(w, http.StatusConflict, "UPLOAD_CLOSED", "Operation is closed; it cannot be replayed")
	case errors.Is(err, db.ErrPrivateImportStageCapacity):
		writeErrorResponse(w, http.StatusServiceUnavailable, "UPLOAD_CAPACITY", "Upload capacity is unavailable")
	case errors.Is(err, processor.ErrPrivateImportBytes):
		// A stored-object check is never a claim about the client body.
		uploadUnavailable(w)
	case errors.Is(err, processor.ErrPrivateIntakeBytes) && audio.err != nil:
		writeUploadInputError(w, audio.err)
	case errors.Is(err, processor.ErrPrivateIntakeBytes), errors.Is(err, processor.ErrPrivateIntakeSize), errors.Is(err, processor.ErrPrivateIntakeProbe):
		writeUploadInputError(w, err)
	default:
		uploadUnavailable(w)
	}
}

func writeUploadReceipt(w http.ResponseWriter, code int, owner, op uuid.UUID, receipt *db.PrivateImportReceipt) {
	if receipt == nil || receipt.OwnerID != owner || receipt.OperationID != op || receipt.TrackID <= 0 ||
		!uploadHash.MatchString(receipt.SHA256) || receipt.ByteLength <= 0 || receipt.ByteLength > db.PrivateImportMaxBytes {
		uploadUnavailable(w)
		return
	}
	uploadJSON(w, code, libraryUploadStatus{AccountID: owner, OperationID: op, Status: "committed", TrackID: receipt.TrackID, SHA256: receipt.SHA256, ByteLength: receipt.ByteLength})
}

func (h *LibraryUploadHandlers) status(w http.ResponseWriter, r *http.Request) {
	// ServeMux treats HEAD as a GET match. Only deliberate GET can reconcile
	// staged bytes and publish their existing durable operation.
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeErrorResponse(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Check import status with GET")
		return
	}
	owner := auth.GetUserFromContext(r.Context()).UserID
	op, ok := uploadOperationID(r.PathValue("operation_id"))
	if owner == uuid.Nil || !ok || r.URL.EscapedPath() != libraryUploadsPath+"/"+op.String() || r.URL.RawQuery != "" || r.URL.ForceQuery {
		uploadNotFound(w)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 27*time.Second)
	defer cancel()
	receipt, err := h.tracks.GetPrivateImportReceipt(ctx, owner, op)
	if err == nil {
		writeUploadReceipt(w, http.StatusOK, owner, op, receipt)
		return
	}
	if !errors.Is(err, db.ErrPrivateImportNotFound) {
		uploadUnavailable(w)
		return
	}
	// Cheap exact-owner admission precedes bounded object reread. A foreign
	// UUID gets the same response as an unknown UUID, even while slots are full.
	_, receipt, err = h.tracks.LoadPrivateImportStage(ctx, owner, op)
	if err == nil && receipt == nil && h.intake != nil {
		select {
		case h.recovering <- struct{}{}:
			defer func() { <-h.recovering }()
		default:
			uploadUnavailable(w)
			return
		}
		receipt, err = h.intake.Recover(ctx, owner, op)
	}
	state := libraryUploadStatus{AccountID: owner, OperationID: op}
	switch {
	case err == nil && receipt != nil:
		writeUploadReceipt(w, http.StatusOK, owner, op, receipt)
		return
	case err == nil, errors.Is(err, db.ErrPrivateImportStagePending):
		state.Status = "pending"
	case errors.Is(err, db.ErrPrivateImportStageClosed):
		state.Status = "closed"
	case errors.Is(err, db.ErrPrivateImportMetadataReview):
		state.Status = "conflict"
	case errors.Is(err, db.ErrPrivateImportNotFound):
		uploadNotFound(w)
		return
	default:
		uploadUnavailable(w)
		return
	}
	uploadJSON(w, http.StatusOK, state)
}

type libraryUploadTrack struct {
	AccountID  uuid.UUID `json:"account_id"`
	ID         int64     `json:"id"`
	SHA256     string    `json:"sha256"`
	ByteLength int64     `json:"byte_length"`
	Title      string    `json:"title"`
	Artist     string    `json:"artist"`
	Album      string    `json:"album"`
	DurationMS int32     `json:"duration_ms"`
	AddedAt    time.Time `json:"added_at"`
}

func (h *LibraryUploadHandlers) exactTrack(w http.ResponseWriter, r *http.Request) {
	owner := auth.GetUserFromContext(r.Context()).UserID
	raw := r.PathValue("track_id")
	id, err := strconv.ParseInt(raw, 10, 64)
	if owner == uuid.Nil || err != nil || id <= 0 || strconv.FormatInt(id, 10) != raw || r.URL.EscapedPath() != "/api/v1/library/tracks/"+raw || r.URL.RawQuery != "" || r.URL.ForceQuery {
		uploadNotFound(w)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	// Membership, private scope and effective text (the ordinary Library's
	// per-user override merge) come from one snapshot. Never authorize on a
	// historical receipt, a global numeric read, or two independent reads.
	track := libraryUploadTrack{AccountID: owner}
	err = h.database.QueryRowContext(ctx, `SELECT t.id,t.source_file_hash,t.file_size_bytes,
  COALESCE(o.title,t.title),COALESCE(o.artist,t.artist,''),COALESCE(o.album,t.album,''),t.duration_ms,ul.added_at
  FROM user_library ul JOIN tracks t ON t.id=ul.track_id AND t.private_owner_id=ul.user_id
  LEFT JOIN track_metadata_overrides o ON o.track_id=t.id AND o.user_id=ul.user_id
  WHERE ul.user_id=$1 AND t.id=$2 AND t.source_type='library_upload'`, owner, id).Scan(&track.ID, &track.SHA256, &track.ByteLength, &track.Title, &track.Artist, &track.Album, &track.DurationMS, &track.AddedAt)
	if errors.Is(err, sql.ErrNoRows) {
		uploadNotFound(w)
		return
	}
	if err != nil || !uploadHash.MatchString(track.SHA256) || track.ByteLength <= 0 || track.ByteLength > db.PrivateImportMaxBytes || track.DurationMS <= 0 {
		uploadUnavailable(w)
		return
	}
	uploadJSON(w, http.StatusOK, track)
}
