# protocol-change/039 — per-session tool roster on creation

**Status**: ACCEPTED 2026-09-15 · **Affects**: daemon control v2 from
protocol-change/015 · **Raised by**: the `[tools] roster` operator setting ·
**Implemented**: storage catalogue, daemon control, terminal launcher.

## Problem

Loom is gaining an operator setting, `[tools] roster = "minimal" | "full"`,
which decides how large a tool registry a session is built with. A daemon
reads that setting once, from its own `loom.toml`, and every session it
hosts inherits it. That is the wrong granularity for the thing being
chosen: one terminal wants a small registry for a cheap model on a narrow
task while another, against the same daemon, wants everything.

The choice cannot be a view setting either. A session's registry is built
during assembly, before the first turn, and the system prompt's
available-tools index is rendered from that registry and then pinned
(`docs/architecture/client.md:651-656`). Anything that arrives afterwards
is narrowing a registry that has already been built and paid for.

## Proposal

Add one optional field to the existing `sessions.create` body:

```json
{"v":2,"id":5,"cmd":"sessions.create","body":{"request_key":"tui-9c1","workspace":"/src/loom","name":"retry work","configuration":"/src/loom/loom.toml","roster":"minimal"}}
```

`roster` is `"minimal"` or `"full"`. Any other value is a `bad_request`
refusal, not a narrowing: a daemon that guessed would start the session
with a registry the operator did not ask for and could not see.

An absent field means inherit, and it is absent — not an empty string —
so a body written by a launcher that predates this change and a body from
a launcher with no `--tools` flag are the same body. The daemon's own
`[tools] roster` decides in that case.

The word is persisted with the registration, so a restarted daemon
rebuilds the registry the session was created with rather than the one
its configuration file names at recovery time. Catalogue schema version 4
adds a `roster` column to `catalogue_sessions`, defaulting to the empty
word; version 1, 2 and 3 catalogues migrate transactionally. Storage does
not know the vocabulary: it holds the word and hands it back, and the
column's own constraint is what keeps a third word out. The client
boundary decodes it totally and refuses any word this build cannot mean,
rather than defaulting to inherit.

Because it is creation metadata, `roster` joins the equality that
recovers a lost creation reply. A retry under the same `request_key` that
names a different roster — including one that drops the field — answers
`conflict`, exactly as a retry with a different `name` or `configuration`
does today. Recovering the original identity is only correct when the
original request is the one being repeated.

The terminal gains a launcher flag, `loom --tools <minimal|full>`, which
sets the roster of sessions that terminal creates. It is deliberately not
forwarded to `daemon_launch_arguments`: a daemon is started once and
outlives any number of sessions, so a per-session choice must not become
the flag a shared daemon boots with.

## Considered and rejected

**`set_config` with `active_tools`.** The hub already accepts an
`active_tools` change on a named strand (`client/gateway.gleam:6238-6251`),
and narrowing that list looks superficially like choosing a roster. It is
not, for three reasons. It only narrows a registry that has already been
built, so none of the cost the minimal roster exists to avoid is avoided.
The system prompt's available-tools index is rendered from the full
registry and pinned before any `set_config` can arrive, so the model would
be told about tools its active list no longer contains. And it needs an
attached socket and a named strand, which a session created and left
unattached does not have — while the roster has to be settled before the
first turn runs.

**A third roster value, or a per-tool list.** Both were left out. The
setting this field mirrors has two values; a wire field with more shapes
than the setting it carries would have no meaning on the daemon side.

**Carrying the roster in `daemon.start` arguments.** Rejected above: it
would make one terminal's preference the shared daemon's policy.

## Impact

Both control codecs, daemon dispatch, the manager's creation record and
retry equality, the catalogue DAL and its generated SQL, and the terminal
launcher change. The generated SQL modules and the embedded migration DDL
are regenerated artifacts and land in their own commit. An older client
omits the field and is unaffected. An older daemon ignores an unknown body
field, so a newer launcher's `--tools` would be silently inherited there;
that is the same tolerance every optional field in this envelope already
has. Conversation databases and the frozen conversation protocol do not
change.

### What inherit means across a flip

An explicit roster survives a restart byte for byte: the word is stored
on the registration and `serve.resolve_managed` applies it over the
daemon's configuration on every rebuild. An inherited roster does not.
A registration whose stored word is empty, which is every session
created without `--tools` and every session created before this change,
follows the daemon's `[tools] roster` at each boot. The rest of the
session does not follow it. The system prompt is pinned once and keyed
only on the enforcement demand, and `strand.config`'s
`active_tool_names` is seeded once at the session's first boot, so
neither re-renders when the configuration moves. An operator who flips
the daemon's default and restarts should therefore expect an existing
inherit session to rebuild a different registry than its pinned prompt
describes: the prompt's available-tools index names tools that are no
longer on the wire, `wiring.tool_specs` drops the unregistered names
when it renders, and `wiring.clear` refuses a call on one. The session
recovers by being replaced; a new session renders its prompt from the
registry it actually got. This is the same class of behaviour
`LOOM_DISABLE_TOOLS` has today. If it ever matters, the fix is to bind
the resolved roster into the prompt pin's identity alongside the
enforcement demand, so a flip re-renders the prompt rather than leaving
it stale.

## Decision

**Accepted.** Per `docs/execution.md` §7 protocol acceptance for this work
was delegated; the orchestrator reviewed this proposal and accepted it.
Corrections recorded during that review: the field is absent rather than
empty when inheriting, and it must join the creation-retry equality rather
than sitting beside it, so a retry cannot recover a session built with a
different registry.
