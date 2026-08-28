# MCP

An MCP server — Model Context Protocol — is somebody else's program,
speaking JSON-RPC 2.0 down a pipe and offering tools it would like a
model to call. Loom's client side of that arrangement is two pieces:
`packages/mcp` holds the protocol codecs, the actor that owns one server
process, the generator that turns a tool listing into Gleam, and the
value translation between the two wires; `client/mcp` is the harness
wiring that reads the configuration, starts a client per server, and
answers capability calls out to them.

One decision shapes everything else in this document. **A server's tools
reach a model only through code mode, as one generated Gleam module per
server.** A program calls `github.create_issue(...)` after writing
`import cap/mcp/github`, and by no other route: nothing about MCP is a
registered harness tool, and there is no generic
`invoke(server, tool, args)` a program can reach. What follows is that
decision's mechanism — the boot path, the hostile-input posture the
generator is built around, the wire one call travels, and what v1
deliberately does not do. `docs/architecture/code-mode.md` carries the
vetting theorem this all rests on and the pipeline the generated modules
are compiled into; this document assumes it rather than restating it.

## One module per server

Code mode's bound is a source-level one: a Gleam program's maximal
capability set is the transitive closure of its imports plus its own
`@external` declarations, so vetting reads the import list and knows what
the program can do. Two shapes were available for reaching an MCP server
from inside that bound, and the difference between them is not whether
the theorem survives.

A generic dispatcher — `cap/tools.invoke(name, args)`, one module every
program may import — does not falsify the theorem. Vetting would still
compute a correct upper bound. The bound would just be *the whole
registry, for every program*, so the import list would stop sorting
programs into capability classes and the broker's per-call check would
be the only thing left discriminating between them. That is one layer
where code mode was built to have two, and the loss would be invisible:
every program still vets, and every program is trusted with every server.

Per-server modules keep the discrimination. The vetting allowlist names
one module per configured server, so a program that imported
`cap/mcp/github` was handed that server and no other, visibly, in its
first few lines. The granularity is the one a human actually reasons
about — nobody vets three hundred tools one at a time, and an operator
who adds a server to `loom.toml` is making exactly one trust decision.

Two structural facts hold the shape in place.

**The marshaling seam is unimportable.** Every generated façade is a
name, a signature, and one call to `cap/internal/mcp.invoke`, which
builds the capability name `"mcp." <> server` and the argument map. Gleam
forbids another package from importing an internal module, so a program
cannot name `invoke` and dispatch to a server string of its own — which
would be the generic dispatcher by the back door, and would collapse
per-server trust to "any server the router knows".

**A module costs what a module costs.** A registered tool renders into
the provider's cached prefix and is paid on every request of every
strand, so a registry-per-tool design scales its cost with the server's
tool count. A generated module renders its surface once, the way
`cap/proc` does, whether the server lists three tools or three hundred.
The scaling lever is therefore which servers an operator enables, not
model-side discovery, which is why Loom builds no tool search:
`docs/design-notes/tool-search-and-code-mode.md` has the arithmetic, and
its MCP half is superseded by what shipped.

## From a table to a callable module

An operator writes one table per server in `loom.toml`, and that is the
whole configuration surface — no CLI flag, no auto-discovered project
file, no live reload:

```toml
[mcp.github]
command = ["mcp-server-github", "--stdio"]
api_key_env = "GITHUB_TOKEN"
```

The table key is load-bearing three times over: it is the `<name>` in the
`cap/mcp/<name>` module a program imports, the `<server>` in the
`mcp.<server>` capability the call travels under, and the catalogue key
an operator reads a refusal against. So `client/catalog` holds it to a
single lowercase-ASCII identifier segment (`[a-z][a-z0-9_]*`), judged by
the same grammar gate vetting holds every import to, and additionally
refuses any key the generator's name mangler would rewrite — a keyword, a
doubled or trailing underscore, anything past 32 characters. On every
config-legal key, mangling is the identity, which is what makes the
promise that `[mcp.github]` yields `cap/mcp/github` provable rather than
usually true. `internal` is refused by name, because `cap/mcp/internal`
would sit confusingly beside the unimportable marshaling layer.

`command` is argv with the executable first, never a shell string.
`api_key_env` names an environment *variable*, never a key: the value is
read from the harness's own environment at spawn through the same
`provider/secret` seam every other configured secret goes through, put
into the child's environment under the same name, and stored in no
record, no log line, and no refusal message. A configured variable that
is unset refuses that server before anything is spawned, because a server
started without the key it was configured with fails later, further away,
and in the server's own words.

### Boot

`client/mcp.start` walks the configured servers in catalogue order and
does four things per server, in this order:

1. **Resolve the secret**, as above, before any process exists.
2. **Spawn and hand-shake.** The client actor is started over
   `mcp/transport.PortTransport` — a child OS process on an Erlang port,
   stdin and stdout as the wire — and sends `initialize` asking for
   revision 2025-06-18, accepting `2025-03-26` and `2024-11-05` and
   refusing anything else, then `notifications/initialized`.
3. **List the tools.** `tools/list`, following `nextCursor` for at most
   64 pages, under one budget for the whole listing (30 seconds by
   default).
4. **Generate the module.** `mcp/codegen.generate` turns the listing into
   a `Generated(module_name, source, surface)`: the `cap/mcp/<name>`
   module's Gleam source, and the rendered description surface the
   `code_mode` tool carries for it.

The client stays running for the life of the session, because dispatch
is the same client. Every step is a place a third party can fail, and
each failure refuses *that server* — one `mcp.unavailable` log line
naming the server and the reason, the client torn down behind it, and
the boot continuing without it. That line is not decoration: a refused
server has no module, so a program importing it is rejected by vetting
with no word about why the module is absent, and the line is the only
place an operator will ever see the cause. A layer that reached at least
one server logs `mcp.ready` with each server's name and tool count.

A host that registers no `code_mode` tool starts no MCP server at all.
Since a server's tools are only ever a module a program may import, a
host with nothing that could import one would be spending process and
attack surface on a capability nobody can reach.

### What one field widens

The layer reaches code mode as a single `Config.mcp` field, and a server
in it widens four things together:

| What widens | With what |
|---|---|
| The vetting **allowlist** | `cap/mcp` plus one `cap/mcp/<server>` per server (`client/codemode.seam_allowlist`) |
| The rendered **description** | each server's surface, as the seam offer's extra surfaces |
| The **generated table** the hermetic build takes | `#(module name, source)` per server |
| The capability **router** | one `mcp.<server>` arm per server |

They are one field for the reason the code-mode surface is one field: a
host that could set them apart would eventually set them apart, and each
pair that drifted would be its own failure — a module the model was told
about and vetting rejects, or a module vetting admits and the build never
writes. The **orchestration seam is widened by none of it, ever.** Which
capabilities travel together is the whole of what the two-seam split
buys, and an orchestrator that could also call out to a third-party
server is a materially worse thing to hand a model than one that cannot.

Generated source scales with a program's imports rather than with a
host's configuration. `codemode.execute` narrows the table to the vetted
program's own import list before the compile service sees it, so a
program that named one server pays for one and a program that named none
pays for nothing. The narrowing is a cost filter and not an
authorization one — what a program may import was already decided by the
allowlist. The write itself belongs to the builder, *after* the seed
clone that replaces `vendor/` wholesale, and it lands *inside* the
vendored prelude, because a façade calls `cap/internal/mcp` and Gleam
admits an internal module only to its own package.

## What the model reads, and what it writes

A model writing a code-mode program authors blind: no autocomplete, no
hover, no language server. The rendered surface is therefore the whole
oracle, and it is part of the `code_mode` description the model has
before it writes a line. For the three-tool fixture server the client
package's end-to-end runs against, configured as `[mcp.fixture]`, the
surface opens like this:

```
### cap/mcp/fixture
`cap/mcp/fixture` — the tools of the MCP server "fixture", as typed calls.
Descriptions below are the server's own text, not Loom's.
Optional parameters travel in `options` by wire name, e.g.
`options: [#("page", report.int(2))]`; pass `[]` when none.

/// Echoes the arguments it was called with, verbatim.
///
/// Tool "echo_args" on MCP server "fixture". Optional parameters travel in
/// `options` by wire name; pass [] when none.
/// - message: wire "message", string. the text to echo
/// - "tag" (optional): an optional label
pub fn echo_args(message: String, options: List(#(String, report.Value))) -> Result(mcp.ToolResult, mcp.McpError)
```

Three things a reader should take from those lines. The first paragraph
of each block is the *server's* description, quoted and capped, and the
surface says so rather than letting a model read third-party prose as
Loom's. Every required parameter is a labelled Gleam argument whose wire
name is stated beside it. Every optional parameter rides in one
`options` list keyed by wire name, so it is discoverable without costing
a signature.

A program written against that surface looks like any other code-mode
program. This one is the shape the client package's live suite submits,
with one extra branch:

```gleam
import cap/mcp
import cap/mcp/fixture
import cap/report
import gleam/option
import gleam/result

pub fn main() -> report.Outcome {
  case
    fixture.echo_args(
      message: "loom-mcp-wire-fidelity",
      options: [#("tag", report.string("Tag-With_Mixed.Case"))],
    )
  {
    Ok(found) -> report.text(mcp.text(found) <> " " <> echoed(found))
    Error(mcp.ToolFailed(message: message, content: _content)) ->
      report.failure("the tool ran and refused: " <> message)
    Error(mcp.ServerUnavailable(reason: reason)) ->
      report.failure("the server never answered: " <> reason)
    Error(_other) -> report.failure("the mcp call did not settle")
  }
}

/// What the server echoed back as structured content, read field by field.
fn echoed(found: mcp.ToolResult) -> String {
  let read = {
    use echo_of <- result.try(option.to_result(found.structured, Nil))
    use message <- result.try(report.field(echo_of, "message"))
    use message <- result.try(report.as_string(message))
    Ok("echoed=" <> message)
  }
  case read {
    Ok(rendered) -> rendered
    Error(Nil) -> "the structured echo carried no message"
  }
}
```

Four details are worth naming, because each is a property rather than a
style choice. The import list is the permission grant: this program was
handed the `fixture` server and nothing else, and it can touch neither
the disk nor the network nor a process. Arguments are built with
`cap/report`'s value builders, which is the one structured-value
vocabulary every seam already carries, so an MCP argument map is composed
the way an `Outcome` is. `ToolFailed` and `ServerUnavailable` are
genuinely different events — the first is a *tool* verdict on a call that
settled, the second is a call that never reached a tool — and nothing
below the program can tell them apart for it. And the patterns are
written out in full (`message: message`, not `message:`), because vetting
parses a slightly narrower Gleam than the compiler and label shorthand is
one of the things it does not take.

## `tools/list` is attacker-controlled input

A server's listing is JSON the harness did not write, and the generator
turns it into Gleam source the harness compiles and the vetting allowlist
admits. That is the sharp edge of the whole feature. The posture that
holds it is one governing rule, three mechanisms that carry it out, and
two sets of bounds.

**The generator's discretion is names and signatures only, never
marshaling.** Every façade it emits is a doc comment, a `pub fn` header,
and one call to `cap/internal/mcp.invoke`; the marshaling — building the
argument map, encoding it, decoding the pinned result, mapping a denial
onto `cap/mcp`'s error vocabulary — lives in that one internal module,
written once by hand. Server-influenced text therefore reaches a
generated module as *identifiers and literals* and never as code that
touches the wire.

**Wire identity never bends.** Every generated body closes over the
original tool name and the original parameter names as escaped string
literals. `mcp/name`'s output is a display artifact, and escaping is
total: `\` and `"` are escaped and every codepoint outside printable
ASCII is emitted as `\u{...}`, so a literal can never carry a raw
newline, a control character, or a bidi override. Whenever mangling
changed anything at all — or the name ran past 32 characters — the result
carries `_` plus the first eight hex characters of a SHA-256 digest of
the original, so two names that differ only in shape cannot silently
become one function. A residual collision after that is engineered rather
than accidental, and the generator refuses the whole server naming both
originals instead of repairing it.

Worked, against the names the checked-in fixture server lists, plus one
name it does not:

| Original, on the wire | Generated Gleam name | What the body sends |
|---|---|---|
| `echo_args` | `echo_args` — mangling changed nothing, so no digest | `"echo_args"` |
| `Create-Issue!` | `create_issue_48f762e0` | `"Create-Issue!"` |
| `Target-Repo` (a parameter of `nested`) | label `target_repo_bc64ccdd` | `#("Target-Repo", …)` |
| `createIssue` (not on this server) | `create_issue_706a5e2e` | `"createIssue"` |

The last row is there for the pairing: `Create-Issue!` and `createIssue`
both mangle to `create_issue`, and the eight digest characters are the
whole of what keeps them two functions rather than one. The generated
function for the second row reads:

```gleam
/// A tool whose name is no Gleam identifier.
///
/// Tool "Create-Issue!" on MCP server "fixture". Optional parameters travel
/// in `options` by wire name; pass [] when none.
/// - title: wire "title", string.
pub fn create_issue_48f762e0(
  title title: String,
  options options: List(#(String, report.Value)),
) -> Result(mcp.ToolResult, mcp.McpError) {
  internal.invoke(
    "fixture",
    "Create-Issue!",
    report.object(list.append(
      [
        #("title", report.string(title)),
      ],
      options,
    )),
  )
}
```

**Server prose stays inside the comment line it was written into.**
`codegen.sanitize` replaces every control and direction-changing
codepoint with a space — C0 and C1 controls, the bidi overrides and
isolates, zero-width characters, the tag-character plane — and caps a
tool description at 400 characters and a parameter note at 120. Every
comment line the generator emits begins `/// `, and every line break
comes from the generator's own word wrap rather than from the server's
text, whose breaks the sanitizer already flattened.

**A backstop proves the other two held.** After rendering,
`codegen.scan_for_at` walks the source and fails generation if a single
`@` appears outside a comment or a string literal. Generated code needs
no attribute at all, so a stray `@` means the sanitizer failed — and
`@external` is exactly the payload a hostile listing would want, since it
is Gleam's one bridge to arbitrary Erlang. The generator refuses the
server loudly rather than hand the compiler an attribute.

### Every schema settles, and no parameter is dropped

`mcp/schema.plan` is the one place a tool's raw `inputSchema` is read,
and it has no error case: tier 3 *is* its failure mode, carried as data.
Each required parameter lands in one of three tiers.

| Tier | What lands there | What the façade takes |
|---|---|---|
| 1 | `string`, `integer`, `number`, `boolean`, or an array of those | a typed Gleam argument (`String`, `Int`, `Float`, `Bool`, `List(...)`) |
| 2 | a nested object, a `$ref`, an `anyOf`, a missing type, or a `required` name with no `properties` entry | a required `report.Value` argument, with the reason in its doc line |
| 3 | an unusable top level — the whole `inputSchema` is not an object schema | one `arguments: report.Value` holding the entire map |

Optional parameters are never typed arguments: they travel in the single
`options` list keyed by their original wire name, and appear in the doc
comment so a model knows they exist. Nothing is silently dropped at any
tier — a `required` name the server never declared becomes a tier-2
argument carrying that as its reason, because dropping a parameter is the
one thing this reading must never do.

The subset is deliberately narrow, and the falsifier for that choice is
written into `codegen_test`: measured against a plausible GitHub-shaped
listing, 30 of 31 required parameters land in tier 1, and if mainstream
servers ever push tier 2 past 25% of required parameters, that is the
trigger to widen the subset and generate nested records.

### Ceilings, and what each one costs a hostile server

| Bound | Value | What happens past it |
|---|---|---|
| tools in one listing | 256 | the server is refused whole |
| rendered surface | 64 KiB after truncation | the server is refused whole |
| `tools/list` pages | 64 | `TooManyPages`; the listing fails |
| one JSON-RPC line | 16 MiB | `LineTooLong`, and the client latches dead |
| one `cap_result` | the cap channel's frame cap, less a 64 KiB envelope margin | the call is refused `mcp_malformed` |
| result nesting | msgpack's `max_depth`, less the two containers the frame adds | the call is refused `mcp_malformed` |

Two refusals are narrower than the rest by design. A residual *tool* name
collision refuses the server; a *label* collision inside one tool degrades
that one function to its tier-3 whole-value form and leaves the rest of
the server typed. And the result ceilings are measured in `client/mcp`,
at the point where the answer is still a refusal a program can read: an
oversized frame dropped further down would leave the program blocked
until its wall deadline, and an over-deep one would settle every
in-flight call and close the channel — one hostile answer costing the
whole execution instead of one call.

## The wire

A call from a generated façade is a capability call like any other.
`cap/internal/mcp.invoke` sends it under the capability name
`"mcp." <> server` with the arguments
`{tool: <the server's original name, verbatim>, arguments: <the map>}`,
and the harness answers with the pinned result shape
`{content: [<block>...], is_error: Bool, structured?: <value>}`, whose
`structured` key is present only when the server sent one.

The plan is `satellite.ServedHere`, exactly as the orchestration seam's
is: the harness answers over a socket it already owns, building no
`CallSpec`, entering no jail, composing no policy. There is nothing to
compose a policy *for* — the call spawns no process and touches no path.
What bounds it instead is the pooled outstanding-effect cap the satellite
host applies before any plan is served, the execution's wall deadline,
and this seam's own 60-second call timeout, which sits deliberately below
the host's 120-second one so a program that asked a server a question
gets a refusal rather than a silence.

The arguments are converted to JSON at plan time rather than after
dispatch, so a value this wire cannot carry is refused before a round
trip that could not have happened.

### What a program reads back

| In-band code | Raised when | What `cap/mcp` makes of it |
|---|---|---|
| `mcp_unavailable` | the client is dead — the child exited, framing broke, the bytes stopped being UTF-8 | `ServerUnavailable(reason)` |
| `mcp_timeout` | `tools/call` did not settle inside the seam's call timeout | `McpDenied("mcp_timeout", …)` |
| `mcp_malformed` | the answer was not the shape the method promises, or would not cross to the capability wire | `McpDenied("mcp_malformed", …)` |
| `jsonrpc_<code>` | the server answered a JSON-RPC error; `-32601` arrives as `jsonrpc_-32601` | `McpDenied(code, message)` |
| `unsupported_cap` | `mcp.<server>` naming a server this host never configured | `McpDenied(...)` |
| `invalid_argument` | the call's own `{tool, arguments}` could not be read, or the arguments do not cross to JSON | `McpDenied(...)` |

Two outcomes are not denials at all. A call that settled with
`is_error: true` is a *tool* verdict, and reaches the program as
`ToolFailed(message, content)`. A `cap_result` that does not match the
pinned shape is `ResultMalformed`. The server's own JSON-RPC code travels
in the string rather than being folded onto one name, because it is the
one fact a program could branch on.

### Two vocabularies that disagree

`mcp/interchange` is the translation between the capability wire
(msgpack) and the MCP wire (JSON), total in both directions: every input
settles as a converted value or as a fault naming the path it was found
at, never a crash and never a silent substitution. Four rules cover the
disagreements, and each was a choice:

- **A msgpack integer always fits JSON**, since `core/json.Int` is
  arbitrary precision. The asymmetry runs the other way.
- **A JSON integer outside `[-2^63, 2^64 - 1]` fails the whole
  conversion** rather than being wrapped, clamped, or turned into a
  float. A program reading a wrapped integer would act on a number the
  server did not send.
- **A msgpack binary is refused in an argument.** JSON has no byte
  string, and both encodings a caller might expect — base64 text, an
  array of integers — are guesses about what the server wants.
  `cap/report`'s builders cannot construct one, so this is unreachable
  from a vetted program.
- **`NilValue` and `Null` are each other**, and a non-string map key is
  refused, because inventing a rendering for one would change what the
  server is asked.

Floats cross unchanged both ways. Depth needs no ceiling here: both
parsers already bound nesting at the same `max_depth`, so a value
arriving is shallow enough for the encoder on the far side.

## What runs where

Three regions, and the boundaries between them are the point.

**In the harness VM:** one client actor per server, its port transport,
and the router arm. The actor owns the child process for the session,
handles the handshake, holds one deadline per in-flight call, and answers
`Unavailable` in band once it is dead. It never restarts a peer and it is
never `process.call`ed — every public call is a monitored
send-and-select, because `process.call` panics on a timeout and on a dead
callee, and a caller holding a tool-call verdict must not die of a wedged
client. The declared client capabilities are an **empty object**, and a
test pins the emptiness: no `sampling` (a server must not spend Loom's
model), no `roots` (a server learns nothing about the filesystem), no
`elicitation` (a server must not put questions to a human through the
harness). A server-initiated request is answered with JSON-RPC's
method-not-found; a notification is decoded and dropped.

**Inside the satellite:** the generated façades, compiled into the
vendored prelude of that execution's hermetic build, running under the
same jail and the same pooled budget as everything else a code-mode
program does. The façade holds no socket and no server handle — it
marshals and calls, and the capability channel carries it out.

**On the child's own stdio:** the server. Its stderr is deliberately not
merged into stdout, because `stderr_to_stdout` would interleave
diagnostics into the newline-delimited JSON-RPC stream and corrupt
framing; the child inherits the BEAM's stderr instead, so a server's
complaints land on the harness's own.

### The spawn is a primitive, and the jail is an open decision

`mcp/client` is written against `mcp/transport.Transport` and nothing
lower. `PortTransport` is the production mechanism and it spawns
**unjailed**; `ChannelTransport` is the test seam — an in-process peer
that receives the connect, sees every outbound line, and delivers inbound
bytes through the same messages a port does, which is why every client
behaviour is provable without an OS process.

Whether an MCP server should run inside a jail at all — through the
`loom-exec` helper, the way every other third-party process Loom starts
does — is an **open decision rather than a deferred implementation**. It
has not been designed, not merely not built. The seam is where the answer
would attach, and it exists so that the answer can land without rewriting
the actor. Until then, an unjailed spawn is the production primitive and
not the final security posture; the threat model in
`docs/architecture/effects.md` already counts a compromised third-party
tool among the things defended against, and this is the place that
defense is currently owed. `docs/next.md` carries it as such.

## What v1 leaves out

Everything below is refused rather than deferred by accident, and each
line says what would bring it back.

| Absent | Why | What would reverse it |
|---|---|---|
| Resources, prompts, logging, progress, cancellation, completion | each is surface a hostile server could push data through, and a tool-calling client needs none of it | a capability that actually needs one, argued on its own |
| Sampling, roots, elicitation | a server must not spend Loom's model, learn about the filesystem, or question a human through the harness; upstream deprecated the first two in 2026-07-28 | nothing short of a design change; a test pins the empty capabilities object, so widening it is deliberate and test-breaking |
| The 2026-07-28 stateless revision | it has no `initialize`, and servers in the field speak the older lifecycle | servers in the field speaking it |
| `listChanged` handling | it decodes faithfully and is ignored: this client lists tools once per connection | a server whose tool set changes mid-session — which also means re-rendering a description the model was already given |
| HTTP and SSE transports | a locally-spawned server speaks stdio, and a spawned child is what the jailing story attaches to | a server worth reaching that speaks nothing else, decided together with the jail question |
| Restart and reconnect supervision | a dead peer latches dead and answers `Unavailable` in band | phase 5's LSP client (#25), which needs the same substrate: a supervised, long-lived stdio peer |
| Nested records for tier-2 parameters | the typed subset covers 30 of 31 required parameters on a GitHub-shaped listing | tier 2 past 25% of required parameters on mainstream servers — the falsifier is in `codegen_test` |
| Per-tool trust | a human trusts a server, not a tool | a policy vocabulary keyed on tool identity, which is a protocol change and strictly more work than generating modules |

Two things are owed rather than declined. The **adversarial corpus** for
hostile `tools/list` input — the shape of `packages/codemode/test`'s
vetting corpus, aimed at the generator — is the long pole and is not
written. And the end-to-end runs against a checked-in fixture server that
is deliberately friendly in its protocol and hostile only in its names; a
run against a third-party server from the wild is still owed.

## Where the code lives

| Path | What it holds |
|---|---|
| `mcp/jsonrpc.gleam` | The JSON-RPC 2.0 envelope: encoders, and one total decoder for the three inbound shapes. |
| `mcp/protocol.gleam` | The five methods v1 speaks, version negotiation against a closed list, and the deliberately empty client capabilities. |
| `mcp/stdio.gleam` | Line framing both ways: a push buffer bounded at 16 MiB, and `frame` for the outbound side. |
| `mcp/transport.gleam` | The `Transport` seam, the `Spawn` spec, and `utf8_prefix`, which reassembles characters split across pipe chunks. |
| `mcp/client.gleam` | The actor: handshake, `list_tools` with bounded pagination, `call_tool`, `stop`, and the death latch. |
| `mcp/schema.gleam` | The three-tier reading of a raw `inputSchema` into a parameter plan; no error case. |
| `mcp/name.gleam` | Mangling a server-chosen name into a Gleam identifier, with the digest rule that keeps two originals distinct. |
| `mcp/codegen.gleam` | The generator: one `cap/mcp/<server>` module and its rendered surface, the sanitizer cage, the `@` backstop, and every refusal. |
| `mcp/interchange.gleam` | msgpack ↔ JSON, total both ways, with the four disagreements decided. |
| `mcp/internal/ffi_port.gleam` | The port externals over `mcp_ffi.erl` — this package's complete inventory of impurity. |
| `client/catalog.gleam` | `[mcp.<name>]`: the key grammar, the mangling gate, and the `api_key_env` indirection. |
| `client/mcp.gleam` | The layer: boot per server, the refusal wording, the `mcp.<server>` router arm, the pinned result shape, and the result ceilings. |
| `client/codemode.gleam` | `over_mcp`, `seam_allowlist`, `seam_caps_on` — the one `Config.mcp` field and the four things it widens. |
| `cap/mcp.gleam` | The generated façades' vocabulary: `Content`, `ToolResult`, `McpError`. Types only, no authority. |
| `cap/internal/mcp.gleam` | The one marshaling seam: `invoke`, the pinned result decoder, and the denial-code mapping. A program cannot import it. |
| `client/test/support/mcp_fixture.escript` | The checked-in third-party server the end-to-end spawns: three tools, one of them an oracle that echoes its arguments back. |
| `client/test/client/codemode_live_test.gleam` | A program reaching a real server process through a real pipe, and the wire-fidelity assertions on what crossed. |

Each Gleam path is relative to its package's source root —
`mcp/codegen.gleam` is `packages/mcp/src/mcp/codegen.gleam` — except the
last two rows, which are under `packages/client/test/`.
`docs/architecture/code-mode.md` is the depth on the pipeline these
modules are compiled into and on what each of its layers confines;
`docs/architecture/effects.md` holds the threat model and the two-channel
doctrine; and `packages/mcp/CLAUDE.md`, `packages/cap/CLAUDE.md` and
`packages/client/CLAUDE.md` are denser than this document about their own
packages.
