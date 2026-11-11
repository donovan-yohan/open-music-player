package download

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// SourceCompletion is SQL's committed terminal receipt, not a worker retry.
type SourceCompletion struct {
	TrackID     int64
	CompletedAt time.Time
	// Unplayable is an internal recovery fact, never a new wire status.
	// SQL remains complete; the Redis projection must not advertise playback.
	Unplayable bool
}

var restoreSourceCompletionScript = redis.NewScript(`
local raw=redis.call('GET',KEYS[1])
if not raw then return 0 end
local current=cjson.decode(raw)
local expected=cjson.decode(ARGV[1])
if current.id~=expected.id or current.user_id~=expected.user_id or current.url~=expected.url or current.source_type~=expected.source_type or (current.source_id or '')~=(expected.source_id or '') or (current.candidate_id or '')~=(expected.candidate_id or '') then
 return redis.error_reply('source completion identity conflict')
end
if ARGV[2]=='unplayable' then
 current.status='failed'
 current.progress=0
 current.error='Completed acquisition is no longer playable in Library'
 current.track_id=nil
else
 current.status='complete'
 current.progress=100
 current.error=nil
 current.track_id=expected.track_id
end
current.updated_at=expected.updated_at
current.completed_at=expected.completed_at
redis.call('SET',KEYS[1],cjson.encode(current))
redis.call('LREM',KEYS[2],0,current.id)
return 1
`)

// ReconcileCompletedSourceJobs repairs a crash after SQL completion but before
// Redis completion. Scan all Redis projections (including terminal stale copies), not a bounded
// page of historical SQL completions, which could starve the interrupted job.
// The server invokes this before workers start; lookup must verify SQL ownership
// and captured source identity. Missing/legacy/noncomplete jobs return nil.
func (s *Service) ReconcileCompletedSourceJobs(ctx context.Context, lookup func(context.Context, *DownloadJob) (*SourceCompletion, error)) error {
	iter := s.queue.client.Scan(ctx, 0, keyJobStatus+"*", 100).Iterator()
	for iter.Next(ctx) {
		data, err := s.queue.client.Get(ctx, iter.Val()).Bytes()
		if errors.Is(err, redis.Nil) {
			continue
		}
		if err != nil {
			return err
		}
		var job DownloadJob
		if err = json.Unmarshal(data, &job); err != nil {
			return err
		}
		if iter.Val() != keyJobStatus+job.ID {
			return errors.New("source completion job key conflict")
		}
		receipt, err := lookup(ctx, &job)
		if err != nil {
			return err
		}
		if receipt == nil {
			continue
		}
		if receipt.TrackID <= 0 || receipt.CompletedAt.IsZero() {
			return errors.New("invalid source completion receipt")
		}
		job.TrackID = &receipt.TrackID
		job.CompletedAt = &receipt.CompletedAt
		job.UpdatedAt = time.Now()
		payload, err := json.Marshal(&job)
		if err != nil {
			return err
		}
		policy := "playable"
		if receipt.Unplayable {
			policy = "unplayable"
		}
		if err = restoreSourceCompletionScript.Run(ctx, s.queue.client, []string{keyJobStatus + job.ID, keyJobQueue}, string(payload), policy).Err(); err != nil {
			return fmt.Errorf("restore source completion: %w", err)
		}
	}
	return iter.Err()
}
