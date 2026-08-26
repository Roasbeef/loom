//go:build !linux

package cgroup

import "fmt"

// notCgroup2 on a platform with no cgroups at all. There is nothing to
// verify and nothing that could pass, so the answer is a reason rather
// than a stub that says yes — the whole point of the check is that a
// directory which merely looks right is not one.
func notCgroup2(path string) string {
	return fmt.Sprintf("%s cannot be a cgroup v2 directory: cgroups are a "+
		"Linux facility and this build is not for Linux", path)
}

// writableProcs cannot be answered off Linux, and is never reached:
// notCgroup2 has already refused.
func writableProcs(procs string) bool { return false }
