package musicbrainz

import "context"

type interactiveCatalogReadKey struct{}

// WithInteractiveCatalogRead limits a small interactive search page to a single
// upstream attempt and a bounded response. The caller owns the wall-clock
// deadline; all attempts still use the shared MusicBrainz pacing owner.
func WithInteractiveCatalogRead(ctx context.Context) context.Context {
	return context.WithValue(ctx, interactiveCatalogReadKey{}, true)
}

func interactiveCatalogRead(ctx context.Context) bool {
	return ctx.Value(interactiveCatalogReadKey{}) == true
}
