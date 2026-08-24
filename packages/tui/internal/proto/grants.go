package proto

import (
	"fmt"
	"strings"
)

// Denial is the structured denial an escalation was raised from,
// mirroring broker/escalation.Denial: why, from where, and the exact
// widening that would satisfy it. The UI shows Wanted verbatim — the
// approval answers this diff and nothing wider.
type Denial struct {
	Reason string `json:"reason"`
	// Source is "policy" (refused before dispatch) or "execution" (the
	// helper's enforcement report showed a degraded run).
	Source string `json:"source"`
	// Enforcement is the helper's ground-truth line list, present for
	// "execution" denials (e.g. "skip:landlock: ...").
	Enforcement []string `json:"enforcement,omitempty"`
	Wanted      []Grant  `json:"wanted"`
}

// Denial sources.
const (
	DenialPolicy    = "policy"
	DenialExecution = "execution"
)

// Grant types, mirroring broker/policy.Grant constructors.
const (
	GrantWritableRoot = "writable_root"
	GrantReadableRoot = "readable_root"
	GrantNetwork      = "network"
	GrantEnv          = "env"
	GrantLimit        = "limit"
	GrantScratch      = "scratch"
)

// Network modes, mirroring broker/policy.NetworkPolicy.
const (
	NetworkOff   = "off"
	NetworkProxy = "proxy"
	NetworkFull  = "full"
)

// Limit fields, mirroring broker/policy.LimitField.
const (
	LimitCPUSeconds  = "cpu_seconds"
	LimitWallSeconds = "wall_seconds"
	LimitMemBytes    = "mem_bytes"
	LimitPids        = "pids"
	LimitFsizeBytes  = "fsize_bytes"
	LimitOutputBytes = "output_bytes"
)

// Scratch modes, mirroring broker/policy.Scratch.
const (
	ScratchTmpfs = "tmpfs"
	ScratchPath  = "path"
)

// Grant is one explicit policy widening, discriminated by Type; the
// other fields are populated per type (see protocol.md). Approving an
// escalation echoes grants back verbatim, so the wire shape must
// round-trip exactly.
type Grant struct {
	Type    string   `json:"type"`
	Path    string   `json:"path,omitempty"`
	Name    string   `json:"name,omitempty"`
	Network *Network `json:"network,omitempty"`
	Field   string   `json:"field,omitempty"`
	Value   int64    `json:"value,omitempty"`
	Scratch *Scratch `json:"scratch,omitempty"`
}

// Network is a NetworkPolicy on the wire.
type Network struct {
	Mode string `json:"mode"`
	// Allow and Proxy are set for mode "proxy": the host-glob
	// allowlist and the harness-owned proxy address.
	Allow []string `json:"allow,omitempty"`
	Proxy string   `json:"proxy,omitempty"`
}

// Scratch is a scratch-space policy on the wire.
type Scratch struct {
	Mode string `json:"mode"`
	Path string `json:"path,omitempty"`
}

// Display renders the grant as the exact policy-diff line the approval
// prompt shows, in the design doc's "wants: network to
// registry.npmjs.org" voice.
func (g Grant) Display() string {
	switch g.Type {
	case GrantWritableRoot:
		return "write access to " + g.Path
	case GrantReadableRoot:
		return "read access to " + g.Path
	case GrantNetwork:
		if g.Network == nil {
			return "network"
		}
		switch g.Network.Mode {
		case NetworkFull:
			return "unrestricted network"
		case NetworkProxy:
			return "network to " + strings.Join(g.Network.Allow, ", ")
		case NetworkOff:
			return "network off"
		default:
			return "network (" + g.Network.Mode + ")"
		}
	case GrantEnv:
		return "environment variable " + g.Name
	case GrantLimit:
		return fmt.Sprintf("limit %s = %d", g.Field, g.Value)
	case GrantScratch:
		if g.Scratch != nil && g.Scratch.Mode == ScratchPath {
			return "scratch at " + g.Scratch.Path
		}
		return "tmpfs scratch"
	default:
		return g.Type
	}
}
