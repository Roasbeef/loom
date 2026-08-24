package cgroup

import (
	"reflect"
	"testing"
)

func TestFileWrites(t *testing.T) {
	cases := []struct {
		name   string
		limits LimitsView
		want   []FileWrite
	}{
		{
			name:   "both limits",
			limits: LimitsView{MemBytes: 1 << 30, Pids: 256},
			want: []FileWrite{
				{Path: "/cg/exec-1/memory.max", Content: "1073741824"},
				{Path: "/cg/exec-1/pids.max", Content: "256"},
			},
		},
		{
			name:   "pids only",
			limits: LimitsView{Pids: 8},
			want:   []FileWrite{{Path: "/cg/exec-1/pids.max", Content: "8"}},
		},
		{
			name:   "mem only",
			limits: LimitsView{MemBytes: 4096},
			want:   []FileWrite{{Path: "/cg/exec-1/memory.max", Content: "4096"}},
		},
		{
			name:   "no limits, no writes",
			limits: LimitsView{},
			want:   nil,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := FileWrites("/cg/exec-1", tc.limits)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("FileWrites = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestOwnV2Path(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"pure v2", "0::/user.slice/session-1.scope\n", "user.slice/session-1.scope"},
		{"hybrid picks v2 line", "12:pids:/init\n0::/box\n", "box"},
		{"root cgroup", "0::/\n", ""},
		{"v1 only", "12:pids:/init\n3:memory:/init\n", ""},
		{"empty", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ownV2Path(tc.in); got != tc.want {
				t.Fatalf("ownV2Path(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}
