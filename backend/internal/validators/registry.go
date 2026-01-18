package validators

import "sync"

// Registry manages URL validators
type Registry struct {
	mu         sync.RWMutex
	validators []Validator
}

// NewRegistry creates a new validator registry
func NewRegistry() *Registry {
	return &Registry{
		validators: make([]Validator, 0),
	}
}

// Register adds a validator to the registry
func (r *Registry) Register(v Validator) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.validators = append(r.validators, v)
}

// Validate finds the appropriate validator and validates the URL
func (r *Registry) Validate(url string) ValidationResult {
	r.mu.RLock()
	defer r.mu.RUnlock()

	for _, v := range r.validators {
		if v.CanHandle(url) {
			return v.Validate(url)
		}
	}

	return ValidationResult{
		Valid:      false,
		SourceType: SourceUnknown,
		URL:        url,
		Error:      "unsupported URL format",
	}
}

// GetSupportedSources returns all source types registered in the registry
func (r *Registry) GetSupportedSources() []SourceType {
	r.mu.RLock()
	defer r.mu.RUnlock()

	sources := make([]SourceType, 0, len(r.validators))
	for _, v := range r.validators {
		sources = append(sources, v.SourceType())
	}
	return sources
}

// DefaultRegistry creates a registry with all built-in validators
func DefaultRegistry() *Registry {
	r := NewRegistry()
	r.Register(NewYouTubeValidator())
	r.Register(NewSoundCloudValidator())
	return r
}
