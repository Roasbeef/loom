package policy

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/vmihailenco/msgpack/v5"
)

// validMap returns a fully-populated SandboxPolicyV1 as a Go map,
// mutated per-test to build the adversarial corpus.
func validMap() map[string]any {
	return map[string]any{
		"v":              2,
		"writable_roots": []any{"/work"},
		"readable_roots": []any{"/usr", "/lib"},
		"protected":      []any{"/work/.git", "/work/.env"},
		"network":        map[string]any{"mode": "off"},
		"limits": map[string]any{
			"cpu_s":        60,
			"wall_s":       300,
			"mem_bytes":    1 << 30,
			"pids":         256,
			"fsize_bytes":  1 << 28,
			"output_bytes": 1 << 20,
		},
		"env_allow": []any{"PATH", "HOME"},
		"scratch":   "tmpfs",
		"mounts": []any{
			map[string]any{"path": "/work/.cap/s", "access": "ro", "required": true},
			map[string]any{"path": "/scratch", "access": "rw", "required": false},
		},
	}
}

func mustPack(t *testing.T, v any) []byte {
	t.Helper()
	b, err := msgpack.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}

func TestDecodeValid(t *testing.T) {
	p, err := Decode(mustPack(t, validMap()))
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	want := Policy{
		WritableRoots: []string{"/work"},
		ReadableRoots: []string{"/usr", "/lib"},
		Protected:     []string{"/work/.git", "/work/.env"},
		Network:       Network{Mode: NetworkOff},
		Limits: Limits{
			CPUSeconds: 60, WallSeconds: 300, MemBytes: 1 << 30,
			Pids: 256, FsizeBytes: 1 << 28, OutputBytes: 1 << 20,
		},
		EnvAllow: []string{"PATH", "HOME"},
		Scratch:  "tmpfs",
		Mounts: []Mount{
			{Path: "/work/.cap/s", Access: MountReadOnly, Required: true},
			{Path: "/scratch", Access: MountReadWrite, Required: false},
		},
	}
	if !reflect.DeepEqual(p, want) {
		t.Fatalf("decoded policy mismatch:\n got %#v\nwant %#v", p, want)
	}
}

func TestDecodeProxyMode(t *testing.T) {
	m := validMap()
	m["network"] = map[string]any{
		"mode": "proxy", "allow": []any{"*.npmjs.org"}, "proxy": "127.0.0.1:3128",
	}
	p, err := Decode(mustPack(t, m))
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if p.Network.Mode != NetworkProxy || p.Network.Proxy != "127.0.0.1:3128" ||
		len(p.Network.Allow) != 1 || p.Network.Allow[0] != "*.npmjs.org" {
		t.Fatalf("proxy network mismatch: %#v", p.Network)
	}
}

func TestEncodeDecodeRoundtrip(t *testing.T) {
	m := validMap()
	m["network"] = map[string]any{"mode": "full"}
	p1, err := Decode(mustPack(t, m))
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	raw, err := Encode(p1)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	p2, err := Decode(raw)
	if err != nil {
		t.Fatalf("re-Decode: %v", err)
	}
	if !reflect.DeepEqual(p1, p2) {
		t.Fatalf("roundtrip mismatch:\n got %#v\nwant %#v", p2, p1)
	}
}

// TestDecodeAdversarial is the negative corpus: every entry must fail
// with a descriptive error and must never panic.
func TestDecodeAdversarial(t *testing.T) {
	del := func(key string) map[string]any { m := validMap(); delete(m, key); return m }
	set := func(key string, v any) map[string]any { m := validMap(); m[key] = v; return m }

	cases := []struct {
		name    string
		raw     []byte
		wantSub string
	}{
		{"empty input", nil, "decode"},
		{"truncated map header", mustPack(t, validMap())[:1], "decode"},
		{"truncated mid-value", mustPack(t, validMap())[:20], "decode"},
		{"not a map", mustPack(t, []any{1, 2, 3}), "expected map"},
		{"scalar", mustPack(t, 42), "expected map"},
		{"version 0", mustPack(t, set("v", 0)), "unsupported version"},
		{"version 1", mustPack(t, set("v", 1)), "unsupported version"},
		{"version 3", mustPack(t, set("v", 3)), "unsupported version"},
		{"version string", mustPack(t, set("v", "2")), "v:"},
		{"missing v", mustPack(t, del("v")), "missing required key"},
		{"missing limits", mustPack(t, del("limits")), "missing required key"},
		{"missing scratch", mustPack(t, del("scratch")), "missing required key"},
		{"missing network", mustPack(t, del("network")), "missing required key"},
		{"missing mounts", mustPack(t, del("mounts")), "missing required key"},
		{"unknown top key", mustPack(t, set("extra", true)), "unknown keys"},
		{"writable wrong type", mustPack(t, set("writable_roots", "/work")), "expected array"},
		{"writable elem wrong type", mustPack(t, set("writable_roots", []any{7})), "expected string"},
		{"relative path", mustPack(t, set("writable_roots", []any{"work"})), "not absolute"},
		{"network wrong type", mustPack(t, set("network", "off")), "expected map"},
		{"unknown network mode", mustPack(t, set("network", map[string]any{"mode": "sometimes"})), "unknown network mode"},
		{"off with stray keys", mustPack(t, set("network", map[string]any{"mode": "off", "allow": []any{}})), "unexpected key"},
		{"limits wrong type", mustPack(t, set("limits", []any{})), "expected map"},
		{"limits missing key", mustPack(t, set("limits", map[string]any{"cpu_s": 1})), "missing key"},
		{"limits unknown key", func() []byte {
			m := validMap()
			lm := m["limits"].(map[string]any)
			lm["disk_bytes"] = 1
			return mustPack(t, m)
		}(), "unknown key"},
		{"negative limit", func() []byte {
			m := validMap()
			m["limits"].(map[string]any)["pids"] = -1
			return mustPack(t, m)
		}(), "negative"},
		{"float limit", func() []byte {
			m := validMap()
			m["limits"].(map[string]any)["cpu_s"] = 1.5
			return mustPack(t, m)
		}(), "expected integer"},
		{"scratch empty", mustPack(t, set("scratch", "")), "scratch"},
		{"scratch relative", mustPack(t, set("scratch", "scratch")), "neither"},
		{"mounts wrong type", mustPack(t, set("mounts", "/work")), "mounts: expected array"},
		{"mount not a map", mustPack(t, set("mounts", []any{"/work"})), "expected map"},
		{"mount unknown key", mustPack(t, set("mounts", []any{
			map[string]any{"path": "/work", "access": "ro", "required": true, "kind": "dir"},
		})), "unknown keys"},
		{"mount missing path", mustPack(t, set("mounts", []any{
			map[string]any{"access": "ro", "required": true},
		})), "missing required key"},
		{"mount missing access", mustPack(t, set("mounts", []any{
			map[string]any{"path": "/work", "required": true},
		})), "missing required key"},
		{"mount missing required", mustPack(t, set("mounts", []any{
			map[string]any{"path": "/work", "access": "ro"},
		})), "missing required key"},
		{"mount relative path", mustPack(t, set("mounts", []any{
			map[string]any{"path": "work", "access": "ro", "required": true},
		})), "not absolute"},
		{"mount empty path", mustPack(t, set("mounts", []any{
			map[string]any{"path": "", "access": "ro", "required": true},
		})), "not absolute"},
		{"mount path wrong type", mustPack(t, set("mounts", []any{
			map[string]any{"path": 7, "access": "ro", "required": true},
		})), "expected string"},
		{"mount unknown access", mustPack(t, set("mounts", []any{
			map[string]any{"path": "/work", "access": "rx", "required": true},
		})), "neither"},
		{"mount required not bool", mustPack(t, set("mounts", []any{
			map[string]any{"path": "/work", "access": "ro", "required": 1},
		})), "expected bool"},
		{"trailing bytes", append(mustPack(t, validMap()), 0xc0), "trailing"},
		{"random junk", []byte{0xde, 0xad, 0xbe, 0xef, 0x01, 0x02}, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Decode(tc.raw)
			if err == nil {
				t.Fatalf("Decode accepted adversarial input")
			}
			if tc.wantSub != "" && !strings.Contains(err.Error(), tc.wantSub) {
				t.Fatalf("error %q does not mention %q", err, tc.wantSub)
			}
		})
	}
}

func TestReadFromEmpty(t *testing.T) {
	if _, err := ReadFrom(strings.NewReader("")); err == nil {
		t.Fatal("empty reader accepted")
	}
}

// TestGoldenFixtures decodes the cross-language golden fixtures shared
// with the Gleam side (ADR-003) when they exist. Skipped otherwise; the
// orchestrator wires the fixture corpus in later.
func TestGoldenFixtures(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "..", "protocol", "msgpack-fixtures")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Skipf("no golden fixtures at %s: %v", dir, err)
	}
	found := 0
	for _, e := range entries {
		if e.IsDir() || !strings.HasPrefix(e.Name(), "sandbox_policy") {
			continue
		}
		found++
		raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatalf("read %s: %v", e.Name(), err)
		}
		if _, err := Decode(raw); err != nil {
			t.Errorf("fixture %s does not decode: %v", e.Name(), err)
		}
	}
	if found == 0 {
		t.Skip("fixture directory present but no sandbox_policy fixtures yet")
	}
}

// TestEncodeDecodeNoMounts pins the empty-mount-list roundtrip. A nil
// slice is the common case and used to be the one shape the helper could
// emit but not read back.
func TestEncodeDecodeNoMounts(t *testing.T) {
	m := validMap()
	m["mounts"] = []any{}
	p1, err := Decode(mustPack(t, m))
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if len(p1.Mounts) != 0 {
		t.Fatalf("expected no mounts, got %#v", p1.Mounts)
	}
	raw, err := Encode(p1)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	p2, err := Decode(raw)
	if err != nil {
		t.Fatalf("re-Decode: %v", err)
	}
	if !reflect.DeepEqual(p1, p2) {
		t.Fatalf("roundtrip mismatch:\n got %#v\nwant %#v", p2, p1)
	}
}

// TestDecodeNilMounts accepts msgpack nil for the list, which is what a
// nil slice encodes to on either side of the wire. The broker's decoder
// makes the same allowance.
func TestDecodeNilMounts(t *testing.T) {
	m := validMap()
	m["mounts"] = nil
	p, err := Decode(mustPack(t, m))
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if len(p.Mounts) != 0 {
		t.Fatalf("expected no mounts, got %#v", p.Mounts)
	}
}
