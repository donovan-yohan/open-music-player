package connect

import (
	"context"
	"time"

	"github.com/google/uuid"
)

// ValidateWriter proves the exact live device incarnation without reporting,
// renewing presence, or advancing sequence. SQL generation authority remains
// with the caller; Redis namespaces provide an additional generation fence.
func (s *Service) ValidateWriter(ctx context.Context, owner uuid.UUID, generation int64, deviceID, leaseID, writerSecret string) error {
	hash, err := writerHash(writerSecret)
	if err != nil {
		return err
	}
	if !ValidID(deviceID) || !ValidID(leaseID) {
		return ErrInvalid
	}
	return s.mutate(ctx, owner, generation, func(records map[string]record, _ time.Time) (bool, error) {
		existing, ok := records[deviceID]
		if !ok {
			return false, ErrGone
		}
		return false, proof(existing, leaseID, hash)
	})
}
