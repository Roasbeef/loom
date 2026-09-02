# ADR-007: extensions run jailed by default, and reach the network through the broker

**Status**: accepted · **Date**: 2026-09-02 · **Supersedes**: nothing ·
**Spec ref**: WP-M (L2, L3); design §7; `docs/design-notes/extension-architecture.md`

## The question

Design §7 places installed extensions at L3, hot-loaded into the harness
VM under typed behaviours, and puts the whole cost of the milestone on
freezing the trusted computing base against them (#33). Nothing of it is
built. The first extension the project needs is web search: a tool the
model calls directly, written in Gleam in its own repository, installed
by an operator, whose API key must not leak. Where does an extension's
code run, and how does it reach the network, given that `cap/net`
refuses everything because the egress proxy sidecar it was written for
does not exist?

## Decision

An installed extension has one manifest and up to two bodies. The
**jailed body** runs in a satellite under an extension seam (the
workspace capabilities, `cap/net` served, and a small `ext` prelude
carrying the typed behaviours), one execution per tool call or hook
event, with the capability channel as its only way out and the broker
judging every effect per call. The **harness-resident body** is §7's L3
and is reserved for a hook or projection that cannot be expressed as a
jailed callback. A tool is always jailed; a hook is harness-resident only
when it cannot be jailed. Installing a jailed extension changes nothing
in the harness VM.

`net.request` is served by the broker performing the HTTP request on the
host under a per-extension policy: an exact-host egress allowlist, the
permitted methods, a response size cap, a per-execution request ceiling,
and secret bindings that name an environment variable and the header it
belongs in for one host. The broker injects the secret when it makes the
request. No socket exists in the jail, the jail never holds the secret,
and no frame on the capability channel carries it.

Hooks arrive in a later phase through a `hook_call` frame from harness to
satellite over the same authenticated channel, with a satellite that
lives for the session; that reverse direction is a `protocol-change/`
proposal written before the phase begins. The harness side of it is one
`weft/event_manager` per session with a handler per installed extension.

The install is the same decision applied to the operator's host: an
install needs a tree fetched, not a git session. `loom ext install`
invokes no git client. It fetches an archive through the broker's HTTP
client under a one-host install policy, extracts it totally into
staging (regular files and directories only, capped, confined), digests
the tree, vets the source, compiles it offline inside the code-mode
sandbox, and records the resolved revision and digest last. Every later
load re-digests the tree against the record.

The client's moments (`input`, `user_bash`, prompts, commands, widgets)
are not in the harness vocabulary. They are the TUI's own extension
surface, in the operator's terminal process, ruled separately and
operator-installed only.

## Why

The risk in an extension system is the hooks, not the tools: a tool call
is a request the model made and the broker judges, while a hook fires on
the harness's timeline holding the harness's data. Putting the more
powerful surface behind the stronger boundary is the ordering the
orchestration seam already uses. Making the jail the default means #33's
freeze test is met by construction for everything the first milestones
need, and the L3 loader can be built when a hook genuinely needs it
rather than as a precondition for the first extension.

The egress proxy was the general answer for a jailed process that opens
sockets. An extension needs a request made, not a socket. Serving the
request from the broker keeps the jail's network namespace empty, which
every sandbox layer already enforces, and it puts the credential where
`api_key_env` already put MCP keys: named in configuration, held by the
harness, never in a file and now never in the jail either. That property
is stronger than pi's, where the skill's script reads the key from the
process environment, and it is what the web-search acceptance test
asserts.

Adopting pi's event names where the moment and the handler's power match
(`tool_call`, `tool_result`, `context`, `before_agent_start`,
`session_start`, `agent_end`, `agent_settled`) and refusing the rest
openly (provider ownership, UI, in-place argument mutation) is #100's
lever: a port becomes mechanical for the subset where it is meaningful.

## Consequences

- A new `packages/ext` and a published `loom_ext` package; a third
  code-mode seam with its own allowlist and router arm; the tool registry
  becomes a list of contributions; `broker` gains an HTTP client under
  policy; `cap/net`'s served surface changes the prelude digest.
- No frozen Part-1 interface moves for phases 1 and 2. Phase 3's
  `hook_call` is a protocol change and is proposed as one.
- Tool calls pay a satellite boot each until the persistent satellite
  lands. That is the same cost code mode pays today and is accepted.
- The L1 skill store and L2 candidate pipeline (#30, #31) become the
  agent-authored on-ramp into the same manifest and install record; they
  are not a parallel mechanism.
- Extensions written in JavaScript are a second satellite runtime
  speaking the same frames under the same token and policy, not a second
  extension system.
- The install path and the extension path share one HTTP client and one
  policy shape, so a cap raised for one is raised for both, on purpose.
- A client-side extension surface, when ruled, adds a `[client]` table to
  the manifest and a body that runs in the TUI; until then the table is
  an unknown key and refuses the manifest.
