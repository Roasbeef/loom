package setup

import (
	"archive/tar"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

// maxRootBytes bounds the regular-file bytes an extraction writes. The guest
// root is about a gigabyte, so this only stops a corrupt or hostile image
// from filling the disk.
const maxRootBytes int64 = 8 << 30

// ExtractRoot unpacks a flattened filesystem tar stream into dir, which must
// exist and be empty, as an unprivileged user can.
//
// The result matches what `podman export | tar -xp` leaves for a user who
// cannot chown: every file is owned by the caller, and the permission bits,
// setuid, setgid and sticky bits included, are applied exactly as the archive
// records them, whatever the umask. That matters for directories such as
// /tmp (1777), which the guest's own programs need world-writable. The
// guest sees every file as the host user regardless, because the root is a
// virtio-fs share, and its init chowns what it needs at every boot. A
// symlink's own permission bits are whatever the umask leaves, where
// `tar -xp` sets 0777; Linux never consults them.
//
// Symlinks are created and never followed. An entry whose parent path
// contains a symlink is refused, so no archive can write outside dir by
// planting a link first. Device nodes and FIFOs are skipped: an unprivileged
// user cannot create the first, and the guest's init mounts /dev itself.
// Directory permissions are applied last and deepest first, so a directory
// the archive makes read-only does not stop the entries inside it from being
// written.
//
// ## Examples
//
//	err := setup.ExtractRoot(layerTar, "/home/me/.loom/vm/cache/v1/guest-root")
func ExtractRoot(r io.Reader, dir string) error {
	var (
		tr      = tar.NewReader(r)
		dirs    []dirMode
		written int64
	)

	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("read archive: %w", err)
		}

		rel, err := entryPath(hdr.Name)
		if err != nil {
			return err
		}

		mode := hdr.FileInfo().Mode()
		if rel == "" {
			// The archive's own "." entry sets the root directory's mode.
			if hdr.Typeflag == tar.TypeDir {
				dirs = append(dirs, dirMode{dir, mode})
			}
			continue
		}

		target := filepath.Join(dir, rel)
		if err := ensureParents(dir, rel); err != nil {
			return err
		}

		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := makeDir(target); err != nil {
				return err
			}
			dirs = append(dirs, dirMode{target, mode})

		case tar.TypeReg:
			written += hdr.Size
			if written > maxRootBytes {
				return fmt.Errorf("archive holds more than %d bytes", maxRootBytes)
			}
			if err := writeFile(tr, hdr, target, mode); err != nil {
				return err
			}

		case tar.TypeSymlink:
			if err := replace(target); err != nil {
				return err
			}
			if err := os.Symlink(hdr.Linkname, target); err != nil {
				return err
			}

		case tar.TypeLink:
			if err := hardLink(dir, hdr, target); err != nil {
				return err
			}

		default:
			// Devices, FIFOs and extended-header records carry no file the
			// guest needs from the image.
		}
	}

	// Deepest first: chmod needs search permission on every ancestor, and an
	// ancestor's own mode is applied after its children's.
	sort.Slice(dirs, func(i, j int) bool { return len(dirs[i].path) > len(dirs[j].path) })
	for _, d := range dirs {
		if err := os.Chmod(d.path, d.mode); err != nil {
			return err
		}
	}

	return nil
}

// dirMode is a directory whose mode is applied after its contents exist.
type dirMode struct {
	path string
	mode fs.FileMode
}

// entryPath turns an archive name into a path relative to the extraction
// root, or "" for the root itself. A name with a ".." element is refused,
// not normalised: no image the build produces contains one.
func entryPath(name string) (string, error) {
	for _, elem := range strings.Split(name, "/") {
		if elem == ".." {
			return "", fmt.Errorf("archive entry %q climbs out of the root", name)
		}
	}

	rel := strings.TrimPrefix(path.Clean("/"+name), "/")

	return filepath.FromSlash(rel), nil
}

// ensureParents creates the directories above rel inside root, refusing a
// path that already has a symlink in it. Directories the archive lists
// itself get their mode later; these are the ones it left implicit.
func ensureParents(root, rel string) error {
	cur := root
	parts := strings.Split(filepath.Dir(rel), string(filepath.Separator))
	for _, part := range parts {
		if part == "." {
			continue
		}

		cur = filepath.Join(cur, part)

		info, err := os.Lstat(cur)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			if err := mkdir(cur); err != nil {
				return err
			}

		case err != nil:
			return err

		case info.Mode()&fs.ModeSymlink != 0:
			return fmt.Errorf("archive entry %q passes through the symlink %s", rel, cur)

		case !info.IsDir():
			return fmt.Errorf("archive entry %q: %s is not a directory", rel, cur)
		}
	}

	return nil
}

// makeDir creates target, accepting a directory the archive made implicitly
// earlier and replacing anything else in its way.
func makeDir(target string) error {
	info, err := os.Lstat(target)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return mkdir(target)

	case err != nil:
		return err

	case info.IsDir():
		return nil
	}

	if err := os.Remove(target); err != nil {
		return err
	}

	return mkdir(target)
}

// mkdir creates a directory with mode 0755 whatever the umask. The archive's
// own mode for it, if it lists one, is applied at the end; this is the mode
// of a directory it left implicit.
func mkdir(path string) error {
	if err := os.Mkdir(path, 0o755); err != nil {
		return err
	}

	return os.Chmod(path, 0o755)
}

// replace removes whatever file or link is at target, so that a create
// replaces an entry rather than following it.
func replace(target string) error {
	err := os.Remove(target)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}

	return nil
}

// writeFile creates one regular file. The mode is applied by chmod after the
// write, because the umask would otherwise change it and a read-only file
// could not be written.
func writeFile(r io.Reader, hdr *tar.Header, target string, mode fs.FileMode) error {
	if err := replace(target); err != nil {
		return err
	}

	f, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}

	_, err = io.Copy(f, io.LimitReader(r, hdr.Size))
	if err = errors.Join(err, f.Close()); err != nil {
		return err
	}

	if err := os.Chmod(target, mode); err != nil {
		return err
	}

	return os.Chtimes(target, hdr.ModTime, hdr.ModTime)
}

// hardLink links target to an earlier entry of the same archive. The earlier
// entry must be a regular file inside the root: linking to a symlink would
// follow it on some systems.
func hardLink(root string, hdr *tar.Header, target string) error {
	rel, err := entryPath(hdr.Linkname)
	if err != nil {
		return err
	}

	source := filepath.Join(root, rel)
	if err := ensureParents(root, rel); err != nil {
		return err
	}

	info, err := os.Lstat(source)
	if err != nil {
		return fmt.Errorf("hard link %q: %w", hdr.Name, err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("hard link %q targets %q, which is not a regular file", hdr.Name, hdr.Linkname)
	}

	if err := replace(target); err != nil {
		return err
	}

	return os.Link(source, target)
}

// RemoveTree deletes dir even when it holds directories without owner write
// permission, which a guest root can (the archive's modes are applied
// verbatim) and which make a plain os.RemoveAll fail partway.
func RemoveTree(dir string) error {
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err == nil && d.IsDir() {
			// WalkDir lists a directory after calling this, so the
			// permissions are fixed before they can stop the listing.
			return os.Chmod(p, 0o700)
		}

		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}

		return err
	})
	if err != nil {
		return err
	}

	return os.RemoveAll(dir)
}
