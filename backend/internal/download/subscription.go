package download

import (
	"encoding/json"

	"github.com/redis/go-redis/v9"
)

// ProgressSubscription wraps a Redis pub/sub subscription for progress events
type ProgressSubscription struct {
	pubsub *redis.PubSub
	ch     <-chan *redis.Message
}

// Channel returns a channel that receives job progress updates
func (s *ProgressSubscription) Channel() <-chan *DownloadJob {
	jobCh := make(chan *DownloadJob)

	go func() {
		defer close(jobCh)
		for msg := range s.ch {
			var job DownloadJob
			if err := json.Unmarshal([]byte(msg.Payload), &job); err != nil {
				continue
			}
			jobCh <- &job
		}
	}()

	return jobCh
}

// Close closes the subscription
func (s *ProgressSubscription) Close() error {
	return s.pubsub.Close()
}
