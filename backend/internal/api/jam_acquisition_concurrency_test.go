package api

import (
	"context"
	"os"
	"sync"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/download"
)

func TestJamAcquisitionConcurrentPublicationExactlyOneRedisEntry(t *testing.T) {
	_, o, _, _ := jamIntegration(t) // Same protected/disposable SQL+Redis guard.
	ctx := context.Background()
	service, e := download.NewService(&download.ServiceConfig{RedisURL: "redis://" + os.Getenv("JAM_TEST_REDIS") + "/0", WorkerCount: 0}, nil)
	if e != nil {
		t.Fatal(e)
	}
	defer service.Queue().Close()
	id := uuid.NewString()
	client := service.Queue().Client()
	defer client.LRem(ctx, "download:queue", 0, id)
	defer client.Del(ctx, "download:job:"+id)
	c := download.SourceCandidate{CandidateID: "youtube:synthetic-concurrent", Provider: "youtube", SourceID: "synthetic-concurrent", SourceURL: "https://www.youtube.com/watch?v=synthetic-concurrent", Title: "Synthetic concurrency"}
	var wg sync.WaitGroup
	start := make(chan struct{})
	errs := make(chan error, 32)
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, err := service.EnsureSourceCandidateWithID(ctx, id, o.UserID.String(), c, nil)
			errs <- err
		}()
	}
	close(start)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	list, e := client.LRange(ctx, "download:queue", 0, -1).Result()
	if e != nil {
		t.Fatal(e)
	}
	count := 0
	for _, item := range list {
		if item == id {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("concurrent ensure published %d entries for ONE durable job", count)
	}
	// An approval retry is not boot recovery and cannot republish active work.
	if e = client.LRem(ctx, "download:queue", 0, id).Err(); e != nil {
		t.Fatal(e)
	}
	if e = service.Queue().UpdateStatus(ctx, id, download.StatusDownloading, 1, ""); e != nil {
		t.Fatal(e)
	}
	if _, e = service.EnsureSourceCandidateWithID(ctx, id, o.UserID.String(), c, nil); e != nil {
		t.Fatal(e)
	}
	list, e = client.LRange(ctx, "download:queue", 0, -1).Result()
	if e != nil {
		t.Fatal(e)
	}
	for _, item := range list {
		if item == id {
			t.Fatal("HTTP retry republished in-flight work")
		}
	}
	// A repeated source decision is a request path too: it may adopt a target
	// playlist but must not hand the claimed job to a second worker.
	if _, e = service.EnsureSourceCandidateForPlaylistWithID(ctx, id, o.UserID.String(), c, nil, 7); e != nil {
		t.Fatal(e)
	}
	list, e = client.LRange(ctx, "download:queue", 0, -1).Result()
	if e != nil {
		t.Fatal(e)
	}
	for _, item := range list {
		if item == id {
			t.Fatal("source-decision retry republished in-flight work")
		}
	}
	if job, e := service.Queue().GetJob(ctx, id); e != nil || job.Status != download.StatusDownloading || job.PlaylistID != 7 {
		t.Fatalf("source-decision retry changed claimed job: %+v %v", job, e)
	}
	// Only boot recovery, before workers start, restores in-flight work.
	if _, e = service.RecoverSourceCandidateForPlaylistWithID(ctx, id, o.UserID.String(), c, nil, 0); e != nil {
		t.Fatal(e)
	}
	list, e = client.LRange(ctx, "download:queue", 0, -1).Result()
	if e != nil {
		t.Fatal(e)
	}
	count = 0
	for _, item := range list {
		if item == id {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("boot in-flight recovery entries %d", count)
	}
}
