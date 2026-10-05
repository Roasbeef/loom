# 069: preserve component state across live upgrades

**Status:** Proposed for implementation on 2026-10-04, under the owner's
authorization to implement and demonstrate live component upgrades.
**Affects:** Extension manifests, the trusted satellite control boundary,
operator control, and the pinned extension runtime dependencies.
**Relates to:** [068](068-runtime-evolution.md) and
[ADR-007](../docs/adr/007-extension-tiers-and-brokered-egress.md).

## Problem

Protocol 068 preserves a session while replacing its extension satellite.
The replacement has a new process and fresh ephemeral state. Selecting an
earlier candidate starts another fresh satellite. That is useful for ordinary
extensions, but it cannot preserve a populated actor while changing its code.

Weft's system-message decoder currently treats `change_code` as unimplemented.
Loading a BEAM module would not close that gap: a running actor retains its
state and callback function values. Both must migrate together, and callers
must know whether queued messages remain compatible with the new handler.

## Contract

An opted-in component has an immutable implementation identity, a state
version, and a message-boundary identifier. An upgrade names the expected
current identity and target identity. The boundary identifier MUST match.
The supported path MUST have an explicit migration from the current state
version to the target. A version label alone MUST NOT authorize a transition.

The component's PID, mailbox, ownership links, and session identity MUST
survive a successful upgrade or a rejected migration. The implementation may
change the state representation inside a stable, totally decoded envelope.
The upgrade MUST replace the state and callback set as one transition.
Callbacks include message handling, shutdown, selectors, and the next
migration function where the behavior uses them. Old callbacks MUST NOT
remain reachable through an otherwise replaced callback bundle.

Only the selected component pauses. Its incoming messages remain queued in
the existing mailbox, and its injected or postponed work remains owned by
the same loop. Unrelated components and ordinary code-mode jobs continue.
A declared finite pause budget covers migration and the controller's resume
obligation. An expired, crashed, or rejected migration MUST leave the original
state and callbacks installed and resume service. A control client losing its
connection MUST NOT strand the component in a suspended state.

Migration is a transformation of state, with no brokered effects. Extension
migrations use a restricted source surface; trusted release migrations carry
the same obligation in their reviewed implementation. The generic weft
callback type alone cannot prove purity. Timeouts do not undo external effects,
so an effectful migration is outside this contract.

### Downgrade and work performed after upgrade

Downgrade applies the target version's migration to the component's **current**
state. It MUST NOT restore a pre-upgrade snapshot. Work accepted under the new
version remains represented after downgrade, and messages queued during the
pause are handled once by the resumed implementation.

As an example, a component with seven accepted items upgrades, accepts three
more, and downgrades. It must still hold ten items. If the older representation
cannot express one of those items, downgrade is refused while the newer
component continues serving. Neither successful nor refused downgrade undoes
external effects already completed.

### Code loading and failure

The loader checks the exact module set and content digests before loading.
Only the component's declared implementation modules may change. Runtime,
prelude, and dependency modules are excluded from authored artifact updates.
New code MUST be loaded from compiled bytes belonging to the admitted artifact;
a switch between functions already present at startup does not satisfy the
live-upgrade acceptance test.

BEAM's current/old code slots are a constraint. The controller MUST refuse a
transition that would require purging code still in use. It MUST NOT force
purge a process to make an upgrade succeed. A load failure cannot publish a
partially migrated component. The implementation must retain enough artifact
identity and bytes to resolve an interrupted transition and perform the
declared downgrade; it need not retain an unbounded history of loaded code.

The native loader uses OTP's
[`code:atomic_load/1`](https://www.erlang.org/doc/apps/kernel/code.html#atomic_load/1)
or its prepare/finish form to load a complete inactive module set. This makes
an individual module failure an all-or-nothing load refusal, before state
migration begins. It does not make the later state migration or catalogue
commit part of that atomic load.

## Authored extensions

An extension opts in through an explicit `[live]` manifest table. The table
names its entry module, state version, and compatible message boundary.
Extensions without the table retain protocol 068's replacement semantics.

```toml
[live]
entry = "counter/live"
migration = "counter/migrate"
boundary = "counter-v1"
state_version = "v2"
accepts = ["v1", "v2"]
pause_ms = 1000
max_state_bytes = 65536
```

`entry` must name a vetted authored module. `migration` names a separate pure
module exporting `migrate(from_version: String, state: String) ->
Result(String, String)`. The state strings contain bounded JSON, validated by
the trusted runtime before and after each transition. Its transitive import closure is restricted to the
approved pure library surface and other equally restricted authored modules;
it cannot reach capability calls through an intermediate helper. `accepts` lists source state
versions that this artifact can migrate. These names do not substitute for
the native identity and generation checks. The pause is positive and at most
1,000 milliseconds; serialized state is bounded to at most 65,536 bytes.
State uses a totally decoded JSON envelope across compiled implementations.
An unknown key, malformed field, excessive bound, or missing entry is a
manifest refusal before compilation or loading.

The authored entry exports `ext/live.Definition`, containing an initial JSON
state string and `on_message: fn(String, Asked) -> Result(#(String, Answer),
String)`. The stable `Asked` and `Answer` boundary carries ordinary invocations;
it does not expose process subjects or native upgrade authority. The trusted
runtime validates returned state and dispatches requests through the same
state-owning actor throughout compatible transitions.

The trusted compiler assigns authored modules to fixed reusable namespaces
within the satellite. An inactive namespace may be reused only after the
loader establishes that its old code is no longer referenced. Staging all
modules precedes migration; a partial load cannot modify the active callback
bundle. Fresh generation numbers MUST NOT create unbounded new module names
over a long-lived satellite's lifetime.

The existing author, evaluate, approve, and select workflow remains the
authority boundary. Approval binds the immutable source and test evidence.
The host compiles the captured source using the pinned compiler and vetting
policy, then transfers only its verified implementation bytes to the existing
jailed satellite. A model-facing call cannot supply raw BEAM bytes, a module
path, or a core component identity.

The satellite's trusted runtime owns a reserved upgrade control operation.
Ordinary tool calls, hooks, and capability messages MUST NOT impersonate that
operation. Authored code remains inside the jail throughout loading,
migration, execution, and rollback. Adding a trusted weft dependency to the
satellite prelude does not expose weft or OTP imports to authored source.

Generation fencing continues to bind advertised behavior to invocation.
Durable selection and the local in-memory migration are distinct operations;
the controller must report their outcome explicitly and recover publication
without applying a successful migration twice. An acknowledgement timeout is
not evidence that migration failed.

An unpublished transition admits no ordinary work to its candidate state.
If catalogue selection fails after preparation, compensation may restore the
bounded pre-transition state and callbacks because no new work was accepted.
That compensation is distinct from an operator-requested downgrade after
publication, which must migrate current state. The satellite retains at most
one unpublished transition and its identity. Its completion, rejection, and
deadline paths must release that custody explicitly.

The finite module set does not by itself bound atoms introduced by new function
or constructor names. Authored BEAM atom tables MUST be checked as bytes before
any API can intern them. Admission MUST bound cumulative atom names and their
encoded bytes across successful and failed loads in one satellite. Exhausting
that budget refuses another upgrade while the current component remains usable;
a VM atom-limit crash is not an acceptable refusal mechanism.

## Reviewed harness components

The harness uses the same weft migration machinery, with a separate artifact
authority. Core artifacts come from reviewed releases and target an explicit
allowlist of opted-in components. An extension approval cannot authorize a
core artifact. The native operator interface does not turn an arbitrary path
or candidate ID into code-loading authority inside the harness VM.

The first supported component is the session's scratch key/value actor. Its
builtin implementation remains available. Upgraded implementations occupy two
fixed namespaces shared by the VM. A native owner tracks the actual actor PIDs
using each slot: an occupied slot may serve another actor only for the exact
same implementation digest, and it cannot be overwritten with a different
implementation while another actor still uses it. Thus upgrading one session
cannot redirect calls made by another session's old implementation.

The existing native `evolution` envelope admits three additional owner-only
actions: `core_upgrade`, `core_downgrade`, and `core_status`. The upgrade
arguments have this shape:

```json
{
  "request_id": "scratch-upgrade-1",
  "component": "scratch",
  "expected_version": "v1",
  "expected_digest": "<current implementation SHA-256>",
  "target_release": "<reviewed release tag>",
  "manifest_digest": "<release manifest SHA-256>",
  "pause_ms": 1000
}
```

`core_downgrade` uses the same identity checks and current-state migration rule.
Target version, state version, and message boundary come from the verified
manifest. Admission returns a queued receipt promptly so fetching artifacts
does not block the session gateway. `core_status` resolves an exact request ID
or inspects the current component. Reusing a request ID with different arguments
is refused. A disconnected CLI does not cancel an acknowledged operation; its
native owner retains cleanup custody and must resume the target on every exit.
The release manifest binds the repository `Roasbeef/loom`, release identity,
component, ABI version, target version, state version, compatible boundary,
fixed implementation slot, and exact module lengths and SHA-256 digests.
The native resolver enforces the reviewed release origin before returning an
opaque verified artifact to the loader. A digest proves byte equality; the
reviewed release origin supplies the separate authority to execute those bytes.
The operator request carries neither a filesystem path nor executable bytes.

The receipt reports the actual implementation identity, component PID,
transition outcome, and observed pause. It carries no raw component state.
This proposal does not authorize replacing arbitrary daemon modules or the
Erlang runtime itself.

## Acceptance evidence

The native end-to-end fixture must establish all of the following:

1. Start a real session, populate the target component, and record its PID,
   session ID, implementation digest, and state observation.
2. Compile and load a different implementation after that component starts.
3. Prove that another component answers requests during the selected pause,
   and that an overlapping jailed code-mode job completes.
4. Upgrade with the original PID and session intact, then observe new behavior
   and the populated state through ordinary requests.
5. Exercise rejected, crashed, and timed-out migration. The old implementation
   and its state must remain usable in each case.
6. Perform additional work after upgrade, queue work during downgrade, and
   prove both are retained after the older behavior resumes.
7. Exercise an incompatible downgrade and demonstrate explicit refusal with
   the current version still serving.
8. Repeat the load and migration proof for a reviewed harness component.
9. Retire the session and establish the existing native worker-drain evidence.

Tests must distinguish actual loading from callback substitution, and
overlapping progress from requests that happened entirely before or after
the pause. Demo output reports those observations without exposing state
payloads or credentials.

## Impact and verification

Weft gains opt-in state and callback migration on its shared system-message
plane. Loom's extension runtime, manifest decoder, immutable compiler output,
operator controller, and native fixtures consume it. The dependency lockfiles,
offline seed, prelude freeze assertions, and package documentation must describe
the resulting trusted surface. SQL changes, if required, use SQLC/Parrot.

The existing full gates remain required. New focused failures establish
migration refusal, bounded timeout, code identity, queue preservation, and
current-state downgrade. Independent review and exact-head platform checks
remain separate from local fixture results.
