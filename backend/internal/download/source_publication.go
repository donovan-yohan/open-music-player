package download

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

// Atomic missing-job publication and list repair. An HTTP retry must not rewind
// or republish a live worker's in-flight job. Boot recovery explicitly opts into
// restoring in-flight jobs before its workers start.
var ensureSourceScript = redis.NewScript(`
local fresh=cjson.decode(ARGV[1])
local raw=redis.call('GET',KEYS[1])
local job=fresh
if raw then
 job=cjson.decode(raw)
 if job.user_id~=fresh.user_id then return redis.error_reply('source job owner conflict') end
 if job.status=='complete' or job.status=='failed' then return raw end
 if job.url~=fresh.url or job.source_type~=fresh.source_type or (job.source_id or '')~=(fresh.source_id or '') or (job.candidate_id or '')~=(fresh.candidate_id or '') then
  return redis.error_reply('source job identity conflict')
 end
 if fresh.playlist_id and not job.playlist_id then
  job.playlist_id=fresh.playlist_id
  job.updated_at=fresh.updated_at
  raw=cjson.encode(job)
  redis.call('SET',KEYS[1],raw)
 end
else
 raw=ARGV[1]
 redis.call('SET',KEYS[1],raw)
end
if (not redis.call('LPOS',KEYS[2],fresh.id)) and (not raw or job.status=='queued' or ARGV[2]=='1') then
 redis.call('LPUSH',KEYS[2],fresh.id)
end
return raw
`)

func (q *Queue) ensureSourceAtomic(ctx context.Context, jobID, userID string, c SourceCandidate, mb *string, playlistID int64, recoverInFlight bool) (*DownloadJob, error) {
	if jobID == "" {
		jobID = uuid.NewString()
	}
	now := time.Now()
	job := &DownloadJob{ID: jobID, UserID: userID, URL: c.SourceURL, SourceType: c.Provider, Status: StatusQueued, CandidateID: c.CandidateID, SourceID: c.SourceID, Title: c.Title, Artist: c.Artist, Album: c.Album, Uploader: c.Uploader, DurationMs: c.DurationMs, ThumbnailURL: c.ThumbnailURL, Metadata: c.Metadata, MBRecordingID: mb, PlaylistID: playlistID, CreatedAt: now, UpdatedAt: now}
	data, e := json.Marshal(job)
	if e != nil {
		return nil, e
	}
	recoverFlag := "0"
	if recoverInFlight {
		recoverFlag = "1"
	}
	raw, e := ensureSourceScript.Run(ctx, q.client, []string{keyJobStatus + jobID, keyJobQueue}, string(data), recoverFlag).Text()
	if e != nil {
		return nil, fmt.Errorf("ensure source job: %w", e)
	}
	if e = json.Unmarshal([]byte(raw), job); e != nil {
		return nil, e
	}
	return job, nil
}
