package libkrun

import (
	"fmt"
	"runtime"
	"syscall"
)

// minNofile is the open-file limit a Linux guest needs. libkrun's virtio-fs
// passthrough holds one open file descriptor in the runner for every inode
// the guest has looked up, and releases it only when the guest's kernel drops
// the cached entry. A guest root of 17,700 files held 4,261 descriptors after
// the executor booted, so the soft limit of 1,024 that most login sessions
// start with, and a hard limit of 4,096, both fail: the guest's own commands
// then report "Too many open files" at random, and so does the executor's
// start. The figure leaves room for a larger root, and a macOS runner holds
// no descriptor per inode.
const minNofile = 65536

// nofileSoft returns the soft open-file limit to set given the hard limit,
// or an error when the hard limit is too low for a guest to boot. The soft
// limit becomes the hard one, because the runner inherits it and nothing
// else in this process needs descriptors it would be refused.
func nofileSoft(hard uint64) (uint64, error) {
	if hard < minNofile {
		return 0, fmt.Errorf("the open-file hard limit is %d and a guest needs "+
			"%d: libkrun keeps a descriptor open per guest inode; raise it "+
			"(ulimit -Hn, or LimitNOFILE= under systemd) and start again",
			hard, minNofile)
	}

	return hard, nil
}

// raiseNofile applies nofileSoft to this process, which the runner inherits.
// It does nothing off Linux.
//
// The explicit setrlimit matters. Go raises the soft limit to the hard one at
// startup and restores the original in every child it starts, so without this
// call the runner would still begin at 1,024; a program's own setrlimit makes
// children inherit what it set.
func raiseNofile() error {
	if runtime.GOOS != "linux" {
		return nil
	}

	var lim syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &lim); err != nil {
		return fmt.Errorf("libkrun: read the open-file limit: %w", err)
	}

	soft, err := nofileSoft(lim.Max)
	if err != nil {
		return fmt.Errorf("libkrun: %w", err)
	}

	lim.Cur = soft
	if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &lim); err != nil {
		return fmt.Errorf("libkrun: raise the open-file limit: %w", err)
	}

	return nil
}
