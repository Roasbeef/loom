//go:build linux || darwin

package jail

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/roasbeef/loom/sandbox/internal/policy"
	"golang.org/x/sys/unix"
)

func publishGitIdentity(pol policy.Policy, workspace string, content []byte) error {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return errors.New("Git identity publication temporary name failed")
	}
	name := ".gitconfig-" + hex.EncodeToString(nonce[:])
	root, relative, err := gitIdentityAuthority(pol, workspace, name)
	if err != nil {
		return err
	}

	// This is an original policy root, never a derived tool-home grant.
	// Once opened, the descriptor retains that root's identity across a
	// rename. Every component below it must itself be a real directory.
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return errors.New("Git identity publication root could not be opened")
	}
	anchor, err := walkGitIdentityHome(fd, strings.TrimPrefix(root, "/"))
	unix.Close(fd)
	if err != nil {
		return errors.New("Git identity publication root could not be opened")
	}
	home, err := walkGitIdentityHome(anchor, relative)
	unix.Close(anchor)
	if err != nil {
		return errors.New("Git identity publication parent is not a confined directory")
	}
	defer unix.Close(home)
	return replaceGitIdentity(home, name, content)
}

// Authorization uses the existing mount precedence without performing any
// mounts. Only an actual host-write grant may anchor publication; a private
// scratch or root tmpfs is not permission to write its host spelling.
func gitIdentityAuthority(pol policy.Policy, workspace, temporary string) (string, string, error) {
	refused := errors.New("Git identity publication is outside the writable policy")
	groups := [][]string{pol.WritableRoots, pol.ReadableRoots, pol.Protected}
	for _, group := range groups {
		for _, path := range group {
			if !filepath.IsAbs(path) || hasParentComponent(path) {
				return "", "", refused
			}
		}
	}
	for _, mount := range pol.Mounts {
		if !filepath.IsAbs(mount.Path) || hasParentComponent(mount.Path) {
			return "", "", refused
		}
	}

	// Resolve only the trusted workspace and policy roots. The fixed child
	// path stays unresolved, so a planted .codemode/home link is encountered
	// by openat(O_NOFOLLOW), not converted into an authorized target.
	workspace, err := filepath.EvalSymlinks(workspace)
	if err != nil {
		return "", "", refused
	}
	home := filepath.Join(workspace, ".codemode", "home")
	destination := filepath.Join(home, "gitconfig")
	tempPath := filepath.Join(home, temporary)
	canonical := pol
	canonical.WritableRoots = gitIdentityPaths(pol.WritableRoots)
	canonical.ReadableRoots = gitIdentityPaths(pol.ReadableRoots)
	canonical.Protected = append(append([]string{}, pol.Protected...), gitIdentityPaths(pol.Protected)...)
	canonical.Mounts = append([]policy.Mount{}, pol.Mounts...)
	for i := range canonical.Mounts {
		canonical.Mounts[i].Path = normalizeSeatbeltPath(canonical.Mounts[i].Path)
	}
	if !pol.ScratchIsTmpfs() {
		if !filepath.IsAbs(pol.Scratch) || hasParentComponent(pol.Scratch) {
			return "", "", refused
		}
		canonical.Scratch = normalizeSeatbeltPath(pol.Scratch)
	}
	for _, protected := range canonical.Protected {
		if pathCovers(protected, destination) || pathCovers(destination, protected) ||
			pathCovers(protected, tempPath) || pathCovers(tempPath, protected) {
			return "", "", refused
		}
	}
	for _, mount := range canonical.Mounts {
		if mount.Path == destination || mount.Path == tempPath {
			return "", "", refused
		}
	}
	plan := MountPlan(canonical, nil, "")
	grant := effective(plan, home).op
	if grant.Class != ClassWritable && grant.Class != ClassMountReadWrite {
		return "", "", refused
	}
	// The private scratch spelling is not a host output directory. An
	// explicit read-write mount is the policy's existing way to restore a
	// host path inside that view; ordinary writable roots are insufficient.
	if pol.ScratchIsTmpfs() && pathCovers(normalizeSeatbeltPath(ScratchMount), home) &&
		grant.Class != ClassMountReadWrite {
		return "", "", refused
	}
	final := effective(plan, destination).op
	if final.Class != ClassWritable && final.Class != ClassMountReadWrite {
		return "", "", refused
	}
	temp := effective(plan, tempPath).op
	if temp.Class != ClassWritable && temp.Class != ClassMountReadWrite {
		return "", "", refused
	}
	relative, err := filepath.Rel(grant.Path, home)
	if err != nil || hasParentComponent(relative) {
		return "", "", refused
	}
	return grant.Path, relative, nil
}

func gitIdentityPaths(paths []string) []string {
	result := make([]string, 0, len(paths))
	for _, path := range paths {
		result = append(result, normalizeSeatbeltPath(path))
	}
	return result
}

// Each open consumes a component relative to the previous descriptor. A
// renamed or replaced parent cannot redirect an already-open descriptor to a
// symlink target. The caller owns the returned descriptor and the input root.
func walkGitIdentityHome(root int, relative string) (int, error) {
	current, err := unix.Dup(root)
	if err != nil {
		return -1, err
	}
	unix.CloseOnExec(current)
	for _, part := range strings.Split(relative, string(filepath.Separator)) {
		if part == "." || part == "" {
			continue
		}
		next, err := unix.Openat(current, part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
		unix.Close(current)
		if err != nil {
			return -1, err
		}
		current = next
	}
	return current, nil
}

// The existing destination is never opened: rename replaces that directory
// entry, so a planted symlink or hard link cannot redirect writes elsewhere.
// Readers already holding the old file retain a complete old configuration.
func replaceGitIdentity(home int, name string, content []byte) error {
	fd, err := unix.Openat(home, name, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
	if err != nil {
		return errors.New("Git identity publication temporary file failed")
	}
	defer unix.Unlinkat(home, name, 0)
	file := os.NewFile(uintptr(fd), "Git identity publication")
	if err := file.Chmod(0600); err != nil {
		file.Close()
		return errors.New("Git identity publication permissions failed")
	}
	_, writeErr := file.Write(content)
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		return errors.New("Git identity publication write failed")
	}
	if err := unix.Renameat(home, name, home, "gitconfig"); err != nil {
		return errors.New("Git identity publication replacement failed")
	}
	return nil
}
