package connect

import (
	"context"
	"github.com/google/uuid"
	"time"
)

func (s *Service) Report(ctx context.Context, owner uuid.UUID, generation int64, id string, req ReportRequest) (Device, error) {
	var result Device
	hash, err := writerHash(req.WriterSecret)
	if err != nil {
		return result, err
	}
	if !ValidID(id) || !ValidID(req.LeaseID) || req.Sequence < 1 || req.Sequence > MaxInteger {
		return result, ErrInvalid
	}
	if err = validatePlayback(req.Playback); err != nil {
		return result, err
	}
	// The typed request projection contains no arbitrary source maps or extras;
	// only its canonical playback digest participates in sequence idempotency.
	reportDigest := digest(req.Playback)
	err = s.mutate(ctx, owner, generation, func(records map[string]record, now time.Time) (bool, error) {
		existing, ok := records[id]
		if !ok {
			return false, ErrGone
		}
		if err := proof(existing, req.LeaseID, hash); err != nil {
			return false, err
		}
		if req.Sequence < existing.Device.Sequence {
			return false, ErrStale
		}
		if req.Sequence == existing.Device.Sequence {
			if existing.Digest != reportDigest {
				return false, ErrStale
			}
			result = existing.Device
			return false, nil
		}
		if existing.Device.Sequence > 0 && now.Sub(existing.Device.LastSeenAt) < time.Second {
			return false, ErrRate
		}
		existing.Device.Sequence = req.Sequence
		existing.Device.Playback = req.Playback
		existing.Device.LastSeenAt = now
		existing.Device.LeaseExpiresAt = now.Add(LeaseTTL)
		existing.Digest = reportDigest
		records[id] = existing
		result = existing.Device
		return true, nil
	})
	return result, err
}
func (s *Service) Remove(ctx context.Context, owner uuid.UUID, generation int64, id string, req Proof) error {
	hash, err := writerHash(req.WriterSecret)
	if err != nil {
		return err
	}
	if !ValidID(id) || !ValidID(req.LeaseID) {
		return ErrInvalid
	}
	return s.mutate(ctx, owner, generation, func(records map[string]record, now time.Time) (bool, error) {
		existing, ok := records[id]
		if !ok {
			return false, nil
		}
		if err := proof(existing, req.LeaseID, hash); err != nil {
			return false, err
		}
		delete(records, id)
		return true, nil
	})
}
