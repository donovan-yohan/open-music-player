package jam

import (
	"context"
	"time"
)

// PurgeRetired is a bounded housekeeping batch for the parent's existing
// maintenance loop. Authorization/expiry predicates never depend on this job.
func (r *Repository) PurgeRetired(ctx context.Context) (int64, error) {
	cutoff := r.Now().UTC().Add(-24 * time.Hour)
	result, e := r.DB.ExecContext(ctx, `DELETE FROM jams WHERE id IN (SELECT id FROM jams WHERE expires_at<$1 OR closed_at<$1 ORDER BY expires_at LIMIT 100 FOR UPDATE SKIP LOCKED)`, cutoff)
	if e != nil {
		return 0, e
	}
	return result.RowsAffected()
}
