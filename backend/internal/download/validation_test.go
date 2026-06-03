package download

import "testing"

func TestValidateUserFacingURLAllowsOnlyAbsoluteHTTPURLs(t *testing.T) {
	cases := []struct {
		name    string
		raw     string
		wantErr bool
	}{
		{name: "https", raw: "https://example.test/watch?v=1"},
		{name: "uppercase http", raw: "HTTP://example.test/watch?v=1"},
		{name: "file", raw: "file:///etc/passwd", wantErr: true},
		{name: "fixture", raw: "fixture://silence", wantErr: true},
		{name: "protocol relative", raw: "//example.test/watch", wantErr: true},
		{name: "relative", raw: "/watch?v=1", wantErr: true},
		{name: "missing host", raw: "https:///watch", wantErr: true},
		{name: "blank", raw: "   ", wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := ValidateUserFacingURL(tc.raw)
			if tc.wantErr && err == nil {
				t.Fatalf("ValidateUserFacingURL(%q) succeeded, want error", tc.raw)
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("ValidateUserFacingURL(%q) = %v, want nil", tc.raw, err)
			}
		})
	}
}
