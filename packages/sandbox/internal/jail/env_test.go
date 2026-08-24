package jail

import (
	"reflect"
	"testing"
)

func TestFilterEnv(t *testing.T) {
	cases := []struct {
		name      string
		requested map[string]string
		allow     []string
		want      []string
	}{
		{
			name:      "allowlist filters and sorts",
			requested: map[string]string{"PATH": "/bin", "HOME": "/root", "SECRET": "x"},
			allow:     []string{"PATH", "HOME"},
			want:      []string{"HOME=/root", "PATH=/bin"},
		},
		{
			name:      "empty allowlist yields empty env",
			requested: map[string]string{"PATH": "/bin"},
			allow:     nil,
			want:      []string{},
		},
		{
			name:      "allowlisted but unset is simply absent",
			requested: map[string]string{},
			allow:     []string{"PATH"},
			want:      []string{},
		},
		{
			name:      "no wildcard semantics",
			requested: map[string]string{"PATH_EXTRA": "x"},
			allow:     []string{"PATH"},
			want:      []string{},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := FilterEnv(tc.requested, tc.allow)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("FilterEnv = %q, want %q", got, tc.want)
			}
		})
	}
}
