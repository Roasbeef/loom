# Approvals and sandboxing

Every command that Loom runs on a model's behalf runs in a kernel sandbox, under a policy that the session sets. When a call needs more access than the policy grants, Loom refuses it before anything runs, and you decide whether to widen the policy for that one call. This page explains the sandbox, the policy, and the approval flow.

## What Loom defends against

Loom defends against four threats, in increasing order of difficulty:

- **Accidents**: a delete in the wrong directory, a force-push, a `.env` file swept into a commit.
- **Prompt injection**: hostile repository, web or tool content that steers the model toward exfiltration or destruction.
- **Malicious generated code**: a program the model wrote that attempts escape or persistence.
- **Compromised third-party tools**: a malicious language server, which runs jailed.

It does not defend against a hostile user on their own machine, and it does not defend against kernel zero-days.

## Rule Zero

BEAM processes isolate faults. They do not isolate untrusted code. Any process in the virtual machine can call `os:cmd`, open any file the operating system user can open, and dial the network. There is no capability model inside the VM to rely on.

So Loom's first rule, Rule Zero, is that model-influenced execution never runs in the harness VM. The BEAM node orchestrates. Shell commands, agent-written programs and installed extensions run in separate OS processes under kernel-enforced policy. The actor model buys supervision and recovery, and the kernel buys isolation. The two are never confused.

## The sandbox

A small Go helper, `loom-exec`, is a separate OS process from the daemon. It restricts itself and then executes the target, so the target starts already inside the jail. On Linux:

- `bwrap` builds the namespaces and the mount view. Protected paths are masked, whatever kind of file they are.
- Each execution gets its own cgroup v2 group with `memory.max` and `pids.max`.
- The helper sets resource limits, applies a Landlock ruleset, and sets `no_new_privs`.
- When the network is off, a seccomp filter stops the process from creating network sockets.
- The helper writes a report of which layers actually took effect, and the broker reads it.

On macOS the helper runs the same stage under a generated Seatbelt profile that denies by default. macOS has no per-execution cgroup, so it enforces less, and the report says so. Run `make selftest` on the machine you plan to use. By default the broker refuses to run a command when a layer the platform promises is missing or skipped: Linux must enforce everything, and macOS may lack only the three gaps that ADR-006 names. `loomd --best-effort` accepts broader gaps, and `loomd --full-enforcement` demands the full contract on every platform.

The child's environment is constructed from an allowlist and never inherited, so the policy alone documents what a jail can see. A tool sees only the variables you name under `[tools]`.

MCP servers are the exception. Configured MCP servers currently run as ordinary host child processes, so treat each one as a trusted installation.

### Containers and guest VMs

A container changes what the helper can enforce. In a plain `docker run`, bubblewrap cannot create a user namespace, so the jail never comes up: the self-test measured 0 of 11 probes enforced, and a model-written program is confined only by Docker itself. The full-isolation posture in [`docs/docker.md`](https://github.com/Roasbeef/loom/blob/main/docs/docker.md) restores Loom's own layers by removing most of Docker's confinement, which suits a dedicated machine and not a shared host.

For a stronger boundary than a shared kernel, `loom --vm` opens a session whose tools run in a libkrun guest VM for that workspace, and `loom run -p "..." --vm` does the same headless. The same jail runs inside the guest, on the guest's kernel, and the guest's network denies by default. There is one guest per workspace, and it runs until `loom vm down`. Guests have booted on macOS and on Linux x86_64 with KVM. Linux arm64 has not been run.

## The policy

A call runs under a policy composed from the session's base policy, the tool's own requirements, and any grants the call carries. Composition is most-restrictive-wins, and grants are the only way to widen it.

| Field | How composition treats it |
|---|---|
| Readable and writable roots | A base root covers a request inside it, and the result is the narrower request. |
| Network | `off` is stricter than `full`. The default for shell commands is `full`, and `[tools] network = "off"` or `loomd --network off` disables it. |
| Limits | The smaller value wins. |
| Environment | The allowlists intersect. |
| Protected paths | They union, and no grant can remove one. |

The default base lets a command write inside the workspace and read most of the host except protected paths. For tighter reads, set `read_scope = "workspace"` under `[workspace]`, or start with `loomd --read-scope workspace`. With the defaults, a jailed command can read most of the host and reach any host on the network, so set `network = "off"` and `read_scope = "workspace"` where that matters.

Every command and every code-mode capability call passes through one function in the harness, the broker's `clear_call`. The native file tools run in the harness and enforce their own path containment. It composes the policy, refuses or narrows the call, reserves a slot against a pooled cap, mints a token, borrows a helper and dispatches. From that point the caller receives exactly one settlement, however the execution ends. The token binds the operation, step, policy and deadline, and settling revokes it. An abort revokes every token of an operation and signals the whole process group, so no orphaned process is left.

## Asking for more access

A call can declare what it needs. `bash` and `code_mode` accept a `permissions` argument with `readable_roots`, `writable_roots` and `network: "full"`, at most 32 paths in all. The native file tools, `fs_read`, `fs_write` and `fs_edit`, ask for the exact path they are about to touch. If the policy falls short, the call is refused before any process starts or budget is spent, and the refusal names the grants that would fix it.

::figure approval

## What you see

If someone is attached, the refusal becomes a question. The terminal opens a dialog with the captured action, the requesting strand and the exact grants, and no choice is selected when it opens. The web page draws a card instead, in its own region above the composer, and ignores clicks for 600 ms after it appears. Your choices:

- **Allow once** authorizes one execution of that call.
- **Allow for the session** does the same and remembers the grants for later calls. It is offered only when every grant can be remembered: readable roots, writable roots and full network access. One narrower case exists: a request for unlimited wall time alone can be remembered for that exact tool and arguments. On the web, only the owner's page offers it.
- **Deny** rejects the question.

The call waits about five seconds for an answer. After that, or when nobody is attached, it settles as refused and the question stays pending. When you answer later, Loom sends the model a notice so it can issue the call again and spend the approval.

An approval is bound to the action by a digest of the call's effective arguments. A call that would do something else can neither claim the record nor spend it. A yes to a harmless command cannot be spent by a different command later.

The number of questions is limited too. A record stops opening new prompts after three asks, unless an approval was actually used, so a model that keeps retrying a refused request cannot wear you down. If two operators answer at once, the first answer to commit wins and the other sees that the decision is stale.

A refusal that happens inside a running command does not become a question. A raw kernel denial reports no grant to ask for, and a capability refused inside a code-mode program arrives after the program's earlier effects happened. Both stay ordinary results, and the model can submit a new call that declares the permissions it needs.

## Standing authority

Two kinds of authority outlive a single call.

- **Remembered grants** come from allow for the session. Only the owner can list and remove them, through the session protocol's `permissions` and `permission_forget` commands. The owner's web page lists them in its Session pane, each with a Forget button. Running commands keep the authority they started with.
- **Added directories** come from the operator. `/add-dir PATH` adds read access and `/add-write-dir PATH` adds read and write. Only the owner or an operator may add one. The path must be an existing directory, and a write addition under a protected path is refused.

## Crashes and restarts

An approval is a durable record. If the daemon dies while a call waits, the call is not run again, and the question stays pending. An answer is spent only by a call with the same want and the same action. A crash between spending an approval and dispatching the command spends the approval without running it, which is the safe direction.

## Read more

- [`docs/architecture/approvals.md`](https://github.com/Roasbeef/loom/blob/main/docs/architecture/approvals.md): the record, its states and the decision rules.
- [`docs/architecture/effects.md`](https://github.com/Roasbeef/loom/blob/main/docs/architecture/effects.md): the broker, the wire, the jail and the self-test.
- [`docs/adr/006-macos-seatbelt-boundary.md`](https://github.com/Roasbeef/loom/blob/main/docs/adr/006-macos-seatbelt-boundary.md): why macOS enforces less than Linux.
- [`docs/architecture/microvm.md`](https://github.com/Roasbeef/loom/blob/main/docs/architecture/microvm.md): the guest VM tier and its known gaps.
- [`docs/docker.md`](https://github.com/Roasbeef/loom/blob/main/docs/docker.md): the container image and its two isolation postures.
