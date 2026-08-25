# Design note: what the agent sees, and what it can do

Status: **note, not a work package.** Three related gaps found by reading
the code, not by anything failing. Nothing here is built. Promote to a
numbered work package when M4 closes.

The three are one subject seen from three sides: the model's context is
nearly empty, its affordances are narrower than the design implies, and
the one lever that would make a large context cheap is unused.

## 1. The system prompt is a slot with nothing in it

`wiring.Config` and `serve.Config` both carry `system: Option(String)`,
threaded to the provider and sent with every generation. Nothing ever
populates it. There is no default, no assembly, and no description of the
environment the agent is working in.

At minimum it should carry the working directory and platform, the
repository's own conventions, and the tool surface. But the interesting
part is Loom-specific: **the agent is operating inside a sandbox whose
enforcement varies by kernel.** `make selftest` exists precisely because
bwrap, Landlock, and cgroup support differ per host, and the broker
reports degraded enforcement honestly rather than hiding it. A model that
does not know it is jailed — or does not know the jail is degraded — will
misread a policy refusal as a bug in its own reasoning and retry
something that cannot work. The refusals are already structured and
in-band; the prompt is where the agent learns to expect them.

The design cites omp's "context-frugal rule injection" as an influence.
Frugality is the right instinct and cuts against dumping the whole
environment in: what belongs here is what changes the agent's behavior,
not what is merely true.

## 2. The model cannot start or talk to another agent

The tool registry is `bash`, `fs_read`, `fs_write`, `fs_edit`, `grep`,
`hashline`, and `blob`. There is no messaging tool and no spawn tool.

So while the messaging plane is real and working — four patterns,
durable payloads, ephemeral doorbells — **nothing exposes any of it to
the model.** Strands are created by the `create_strand` protocol command,
which is a human acting through a client. Every multi-agent story the
design tells is operator-driven today. The model is a participant in
someone else's orchestration, not an orchestrator.

Closing this means tools: `spawn_strand`, `send_message`, and something
to await a reply. The important part is *why a tool and not a capability*,
because the same question arrived from the other direction when a
`cap/strand` was considered and deferred (see `spec-gaps.md`, WP-J item
5). A tool runs in the harness: trusted code, policy-checked, and able to
commit durably — which the messaging doctrine requires, since a message
that changes what the recipient does must travel through a commit. A cap
runs inside the untrusted satellite. Handing jailed model-written code a
messaging capability imports an untrusted writer into a plane built for
trusted ones; handing the *model* a messaging tool does not, because the
harness still decides what the tool call does. Same feature, two homes,
and only one of them keeps the trust story intact.

Three design questions to settle before building it, none of them
obvious:

- **What does a spawned strand inherit?** Its parent's policy, or a
  narrowed one? Unrestricted spawning is a budget amplification hole
  wearing a different hat — the same hole pooled budgets closed for code
  mode.
- **Does `await_reply` block an operation?** The state machine has a
  durable program counter and an effect sandwich; a blocking await is an
  effect with a deadline, not a new kind of thing. It should reuse that
  machinery rather than invent a parallel wait.
- **What does the parent see when a child fails?** The orchestration doc
  already answers this for operations; a spawned strand should not get a
  different failure story.

## 3. Caching is measured but never requested

`Usage` records `cache_read`, `cache_write`, and `cache_write_1h`, and
`UsageCost` prices them. The ledger is durable and correct. But
`cache_control` appears nowhere in the provider package: **Loom faithfully
accounts for cache hits it never asks for.**

The straightforward fix is marking the stable prefix — system prompt,
tool definitions, early conversation — so a provider that supports
caching can serve it. The Loom-specific complication is worth stating
plainly, because it will shape where the breakpoints go:

**Rewrite and compaction are hostile to caching.** A cache hit needs a
byte-stable prefix, and precise rewrite exists to mutate history while
compaction exists to replace a long prefix with a shorter one. Either
invalidates everything after the point it touches. This is not a reason
to skip caching; it is a reason to place breakpoints so that the
stable-forever material (prompt, tools) sits ahead of everything a
rewrite can reach, and to expect a rewrite to cost a full cache write on
the next turn.

The feedback loop is already built: the usage ledger's cache fields
measure whether any of this works, per turn, durably. That is an unusual
luxury — most systems add caching and guess. Here the instrumentation
landed first.

## Why these three belong together

A `spawn_strand` tool is close to useless if the spawned strand's system
prompt does not tell it what it is, what it is working on, or what it is
allowed to do. And both of them make the context longer, which is what
makes the unused caching lever expensive. Building any one of the three
alone leaves most of its value on the table.
