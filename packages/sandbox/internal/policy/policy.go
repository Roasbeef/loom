// Package policy decodes and validates SandboxPolicyV1, the frozen
// policy shape from the implementation spec, Part 1.4.
//
// Decoding is deliberately strict and total: the policy crosses a trust
// boundary (the broker is trusted, but the bytes travel a wire and the
// jail we build from them is only as good as our reading of them), so an
// unknown version, a missing field, an unknown field, or a wrong type is
// an error — never a guess, never a partial value, never a panic.
package policy

import (
	"bytes"
	"fmt"
	"io"
	"sort"

	"github.com/vmihailenco/msgpack/v5"
)

// Version is the only policy version this helper understands. A policy
// with any other "v" is rejected outright; shape changes require a new
// version, not silent tolerance (frozen-interface rule, spec §0.3).
//
// Version 2 is protocol-change/004's `mounts` field. Version 1 is not
// accepted alongside it: an absent `mounts` key would have to mean "no
// explicit mounts", which is the same reading as an empty list, and the
// helper would have no way to tell a v1 sender from a v2 sender that
// asked for nothing. The broker refuses every version but its own for
// the same reason, so the two halves move together or not at all.
const Version = 2

// NetworkMode enumerates the network policy modes of SandboxPolicyV1.
type NetworkMode string

const (
	// NetworkOff blocks all network access: bwrap unshares the net
	// namespace and a seccomp filter denies non-AF_UNIX socket creation.
	NetworkOff NetworkMode = "off"
	// NetworkProxy allows egress only through a harness-owned proxy.
	// The enforcing sidecar is not implemented in phase 1 (spec WP-H
	// "Egress proxy sidecar"; hardening in follow-up track 10), so the
	// helper fails closed: proxy mode is jailed exactly like NetworkOff
	// (bwrap unshares the net namespace, seccomp denies non-AF_UNIX
	// sockets) and the enforcement report carries a skipped
	// "network-proxy" entry saying the allowlist was not enforced. The
	// one forbidden outcome — unrestricted egress reported as confined —
	// cannot happen.
	NetworkProxy NetworkMode = "proxy"
	// NetworkFull applies no network restriction.
	NetworkFull NetworkMode = "full"
)

// Network is the decoded network policy.
type Network struct {
	Mode NetworkMode
	// Allow holds host globs; only meaningful in proxy mode.
	Allow []string
	// Proxy is the proxy address; only meaningful in proxy mode.
	Proxy string
}

// MountAccess is how an explicit mount binds its path into the jail.
type MountAccess string

const (
	// MountReadOnly binds the path read-only (`--ro-bind`).
	MountReadOnly MountAccess = "ro"
	// MountReadWrite binds the path read-write (`--bind`).
	MountReadWrite MountAccess = "rw"
)

// Mount is one explicit bind of a host path into the jail, the
// vocabulary protocol-change/004 added at policy version 2.
//
// A mount is emitted after the protected masks and after the scratch
// mount, so a path the policy names here is visible in the jail even
// where a mask or the scratch tmpfs would otherwise shadow it. The cap
// socket and the cap token are the two paths that need that, and under
// the present base view (the whole host bound read-only) they are the
// only reason the field exists.
type Mount struct {
	// Path is the host path, bound at the same location inside the
	// jail. Invariant, checked on decode: absolute.
	Path string
	// Access is "ro" or "rw".
	Access MountAccess
	// Required refuses the execution when the source path does not
	// exist on this host, rather than running a jail the caller
	// believes carries it. An optional mount is skipped instead.
	//
	// This stays a bool because the wire has bools and Go has one; the
	// two-variant type the Gleam side carries is a house rule about
	// record fields there (lint R9), not a property of the format.
	Required bool
}

// Limits are resource ceilings. Zero means "no limit of this kind": the
// broker expresses "unlimited" as 0 rather than omitting the key, because
// every key of the frozen map is required.
type Limits struct {
	CPUSeconds  uint64 // RLIMIT_CPU on the jailed process
	WallSeconds uint64 // enforced by the helper's supervision timer
	MemBytes    uint64 // cgroup v2 memory.max, when a delegated cgroup exists
	Pids        uint64 // cgroup v2 pids.max, when a delegated cgroup exists
	FsizeBytes  uint64 // RLIMIT_FSIZE on the jailed process
	OutputBytes uint64 // per-stream stdout/stderr cap enforced by the helper
}

// Policy is a validated SandboxPolicyV1.
type Policy struct {
	WritableRoots []string
	ReadableRoots []string
	Protected     []string
	Network       Network
	Limits        Limits
	EnvAllow      []string
	// Scratch is either the literal "tmpfs" or an absolute path.
	Scratch string
	// Mounts are the explicit binds, in the order the sender wrote
	// them. Ordering inside the jail is decided by the mount plan, not
	// by this list.
	Mounts []Mount
}

// ScratchIsTmpfs reports whether the scratch area is a fresh tmpfs
// rather than a bind-mounted host path.
func (p *Policy) ScratchIsTmpfs() bool { return p.Scratch == "tmpfs" }

// Decode parses a SandboxPolicyV1 msgpack map. It rejects: a version
// other than Version, missing keys, unknown keys, wrong types, an unknown
// network mode, and trailing bytes after the map. Unknown keys are an
// error rather than ignored because a field we do not understand could be
// a restriction we would silently fail to enforce.
func Decode(raw []byte) (Policy, error) {
	dec := msgpack.NewDecoder(bytes.NewReader(raw))
	p, err := decodeFrom(dec)
	if err != nil {
		return Policy{}, err
	}
	// Trailing garbage after a security-relevant document is corruption.
	if _, err := dec.PeekCode(); err != io.EOF {
		return Policy{}, fmt.Errorf("policy: trailing bytes after policy map")
	}
	return p, nil
}

// DecodeValue parses a SandboxPolicyV1 from an already-decoded msgpack
// value (as produced by decoding a parent map loosely). Used when the
// policy is nested inside an exec_start body.
func DecodeValue(v any) (Policy, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return Policy{}, fmt.Errorf("policy: expected map, got %T", v)
	}
	return fromMap(m)
}

// ReadFrom consumes an entire reader (e.g. fd 3) and decodes the policy.
func ReadFrom(r io.Reader) (Policy, error) {
	raw, err := io.ReadAll(io.LimitReader(r, 1<<20))
	if err != nil {
		return Policy{}, fmt.Errorf("policy: read: %w", err)
	}
	if len(raw) == 0 {
		return Policy{}, fmt.Errorf("policy: empty input")
	}
	return Decode(raw)
}

// Encode serializes the policy back to the frozen wire shape. Used to
// hand the policy to the restrict-and-exec stage over a pipe, and by
// tests for roundtripping.
func Encode(p Policy) ([]byte, error) {
	var buf bytes.Buffer
	enc := msgpack.NewEncoder(&buf)
	m := map[string]any{
		"v":              Version,
		"writable_roots": p.WritableRoots,
		"readable_roots": p.ReadableRoots,
		"protected":      p.Protected,
		"network":        encodeNetwork(p.Network),
		"limits": map[string]any{
			"cpu_s":        p.Limits.CPUSeconds,
			"wall_s":       p.Limits.WallSeconds,
			"mem_bytes":    p.Limits.MemBytes,
			"pids":         p.Limits.Pids,
			"fsize_bytes":  p.Limits.FsizeBytes,
			"output_bytes": p.Limits.OutputBytes,
		},
		"env_allow": p.EnvAllow,
		"scratch":   p.Scratch,
		"mounts":    encodeMounts(p.Mounts),
	}
	enc.SetSortMapKeys(true) // deterministic bytes for golden tests
	if err := enc.Encode(m); err != nil {
		return nil, fmt.Errorf("policy: encode: %w", err)
	}
	return buf.Bytes(), nil
}

// encodeMounts renders the mount list as the wire's array of maps. A nil
// slice becomes an empty array rather than msgpack nil, because the
// helper's own encoder feeds the stage-2 pipe and an empty mount list is
// the common case; leaving it nil would make the helper emit a document
// its own decoder only tolerates by special case.
func encodeMounts(mounts []Mount) []any {
	out := make([]any, 0, len(mounts))
	for _, m := range mounts {
		out = append(out, map[string]any{
			"path":     m.Path,
			"access":   string(m.Access),
			"required": m.Required,
		})
	}
	return out
}

func encodeNetwork(n Network) map[string]any {
	switch n.Mode {
	case NetworkProxy:
		return map[string]any{"mode": "proxy", "allow": n.Allow, "proxy": n.Proxy}
	default:
		return map[string]any{"mode": string(n.Mode)}
	}
}

func decodeFrom(dec *msgpack.Decoder) (Policy, error) {
	dec.UseLooseInterfaceDecoding(true)
	v, err := dec.DecodeInterfaceLoose()
	if err != nil {
		return Policy{}, fmt.Errorf("policy: decode: %w", err)
	}
	m, ok := v.(map[string]any)
	if !ok {
		return Policy{}, fmt.Errorf("policy: expected map, got %T", v)
	}
	return fromMap(m)
}

func fromMap(m map[string]any) (Policy, error) {
	known := map[string]bool{
		"v": true, "writable_roots": true, "readable_roots": true,
		"protected": true, "network": true, "limits": true,
		"env_allow": true, "scratch": true, "mounts": true,
	}
	var unknown []string
	for k := range m {
		if !known[k] {
			unknown = append(unknown, k)
		}
	}
	if len(unknown) > 0 {
		sort.Strings(unknown)
		return Policy{}, fmt.Errorf("policy: unknown keys %v", unknown)
	}
	for k := range known {
		if _, present := m[k]; !present {
			return Policy{}, fmt.Errorf("policy: missing required key %q", k)
		}
	}

	ver, err := asUint(m["v"])
	if err != nil {
		return Policy{}, fmt.Errorf("policy: v: %w", err)
	}
	if ver != Version {
		return Policy{}, fmt.Errorf("policy: unsupported version %d (want %d)", ver, Version)
	}

	var p Policy
	if p.WritableRoots, err = asStrings(m["writable_roots"]); err != nil {
		return Policy{}, fmt.Errorf("policy: writable_roots: %w", err)
	}
	if p.ReadableRoots, err = asStrings(m["readable_roots"]); err != nil {
		return Policy{}, fmt.Errorf("policy: readable_roots: %w", err)
	}
	if p.Protected, err = asStrings(m["protected"]); err != nil {
		return Policy{}, fmt.Errorf("policy: protected: %w", err)
	}
	if p.Network, err = networkFrom(m["network"]); err != nil {
		return Policy{}, err
	}
	if p.Limits, err = limitsFrom(m["limits"]); err != nil {
		return Policy{}, err
	}
	if p.EnvAllow, err = asStrings(m["env_allow"]); err != nil {
		return Policy{}, fmt.Errorf("policy: env_allow: %w", err)
	}
	scratch, err := asString(m["scratch"])
	if err != nil {
		return Policy{}, fmt.Errorf("policy: scratch: %w", err)
	}
	if scratch == "" {
		return Policy{}, fmt.Errorf("policy: scratch must be \"tmpfs\" or an absolute path")
	}
	if scratch != "tmpfs" && scratch[0] != '/' {
		return Policy{}, fmt.Errorf("policy: scratch %q is neither \"tmpfs\" nor absolute", scratch)
	}
	p.Scratch = scratch
	if p.Mounts, err = mountsFrom(m["mounts"]); err != nil {
		return Policy{}, err
	}

	for _, group := range [][]string{p.WritableRoots, p.ReadableRoots, p.Protected} {
		for _, path := range group {
			if len(path) == 0 || path[0] != '/' {
				return Policy{}, fmt.Errorf("policy: path %q is not absolute", path)
			}
		}
	}
	return p, nil
}

// mountsFrom decodes the `mounts` array. It is as strict as every other
// field here and as strict as the broker's own decoder: an unknown key,
// a relative path, an access that is neither "ro" nor "rw", or a
// `required` that is not a bool is an error rather than a guess, because
// a mount the helper misreads is a host path bound into the jail on
// terms nobody chose.
func mountsFrom(v any) ([]Mount, error) {
	// A nil slice on either side of the wire encodes as msgpack nil.
	// The broker's decoder tolerates it for the same reason, so the two
	// agree on what "no explicit mounts" looks like.
	if v == nil {
		return nil, nil
	}
	arr, ok := v.([]any)
	if !ok {
		return nil, fmt.Errorf("policy: mounts: expected array, got %T", v)
	}
	out := make([]Mount, 0, len(arr))
	for i, e := range arr {
		mount, err := mountFrom(e)
		if err != nil {
			return nil, fmt.Errorf("policy: mounts[%d]: %w", i, err)
		}
		out = append(out, mount)
	}
	return out, nil
}

func mountFrom(v any) (Mount, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return Mount{}, fmt.Errorf("expected map, got %T", v)
	}
	known := map[string]bool{"path": true, "access": true, "required": true}
	var unknown []string
	for k := range m {
		if !known[k] {
			unknown = append(unknown, k)
		}
	}
	if len(unknown) > 0 {
		sort.Strings(unknown)
		return Mount{}, fmt.Errorf("unknown keys %v", unknown)
	}
	for k := range known {
		if _, present := m[k]; !present {
			return Mount{}, fmt.Errorf("missing required key %q", k)
		}
	}

	path, err := asString(m["path"])
	if err != nil {
		return Mount{}, fmt.Errorf("path: %w", err)
	}
	if len(path) == 0 || path[0] != '/' {
		return Mount{}, fmt.Errorf("path %q is not absolute", path)
	}
	access, err := asString(m["access"])
	if err != nil {
		return Mount{}, fmt.Errorf("access: %w", err)
	}
	switch MountAccess(access) {
	case MountReadOnly, MountReadWrite:
	default:
		return Mount{}, fmt.Errorf("access %q is neither \"ro\" nor \"rw\"", access)
	}
	required, ok := m["required"].(bool)
	if !ok {
		return Mount{}, fmt.Errorf("required: expected bool, got %T", m["required"])
	}
	return Mount{Path: path, Access: MountAccess(access), Required: required}, nil
}

func networkFrom(v any) (Network, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return Network{}, fmt.Errorf("policy: network: expected map, got %T", v)
	}
	mode, err := asString(m["mode"])
	if err != nil {
		return Network{}, fmt.Errorf("policy: network.mode: %w", err)
	}
	switch NetworkMode(mode) {
	case NetworkOff, NetworkFull:
		for k := range m {
			if k != "mode" {
				return Network{}, fmt.Errorf("policy: network: unexpected key %q for mode %q", k, mode)
			}
		}
		return Network{Mode: NetworkMode(mode)}, nil
	case NetworkProxy:
		for k := range m {
			if k != "mode" && k != "allow" && k != "proxy" {
				return Network{}, fmt.Errorf("policy: network: unknown key %q", k)
			}
		}
		allow, err := asStrings(m["allow"])
		if err != nil {
			return Network{}, fmt.Errorf("policy: network.allow: %w", err)
		}
		proxy, err := asString(m["proxy"])
		if err != nil {
			return Network{}, fmt.Errorf("policy: network.proxy: %w", err)
		}
		return Network{Mode: NetworkProxy, Allow: allow, Proxy: proxy}, nil
	default:
		return Network{}, fmt.Errorf("policy: unknown network mode %q", mode)
	}
}

func limitsFrom(v any) (Limits, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return Limits{}, fmt.Errorf("policy: limits: expected map, got %T", v)
	}
	want := []string{"cpu_s", "wall_s", "mem_bytes", "pids", "fsize_bytes", "output_bytes"}
	for k := range m {
		found := false
		for _, w := range want {
			if k == w {
				found = true
				break
			}
		}
		if !found {
			return Limits{}, fmt.Errorf("policy: limits: unknown key %q", k)
		}
	}
	vals := make(map[string]uint64, len(want))
	for _, k := range want {
		raw, present := m[k]
		if !present {
			return Limits{}, fmt.Errorf("policy: limits: missing key %q", k)
		}
		n, err := asUint(raw)
		if err != nil {
			return Limits{}, fmt.Errorf("policy: limits.%s: %w", k, err)
		}
		vals[k] = n
	}
	return Limits{
		CPUSeconds:  vals["cpu_s"],
		WallSeconds: vals["wall_s"],
		MemBytes:    vals["mem_bytes"],
		Pids:        vals["pids"],
		FsizeBytes:  vals["fsize_bytes"],
		OutputBytes: vals["output_bytes"],
	}, nil
}

// asUint accepts the integer representations msgpack decoding can
// produce and rejects everything else, including negative values and
// floats (a fractional limit is a sender bug, not a value to round).
func asUint(v any) (uint64, error) {
	switch n := v.(type) {
	case int64:
		if n < 0 {
			return 0, fmt.Errorf("negative value %d", n)
		}
		return uint64(n), nil
	case uint64:
		return n, nil
	case int8:
		if n < 0 {
			return 0, fmt.Errorf("negative value %d", n)
		}
		return uint64(n), nil
	case int:
		if n < 0 {
			return 0, fmt.Errorf("negative value %d", n)
		}
		return uint64(n), nil
	default:
		return 0, fmt.Errorf("expected integer, got %T", v)
	}
}

func asString(v any) (string, error) {
	s, ok := v.(string)
	if !ok {
		return "", fmt.Errorf("expected string, got %T", v)
	}
	return s, nil
}

func asStrings(v any) ([]string, error) {
	arr, ok := v.([]any)
	if !ok {
		return nil, fmt.Errorf("expected array, got %T", v)
	}
	out := make([]string, 0, len(arr))
	for i, e := range arr {
		s, ok := e.(string)
		if !ok {
			return nil, fmt.Errorf("element %d: expected string, got %T", i, e)
		}
		out = append(out, s)
	}
	return out, nil
}
