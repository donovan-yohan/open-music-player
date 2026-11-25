package musicbrainz

import (
	"testing"
	"testing/synctest"
)

// Isolate unrelated serial fixtures, not requests within a fixture. Keep
// the original URLs and let production allocate slots and enforce cooldowns
// for every origin, including redirect destinations. Do not run in parallel
// with tests that use the shared registry.
func isolateFixtureBudgets(t *testing.T) {
	t.Helper()
	providerBudgets.Lock()
	previous := providerBudgets.origins
	providerBudgets.origins = make(map[string]*requestBudget)
	providerBudgets.Unlock()
	t.Cleanup(func() {
		providerBudgets.Lock()
		defer providerBudgets.Unlock()
		providerBudgets.origins = previous
	})
}

// Controlled transports and their timers run entirely inside the bubble.
// Allocate the budgets there too; never carry a real-clock timestamp or a
// synctest channel over to another case. Keep socket-based fixtures outside.
func withFixtureClock(t *testing.T, run func(*testing.T)) {
	t.Helper()
	isolateFixtureBudgets(t)
	synctest.Test(t, run)
}
