package jail

import "testing"

func TestStreamLimiter(t *testing.T) {
	type step struct {
		n             int
		wantAllow     int
		wantJustTrunc bool
	}
	cases := []struct {
		name          string
		limit         uint64
		steps         []step
		wantAdmitted  uint64
		wantTruncated bool
	}{
		{
			name:         "unlimited",
			limit:        0,
			steps:        []step{{100, 100, false}, {1 << 20, 1 << 20, false}},
			wantAdmitted: 100 + 1<<20,
		},
		{
			name:         "under cap",
			limit:        100,
			steps:        []step{{40, 40, false}, {60, 60, false}},
			wantAdmitted: 100,
		},
		{
			name:          "exact boundary chunk then more",
			limit:         100,
			steps:         []step{{100, 100, false}, {1, 0, true}},
			wantAdmitted:  100,
			wantTruncated: true,
		},
		{
			name:          "chunk crosses cap",
			limit:         100,
			steps:         []step{{80, 80, false}, {50, 20, true}, {10, 0, false}},
			wantAdmitted:  100,
			wantTruncated: true,
		},
		{
			name:          "first chunk over cap",
			limit:         10,
			steps:         []step{{100, 10, true}, {100, 0, false}},
			wantAdmitted:  10,
			wantTruncated: true,
		},
		{
			name:         "zero and negative reads are inert",
			limit:        5,
			steps:        []step{{0, 0, false}, {-3, 0, false}, {5, 5, false}},
			wantAdmitted: 5,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			l := NewStreamLimiter(tc.limit)
			for i, s := range tc.steps {
				allow, jt := l.Admit(s.n)
				if allow != s.wantAllow || jt != s.wantJustTrunc {
					t.Fatalf("step %d: Admit(%d) = (%d, %v), want (%d, %v)",
						i, s.n, allow, jt, s.wantAllow, s.wantJustTrunc)
				}
			}
			if l.Admitted() != tc.wantAdmitted {
				t.Fatalf("Admitted = %d, want %d", l.Admitted(), tc.wantAdmitted)
			}
			if l.Truncated() != tc.wantTruncated {
				t.Fatalf("Truncated = %v, want %v", l.Truncated(), tc.wantTruncated)
			}
		})
	}
}

// The truncation signal fires exactly once, no matter how much more
// data flows: the wire contract marks one final chunk.
func TestStreamLimiterTruncatesOnce(t *testing.T) {
	l := NewStreamLimiter(10)
	fires := 0
	for i := 0; i < 100; i++ {
		if _, jt := l.Admit(7); jt {
			fires++
		}
	}
	if fires != 1 {
		t.Fatalf("truncation fired %d times, want exactly 1", fires)
	}
}
