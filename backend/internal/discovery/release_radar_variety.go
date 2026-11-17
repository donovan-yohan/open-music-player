package discovery

// radarVariety consumes date/ID ordered, freshly unowned candidates. Stable
// iteration is the final originalDateIdIndex tie-breaker. Counts demote repeats
// progressively; they never exclude an album or artist. Only the existing seed
// credits are evidence, not full collaboration affinity or personal relevance.
func radarVariety(candidates []RadarSong) []RadarSong {
	remaining := append([]RadarSong{}, candidates...)
	ordered := make([]RadarSong, 0, len(remaining))
	albums, artists := map[string]int{}, map[string]int{}
	for len(remaining) > 0 {
		best, bestAlbum, bestArtist := 0, 0, 0
		for i, song := range remaining {
			album := albums[radarAlbumKey(song)]
			artist := 0
			for _, id := range song.CreditedSeedArtistMbids {
				if artists[id] > artist {
					artist = artists[id]
				}
			}
			if i == 0 || album < bestAlbum || (album == bestAlbum && artist < bestArtist) {
				best, bestAlbum, bestArtist = i, album, artist
			}
		}
		song := remaining[best]
		ordered = append(ordered, song)
		albums[radarAlbumKey(song)]++
		for _, id := range song.CreditedSeedArtistMbids {
			artists[id]++
		}
		remaining = append(remaining[:best], remaining[best+1:]...)
	}
	return ordered
}

func radarAlbumKey(song RadarSong) string {
	if radarID(song.ReleaseGroupMbid) {
		return "group:" + song.ReleaseGroupMbid
	}
	if radarID(song.ReleaseMbid) {
		return "release:" + song.ReleaseMbid
	}
	return "unknown-recording:" + song.RecordingMbid
}
