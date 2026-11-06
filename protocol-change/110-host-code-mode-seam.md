# protocol-change/110: a code-mode seam the host defines

**Status**: PROPOSED 2026-11-06, built in the PR that adds this file.
**Affects**: `client/codemode.Config` (one field, `host`) and
`client/codemode.OwnerSide` (one field, `host`); `client/serve.Settings` (one
field, `code_mode_host`); the remote node vocabulary of
[078](078-distributed-runtime.md), whose `McpPlan` gains a field and whose
`version` goes from 6 to 7; the untrusted link of
[109](109-untrusted-executors.md), whose callback check gains one rule; and the
capability prelude's internal module `cap/internal/mcp`, which gains
`host_invoke` and `host_invoke_typed`. No Part 1 interface and no client
control protocol command changes.
**Raised by**: aegis (lightninglabs/aegis), a security-review service built on
Loom. Its hunters make one tool call per model turn; on its first staging scan a
hunter read about 3.6M input tokens to write about 15K, and half of them ran
into the hour-long turn limit. Aegis is adopting code mode with a module of its
own, `cap/aegis`, over the job's catalog tools. Its design is aegis's
`docs/design-notes/code-mode-seam.md` and its protocol-change/067 and 068.
**Builds on**: 078 (the owner port, `cap_placement`, the MCP plan), 109 (the
untrusted link and its owner callbacks), the MCP façade generator
(`mcp/codegen`).

## Problem

A program is vetted against one of Loom's own seams (`codemode/vet/policy.Seam`),
a closed set of `cap/*` modules a host selects from, widened by the doors the
host wired: MCP servers, a language server, a blackboard, governed evolution.
`client/codemode` offers no way for a host that embeds Loom to say anything
else. Aegis needs three things it cannot express today:

1. **Its own allowlist, per session.** Aegis admits `cap/search`, `cap/lsp`,
   `cap/task`, `cap/kv` and `cap/report`, and refuses `cap/fs`, `proc`, `net`,
   `git`, `peer`, `actor`, `schedule` and `job`. It wants `cap/lsp`'s queries
   without `lsp.rename`, which writes files.
2. **A module of its own.** `cap/aegis` exposes the job's catalog tools
   (findings, notes, verdicts) with their argument and result types, vendored
   into the program's prelude the way `cap/mcp/<server>` is, and shown in the
   `code_mode` description.
3. **Calls that are checked as direct calls are.** A program's
   `aegis.file_finding(..)` must reach the same handler a direct
   `file_finding` call reaches, with the same decoder, the same stage and grant
   checks, and the same refusal.

And it must work where aegis runs code. Aegis runs model-influenced code only
in an untrusted runner pod, which is a 109 executor: never a distribution
peer, no credentials, no egress. The controller has no jail. So the program
runs on the executor, beside the job's checkout, and `cap/search`, `cap/lsp`
and `cap/kv` are answered there, while every `cap/aegis` call must come back to
the controller, which owns the store.

## What was considered

### The host calls `codemode.execute` itself (rejected)

The pipeline is public, and a host can pass its own `VetPolicy`. It gives up
the `code_mode` tool, the background modes, the call log and the description,
and on a remote workspace it has nothing to send the program to: the executor
runs `code_mode` as a tool call, not as a pipeline a host can reach.

### The host as an in-process MCP server (rejected)

`cap/mcp/<server>` already has generated types, a description surface, a
router arm and owner-bound placement. A host could register its tools as a
fake MCP server. The module would then be named `cap/mcp/<server>`, its calls
would travel as `mcp.<server>` beside real MCP servers whose answers come from
a process an operator configured, and nothing would narrow the rest of the
seam. The generator is the part worth reusing, and this proposal reuses it.

### A handler closure per function (rejected)

The host could supply `fn(arguments) -> Result(Json, Refusal)` per function.
Then "checked as a direct call is" depends on the host calling the same code
from two places, and a refusal's text can drift between them. Taking the
host's `tool.Tool` makes the direct call and the program call the same `run`,
so the decoder, the checks and the refusal are one value by construction.

### A route of the host's own for the remote case (rejected)

Aegis's first draft added `POST /v1/agent/codemode`, a stream its controller
opens to carry each `aegis.*` call back. 109's link already carries owner
callbacks on a connection the orchestrator opened, checked per binding, and a
`code_mode` call already uses the session's owner-bound capabilities as that
call's strand. A host module's calls are owner-bound capabilities, so they use
that path.

## Decision

### What a host declares

`client/host_seam.HostSeam(imports, withheld, module)`:

- `imports`: the `cap/*` modules a program may import. A name that is not a
  shipped capability module or an MCP façade (`cap/mcp/<segment>`) is refused
  when the seam is built, so a misspelling cannot silently drop a module.
- `withheld`: capability names refused although their module is admitted, such
  as `lsp.rename`.
- `module`: `HostModule(name, functions)`, where each `HostFunction(tool,
  output)` is a `tool.Tool` the host also offers directly and the optional JSON
  schema of its `details` on success.

`host_seam.build` checks the declaration and generates the module. The name
must be a lower-case Gleam identifier that is not a shipped `cap/*` module,
`cap/internal` or `cap/mcp`, and no tool may appear twice.

### The generated module

`mcp/codegen.generate_host(name, descriptors, digest)` is `generate` with a
different target. Every body calls `cap/internal/mcp.host_invoke` (or
`host_invoke_typed` for a function with a declared output) under the capability
`host.<name>`, with the tool's name and its JSON arguments, and the module is
`cap/<name>`. The descriptors are the tools' names, descriptions and argument
schemas. Bounds, name mangling, the sanitizer and the `@` backstop are the MCP
generator's, unchanged, because a host's descriptions are text a model reads and
the module is compiled into a jailed program like any façade.

Functions return `cap/mcp`'s vocabulary: a refusal is `ToolFailed(message)`
carrying the tool's own text. A seam with a host module therefore also admits
`cap/mcp`, which declares types and carries no authority.

The module lands in the vendored prelude (`compile.generated_path`), because it
imports `cap/internal/mcp` and Gleam admits an internal module only to its own
package.

### How code mode applies it

`codemode.over_host(config, Some(layer))` sets one field, which does four
things together, as `mcp` and `lsp` each do:

1. **Vetting.** `seam_allowlist` applies the layer last: every `cap/*` module
   the imports omit is removed, and the host module and `cap/mcp` are added.
   The layer narrows only. `cap/lsp` on the imports of a host with no language
   server stays refused.
2. **Description.** `seam_caps_on` drops withheld names and names whose module
   the imports exclude, and adds `host.<name>`. The module's surface joins the
   extra surfaces.
3. **Build.** The module's source joins the generated modules the hermetic
   build may write.
4. **Routing.** An arm outside every other refuses a withheld name and answers
   `host.<name>`.

It applies to the workspace and orchestration seams. An installed extension and
a resident hook keep the allowlists they were installed and frozen under.

### How a call is answered

The arm decodes `{tool, arguments}`, finds the function whose tool has that
name, and plans a served call. In the served worker it asks the strand's tool
list for that tool (`codemode/tool_gate.holding`, the same question and refusal
`tool_gate.precheck` uses for every other capability), and then runs the tool's
own `run` on the arguments under a rebuilt `tool.Ctx`. The outcome becomes the
MCP-shaped result `cap/internal/mcp` decodes: the text blocks, `is_error`, and
the details as the structured value when the function declared an output and
the tool succeeded.

`tool_gate.decided` treats `host.` as decided, like `mcp.`: the authorizing tool
is named per call, so the router asks rather than the table.

### Where it runs

Code mode runs where the session's workspace is placed, as it does today.

- **A local workspace** composes the arm into its own execution. The tool's
  context is the execution's, rebuilt as an evolution operation's is.
- **A workspace on an executor**, trusted or not, runs the program there. The
  owner sends the seam in the plan the executor already asks for
  (`McpPlan.host`, a `HostPlan` of the imports, the withheld names and the
  generated module as a `Facade`); no tool crosses. The executor applies it
  with `owner_codemode.hosting`, so it vets and describes programs under the
  seam. `cap_placement` makes `host.` owner-bound, so `over_owner` sends every
  host call back as an `OwnerCapCall`. On the owner, `OwnerSide.host` holds the
  layer and the session's clock, and `owner_answering` answers the call from
  the same arm, with the Agency's `holds` and a context of the call's
  coordinates.

`client/serve` builds the layer once per session from `Settings.code_mode_host`
and refuses the session with the reason if the declaration is wrong. It applies
it to the local configuration, to the owner's side and to the plan.

### The owner holds the seam

Vetting on an executor is the executor's. An untrusted executor can ignore the
plan and send any owner-bound capability it likes, so the owner judges each one
again: `host_seam.owner_admits` refuses a withheld name, and a call in a
code-mode family (`strand`, `notes`, `schedule`, `peer`, `execution`,
`workflow`, `evolution`, `mcp`, `host`) whose module the imports exclude. On a
session whose host admits no `cap/strand`, a hostile executor gets no
`strand.spawn` from the owner, although the owner's Agency would answer one.
Names outside those families, such as an extension's `ext.remember`, are not
code mode's to judge and pass as before.

### The link requires a running program

109's link already admits a `capability` callback only under a binding it
minted and has not retired, with an id above every one it accepted on that
binding, and while a `run` of the binding's session is in flight at the
callback's operation, step, source index and strand. A host call must
additionally name a `run` whose tool is `code_mode`
(`untrusted_link.from_a_program`). Only a program reaches a host module, so a
host call under another in-flight tool call is forged. Other capabilities keep
109's rule, which an extension's own owner-bound calls rely on.

### The wire

`McpPlan` gains `host: Option(HostPlan)`. Over distribution the record's shape
changes, so `protocol.version` goes to 7 and an executor upgrades with its
orchestrators, as every version step requires. Over the untrusted link the plan
is JSON with a `host` member, `null` for none, decoded totally; the attach that
precedes the plan carries the version, so the two sides already agree.

## Threat model

The parties are the host that embeds Loom, the model and the program it
writes, and, on a remote workspace, the executor.

**The host is trusted.** It chooses the seam, writes the tools and their
descriptions, and runs them in its own VM. Loom checks its declaration for
mistakes (an unknown module, a shadowing name, a duplicate tool, the
generator's bounds and sanitizer) but does not defend against it.

**The program is untrusted** and gains nothing new:

- It can import only what the narrowed allowlist admits, and the host's
  module and `cap/mcp`. The narrowing removes modules; it cannot add one whose
  door the host did not wire.
- A host call can run only a function the host declared, only if the strand
  holds that function's tool, and only through the tool's own `run`. That is
  exactly what the model could do with a direct call to the same tool.
- The arguments are the program's and are decoded by the tool, as a direct
  call's are. Converting them to JSON is total, and a value with no JSON form
  is refused in band.
- The program cannot name the strand, operation or step it acts as; they are
  the dispatching `code_mode` call's.

**The executor is untrusted** (109). It sees the plan: the seam and the host
module's source and surface, which are a description of the host's tools and
no more than the model is told. It never holds a tool, a credential or the
host's state. It can:

- ignore the plan and run any program in its own jail, which is already true
  of anything it runs;
- send owner-bound calls the seam does not admit, which the owner refuses
  (`owner_admits`);
- send host calls while a `code_mode` call of the session is in flight, as
  that call's strand, which is what the program could do;
- deny service.

It cannot:

- call a host function outside a running `code_mode` call of the session, under
  another tool call, through a retired binding, or by replaying an accepted
  callback id;
- reach a capability the host's seam excludes, on the owner;
- reach a tool the host did not put in its module, or one the strand does not
  hold.

**Residual risks.**

- While a `code_mode` call runs, a hostile executor can make any host call that
  call's strand may make, in any number up to 109's bounds (64 outstanding per
  binding), with arguments of its choosing. The program could have done the
  same; the host's tools must enforce their own limits (aegis's writer mark and
  per-stage checks do). Narrowing this to the calls the program actually made
  would need the orchestrator to see the program's calls, which only the
  executor sees.
- A host tool runs in the host's VM under a context with no workspace. A tool
  that reads `ctx.workspace` or the filesystem seam gets nothing on an owner.
  Host modules are for the host's own state.
- A background program (109 slice 2) reaches no host module over the untrusted
  link: the link requires a foreground `run`. That is aegis's first cut; a
  later change can admit a background execution's start under the same rule.

## What it costs

- One field on two code-mode records and one on `serve.Settings`, each `None`
  by default, so every existing host is unchanged.
- A wire version step for distributed executors.
- A second entry point in the MCP generator and two in `cap/internal/mcp`, which
  share the existing code.
- The owner-side admission check adds a list lookup per owner-bound call on a
  session with a host seam.

## Tests

- `client/host_seam_test`: a program importing each refused module is refused
  at vetting under both seams; the admitted modules pass; a host seam never
  widens; the description carries the module and drops the rest; the module
  calls the `host.` family; bad declarations are refused; a withheld name is
  refused by the router; a host call runs the host's tool; a refusal reads the
  same as the direct tool's, locally and on an owner; a strand without the tool
  is refused before it runs; an owner refuses what the seam excludes.
- `client/remote/untrusted_host_seam_test`: over the real link with a
  hand-driven executor, a host call is refused with no program running, under
  another tool call, after the program ends, on a replayed or older id, and
  through a retired binding, and reaches the owner while its program runs.
- `client/untrusted_host_codemode_test`: a real executor plane behind the
  untrusted gateway runs a program that greps with `cap/search`, hovers with
  `cap/lsp` over a `gleam lsp` server, files a finding through `cap/aegis` and
  reads the tool's refusal for a second; the executor describes the narrowed
  seam, and a program importing `cap/fs` is refused at vetting there.
- `remote/untrusted_codec_test`: the plan's host member round-trips.
