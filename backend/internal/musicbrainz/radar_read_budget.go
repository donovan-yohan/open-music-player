package musicbrainz

import "context"

type radarReadBudgetKey struct{}

// WithRadarReadBudget opts only this read into the feed's fixed response/retry
// ceiling. It never changes ordinary search/matcher defaults or pacing.
func WithRadarReadBudget(ctx context.Context) context.Context {
	return context.WithValue(ctx, radarReadBudgetKey{}, true)
}
func radarReadBounded(ctx context.Context) bool { return ctx.Value(radarReadBudgetKey{}) == true }
