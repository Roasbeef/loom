package jail

// The system view: what a jail must contain before it can run anything
// at all.
//
// The base view used to be the whole host filesystem read-only, so no
// list like this was needed: everything a command could want was already
// there, and so was every other workspace, every other session's scratch
// and every dotfile on the account. protocol-change/020 replaces that
// with an empty root plus the directories below, which turns the base
// view from a denylist (`protected` covers the paths the harness thought
// to name) into an allowlist.
//
// Both lists are plain data rather than a probe of the host, and both are
// bound tolerantly: a distribution that does not carry one of these paths
// loses nothing but a bind that had nothing to bind. What is *not* here
// is the point of the change. `/home` and `/root` are absent, so the
// user's home directory reaches a jail only through the workspace, the
// policy's roots and its explicit mounts; `/tmp` is absent because the
// scratch tmpfs owns it; `/var` is absent except for `/var/lib`, so
// `/var/tmp` is not a shared writable region either.

// SystemRoots is the read-only system view a Linux jail is given. Each
// entry earns its place:
//
//   - `/usr` holds the libraries, the dynamic loader and the toolchains
//     on every modern distribution, and is the one entry nothing runs
//     without.
//   - `/bin`, `/sbin`, `/lib`, `/lib32` and `/lib64` are the same content
//     on a merged-usr distribution, where they are symlinks into `/usr`,
//     and are the real directories on one that is not merged. Binding
//     them tolerantly makes the two layouts one code path: on a merged
//     system the bind follows the link and reproduces the directory under
//     its old name, and on a system without `/lib32` the bind is skipped.
//   - `/etc` carries the configuration a toolchain reads on startup, from
//     `ld.so.conf` and `nsswitch.conf` to the TLS trust store.
//   - `/opt` is where hand-installed and vendor toolchains land.
//   - `/var/lib` holds package-manager-installed data a toolchain reads,
//     and on openSUSE it holds the TLS trust store itself: `/etc/ssl/certs`
//     is a symlink into `/var/lib/ca-certificates`, so without this entry
//     an HTTPS client there fails to verify any certificate. The rest of
//     `/var` (`/var/tmp` above all) is a writable region shared across the
//     account and stays out.
//   - `/run/systemd/resolve`, `/run/resolvconf` and `/run/NetworkManager`
//     are where the three common resolver managers keep the real
//     `resolv.conf`. On such a host `/etc/resolv.conf` is a symlink into
//     one of them, and a jail that binds `/etc` without the target has a
//     dangling link and resolves no name at all. Which of the three a
//     host uses is its own business, so all three are bound tolerantly
//     and the absent ones cost nothing.
//   - `/run/current-system` and `/nix/store` are NixOS: the profile that
//     `/usr/bin/env` and every `/etc` symlink resolve into, and the store
//     every binary's interpreter and libraries live in. Without them a
//     NixOS jail cannot exec a shell.
var SystemRoots = []string{
	"/usr",
	"/bin",
	"/sbin",
	"/lib",
	"/lib32",
	"/lib64",
	"/etc",
	"/opt",
	"/var/lib",
	"/run/systemd/resolve",
	"/run/resolvconf",
	"/run/NetworkManager",
	"/run/current-system",
	"/nix/store",
}

// DarwinSystemRoots is the read-only system view a Seatbelt profile
// grants. macOS has no bind mounts, so these are subpath read allows
// rather than binds, but the list answers the same question:
//
//   - `/System` holds the OS itself, including the dyld shared cache
//     under `/System/Library/dyld` that every process maps before it runs
//     its first instruction.
//   - `/usr`, `/bin` and `/sbin` are the system binaries and libraries.
//   - `/Library` carries system-wide frameworks and configuration.
//   - `/private/etc` is the real `/etc` (`/etc` is a symlink to it),
//     `/private/var/db` holds the directory-services and timezone
//     databases `opendirectoryd` clients read, and `/private/var/select`
//     holds the symlink `/bin/sh` follows to pick its shell — without it
//     the shell starts and immediately reports
//     `Error opening /private/var/select/sh`.
//   - `/dev` is the device tree; Seatbelt has no equivalent of bwrap's
//     minimal `--dev`, so the write side stays denied by the profile's
//     deny-default and the `/dev/null` write rule remains the one
//     exception.
//   - `/opt/homebrew` and `/usr/local` are the two Homebrew prefixes,
//     which is where an operator's `erl` and `gleam` usually live.
//
// `/Users` is absent for the same reason `/home` is absent on Linux.
var DarwinSystemRoots = []string{
	"/System",
	"/usr",
	"/bin",
	"/sbin",
	"/Library",
	"/private/etc",
	"/private/var/db",
	"/private/var/select",
	"/dev",
	"/opt/homebrew",
	"/usr/local",
}

// RootRegion is the region a whole-host grant names. A policy carrying it
// as a readable root asks for the pre-020 base view.
const RootRegion = "/"

// PlanIsMinimal reports whether a policy leaves the minimal base view in
// place. A `readable_roots` entry of "/" binds the host back over the
// tmpfs and reproduces the view the helper had before
// protocol-change/020, so the audit says which of the two was in effect
// rather than leaving a reader of the enforcement report to guess.
//
// This is a property of the policy, not of the rendered plan, so the
// Linux and Darwin backends answer it the same way from the same input.
func PlanIsMinimal(readableRoots []string) bool {
	for _, r := range readableRoots {
		if region(r) == RootRegion {
			return false
		}
	}
	return true
}

// BaseViewName renders PlanIsMinimal for the enforcement report's
// `base=` field.
func BaseViewName(readableRoots []string) string {
	if PlanIsMinimal(readableRoots) {
		return "minimal"
	}
	return "host-view"
}
