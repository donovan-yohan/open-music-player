package download

// A finite explicit sync acquisition is background work. Foreground preparation
// always wins dequeue selection; sync service also limits outstanding work to one.
func downloadQueueKey(job *DownloadJob) string {
	if job != nil && job.Metadata != nil && job.Metadata["manualSync"] == true {
		return keyJobQueue + ":manual-sync"
	}
	return keyJobQueue
}
