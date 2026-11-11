package download

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestSourceCompletionAtomicRetirement(t *testing.T) {
	if os.Getenv("REDIS_URL") == "" {
		t.Skip("requires explicitly owned Redis")
	}
	for _, unplayable := range []bool{false, true} {
		policy := "playable"
		if unplayable {
			policy = "unplayable"
		}
		for _, variant := range []string{"metadata", "owner", "source", "candidate", "url", "key", "unrelated"} {
			t.Run(policy+"/"+variant, func(t *testing.T) {
				ctx := context.Background()
				q, err := NewQueue(os.Getenv("REDIS_URL"))
				if err != nil {
					t.Fatal(err)
				}
				defer q.Close()
				job, err := q.EnqueueCandidate(ctx, "owner", SourceCandidate{CandidateID: "youtube:proof", Provider: "youtube", SourceID: "proof", SourceURL: "https://example.invalid/proof"}, nil)
				if err != nil {
					t.Fatal(err)
				}
				defer q.client.Del(ctx, keyJobStatus+job.ID)
				defer q.client.LRem(ctx, keyJobQueue, 0, job.ID)
				if err = q.client.LPush(ctx, keyJobQueue, job.ID, job.ID).Err(); err != nil {
					t.Fatal(err)
				}
				// A complete Redis projection may still have stale runnable list copies.
				job.Status = StatusComplete
				id := job.ID
				if variant == "key" {
					job.ID = "embedded-wrong-id"
				}
				raw, err := json.Marshal(job)
				if err != nil {
					t.Fatal(err)
				}
				if err = q.client.Set(ctx, keyJobStatus+id, raw, 0).Err(); err != nil {
					t.Fatal(err)
				}
				completed := time.Now().UTC()
				err = (&Service{queue: q}).ReconcileCompletedSourceJobs(ctx, func(ctx context.Context, scanned *DownloadJob) (*SourceCompletion, error) {
					// Other packages share this Redis; only this test's job may be
					// reconciled or counted.
					if variant == "unrelated" || scanned.ID != id {
						return nil, nil
					}
					current, e := q.GetJob(ctx, id)
					if e != nil {
						return nil, e
					}
					current.RetryCount = 7
					current.PlaylistID = 123
					switch variant {
					case "owner":
						current.UserID = "forged-owner"
					case "source":
						current.SourceID = "forged-source"
					case "candidate":
						current.CandidateID = "forged-candidate"
					case "url":
						current.URL = "https://example.invalid/forged"
					}
					if e = q.saveJob(ctx, current); e != nil {
						return nil, e
					}
					return &SourceCompletion{TrackID: 42, CompletedAt: completed, Unplayable: unplayable}, nil
				})
				current, e := q.GetJob(ctx, id)
				if e != nil {
					t.Fatal(e)
				}
				positions, e := q.client.LPosCount(ctx, keyJobQueue, id, 0, redis.LPosArgs{}).Result()
				if e != nil {
					t.Fatal(e)
				}
				count := len(positions)
				if variant != "metadata" {
					if variant == "unrelated" {
						if err != nil {
							t.Fatal(err)
						}
					} else if err == nil {
						t.Fatal("identity conflict accepted")
					}
					if count != 3 || current.TrackID != nil {
						t.Fatalf("refusal mutated receipt/list: %d %+v", count, current)
					}
					return
				}
				if err != nil {
					t.Fatal(err)
				}
				if count != 0 || current.CompletedAt == nil || !current.CompletedAt.Equal(completed) || current.RetryCount != 7 || current.PlaylistID != 123 {
					t.Fatalf("non-atomic/lost metadata restoration: %d %+v", count, current)
				}
				if unplayable {
					if current.Status != StatusFailed || current.TrackID != nil {
						t.Fatalf("unplayable receipt: %+v", current)
					}
				} else if current.Status != StatusComplete || current.TrackID == nil || *current.TrackID != 42 {
					t.Fatalf("playable receipt: %+v", current)
				}
			})
		}
	}
}
