package playlistsync

import (
	"context"
	"fmt"
	"sort"
	"strings"
)

// Reconciler joins provider resolution to the future persistence seam. Planning
// remains pure so callers can test or inspect a plan before any integration is
// added.
type Reconciler struct {
	adapter SourceAdapter
	store   Store
}

func NewReconciler(adapter SourceAdapter, store Store) *Reconciler {
	return &Reconciler{adapter: adapter, store: store}
}

// Reconcile resolves a source, rejects incomplete snapshots before reading or
// applying mutations, and applies a plan only when it changes membership/order.
func (r *Reconciler) Reconcile(ctx context.Context, playlistID int64, sourceURL string) (Result, error) {
	if playlistID <= 0 {
		return Result{}, ErrInvalidPlaylistID
	}
	if r.adapter == nil {
		return Result{}, ErrMissingAdapter
	}
	if r.store == nil {
		return Result{}, ErrMissingStore
	}

	snapshot, err := r.adapter.Resolve(ctx, sourceURL)
	if err != nil {
		return Result{}, err
	}
	if err := ValidateComplete(snapshot); err != nil {
		return Result{}, err
	}

	mappings, err := r.store.ListSourceEntryMappings(ctx, playlistID, snapshot.Source)
	if err != nil {
		return Result{}, err
	}
	plan, err := PlanReconciliation(snapshot, mappings)
	if err != nil {
		return Result{}, err
	}
	result := resultForPlan(plan)
	if plan.Noop {
		return result, nil
	}
	if err := r.store.ApplyReconciliation(ctx, playlistID, plan); err != nil {
		return Result{}, err
	}
	return result, nil
}

// PlanReconciliation normalizes a complete source snapshot and compares it to
// existing source-entry mappings. It does not mutate its inputs.
func PlanReconciliation(snapshot Snapshot, mappings []SourceEntryMapping) (ReconciliationPlan, error) {
	if err := ValidateComplete(snapshot); err != nil {
		return ReconciliationPlan{}, err
	}

	stored, err := normalizedMappings(mappings)
	if err != nil {
		return ReconciliationPlan{}, err
	}
	entries, duplicates := firstStableEntries(snapshot.Entries)
	desiredIDs := make([]string, 0, len(entries))
	desired := make(map[string]Entry, len(entries))
	for _, entry := range entries {
		desiredIDs = append(desiredIDs, entry.StableID)
		desired[entry.StableID] = entry
	}

	plan := ReconciliationPlan{
		Source:            snapshot.Source,
		OrderedEntryIDs:   desiredIDs,
		SkippedDuplicates: duplicates,
	}
	existingOrder := make([]string, 0, len(stored.ordered))
	desiredExistingOrder := make([]string, 0, len(stored.ordered))
	for _, mapping := range stored.ordered {
		if _, exists := desired[mapping.StableEntryID]; exists {
			existingOrder = append(existingOrder, mapping.StableEntryID)
		}
	}
	for _, stableID := range desiredIDs {
		if _, exists := stored.byID[stableID]; exists {
			desiredExistingOrder = append(desiredExistingOrder, stableID)
			continue
		}
		plan.Additions = append(plan.Additions, desired[stableID])
	}
	for _, mapping := range stored.ordered {
		if _, exists := desired[mapping.StableEntryID]; !exists {
			plan.MembershipRemovals = append(plan.MembershipRemovals, mapping)
		}
	}
	plan.Reordered = !sameStrings(existingOrder, desiredExistingOrder)
	plan.Noop = len(plan.Additions) == 0 && len(plan.MembershipRemovals) == 0 && !plan.Reordered
	return plan, nil
}

type mappingSet struct {
	ordered []SourceEntryMapping
	byID    map[string]SourceEntryMapping
}

func normalizedMappings(mappings []SourceEntryMapping) (mappingSet, error) {
	ordered := append([]SourceEntryMapping(nil), mappings...)
	sort.SliceStable(ordered, func(left, right int) bool {
		if ordered[left].Position != ordered[right].Position {
			return ordered[left].Position < ordered[right].Position
		}
		return ordered[left].StableEntryID < ordered[right].StableEntryID
	})
	byID := make(map[string]SourceEntryMapping, len(ordered))
	for _, mapping := range ordered {
		if strings.TrimSpace(mapping.StableEntryID) == "" ||
			strings.TrimSpace(mapping.StableEntryID) != mapping.StableEntryID {
			return mappingSet{}, fmt.Errorf("%w: empty stable entry ID", ErrInvalidMappings)
		}
		if _, exists := byID[mapping.StableEntryID]; exists {
			return mappingSet{}, fmt.Errorf("%w: duplicate stable entry ID %q", ErrInvalidMappings, mapping.StableEntryID)
		}
		byID[mapping.StableEntryID] = mapping
	}
	return mappingSet{ordered: ordered, byID: byID}, nil
}

func firstStableEntries(entries []Entry) ([]Entry, []SkippedDuplicate) {
	firstPositions := make(map[string]int, len(entries))
	unique := make([]Entry, 0, len(entries))
	duplicates := make([]SkippedDuplicate, 0)
	for position, entry := range entries {
		if firstPosition, exists := firstPositions[entry.StableID]; exists {
			duplicates = append(duplicates, SkippedDuplicate{
				StableEntryID:     entry.StableID,
				FirstPosition:     firstPosition,
				DuplicatePosition: position,
			})
			continue
		}
		firstPositions[entry.StableID] = position
		unique = append(unique, entry)
	}
	return unique, duplicates
}

func resultForPlan(plan ReconciliationPlan) Result {
	return Result{
		Noop:              plan.Noop,
		Added:             len(plan.Additions),
		Removed:           len(plan.MembershipRemovals),
		Reordered:         plan.Reordered,
		Reused:            len(plan.OrderedEntryIDs) - len(plan.Additions),
		SkippedDuplicates: len(plan.SkippedDuplicates),
	}
}

func sameStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
