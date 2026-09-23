//go:build windows

package main

import (
	"errors"
	"os"
)

func acquireProfileLock(string, string) (*os.File, error) {
	return nil, errors.New("subscription helper is not available on Windows")
}
