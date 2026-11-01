package main

import (
	"strings"
	"testing"
)

// TestSetupRefusesBadFlagCombinations checks the flag rules that are decided
// before anything is read or downloaded.
func TestSetupRefusesBadFlagCombinations(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"neither", nil, "exactly one of"},
		{"both", []string{"--release", "v1", "--from-build", "/x"}, "exactly one of"},
		{"revision with a release", []string{"--release", "v1", "--revision", "abc"}, "--from-build"},
		{"unknown flag", []string{"--nope"}, "flag provided but not defined"},
	}

	for _, tc := range cases {
		err := setupCmd(tc.args)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v, want %q", tc.name, err, tc.want)
		}
	}
}
