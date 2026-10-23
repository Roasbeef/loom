# Self-evolution

Loom lets an agent write new extensions, code-mode programs and prompt profiles for itself, and lets an operator test, approve and select them while the session keeps running. A selected extension or program is callable in that session at once. A selected prompt profile applies to sessions started afterwards. The agent proposes. The operator decides. The authored code runs in kernel-jailed satellites and never enters the harness VM.

This page describes governed evolution as it is on the `main` branch. It follows [the architecture page](https://github.com/Roasbeef/loom/blob/main/docs/architecture/evolution.md) and [the live-upgrade page](https://github.com/Roasbeef/loom/blob/main/docs/architecture/live-upgrades.md). Today it works for a session on a local workspace with code mode available. A session on an executor or in a pool cannot use it yet, and [the last section](#/docs/self-evolution/what-is-not-done-yet) says why.

## What the agent can author

There are three kinds of artifact. A candidate is one of them, together with a test entry, a description and an input schema where the kind has them. A prompt profile has none of the three.

| Kind | What it is | Who selects it, and what it applies to |
|---|---|---|
| Extension (`extension`) | A tool or a hook, written in Gleam, with a manifest, argument schemas and its own author tests. It runs in the extension jail. | An authenticated operator selects a version for one session. |
| Program (`program`) | A named code-mode program, `run(input: String) -> report.Outcome`, with a description and a JSON input contract. Each call receives fresh input and goes through the usual vetting and offline compilation. | The owner selects a version for a workspace. Each caller's own policy still governs what the program may do. |
| Prompt profile (`prompt`) | A `prompt.json` for one exact provider, model and API: a system suffix, a task prefix and rewritten tool descriptions. | The owner selects one profile for an exact model. A new session pins the selected profile. A session that is already running, or is resumed, keeps the one it started with. |

A program here is not the same thing as an instruction-only `SKILL.md` playbook. A candidate can only combine capabilities that Loom already has. A request that needs a new trusted capability, a new storage mechanism or a change to the harness itself gets `CoreChangeRequired` and has to go through an ordinary pull request and a reviewed release.

## The lifecycle

The model has six tools for this: `evolution_propose`, `evolution_test`, `evolution_inspect`, `evolution_catalogue`, `evolution_invoke` and `evolution_trace`. None of them approves or selects anything. Those steps are operator commands that the model cannot call.

::figure evolution

The steps in the figure, in words:

- **Propose.** The model names a directory it can already read. The daemon runs a bounded `tar` of it under the caller's own jail, then decodes and hashes the bytes itself. The candidate ID covers the source, the test entry, the schemas, the kind, the publication scope, the session and strand that proposed it, and the build, seam and evaluator identities. A path or a digest that the model supplies grants nothing.
- **Test.** The candidate is compiled offline and its author tests run in a jail. The result is a separate, content-addressed evidence record. A passing author test shows that the author's own checks pass. It does not show that the candidate is any good, and it does not replace Loom's own isolation and lifecycle tests.
- **Review and approve.** The operator reads the exact source and evidence, then approves one candidate ID together with one evidence ID.
- **Select.** The operator selects the approved version and names the generation it expects to replace. The daemon answers with a queued receipt and does the work in the background.
- **Stage and publish.** The daemon compiles the successor in a jail, retires the previous generation, confirms that its processes are gone, and commits the selection in one compare-and-swap. Only then does the successor become callable.
- **Serve.** The model discovers the callable name, schema, candidate ID and generation through `evolution_catalogue`. `evolution_invoke` needs that exact pair, and a stale one is refused.
- **Roll back and retire.** A rollback selects an earlier approved version under a new generation. The version it replaces is retired the same way as in a replacement.

The conversation is never restarted. The session, its history and its other tools carry on through activation and rollback.

## What the operator does

The same controls exist as `loom evolution` and `loomd evolution`. The session has to be resident, and the command authenticates with the daemon's private owner credential, so nothing in the JSON can name a role or a principal.

```sh
loom evolution catalogue SESSION
loom evolution inspect SESSION --candidate-id SHA256
loom evolution evidence SESSION --evidence-id SHA256
loom evolution approve SESSION --args approval.json
loom evolution select SESSION --args selection.json
loom evolution status SESSION --request-id publish-1
```

The other actions are `revoke`, `rollback`, `admit_tasks`, `mark_outcome`, `core_status`, `core_upgrade` and `core_downgrade`. Put `--state-dir PATH` before the action when the daemon keeps its state somewhere other than the default.

An approval names the two IDs that the operator looked at:

```json
{"candidate_id": "<candidate SHA256>", "evidence_id": "<evidence SHA256>"}
```

A selection names them again, with the generation it expects to replace. Generation `0` means that nothing is selected yet. For a replacement, give the generation of the version that is selected now.

```json
{
  "candidate_id": "<candidate SHA256>",
  "evidence_id": "<evidence SHA256>",
  "expected_generation": 0,
  "reason": "Verified the author checks and the lifecycle evidence",
  "request_id": "publish-1",
  "deadline_ms": 60000
}
```

Each command prints one JSON value. Exit status `0` means the daemon acknowledged the request. A `queued` response only means that the work was accepted, so poll `status` with the same `request_id`. Status `2` means invalid input, `3` means the request was refused or never sent, and `4` means the outcome is unknown and you should look the receipt up before retrying. Retrying with the same `request_id` and the same arguments finds the same request. Reusing an ID for different arguments is refused. `--args` takes a JSON object of at most 48 KiB, and the deadline is at most 120 seconds.

A session operator can change their own session. Selecting a workspace program or an exact model profile needs owner authority. An observer can inspect the catalogue and read status but cannot change anything.

## The safety model

**Authority.** The model proposes and tests. Approval, selection and the evidence it relies on stay with the daemon, and an authenticated operator is the only one who can approve or select a candidate. The model has no tool for approving its own candidate, and nothing in a request body can grant a role.

**Jails and Rule Zero.** Rule Zero says that model-influenced code never runs in the harness VM. Governed evolution keeps to it. Snapshots are taken under the caller's jail, author tests and offline compilation run in jails, and a selected extension runs in a persistent satellite, a separate BEAM node inside a kernel sandbox, with its own small executor pool: one satellite, plus one brokered process nested under it. The catalogue directory, its SQLite files and the scratch space are hidden from filesystem tools and from every jail, so authored code cannot read or rewrite them. The one path that loads code into the harness VM is the scratch component upgrade below, and that is why it accepts only a reviewed release identity and never a candidate.

**The generation fence.** A selection compares the whole preceding selection and the current approval and revocation sequence before it commits, so rolling from A to B and back to A cannot bypass an expected-generation check. An invocation that carries an old generation is refused instead of running old arguments against a new schema.

**Custody.** A retired generation must be confirmed gone before its successor is published. A BEAM exit report or a stop notice is not proof that the jailed processes ended, so Loom keeps the remaining cleanup task and refuses to publish or allocate again until it is confirmed. The selection commit and the session's adoption record are two separate SQLite transactions. If the daemon stops between them, recovery writes the missing record and rebuilds the committed version before publishing. A caller that loses an acknowledgement looks the request up by its ID, because a missing reply does not mean that the selection failed.

**What it does not do.** A rollback selects older source. It does not undo files written, network calls made or any other effect of earlier calls. Trace excerpts are scrubbed for credential-shaped text before they are shown, and that is a heuristic, not a guarantee against every secret.

## Live upgrades and state migration

Replacing an extension normally resets its in-memory state. An extension can opt in to keeping it by adding a `[live]` table to its manifest. The table names a live entry point, a migration module, the message boundary, the state version, the older versions it accepts, and finite limits for the pause and the size of the state. The state is bounded JSON.

An opted-in upgrade is a transaction with three calls into the running extension: prepare, publish and abort. Each one is an OTP system operation on the extension's actor inside its satellite. Prepare compiles the approved successor into the inactive one of two fixed module names, suspends the actor with `sys:suspend`, loads the new modules and migrates the current state with `sys:change_code`. The actor stays suspended, and calls that arrive wait in its mailbox. Publish resumes it with the migrated state. Abort runs a second `sys:change_code` that restores the callbacks and state the actor held before prepare, then resumes it. The actor's process ID and mailbox are the same throughout. If catalogue selection fails, abort has the previous state to return to, because no new work was admitted while the actor was suspended. Once the successor is published, a downgrade migrates the current state, because restoring an old snapshot would discard work that was already acknowledged. The migration module is checked to import only pure code, and a refused migration leaves the old callbacks and state in place.

Loom can also replace the code of one harness component in place: the session's scratch key-value store. The owner names a release tag and a manifest digest. The controller downloads the module from the fixed release origin over verified TLS, checks it against the digest, suspends the actor with `sys:suspend`, installs the module with `sys:change_code` and resumes it with `sys:resume`. The actor keeps its process ID, mailbox and entries, and other components keep answering during the pause. The controller is a supervised child of the session beside the scratch store, so an accepted upgrade belongs to the session and not to the command that submitted it. If that command disconnects while the actor is suspended, the controller still resumes it. No reviewed scratch build has been published, so the only identity to name today is `builtin`.

```sh
loom evolution core_status SESSION
loom evolution core_upgrade SESSION --args upgrade.json
loom evolution core_status SESSION --request-id scratch-upgrade-1
```

```json
{
  "request_id": "scratch-upgrade-1",
  "component": "scratch",
  "expected_version": "builtin",
  "expected_digest": "builtin",
  "target_release": "<reviewed release tag>",
  "manifest_digest": "<exact manifest SHA-256>",
  "pause_ms": 1000
}
```

The two paths keep separate authorities. An extension approval never allows code inside the harness VM, and a component upgrade accepts a reviewed release identity, never authored source. `pause_ms` is between 400 and 1000. This is a partial component upgrade, not arbitrary module replacement and not a live upgrade of the whole Erlang runtime. The recipe for building one is in the repository.

## Prompt-profile trials

A prompt profile is judged by running it. The operator admits a task set with `admit_tasks`: up to ten tasks, each with a prompt, a map of starting files and a map of the exact files expected at the end. The model can name an admitted task set in `evolution_test`, but it cannot write its own scorer.

Every trial opens a fresh session and workspace with the ordinary jailed tools and one resolved model, once with the baseline profile and once with the candidate. Files are compared after the trial's processes have retired. The comparison records usage, turns, tool executions and the profile and composed-request digests. Before every request, a guard reserves its worst-case tokens and cost, including requests that fail, so an attempt with no usage report is never refunded. If anything is incomplete, the result is recorded as inconclusive. A comparison runs at most 20 trials, 20 turns, one million tokens and two dollars unless the caller lowers them.

An operator can also mark a settled assistant message in a session with `mark_outcome`. `evolution_trace` joins bounded excerpts of the conversation with the model identity, usage and these marks, and a message without a mark stays `unmarked`. Thinking blocks, signatures and images are left out.

## Configuration

Evolution has no `loom.toml` keys. The operator-facing limits are in the commands: the 48 KiB argument size, the 120 second deadline and the trial ceilings above. The catalogue holds at most 128 candidates, at most 1 MiB each. An extension's `[live]` table lives in its own manifest, not in `loom.toml`.

## What is not done yet

- **Remote placements.** Evolution is wired only for a session on a local workspace where code mode is available, which means a Gleam and Erlang toolchain was found. A session on an executor or in a pool has no evolution tools, no catalogue and no upgrade controller, and nothing on `main` serves it there.
- **Search.** There is no multiple-candidate search or automatic optimisation of profiles, and no inference of a profile for a family of models.
- **Resident authored modules and downloads.** Authored code is not loaded into the harness, and a candidate cannot download dependencies.
- **Automatic state migration.** An extension keeps its state across an upgrade only if its author wrote the migration and opted in.
- **Model quality.** The acceptance tests use a scripted provider. They show that the loop works end to end. They do not show that a profile improves a commercial model. That takes real trials.

## Read more

In the repository, on `main`:

- [`docs/architecture/evolution.md`](https://github.com/Roasbeef/loom/blob/main/docs/architecture/evolution.md): the owners of each step, the failure table and the hard bounds.
- [`docs/architecture/live-upgrades.md`](https://github.com/Roasbeef/loom/blob/main/docs/architecture/live-upgrades.md): the upgrade transaction and the scratch component.
- [`protocol-change/068-runtime-evolution.md`](https://github.com/Roasbeef/loom/blob/main/protocol-change/068-runtime-evolution.md) and [`protocol-change/069-state-preserving-component-upgrades.md`](https://github.com/Roasbeef/loom/blob/main/protocol-change/069-state-preserving-component-upgrades.md): the wire and durable formats.
