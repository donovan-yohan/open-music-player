package connect

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

type Service struct{ client *redis.Client }

func NewService(client *redis.Client) *Service { return &Service{client: client} }
func key(owner uuid.UUID, generation int64) string {
	return "connect:v1:" + owner.String() + ":" + strconv.FormatInt(generation, 10)
}

type record struct {
	Device     Device `json:"device"`
	WriterHash string `json:"writerHash"`
	Digest     string `json:"digest"`
}

// mutate serializes the bounded map. Redis TIME, not client time, decides expiry.
// Read and replay paths never SET and thus never extend the key's lifetime.
func (s *Service) mutate(ctx context.Context, owner uuid.UUID, generation int64, fn func(map[string]record, time.Time) (bool, error)) error {
	if s == nil || s.client == nil {
		return ErrUnavailable
	}
	if owner == uuid.Nil || generation < 0 {
		return ErrInvalid
	}
	k := key(owner, generation)
	for attempts := 0; attempts < 128; attempts++ {
		err := s.client.Watch(ctx, func(tx *redis.Tx) error {
			raw, err := tx.Get(ctx, k).Bytes()
			if err != nil && err != redis.Nil {
				return err
			}
			records := map[string]record{}
			if err == nil {
				if err = json.Unmarshal(raw, &records); err != nil {
					return err
				}
			}
			if records == nil || len(records) > 8 {
				return ErrUnavailable
			}
			now, err := tx.Time(ctx).Result()
			if err != nil {
				return err
			}
			now = now.UTC().Truncate(time.Millisecond)
			for id, r := range records {
				if !now.Before(r.Device.LeaseExpiresAt) {
					delete(records, id)
				}
			}
			changed, err := fn(records, now)
			if err != nil {
				return err
			}
			if !changed {
				return nil
			}
			encoded, err := json.Marshal(records)
			if err != nil {
				return err
			}
			_, err = tx.TxPipelined(ctx, func(pipe redis.Pipeliner) error {
				if len(records) == 0 {
					pipe.Del(ctx, k)
				} else {
					var latest time.Time
					for _, r := range records {
						if r.Device.LeaseExpiresAt.After(latest) {
							latest = r.Device.LeaseExpiresAt
						}
					}
					pipe.Set(ctx, k, encoded, latest.Sub(now))
				}
				return nil
			})
			return err
		}, k)
		if err == redis.TxFailedErr {
			continue
		}
		if err == nil {
			return nil
		}
		if errors.Is(err, ErrConflict) || errors.Is(err, ErrCapacity) || errors.Is(err, ErrGone) || errors.Is(err, ErrWriter) || errors.Is(err, ErrStale) || errors.Is(err, ErrRate) || errors.Is(err, ErrInvalid) {
			return err
		}
		return ErrUnavailable
	}
	return ErrUnavailable
}
func ValidID(id string) bool {
	u, err := uuid.Parse(id)
	return err == nil && u != uuid.Nil && u.String() == id
}
func validText(s string, min, max int) bool {
	return utf8.ValidString(s) && len(s) >= min && len(s) <= max
}
func writerHash(secret string) (string, error) {
	raw, err := base64.RawURLEncoding.DecodeString(secret)
	if err != nil || len(raw) != 32 || base64.RawURLEncoding.EncodeToString(raw) != secret {
		return "", ErrInvalid
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}
func (s *Service) Register(ctx context.Context, owner uuid.UUID, generation int64, req RegisterRequest) (Device, error) {
	var result Device
	hash, err := writerHash(req.WriterSecret)
	if err != nil {
		return result, err
	}
	if !ValidID(req.DeviceID) || !validText(req.Label, 1, 64) {
		return result, ErrInvalid
	}
	switch req.Platform {
	case "android", "ios", "macos", "windows", "linux", "web":
	default:
		return result, ErrInvalid
	}
	err = s.mutate(ctx, owner, generation, func(records map[string]record, now time.Time) (bool, error) {
		if existing, ok := records[req.DeviceID]; ok {
			if subtle.ConstantTimeCompare([]byte(hash), []byte(existing.WriterHash)) != 1 || existing.Device.Label != req.Label || existing.Device.Platform != req.Platform {
				return false, ErrConflict
			}
			result = existing.Device
			return false, nil
		}
		if len(records) >= 8 {
			return false, ErrCapacity
		}
		result = Device{DeviceID: req.DeviceID, LeaseID: uuid.NewString(), Label: req.Label, Platform: req.Platform, LastSeenAt: now, LeaseExpiresAt: now.Add(LeaseTTL)}
		records[req.DeviceID] = record{Device: result, WriterHash: hash}
		return true, nil
	})
	return result, err
}
func (s *Service) List(ctx context.Context, owner uuid.UUID, generation int64) ([]Device, time.Time, error) {
	devices := []Device{}
	var serverTime time.Time
	err := s.mutate(ctx, owner, generation, func(records map[string]record, now time.Time) (bool, error) {
		devices = devices[:0]
		serverTime = now
		for _, r := range records {
			devices = append(devices, r.Device)
		}
		return false, nil
	})
	sort.Slice(devices, func(i, j int) bool { return devices[i].DeviceID < devices[j].DeviceID })
	return devices, serverTime, err
}

func validatePlayback(p *Playback) error {
	if p == nil {
		return nil
	}
	if !validText(p.SessionID, 1, 128) || (p.QueueItemID != nil && !validText(*p.QueueItemID, 1, 128)) || !validText(p.Track.Title, 0, 200) || !validText(p.Track.Artist, 0, 200) {
		return ErrInvalid
	}
	if p.Track.TrackID != nil && (*p.Track.TrackID < 1 || *p.Track.TrackID > MaxInteger) {
		return ErrInvalid
	}
	if p.PositionMs < 0 || p.PositionMs > MaxInteger || p.DurationMs < 0 || p.DurationMs > MaxInteger || p.ActiveVoiceCount < 0 || p.ActiveVoiceCount > 4 {
		return ErrInvalid
	}
	switch p.ProcessingState {
	case "idle", "loading", "buffering", "ready", "completed":
		return nil
	}
	return ErrInvalid
}
func proof(r record, lease, hash string) error {
	if r.Device.LeaseID != lease {
		return ErrGone
	}
	if subtle.ConstantTimeCompare([]byte(hash), []byte(r.WriterHash)) != 1 {
		return ErrWriter
	}
	return nil
}
func digest(p *Playback) string {
	raw, _ := json.Marshal(p)
	sum := sha256.Sum256(raw)
	return fmt.Sprintf("%x", sum)
}
