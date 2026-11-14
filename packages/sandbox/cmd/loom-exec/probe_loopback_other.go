//go:build !linux

package main

import (
	"fmt"
	"os"
)

// probeLoopback has nothing to witness off Linux: loopback mode is
// refused there, so no jail ever runs it.
func probeLoopback([]string) {
	fmt.Println("probe-loopback=unsupported-platform")
	os.Exit(2)
}
