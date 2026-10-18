//// The Agency: `tools/agent`'s messaging seam, implemented over a live
//// runtime.
////
//// `tools` cannot see `runtime` and `runtime` cannot see `tools`; they
//// meet here, in the only package that depends on both. `tools/agent`
//// declares a record of closures in plain data, this module fills it, and
//// the six `agent_*` tools stay what tools are in this codebase: a name, a
//// schema, and a total `run` that turns a refusal into a structured error
//// result. Everything with teeth — the addressing rule, the depth and
//// fan-out caps, the deadline, the wait loop, the lineage ledger — lives
//// on this side.
////
//// ## Flow
////
//// `seam` → `spawn` → `spawn_on` → `reconcile` → `create` → `wait` → `wait_loop`
////
//// 1. `seam` fills the `tools/agent` record with closures over the holder's name;
////    `start` stands up the holder those closures call into.
//// 2. `spawn` asks the holder to run `spawn_on`, which serializes admission:
////    it reads the ledger with `read_ledger` and enforces the depth cap.
//// 3. `child_name` derives the child's name from its call site, and `adopt`
////    returns an existing child only when the ledger says this caller minted it.
//// 4. `reconcile` finishes a first spawn or a half-made one: `check_capacity`,
////    then `create`, then `write_result_schema` ahead of the lineage cell.
//// 5. `wait` borrows the runtime outside the holder, checks descent with
////    `is_descendant`, and `reap_overdue` marks late children.
//// 6. `wait_loop` polls with `settle_pass` until every handle settles or the
////    budget runs out, and `ready` reads each settled child's notes.
//// 7. `send` and `roster` read the ledger to decide whom a strand may reach;
////    `note` and `notes` keep a child's notes under its own prefix.
//// 8. `reaping_hooks` spawns `reap_run` unlinked, off the driver, at a run end.
//// 9. `delegate_spawn`, `delegate_join`, `delegate_run_ended` and
////    `delegate_release` (and `delegate_occupancy`, which only reads) are the
////    same machinery for a parent on another
////    orchestrator: `spawn_on` takes a `Source` that says whether the caller is
////    a strand here or a `Delegation`, `run_ended_in` writes the ended fence
////    before it reaps, and `released_in` writes the released fence before it
////    stops every child.
//// 10. `metering_hooks` wraps a delegate session's usage slot: each settled
////     request spawns one process, off the driver, that adds its tokens to the
////     spawner's day through the metering report and, when the spawner sets a
////     child token budget, has `stop_if_spent` read the child's total and ask
////     the holder to stop it. The holder's `StopChild` runs the same `reap` as
////     every other stop.
//// 11. Phase 2 of protocol-change/084 lets the two sides talk. A child's send
////     to its parent is `queue_upward`, which writes a row the
////     delegate session's drainer sends (`client/delegate_outbox`). The parent's
////     Agency admits that mail in its holder with `admit_mail`, reached through
////     `child_inbox`, and keeps a child's glance with `child_progress`. A send
////     from the parent into a remote child is `send_remote`, delivered on the
////     other side by `delegate_send`, which stores a receipt so a resend
////     delivers once.
//// 12. Protocol-change/090 lets the parent look at a child's working:
////     `delegate_history` reads one bounded page of a child's branch for its
////     remote parent, after the same descent test a send makes, and answers
////     it as a `session_view/remote_transcript` page.
//// 13. The other direction, a child that runs on another orchestrator, is
////     `spawn_elsewhere`: the holder's `admit_remote` writes the stub, then
////     `ask_until_answered` sends the `Spawn` and `record_answer` writes down
////     the reply. `wait_across` joins local and remote handles in one call,
////     `remote_peers` lists remote children from their stubs, and
////     `live_stubs` counts the stubs whose child may still be running.
////
//// ## The bootstrap knot, and the name that unties it
////
//// "Production wiring fills the seam with closures over the live runtime"
//// is not achievable as stated, and the reason is a genuine value cycle
//// rather than a plumbing inconvenience: `api.open` *takes* the `Effects`
//// record and *returns* the `Runtime`, and `Runtime` *contains*
//// `effects`. A closure reachable from `Effects` that captures the
//// `Runtime` cannot be built, in either order.
////
//// The repo already ships the fix, four lines from where the knot is
//// tied: `gateway.commit_forwarder(to: name)` uses an address minted before
//// the hub exists and closes over the *name*, not the process. The Agency
//// does the same. `seam(config)` closes over `config.name` and nothing
//// else, so it can be built before `api.open`; `start(config, runtime)`
//// then stands up a holder actor under that name, holding the runtime the
//// open returned. A call arriving before the holder is up — or after it
//// has died — settles as the ordinary in-band `AgencyUnavailable`
//// refusal, which is what the model should see anyway.
////
//// The holder serializes child admission, workflow intents and peer grant
//// mutations. These operations must keep their read-check-write ordering.
//// Blocking joins borrow the runtime and run outside the holder, so one
//// waiting agent cannot prevent another from spawning or receiving mail.
////
//// ## A parent on another orchestrator
////
//// A subagent can run in this session for a parent that lives on another
//// orchestrator (protocol-change/084). The session is then a delegate session,
//// created for the pair (spawner, parent session) and used for nothing else,
//// and the parent is not one of its strands. Its children's lineage names the
//// reference `^main`, the parent strand with a caret in front, and strand
//// creation refuses every name that begins with a caret, so the reference can
//// never name a real strand. Addressing needs no change: `lineage.is_descendant`
//// compares names, and every child's chain ends at a reference with no cell.
////
//// What a local spawn reads from its parent strand comes from elsewhere. The
//// depth, the parent's tools and the spawner's terms travel in the message as a
//// `remote_spawn.Delegation`. The base configuration is the delegate session's
//// own `main` strand, which the spawner's profile seeded.
////
//// The parent's run can end while a `Spawn` for it is still in flight, because
//// the two messages come from different processes on the other orchestrator and
//// distribution orders only per sender. A fence handles it: `RunEnded` writes
//// `delegate/ended/{operation}` and then reaps, and the admission of a new child
//// reads the fence. Both run inside the holder, so whichever message arrives
//// first decides and the other agrees with it. A child that already exists is
//// adopted whatever the fence says, since adopting creates nothing that the run
//// end would have to reap.
////
//// The parent session itself can be deleted. The orchestrator that deleted it
//// sends `Release`, and the holder's `released_in` writes
//// `delegate/released`, a fence on the whole session and not on one operation,
//// then stops every child that is running with `child_run.Released`. The
//// admission of a new child reads this fence beside the ended one, on the same
//// create path and after adoption, so a `Spawn` that overtakes the `Release`
//// is refused and one that came first is a child this stop reaches. The
//// registry deletes the session once its slot drains (`manager.release_delegate`),
//// and that deletion removes everything stored under the session.
////
//// The spawner may also never come back. A child there is bounded by its
//// deadline on this machine's clock, and ordinarily a deadline is enforced when
//// a wait or a roster reads the ledger, which a spawner that has gone away will
//// not do. So a delegate session sets `Config.deadline_tick_ms`, and its holder
//// then runs a weft periodic timeout whose `DeadlineTick` message calls
//// `reap_overdue`. The tick stops a child the same way a wait does: the durable
//// `BudgetExpired` mark is written before the operation is cancelled, so a pass
//// that repeats, or that runs after a restart has reopened the session, finds the
//// children already stopped or stops the ones that became overdue while the
//// daemon was down. Deadlines are absolute, so time spent down counts.
////
//// ## Metering a spawner's children
////
//// A spawner can bound what its children spend on this machine
//// (`client/spawners`). The day's totals live in the registry's catalogue, and
//// the Agency's part is the two things only it can do. It reports each settled
//// request's tokens, and it stops a child that has used its own budget.
////
//// Both happen on a process the usage hook spawns unlinked, because the hook runs
//// on the strand's driver and the driver must not wait on the registry or on the
//// holder. The spawned process reads the child's total from the usage ledger
//// (`child_usage.of_strands`, a scan outside the holder) and, if the budget is
//// spent, sends the holder a `StopChild`. The holder then records the stop and
//// aborts the run through `reap`, in the same turn as every other stop, so the
//// durable mark still comes before the abort. The request that crossed the budget
//// has already been paid for, so a child overshoots by at most one request. A
//// stop that races the child's own finish is harmless: a run that completed keeps
//// its outcome, and only an aborted one reads the reason.
////
//// ## A child on another orchestrator
////
//// `agent_spawn` with `on` starts a child on another orchestrator
//// (protocol-change/084). The child has no strand in this session, so what the
//// session holds is a stub (`client/remote_child`) written before the first
//// message, a lineage cell that names the orchestrator and is written when the
//// orchestrator answers, and nothing in the strand registers. Four things in this
//// module change for it.
////
//// - **Capacity.** `is_live` reads a strand's own state, which a remote child does
////   not have, so `check_capacity` counts the live stubs beside the cells. A stub
////   whose orchestrator has not answered still counts, which errs toward refusing.
////   A stub whose child is running counts until the child's deadline passes or a
////   join reports it finished, and the second drainer instance asks for that join
////   when nobody waits, so a child that nobody waits on does not hold its slot
////   for good.
//// - **Waiting.** A handle is remote when a stub of this session holds it, and
////   never because of the text of the handle. A wait over remote handles sends
////   one `Join` per orchestrator, in tasks beside the local wait, so the whole is
////   as long as the longest and not the sum.
//// - **Listing.** The roster takes remote children from the stubs, and says how
////   far each record has got.
//// - **The end of a run.** A remote child is always detached. `reap_run` aborts
////   the local children as ever and sends nothing across, so a child on another
////   orchestrator outlives the run that started it and is bounded by its own
////   deadline and by that orchestrator's retention sweep.
////
//// The network never runs in the holder. The holder only admits the spawn and
//// writes the stub, so a slow or silent orchestrator cannot stop the session's
//// other spawns, sends or peer mail.
////
//// ## Messages between a parent and a child on another orchestrator
////
//// Phase 1 refused a send to a remote child and an upward send from one. Phase 2
//// delivers both, and the two directions differ in who can wait.
////
//// **Down.** The parent's `send` finds the child's stub, and asks the child's
//// orchestrator to deliver through `Reach.send`. The message id is the sending
//// call site's digest, and the orchestrator stores `delegate/receipt/{id}` in
//// the same commit that delivers, so a resend answers `Admitted` and delivers
//// nothing twice. A child with no run open is started on a detached run whose
//// deadline is the child's existing one (the run record gets the absolute deadline
//// the spawn gave the child, so no number of sends lengthens it, and a send
//// after it is refused). An orchestrator that does not answer leaves a
//// `remote-send/{id}` row that the remote drainer resends, and the model is told
//// the message is queued.
////
//// **Up.** A remote child's `agent_send` to `^main` writes a
//// `delegate/outbox/mail/{id}` row and answers `queued`. It does not go through
//// peer mail: no link is written and `peers.send` is not used, because the
//// authorization is the spawn itself, and the delegate session cannot dial its
//// parent. The laptop admits the mail by name, finding the stub by the child's
//// strand name and never by its handle, so mail that races the answer to the
//// `Spawn` still finds the `Requested` stub. The steer and the receipt
//// `remote-mail/{id}` are one commit, and a parent with no run open declines the
//// message and records that as the receipt.
////
//// ## What the ledger is for
////
//// `runtime/lineage` is the durable ledger, one `fact.custom` cell per
//// spawned strand under the reserved `lineage/` prefix. Four things read
//// it and nothing else decides them: whether a strand may be addressed
//// (parent, or descendant, and **nothing else** — a strand with no cell
//// is a root and is nobody's descendant, which is why "no lineage fact"
//// fails closed); whether a spawn is within its depth and fan-out caps;
//// whether a replayed spawn is looking at a child that already exists;
//// and which children a run end should reap.
////
//// ## Completion checks and background cleanup
////
//// The completion guard reads only the holder, session store and writer.
//// None of those reads calls back into the parent driver. It therefore keeps
//// the existing synchronous hook ordering: while attached children run, a
//// born-placed follow-up names their current handles and keeps the parent
//// operation open. Once they settle, cleanup runs on a background process.
//// Cancelled or already-ended parents retain their existing cleanup behavior.
////
//// ## Two things this does not fix
////
//// `api.await_strand_result`'s own timeout is a floor rather than a bound
//// — it sleeps 10 ms, recurses on `timeout_ms - 10`, and charges nothing
//// for the two store reads each iteration performs. The wait loop here
//// routes *around* that by calling it with a zero budget (which reads
//// both rows once and returns) and owning the clock itself. That is not a
//// fix: every other caller of `api.await_strand_result` still has the
//// floor, and `docs/notebook.md`'s item stays open.
////
//// ## Where a result contract is enforced, and why there
////
//// A spawn may carry a `result_schema`. Two places could check it, and
//// they are not equivalent. Checking it here, in the parent's `wait`,
//// lets the child finish successfully and then tells the parent its
//// child was useless — a verdict delivered to the one party that cannot
//// act on it, one context window away from the model that wrote the
//// value, after the run that could have fixed it has ended. Checking it
//// on the child's own `agent_note` call refuses the write to the model
//// that made it, in the turn it made it, with the tools and the context
//// still in hand; the child sees what was expected, what it sent, and
//// tries again. So the enforcement point is the child, and the whole of
//// the reason is attributability: a failure belongs to whoever can
//// repair it.
////
//// The parent's `wait` still validates, and that is not a second
//// authorization. The cell is read back out of the durable store, and
//// the house rule for a value crossing that boundary is that it is
//// decoded rather than trusted — a schema rewritten between the write
//// and the read, or a cell seeded before a contract existed, has to
//// come back as `ResultUnusable` naming the schema rather than as a
//// value a program will branch on.
////
//// The schema itself lives in its own fact cell, `result-schema/{child}`,
//// written before the lineage cell so a crash between the two can only
//// leave a schema with no child, never a child whose contract vanished.
//// It sits outside `agent/` on purpose: `agent_note` prepends
//// `agent/{caller}/` to every key a model supplies and `agent_notes`
//// reads under `agent/` alone, so a child can neither rewrite the
//// contract it is judged against nor discover its siblings'.
////
//// And `send` upward into a parent that has *finished* is refused rather
//// than delivered, because `api.send_to_strand` falls back to accepting a
//// fresh run when the target is idle — which would wake a finished parent
//// with no human present, the exact property auto-enqueued child results
//// were rejected over. Refusing it keeps that argument honest. The refusal
//// is narrow: downward sends may start a run, because a parent choosing to
//// give an idle child more work is a live agent's explicit decision, made
//// inside its own run. The check is a read followed by a send, so a parent
//// that finishes in between is still woken; the window is small and named
//// rather than claimed shut.

import broker/internal/call
import client/child_usage
import client/delegate_outbox
import client/internal/session_owner
import client/internal/timebase
import client/peer_mail
import client/peer_outbox
import client/remote_child
import client/remote_mail
import client/remote_reach
import client/remote_send
import client/remote_spawn
import client/workflow_ledger
import core/clock.{type Clock}
import core/entry
import core/glance.{type Glance}
import core/ids.{type EntryId, type OpId}
import core/json.{type JsonValue}
import core/message.{type AgentMessage}
import core/todo_list
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/operation.{type LastResult}
import machine/strand as machine_strand
import runtime/api
import runtime/async_execution
import runtime/child_run
import runtime/effects
import runtime/lineage.{type CallSite, type Lineage, CallSite, Lineage}
import runtime/residency
import runtime/writer
import session/session
import session_view/remote_transcript
import session_view/strand_framing
import storage/storage
import telemetry/owner
import tools/agent.{
  type Agency, type Caller, type Delivery, type Handle, type Outcome, type Peer,
  type Refusal, type ResultSchema, type Spawned, type TerminalResult,
  type Waited, Aborted, Completed, Failed, Handle, Pending, Ready, Spawned,
}
import tools/todos
import weft
import weft/actor
import weft/poll
import weft/registry as address

/// The name prefix every minted subagent strand carries. It is what
/// `api.Options.subagent` matches on to route a model-spawned strand into
/// the tree's second strand factory, so a subagent crash loop cannot
/// spend the restart budget protecting the strand a human is talking to.
pub const subagent_prefix = agent.subagent_prefix

/// Where a child's result contract lives: one `fact.custom` cell per
/// child with a schema, at `result-schema/{child strand}`.
///
/// Deliberately outside `agent/`. `agent_note` forces every model-supplied
/// key under `agent/{caller}/` and `agent_notes` lists under `agent/`
/// alone, so this corner is unreachable from the model's own tools in
/// both directions: a child cannot rewrite the contract it is held to,
/// and cannot read what its siblings were asked for. It is not one of the
/// runtime's four *reserved* prefixes, which would be a change to
/// `runtime/api` rather than to this seam; what keeps it safe is that
/// nothing a model can reach ever addresses it.
pub const result_schema_prefix = "result-schema/"

/// How far a descendant walk will climb before giving up. A cycle would
/// require a strand name to have been claimed twice, and `seed_strand`
/// claims each name under a `seq: None` compare-and-set — but a bounded
/// walk costs nothing and turns a corrupt ledger into a refusal rather
/// than a hang.
pub const max_ancestor_walk = 32

/// Everything the Agency needs that is not the runtime.
///
/// Constructor invariants: `name` is minted before `api.open` and is the
/// holder's reference address; `clock` shares the session's time base (so a
/// simulated session waits on logical time); `depth_cap` is the deepest
/// spawn allowed, counting the strand a human talks to as depth 0;
/// `fan_out` bounds one strand's live children and `session_strands`
/// bounds the whole session's live spawned strands, both counted from the
/// ledger against settled state, so a finished child frees its slot;
/// `max_wait_ms` is the ceiling one `agent_wait` call is clamped to;
/// `default_within_ms` is the budget a spawn gets when the model names
/// none; `first_slice_ms` and `max_slice_ms` bound the wait loop's
/// backoff; `rest` is the injected sleep the loop backs off through;
/// `holder_timeout_ms` bounds the call that borrows the runtime.
pub type Config {
  Config(
    name: address.Address(Message),
    clock: Clock,
    depth_cap: Int,
    fan_out: Int,
    session_strands: Int,
    max_wait_ms: Int,
    default_within_ms: Option(Int),
    first_slice_ms: Int,
    max_slice_ms: Int,
    rest: fn(Int) -> Nil,
    holder_timeout_ms: Int,
    /// The identity and seed thinking level a spawned child is
    /// configured with — the host's `subagent` route, resolved.
    /// `Error(Nil)` means the host routes no subagent model, and the
    /// child inherits its parent's configuration wholesale, which is what
    /// every child did before the role was wired.
    ///
    /// A closure for the same reason `rest` and `clock` are: the Agency
    /// is built before `api.open` and must not capture a gateway's
    /// answer at that moment rather than the host's seam.
    subagent_model: fn() ->
      Result(#(machine_strand.ModelIdentity, machine_strand.ThinkingLevel), Nil),
    /// The host catalogue's explicit choices, keyed by identity.provider.
    /// Selecting one seeds both identity and thinking before the child runs.
    models: List(#(machine_strand.ModelIdentity, machine_strand.ThinkingLevel)),
    /// What the daemon lends peer admission to decide a default link
    /// (protocol-change/077). `peer_mail.no_defaults` links nothing
    /// implicitly, which is every embedded host.
    peer_defaults: peer_mail.Defaults,
    /// Called once after a peer message is recorded as still undelivered
    /// (`peer_outbox.Unanswered` or `peer_outbox.NotOpen`), so the outbox
    /// drainer arms its retry timer. The Agency does not own the drainer and
    /// cannot start it; the host supplies a closure over the drainer's name. An embedded host with
    /// no drainer leaves the no-op, and a message that could not be delivered
    /// then waits for the next session open.
    outbox_queued: fn() -> Nil,
    /// The other orchestrators this session may start children on, and how to
    /// ask them (protocol-change/084). `remote_reach.none` is every host that
    /// reaches none, and `agent_spawn` then offers no `on`.
    remote: remote_reach.Reach,
    /// Called once after a record of a remote child is left for the second
    /// drainer instance to act on (a spawn that was not answered, or a child
    /// that is running and may finish unwaited), so that instance arms its retry
    /// timer. The Agency does not own that
    /// drainer, as it does not own the peer-mail one, so the host supplies a
    /// closure over the drainer's name.
    remote_queued: fn() -> Nil,
    /// How often the holder reaps children that are past their deadlines, in
    /// milliseconds, when nobody is waiting on them. `None` reaps only when a
    /// wait or a roster observes the ledger, which is every session but a
    /// delegate session. A delegate session sets
    /// `delegate_deadline_tick_ms`, because the spawner that started its
    /// children may never return to wait on them (protocol-change/084).
    deadline_tick_ms: Option(Int),
    /// Cancels the effect plane's executions under an operation, called with
    /// the child's operation after the reap has stopped it. The runtime's own
    /// abort kills the strand's live effect processes and nothing else, so a
    /// background job (which runs under the jobs actor, not under the tool
    /// call that started it) would otherwise run to its wall deadline. The
    /// host owns the broker, so the host supplies this; the default is a no-op
    /// for embedded hosts with no effect plane. It must not wait.
    abort_effects: fn(OpId) -> Nil,
    /// Claims one spawn against the spawner's rolling day (protocol-change/084,
    /// phase 2), called with the longest the registry may take to answer, in
    /// milliseconds. `None` when the spawner sets neither `token_budget_per_day`
    /// nor `max_per_day`, and for every session but a delegate session. The
    /// holder calls it for a child it is about to create, after the child's call
    /// site is found to be new and the fences have passed, so a resent spawn
    /// that is adopted is neither counted nor refused. It must answer
    /// `StoreFailure` when the registry does not answer in time, never a cap.
    claim: Option(fn(Int) -> Result(Nil, remote_spawn.SpawnRefusal)),
    /// Where this delegate session's parent is, or `None` for every session but
    /// a delegate session (protocol-change/084, phase 2). With it set, a child's
    /// `agent_send` to its parent reference writes an outbox row and answers
    /// `queued`, and without it the same send is refused, as it was in phase 1.
    /// The daemon fills it from the session's catalogue row, as it does
    /// `deadline_tick_ms`.
    spawner: Option(delegate_outbox.SpawnerLink),
    /// Called once after the delegate session leaves something for its second
    /// drainer instance to send (a mail row, or a new child that will glance), so
    /// that instance arms its retry timer. The host supplies a closure over the
    /// drainer's name, as it does for `outbox_queued`.
    upward_queued: fn() -> Nil,
  )
}

/// How often a delegate session's holder reaps overdue children, in
/// milliseconds. The bound a remote child runs under is its deadline, and the
/// tick is what enforces it when no wait is looking, so this is also how late
/// a child can be stopped. It is a provisional figure: the cost of a pass is one
/// read of the lineage ledger.
pub const delegate_deadline_tick_ms = 15_000

/// Sensible defaults for a production host.
///
/// `max_wait_ms` is 30 s rather than the 60 s a single-handle wait was
/// once costed at, and the arithmetic is worth writing down because it
/// changed. A wait holds an operation open, and a human steering that
/// strand meanwhile is committed but undrainable until the batch ends —
/// so the number that matters is the worst-case time a *batch* can hold
/// the strand, not the time one child can take. Making the wait
/// multi-handle removed the fan-out multiplier: joining eight children is
/// one window, not eight. What remains is the number of `agent_wait`
/// calls a model can put in one batch, which nothing bounds, so the cap
/// is halved to keep the ordinary two-call batch inside the same latency
/// budget the single 60 s window was justified against. The residual — a
/// model that emits many waits in one batch — is real, stated, and
/// bounded only by `abort`, which stays the immediate exit.
///
/// It is also the smaller half of a cross-package ordering: `max_wait_ms`
/// must stay **below** `client/codemode.default_call_timeout_ms`, so that
/// a `strand.wait` reaching this seam through the code-mode cap channel
/// is answered by this ceiling rather than abandoned by the satellite
/// host's. Raise it past 120 s and every such wait answers `unsettled`.
/// `codemode_test` pins the relation.
///
/// ## Examples
///
/// ```gleam
/// // agency.default_config(address.new_address(namespace), clock)
/// ```
///
pub fn default_config(name: address.Address(Message), clock: Clock) -> Config {
  Config(
    name:,
    clock:,
    // Only the strand a human is talking to may spawn. The value of
    // grandchildren is unproven and the cost of unbounded recursion is
    // not.
    depth_cap: 1,
    fan_out: 8,
    session_strands: 16,
    max_wait_ms: 30_000,
    default_within_ms: Some(child_run.default_within_ms),
    first_slice_ms: 25,
    max_slice_ms: 250,
    rest: process.sleep,
    holder_timeout_ms: 5000,
    // No subagent route by default: a child inherits its parent, which is
    // what children did before roles reached the seam. `client/serve`
    // fills this from the gateway.
    subagent_model: fn() { Error(Nil) },
    models: [],
    peer_defaults: peer_mail.no_defaults,
    outbox_queued: fn() { Nil },
    remote: remote_reach.none(""),
    remote_queued: fn() { Nil },
    deadline_tick_ms: None,
    abort_effects: fn(_operation) { Nil },
    claim: None,
    spawner: None,
    upward_queued: fn() { Nil },
  )
}

/// The holder's mailbox: one message, answered with a plain data value.
pub type Message {
  /// Hand back the live runtime. The caller does the work itself.
  Borrow(reply: Subject(api.Runtime))

  /// Services peer admission without copying the runtime to another session.
  PeerRequest(
    command: peer_mail.Command,
    reply: Subject(Result(JsonValue, String)),
  )

  /// Reserves a durable named identity before ordinary child reconciliation.
  WorkflowChild(
    caller: Caller,
    step: workflow_ledger.Step,
    request: agent.SpawnRequest,
    custody: api.AsyncCustody,
    reply: Subject(Result(Spawned, Refusal)),
  )

  /// Serializes the capacity check and publication of each child.
  SpawnChild(
    caller: Caller,
    request: agent.SpawnRequest,
    custody: Option(api.AsyncCustody),
    reply: Subject(Result(Spawned, Refusal)),
  )

  /// Admits a spawn that is to run on another orchestrator: checks the caps,
  /// counting the stubs of remote children, and writes the stub before anything
  /// is sent. Serialized with the other admissions so the check and the write
  /// cannot interleave with a local child's. Answers the stub's key and the stub,
  /// which is the one an earlier attempt wrote when the call site was seen before.
  AdmitRemote(
    caller: Caller,
    request: agent.SpawnRequest,
    orchestrator: String,
    reply: Subject(Result(#(String, remote_child.Stub), Refusal)),
  )

  /// Admits one child for a parent on another orchestrator. It is serialized
  /// with `DelegateEnded`, which is what makes the ended fence decide.
  DelegateSpawn(
    delegation: remote_spawn.Delegation,
    site: remote_spawn.CallSite,
    request: agent.SpawnRequest,
    reply: Subject(Result(Spawned, remote_spawn.SpawnRefusal)),
  )

  /// Records that a run of a parent on another orchestrator ended, then stops
  /// the children it owns. Answers how many were stopped.
  DelegateEnded(operation: OpId, reply: Subject(Result(Int, Refusal)))

  /// Records that the parent session on another orchestrator was deleted, then
  /// stops every child still running. Answers how many were stopped.
  DelegateRelease(reply: Subject(Result(Int, Refusal)))

  /// Stops the child on `strand` if its current run has no stop yet, recording
  /// `stop` before the abort. Sent by the usage hook's spawned process when a
  /// child has spent its token budget, and fire-and-forget: the sender has
  /// nothing to wait for, and a repeat finds the run already stopped.
  StopChild(strand: String, stop: child_run.Stop)

  /// Admits mail from a child that runs on another orchestrator (protocol-change
  /// /084, phase 2): finds the child's stub by name, checks that the orchestrator
  /// the stub names is the one the message came from, and steers the parent
  /// strand in the commit that writes the receipt. Serialized with the holder's
  /// other admissions, so two resends of one message cannot both reach the
  /// strand.
  AdmitChildMail(
    parent: remote_spawn.Parent,
    child: Handle,
    message_id: String,
    text: String,
    admits: fn(String) -> Bool,
    reply: Subject(Result(remote_mail.Receipt, remote_mail.ChildRefusal)),
  )

  /// The periodic heartbeat of a session with `deadline_tick_ms`: stops every
  /// child whose deadline has passed, whether or not anything is waiting.
  DeadlineTick
}

/// Starts the holder under `config.name`, after `api.open` has returned
/// the runtime it holds.
///
/// It is deliberately not supervised, in the same way and for the same
/// reason as the gateway hub: the boot process links it, does not trap
/// exits, and a death there ends the server rather than leaving a session
/// serving tools that quietly refuse.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(_holder) = agency.start(config, runtime)
/// ```
///
pub fn start(
  config: Config,
  runtime: api.Runtime,
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(5000, fn(subject) {
    // The initialiser runs in the actor's own process, so this label names
    // it to the ownership inspector under its session.
    session_owner.label(runtime, owner.Agency)

    actor.initialised(runtime)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    case message {
      WorkflowChild(caller, step, request, custody, reply) -> {
        let answer = {
          use caller <- result.try(
            workflow_ledger.reserve(state, caller, step)
            |> result.map_error(agent.PlaneFailed),
          )
          spawn_on(config, state, caller, Local, request, Some(custody))
        }
        process.send(reply, answer)
        actor.continue(state)
      }
      PeerRequest(command:, reply:) -> {
        let answer =
          peer_mail.handle_with(
            state,
            config.clock,
            config.peer_defaults,
            command,
          )

        // The doorbell rings after the row is durable, so a drainer that
        // wakes at once finds the message it was told about.
        case command, answer {
          peer_mail.OutboxSettle(outcome: peer_outbox.Unanswered, ..), Ok(_)
          | peer_mail.OutboxSettle(outcome: peer_outbox.NotOpen, ..), Ok(_)
          -> config.outbox_queued()
          _, _ -> Nil
        }
        process.send(reply, answer)
        actor.continue(state)
      }
      SpawnChild(caller:, request:, custody:, reply:) -> {
        process.send(
          reply,
          spawn_on(config, state, caller, Local, request, custody),
        )
        actor.continue(state)
      }
      AdmitRemote(caller:, request:, orchestrator:, reply:) -> {
        process.send(
          reply,
          admit_remote(config, state, caller, request, orchestrator),
        )
        actor.continue(state)
      }
      DelegateSpawn(delegation:, site:, request:, reply:) -> {
        let caller = delegated_caller(delegation.parent, site)
        let admitted =
          spawn_delegated(config, state, caller, delegation, request)

        // A child that was admitted will glance, and nothing rings the drainer
        // for a glance, so the drainer is rung once for the child.
        case admitted, config.spawner {
          Ok(_), Some(_) -> config.upward_queued()
          _, _ -> Nil
        }
        process.send(reply, admitted)
        actor.continue(state)
      }
      DelegateEnded(operation:, reply:) -> {
        process.send(reply, run_ended_in(config, state, operation))
        actor.continue(state)
      }
      DelegateRelease(reply:) -> {
        process.send(reply, released_in(config, state))
        actor.continue(state)
      }
      AdmitChildMail(parent:, child:, message_id:, text:, admits:, reply:) -> {
        process.send(
          reply,
          admit_mail(config, state, parent, child, message_id, text, admits),
        )
        actor.continue(state)
      }
      StopChild(strand:, stop:) -> {
        // A ledger that cannot be read drops the stop. The child's next settled
        // request is judged again by the same budget, so nothing is lost for good.
        case read_ledger(state) {
          Ok(ledger) -> stop_child_in(config, state, ledger, strand, stop)
          Error(_refusal) -> Nil
        }
        actor.continue(state)
      }
      DeadlineTick -> {
        // A ledger that cannot be read leaves the pass for the next tick, which
        // reads it again; the durable mark a reap writes is what makes a
        // repeated pass harmless.
        case read_ledger(state) {
          Ok(ledger) -> reap_overdue(config, state, ledger)
          Error(_refusal) -> Nil
        }
        actor.continue(state)
      }
      Borrow(reply:) -> {
        process.send(reply, state)
        actor.continue(state)
      }
    }
  })
  |> with_deadline_tick(config.deadline_tick_ms)
  |> actor.addressed(config.name)
  |> actor.hibernate_after(residency.hibernate_after_ms)
  |> actor.start
}

// The heartbeat is a weft periodic timeout, whose fixed delay arms the next
// fire after this one's handler returns, so a slow pass slows the ticks and
// never queues a backlog of them. Only a delegate session has one: its
// children belong to a spawner that may never return to wait on them.
//
// The 15 s beat is shorter than `residency.hibernate_after_ms` (30 s), so a
// delegate holder never hibernates. That costs only the holder's memory and is
// accepted.
fn with_deadline_tick(
  builder: actor.Builder(api.Runtime, Message, Subject(Message)),
  every: Option(Int),
) -> actor.Builder(api.Runtime, Message, Subject(Message)) {
  case every {
    Some(ms) -> actor.periodic(builder, every: ms, sending: DeadlineTick)
    None -> builder
  }
}

/// Whether a strand name was minted by an Agency. The predicate
/// `api.Options.subagent` is given, and the reason the runtime needs one
/// at all: lineage is this package's ledger, so the supervisor cannot
/// tell a model-spawned strand from an operator-spawned one by itself.
///
/// ## Examples
///
/// ```gleam
/// assert agency.is_subagent("sub:main/reviewer-1-turn-1-0")
/// ```
///
/// ```gleam
/// assert !agency.is_subagent("main")
/// ```
///
pub fn is_subagent(strand: String) -> Bool {
  agent.is_subagent(strand)
}

/// The messaging seam, closed over the holder's *name* rather than over a
/// runtime that does not exist yet. Safe to build before `api.open`.
///
/// ## Examples
///
/// ```gleam
/// // contributions.built_in(option.Some(agency.seam(config)), ..)
/// ```
///
pub fn seam(config: Config) -> Agency {
  seam_with_custody(config, None)
}

/// Binds orchestration calls to one live asynchronous execution.
///
/// ## Examples
///
/// ```gleam
/// // agency.async_seam(config, custody)
/// ```
pub fn async_seam(config: Config, custody: api.AsyncCustody) -> Agency {
  seam_with_custody(config, Some(custody))
}

fn seam_with_custody(
  config: Config,
  custody: Option(api.AsyncCustody),
) -> Agency {
  agent.Agency(
    spawn: fn(caller, request) { spawn(config, caller, request, custody) },
    send: fn(caller, to, text, within_ms) {
      send(config, caller, to, text, within_ms, custody)
    },
    wait: fn(caller, handles, within_ms) {
      wait(config, caller, handles, within_ms)
    },
    note: fn(caller, key, value) { note(config, caller, key, value) },
    notes: fn(caller, prefix) { notes(config, caller, prefix) },
    todos: fn(caller, step) { update_todos(config, caller, step) },
    roster: fn(caller) { roster(config, caller) },
    max_wait_ms: config.max_wait_ms,
    model_names: list.map(config.models, fn(entry) { entry.0.provider }),
    orchestrator_names: config.remote.orchestrators,
    holds: fn(caller, tool) { holds(config, caller.strand, tool) },
  )
}

// `Ok` when `strand`'s durable active tool list names `tool`, read at call
// time from the same cell the tool registry's clearance reads. Only a tool
// genuinely missing from a readable list is `ToolNotHeld`. A holder that is
// down, an unreadable store and a strand with no configuration cell keep
// their own refusals, so a transient fault reads as one rather than as
// policy; every `Error` still means the caller proceeds no further.
fn holds(config: Config, strand: String, tool: String) -> Result(Nil, Refusal) {
  use runtime <- result.try(borrow(config))
  use configuration <- result.try(read_configuration(runtime, strand))
  case list.contains(configuration.active_tool_names, tool) {
    True -> Ok(Nil)
    False -> Error(agent.ToolNotHeld(tool:))
  }
}

/// Keeps an uncancelled parent open while its attached children are active.
///
/// The guard reads the separate writer and session store. A follow-up carries
/// the exact current handles, so a resumed child cannot be mistaken for its
/// original aborted run. Detached children do not hold their parent open.
/// Cancelled or ended parents retain their existing cleanup behavior.
///
/// ## Examples
///
/// ```gleam
/// // effects.Effects(..built, hooks: agency.reaping_hooks(built.hooks, config))
/// ```
///
pub fn reaping_hooks(hooks: effects.Hooks, config: Config) -> effects.Hooks {
  let inner = hooks.run_end
  effects.Hooks(..hooks, run_end: fn(operation) {
    case unfinished_children(config, operation) {
      // Once the holder has retired, shutdown owns draining the runtime.
      // A model follow-up here would survive into the next session open.
      Ok([]) | Error(agent.AgencyUnavailable) -> {
        let _reaper =
          process.spawn_unlinked(fn() { reap_run(config, operation) })
        inner(operation)
      }
      Ok(handles) ->
        Some(completion_follow_up(
          config,
          "Your attached child runs are still working. Your run remains open. "
            <> "Use agent_wait on these current handles and collect their results "
            <> "before finishing: "
            <> string.join(handles, ", "),
        ))
      Error(refusal) ->
        Some(completion_follow_up(
          config,
          "Child completion could not be checked: "
            <> string.inspect(refusal)
            <> ". Check agent_roster and wait for attached children before finishing.",
        ))
    }
  })
}

/// What a delegate session reports to the daemon about its children's spend,
/// and the budget it enforces on one child (protocol-change/084, phase 2).
pub type Metering {
  Metering(
    /// Adds tokens to the spawner's day. It may wait on the registry, so the hook
    /// calls it only from a process of its own.
    spend: fn(Int) -> Nil,
    /// The tokens one child may use, input plus output, or `None` for no bound.
    child_budget: Option(Int),
    /// Claims one spawn against the spawner's day, or `None` when the spawner
    /// sets no day cap. The session's `Config.claim` is this field.
    claim: Option(fn(Int) -> Result(Nil, remote_spawn.SpawnRefusal)),
  )
}

/// Wraps the usage slot of a delegate session so that every settled request
/// reports its tokens and is judged against the child's budget.
///
/// The slot runs on the strand driver's own process, so the whole of the work
/// there is one `process.spawn_unlinked`; the report, the ledger read and the
/// stop all happen on the spawned process. A request that used no tokens spawns
/// nothing, and an adjustment row that took tokens back is not reported as
/// negative spend. The inner slot is called after the spawn, as the glance hook
/// does.
///
/// ## Examples
///
/// ```gleam
/// // effects.Hooks(..built.hooks, usage: ..) == agency.metering_hooks(built.hooks, config, metering)
/// ```
pub fn metering_hooks(
  hooks: effects.Hooks,
  config: Config,
  metering: Metering,
) -> effects.Hooks {
  let inner = hooks.usage
  effects.Hooks(..hooks, usage: fn(operation, row: entry.UsageRow) {
    let tokens = row.usage.input + row.usage.output
    case tokens > 0 {
      True -> {
        let _meter =
          process.spawn_unlinked(fn() {
            // The stop comes first, so it never waits behind the registry.
            stop_if_spent(config, operation, metering.child_budget)
            metering.spend(tokens)
          })
        Nil
      }
      False -> Nil
    }
    inner(operation, row)
  })
}

// Judges the child that ran `operation` against its budget and asks the holder
// to stop it when the budget is spent. An operation that belongs to no child (the
// delegate session's own strand) has no run record, and a ledger or a holder that
// cannot be reached leaves the judgment to the child's next request.
fn stop_if_spent(config: Config, operation: OpId, budget: Option(Int)) -> Nil {
  case budget {
    None -> Nil
    Some(budget) -> {
      let judged = {
        use runtime <- result.try(borrow(config))
        use strand <- result.try(run_strand(runtime, operation))
        use total <- result.try(
          child_usage.of_strands(runtime, [strand])
          |> result.map_error(agent.PlaneFailed),
        )
        use usage <- result.try(
          dict.get(total, strand)
          |> result.replace_error(agent.NotAddressable(strand:)),
        )
        use holder <- result.map(
          holder(config)
          |> result.replace_error(agent.AgencyUnavailable),
        )
        case usage.input + usage.output >= budget {
          True ->
            process.send(
              holder,
              StopChild(strand:, stop: child_run.TokenBudgetSpent),
            )
          False -> Nil
        }
      }
      result.unwrap(judged, Nil)
    }
  }
}

// The strand an operation ran on, from its run record. A child's every run has
// one, and the delegate session's own strand has none.
fn run_strand(
  runtime: api.Runtime,
  operation: OpId,
) -> Result(String, Refusal) {
  use cell <- result.try(
    api.fact_cell(runtime, child_run.key(operation))
    |> result.map_error(fn(error) { agent.PlaneFailed(describe_api(error)) }),
  )
  case cell {
    Some(api.FactCell(value:, ..)) ->
      child_run.decode(value)
      |> result.map(fn(run) { run.strand })
      |> result.replace_error(agent.PlaneFailed(
        "the child run record is corrupt",
      ))
    None -> Error(agent.NotAddressable(strand: ""))
  }
}

// The parent operation, rather than the original spawn, owns renewed work.
// Expiry is observed here too, so repeated attempts to finish cannot leave a
// child running past the same budget that agent_wait would enforce.
fn unfinished_children(
  config: Config,
  operation: OpId,
) -> Result(List(String), Refusal) {
  use runtime <- result.try(borrow(config))
  use state <- result.try(
    session.op_state(runtime.session, operation)
    |> result.replace_error(agent.PlaneFailed("parent operation is unreadable")),
  )
  case state {
    Some(session.Cell(
      value: operation.RunState(control: operation.Running, ..),
      ..,
    )) -> {
      use ledger <- result.try(read_ledger(runtime))
      reap_overdue(config, runtime, ledger)
      use runs <- result.map(
        list.try_map(dict.values(ledger), current_run(runtime, _)),
      )
      runs
      |> list.filter_map(fn(run) {
        case run {
          Some(ObservedRun(
            operation: child,
            record: child_run.Run(
              owner: Some(child_run.ParentRun(parent)),
              strand:,
              ..,
            ),
            ..,
          ))
            if parent == operation
          -> Ok(agent.handle_to_string(Handle(strand:, operation: child)))
          _ -> Error(Nil)
        }
      })
      |> list.sort(string.compare)
    }
    Some(_) | None -> Ok([])
  }
}

fn completion_follow_up(config: Config, text: String) -> message.AgentMessage {
  let #(now, _) = clock.read(config.clock)
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: now,
    origin: None,
  )
}

// --- borrowing the runtime -------------------------------------------------

// The holder is checked alive before it is called, because
// `process.call` exits the caller when the callee is gone and an
// unstarted holder is the common case (a host that wired no messaging
// plane, or a call racing boot). The residual window — the holder dying
// between the check and the reply — settles in-band anyway: a tool body
// runs on its own monitored effect process, whose death the driver turns
// into a synthetic error result rather than a fault.
fn borrow(config: Config) -> Result(api.Runtime, Refusal) {
  borrow_runtime(config) |> result.replace_error(agent.AgencyUnavailable)
}

/// Borrows the live runtime from the holder, for a seam other than this
/// one.
///
/// The holder is the session's one answer to a problem every tool seam
/// built before `api.open` has: the runtime does not exist yet, and a
/// closure over it would be a value cycle rather than an ordering
/// problem. Rather than stand up a second actor holding the same value,
/// a second seam borrows from this one — `client/scheduleseam` does —
/// and takes the same in-band unavailability when the holder is not up.
///
/// The `Nil` error is deliberate: a caller outside the messaging plane
/// has its own refusal vocabulary and should not be handed
/// `agent.AgencyUnavailable`, which names a plane it has nothing to do
/// with.
///
/// ## Examples
///
/// ```gleam
/// // agency.borrow_runtime(config)
/// ```
///
pub fn borrow_runtime(config: Config) -> Result(api.Runtime, Nil) {
  borrow_named(config.name, config.holder_timeout_ms)
}

/// Projects a fact-only supplier without retaining the rest of the Agency.
///
/// ## Examples
///
/// ```gleam
/// // agency.fact_supplier(config)()
/// ```
pub fn fact_supplier(config: Config) -> fn() -> Result(api.FactHandle, Nil) {
  let name = config.name
  let timeout = config.holder_timeout_ms
  fn() {
    use subject <- result.try(address.lookup(name))
    call.try_call(subject, waiting: timeout, sending: Borrow)
    |> result.replace_error(Nil)
    |> result.map(api.fact_handle)
  }
}

/// Projects `borrow_runtime` without retaining the rest of the Agency.
///
/// The returned supplier closes over the holder's address and timeout and
/// nothing else, for the reason `fact_supplier` does: a service which keeps
/// the whole `Config` for the life of the session keeps its closures too.
///
/// ## Examples
///
/// ```gleam
/// // agency.runtime_supplier(config)()
/// ```
pub fn runtime_supplier(config: Config) -> fn() -> Result(api.Runtime, Nil) {
  let name = config.name
  let timeout = config.holder_timeout_ms
  fn() { borrow_named(name, timeout) }
}

fn borrow_named(
  name: address.Address(Message),
  timeout: Int,
) -> Result(api.Runtime, Nil) {
  use subject <- result.try(address.lookup(name))
  use pid <- result.try(process.subject_owner(subject))
  use <- bool.guard(when: !process.is_alive(pid), return: Error(Nil))
  Ok(process.call(subject, timeout, Borrow))
}

// The whole ledger, once per Agency call. It is bounded by the session's
// live strand count (16 by default), and one listing beats a point
// lookup per hop for every question asked of it.
fn read_ledger(runtime: api.Runtime) -> Result(Dict(String, Lineage), Refusal) {
  case api.reserved_facts(runtime, prefix: lineage.key_prefix) {
    Error(error) -> Error(agent.PlaneFailed(reason: describe_api(error)))
    Ok(cells) ->
      cells
      |> list.filter_map(fn(pair) {
        let #(key, payload) = pair

        // A cell that will not decode is dropped rather than faulting the
        // read: every question asked of the ledger fails closed on a
        // missing cell, so a corrupt one degrades into a refusal instead
        // of into permission.
        case lineage.strand_of_key(key), lineage.decode(payload) {
          Ok(strand), Ok(cell) -> Ok(#(strand, cell))
          _, _ -> Error(Nil)
        }
      })
      |> dict.from_list
      |> Ok
  }
}

/// Whether `ancestor` spawned `strand`, directly or through a chain of
/// spawns, according to the durable lineage ledger.
///
/// The addressing rule this package enforces on every `agent_*` call,
/// exposed for a seam outside the messaging plane that has to answer the
/// same question. `client/scheduleseam` is the caller: a strand may
/// schedule a heartbeat onto itself or onto a strand it spawned, and
/// nothing else, so the seam needs the ledger's answer rather than a
/// guess from the shape of a name (`is_subagent` says a name was minted
/// by *an* Agency, not by whom).
///
/// **Fails closed at every step**, which is what makes it safe to ask
/// from outside: a ledger that cannot be read is `False`, a strand with
/// no cell is a root and nobody's descendant, a cell that will not
/// decode is dropped by the read and therefore also `False`, and
/// `ancestor == strand` is `False` because the relation is strict — a
/// caller that means "itself or a descendant" says so at its own door,
/// where the difference is a decision rather than an accident.
///
/// ## Examples
///
/// ```gleam
/// // agency.owns(runtime, ancestor: "main", strand: "sub:main/x-1")
/// ```
///
pub fn owns(
  runtime: api.Runtime,
  ancestor ancestor: String,
  strand strand: String,
) -> Bool {
  case read_ledger(runtime) {
    Error(_unreadable) -> False
    Ok(ledger) -> is_descendant(ledger, ancestor, strand)
  }
}

fn cell_of(ledger: Dict(String, Lineage), strand: String) -> Option(Lineage) {
  option.from_result(dict.get(ledger, strand))
}

fn is_descendant(
  ledger: Dict(String, Lineage),
  ancestor: String,
  candidate: String,
) -> Bool {
  lineage.is_descendant(
    of: ancestor,
    strand: candidate,
    cells: fn(strand) { cell_of(ledger, strand) },
    limit: max_ancestor_walk,
  )
}

// --- spawn -----------------------------------------------------------------

fn spawn(
  config: Config,
  caller: Caller,
  request: agent.SpawnRequest,
  custody: Option(api.AsyncCustody),
) -> Result(Spawned, Refusal) {
  use subject <- result.try(
    address.lookup(config.name) |> result.replace_error(agent.AgencyUnavailable),
  )
  case request.on {
    Some(orchestrator) ->
      spawn_elsewhere(config, subject, caller, request, orchestrator, custody)
    None ->
      Ok(
        process.call(subject, config.holder_timeout_ms, fn(reply) {
          SpawnChild(caller:, request:, custody:, reply:)
        }),
      )
      |> result.flatten
  }
}

// Where a spawn comes from. A local caller is a strand of this session, and
// everything the spawn needs to know about it is read from that strand's cells.
// A delegated caller is a parent on another orchestrator and is not a strand
// here, so the same facts arrive in the message.
type Source {
  Local
  Delegated(delegation: remote_spawn.Delegation)
}

// The deepest child this source may have: the Agency's own cap for a strand of
// this session, and for a remote parent the spawner's `max_depth` but never
// above that same cap. A remote child's own spawn is judged as a local one
// against the cap, so a limit above it would hand the child a spawn tool that
// every call of it would be refused.
fn depth_limit(config: Config, source: Source) -> Int {
  case source {
    Local -> config.depth_cap
    Delegated(delegation) ->
      int.min(delegation.terms.max_depth, config.depth_cap)
  }
}

fn spawn_on(
  config: Config,
  runtime: api.Runtime,
  caller: Caller,
  source: Source,
  request: agent.SpawnRequest,
  custody: Option(api.AsyncCustody),
) -> Result(Spawned, Refusal) {
  use ledger <- result.try(read_ledger(runtime))
  let depth = case source {
    Delegated(delegation) -> delegation.depth + 1
    Local ->
      case cell_of(ledger, caller.strand) {
        None -> 1
        Some(parent) -> parent.depth + 1
      }
  }
  use Nil <- result.try(case depth > depth_limit(config, source) {
    True -> Error(agent.DepthCapReached(depth: depth_limit(config, source)))
    False -> Ok(Nil)
  })
  use name <- result.try(child_name(caller, request.purpose))
  case cell_of(ledger, name) {
    Some(existing) -> adopt(runtime, caller, existing)
    None -> {
      use Nil <- result.try(admit_run(runtime, caller, source))
      reconcile(
        config,
        runtime,
        ledger,
        caller,
        source,
        request,
        name,
        depth,
        custody,
      )
    }
  }
}

// A spawn for a remote parent, as the holder serves it. A spawner's day cap is
// claimed here, in the holder, and not in the registry's turn that admitted the
// session: only the holder can tell a resent spawn, whose call site already has a
// child that `spawn_on` adopts, from a new one, and a resend must be neither
// counted nor refused at the cap. The claim comes after the fences, so a spawn
// the ended or released fence refuses is not counted, and before the child is
// created. The registry never waits on a holder, so the holder waiting on it
// cannot deadlock.
fn spawn_delegated(
  config: Config,
  runtime: api.Runtime,
  caller: Caller,
  delegation: remote_spawn.Delegation,
  request: agent.SpawnRequest,
) -> Result(Spawned, remote_spawn.SpawnRefusal) {
  let source = Delegated(delegation)
  use Nil <- result.try(claim_if_new(config, runtime, caller, source, request))
  spawn_on(config, runtime, caller, source, request, None)
  |> result.map_error(refused(config, _))
}

// Claims the spawn when the call site has no child yet. A name that cannot be
// derived and a ledger that cannot be read are left for `spawn_on` to refuse in
// its own words, and nothing is claimed for them.
fn claim_if_new(
  config: Config,
  runtime: api.Runtime,
  caller: Caller,
  source: Source,
  request: agent.SpawnRequest,
) -> Result(Nil, remote_spawn.SpawnRefusal) {
  case config.claim {
    None -> Ok(Nil)
    Some(claim) ->
      case read_ledger(runtime), child_name(caller, request.purpose) {
        Ok(ledger), Ok(name) ->
          case cell_of(ledger, name) {
            Some(_existing) -> Ok(Nil)
            None -> {
              use Nil <- result.try(
                admit_run(runtime, caller, source)
                |> result.map_error(refused(config, _)),
              )
              claim(config.holder_timeout_ms)
            }
          }
        Error(_), _ | _, Error(_) -> Ok(Nil)
      }
  }
}

// A remote parent's run that has ended owns no more children. The fence that
// says so is read here, on the path that would create or finish a child, and
// not on the adoption path above it: adopting hands back a child that already
// exists and so leaves nothing for the run end to have missed.
fn admit_run(
  runtime: api.Runtime,
  caller: Caller,
  source: Source,
) -> Result(Nil, Refusal) {
  case source {
    // The released fence is session-wide, and only a delegate session ever holds
    // it, so reading it here costs a local spawn one fact and refuses nothing.
    Local -> refuse_if_fenced(runtime, released_key(), caller)
    Delegated(..) -> {
      use Nil <- result.try(refuse_if_fenced(
        runtime,
        ended_key(caller.operation),
        caller,
      ))
      refuse_if_fenced(runtime, released_key(), caller)
    }
  }
}

// A fence that is written refuses the spawn; one that is absent admits it.
fn refuse_if_fenced(
  runtime: api.Runtime,
  key: String,
  caller: Caller,
) -> Result(Nil, Refusal) {
  case api.fact(runtime, key) {
    Ok(None) -> Ok(Nil)
    Ok(Some(_)) -> Error(agent.ParentRunEnded(strand: caller.strand))
    Error(error) -> Error(plane_failed(error))
  }
}

// The key of the fence for the whole session of a remote parent, written when
// the parent session is deleted.
fn released_key() -> String {
  api.delegate_fact_prefix <> "released"
}

// The key of the fence for one run of a remote parent.
fn ended_key(operation: OpId) -> String {
  api.delegate_fact_prefix <> "ended/" <> ids.op_id_to_string(operation)
}

// A child already sits under the derived name. That is the ordinary
// replay path — the first execution completed and the same handle is
// handed back, which is the whole of what makes `agent_spawn`
// `ReplaySafe` — but only when the ledger agrees this caller is the one
// that minted it.
//
// A name match on its own is not an ownership proof, and treating it as
// one is an ownership *transfer*: the adopting caller's brief, tools,
// `within_ms`, `detach` and `result_schema` are all silently dropped —
// `write_result_schema` runs on the other branch — and `check_capacity`
// is skipped, so the adopted child costs its new parent nothing against
// `fan_out`. The caller then waits on a strand doing something else and
// reports its answer as the answer to a question it never asked.
//
// So the ledger, not the name, decides. `minted_by` is the call site the
// name was derived from, and `agent.minting_step` is what makes "the same
// caller" mean the same operation, the same step, the same planned call
// *and* the same minter inside it — a program's ordinal included, since
// `CallSite` has no field of its own for it. Anything else is refused.
// The check is cheap and the name derivation already makes reaching it
// hard; it is here because a name is derived and a ledger cell is
// recorded, and only one of those two is evidence.
fn adopt(
  runtime: api.Runtime,
  caller: Caller,
  existing: Lineage,
) -> Result(Spawned, Refusal) {
  use <- bool.guard(
    when: existing.minted_by != call_site(caller),
    return: Error(agent.NameAlreadyMinted(strand: existing.strand)),
  )
  spawn_receipt(runtime, existing)
}

// Read the durable choice on both creation and replay. Re-resolving the
// request here could report a newly configured route for an older child.
fn spawn_receipt(
  runtime: api.Runtime,
  cell: Lineage,
) -> Result(Spawned, Refusal) {
  use configuration <- result.try(read_configuration(runtime, cell.strand))
  Ok(Spawned(
    handle: Handle(strand: cell.strand, operation: cell.brief),
    strand: cell.strand,
    tools: cell.tools,
    model: configuration.model.provider,
    model_id: configuration.model.model_id,
    deadline_ms: cell.deadline,
  ))
}

// The call site a spawn is recorded under and reconciled against. One
// function, so the cell that is written and the cell that is compared can
// never drift apart.
fn call_site(caller: Caller) -> CallSite {
  CallSite(
    operation: caller.operation,
    step_id: agent.minting_step(caller),
    source_index: caller.source_index,
  )
}

/// The name a spawn mints for a child, derived only from state that is
/// durable in the intent: the caller's strand, the purpose it slugged,
/// and `agent.call_site_digest` over the coordinates a replayed call
/// arrives under — operation, minting step, and source index.
///
/// The model never supplies a name, so it cannot claim `main`, cannot
/// shadow an operator's convention, and cannot collide with a sibling —
/// and the determinism is exactly what lets a replayed spawn find its own
/// child instead of minting a second one.
///
/// ## Two halves, and why only one of them may be truncated
///
/// The slug is the model's half and is decoration: it is bounded at
/// `agent.max_slug_length` so a pasted paragraph cannot become a register
/// key, and nothing about who owns the child rests on it. The digest is
/// the harness's half and is the whole of the identity: sixteen hex
/// characters, constant width, no model input.
///
/// The two properties that division buys are the two the previous shape
/// lacked, and it lacked them together. It ended `-{step-slug}-{index}`,
/// where the step was slugged by the *purpose* slugger and so truncated
/// at twenty-four characters — and a production step id is a
/// thirty-six-character UUID, so every discriminator a caller appended to
/// the step was cut off before it reached the name. A constant-width
/// field has no cap left to be truncated against. And because the digest
/// takes no model-supplied input, a chosen purpose moves the decoration
/// and nothing else; there is no string a model can pick that makes two
/// call sites derive one name.
///
/// The step and index are not lost, only moved: they are recorded whole
/// in the child's lineage cell, under `minted_by`, which is where an
/// operator asking "where did this strand come from" should look and is
/// what a reconciliation is checked against.
///
/// Exposed because it is the coordinate function the idempotence
/// argument rests on, and a claim like that should be checkable from
/// outside.
///
/// ## Examples
///
/// ```gleam
/// // agency.child_name(caller, "review the auth code")
/// // -> Ok("sub:main/review-the-auth-code-7b1c0a4e2d95f318")
/// ```
///
pub fn child_name(caller: Caller, purpose: String) -> Result(String, Refusal) {
  use slug <- result.try(
    agent.slug(purpose)
    |> result.replace_error(agent.InvalidArgument(
      reason: "`purpose` must contain at least one letter or digit",
    )),
  )
  Ok(
    subagent_prefix
    <> caller.strand
    <> "/"
    <> slug
    <> "-"
    <> agent.call_site_digest(caller),
  )
}

// No lineage cell for the minted name. Either the strand does not exist
// (the ordinary path) or a previous execution crashed between
// `create_strand`'s two commits and left one that does. All four arms
// converge on one child with one handle.
fn reconcile(
  config: Config,
  runtime: api.Runtime,
  ledger: Dict(String, Lineage),
  caller: Caller,
  source: Source,
  request: agent.SpawnRequest,
  name: String,
  depth: Int,
  custody: Option(api.AsyncCustody),
) -> Result(Spawned, Refusal) {
  // The configuration a child is built on, and the tools it may narrow. For a
  // strand of this session both are the parent's own cells. A remote parent has
  // none, so the base is the delegate session's `main` strand, which the
  // spawner's profile seeded, and the tools are the message's, already clamped
  // to the spawner's ceiling.
  use #(parent_configuration, parent_tools) <- result.try(case source {
    Local -> {
      use configuration <- result.map(read_configuration(runtime, caller.strand))
      #(configuration, configuration.active_tool_names)
    }
    Delegated(delegation) -> {
      use configuration <- result.map(read_configuration(
        runtime,
        session_main_strand,
      ))
      #(configuration, delegation.parent_tools)
    }
  })
  use tools <- result.try(child_tools(
    depth_limit(config, source),
    parent_tools,
    request.tools,
    depth,
  ))
  use state <- result.try(read_strand_state(runtime, name))
  use brief <- result.try(case state {
    // The strand does not exist: an ordinary first spawn, and the only
    // arm the caps are checked on — a reconciliation is finishing a
    // child that was already counted.
    None -> {
      use Nil <- result.try(check_capacity(config, runtime, ledger, caller))
      create(
        config,
        runtime,
        caller,
        source,
        request,
        name,
        parent_configuration,
        tools,
        custody,
      )
    }

    // The registers are seeded but the brief run was never accepted, or
    // was accepted and has already finished. The last arm recovers by
    // adopting a brief.
    Some(state) -> {
      // The child already exists, so what it was seeded with is what it can
      // call. The notice names that list rather than the one recomputed
      // from the parent's current configuration, which may have changed
      // since the crash.
      use seeded <- result.try(read_configuration(runtime, name))
      recover_brief(
        config,
        runtime,
        caller,
        source,
        request,
        name,
        seeded.active_tool_names,
        state,
        custody,
      )
    }
  })
  let #(now, _clock) = clock.read(config.clock)
  let cell =
    Lineage(
      strand: name,
      parent: caller.strand,
      depth:,
      minted_by: call_site(caller),
      brief:,
      tools:,
      default_within_ms: config.default_within_ms,
      deadline: deadline_of(config, now, request.within_ms),
      detached: request.detach,
      reaped: False,
      orchestrator: None,
    )

  // Before the lineage cell, not after: the replay path keys on the
  // lineage cell and returns early when it finds one, so a crash between
  // these two commits must be able to leave a schema with no child and
  // never a child whose contract went missing.
  use Nil <- result.try(write_result_schema(
    runtime,
    name,
    request.result_schema,
  ))
  use cell <- result.try(seed_original_run(runtime, cell))
  use Nil <- result.try(write_cell(runtime, cell))
  spawn_receipt(runtime, cell)
}

// A crash can leave the run record committed before the lineage cell. Resume
// that admission with its original deadline rather than granting extra time or
// refusing every later replay because the first write already exists.
fn seed_original_run(
  runtime: api.Runtime,
  cell: Lineage,
) -> Result(Lineage, Refusal) {
  use existing <- result.try(run_record(
    runtime,
    Handle(strand: cell.strand, operation: cell.brief),
  ))
  case existing {
    Some(run) -> Ok(Lineage(..cell, deadline: run.record.deadline))
    None ->
      api.put_reserved_fact_expecting(
        runtime,
        child_run.key(cell.brief),
        child_run.encode(original_run(cell)),
        expected: None,
      )
      |> result.replace(cell)
      |> result.map_error(fn(error) {
        agent.PlaneFailed(reason: describe_api(error))
      })
  }
}

fn write_result_schema(
  runtime: api.Runtime,
  strand: String,
  schema: Option(ResultSchema),
) -> Result(Nil, Refusal) {
  case schema {
    None -> Ok(Nil)
    Some(schema) ->
      api.put_fact(
        runtime,
        result_schema_prefix <> strand,
        agent.render_result_schema(schema),
      )
      |> result.map_error(fn(error) {
        agent.PlaneFailed(reason: describe_api(error))
      })
  }
}

// The contract, read back. `render_result_schema` is the canonical form
// and `parse_result_schema` is total over it, so a cell that will not
// decode — corrupt, or hand-written by an operator — degrades into "no
// contract" rather than faulting a join nobody inside the session could
// repair. Failing open is safe *here* in a way it is not in the lineage
// ledger, and the difference is worth stating: a missing lineage fact
// would grant an addressing right, while a missing contract grants
// nothing. It costs a join that reports `NoResultAsked` when a schema
// was in fact asked for — a wrong answer, but a legible one that names
// no authority the caller did not have.
fn read_result_schema(
  runtime: api.Runtime,
  strand: String,
) -> Option(ResultSchema) {
  case api.fact(runtime, result_schema_prefix <> strand) {
    Error(_error) -> None
    Ok(None) -> None
    Ok(Some(payload)) -> option.from_result(agent.parse_result_schema(payload))
  }
}

// The registers are seeded but the brief run was never accepted, or was
// accepted and has already finished. The first two arms recover the
// operation id; the last one is the state a crash between the seed
// commit and the brief commit leaves behind, which nothing else can
// recover — re-seeding is refused as `StrandExists`, and without this
// arm the name stays claimed forever on a strand the booter restarts on
// every reboot and which never does anything.
fn recover_brief(
  config: Config,
  runtime: api.Runtime,
  caller: Caller,
  source: Source,
  request: agent.SpawnRequest,
  name: String,
  tools: List(String),
  state: machine_strand.StrandState,
  custody: Option(api.AsyncCustody),
) -> Result(OpId, Refusal) {
  case custody {
    Some(owner) -> {
      use original <- result.try(
        api.fact(runtime, child_run.initial_key(name))
        |> result.map_error(fn(error) { agent.PlaneFailed(describe_api(error)) }),
      )
      case original {
        Some(json.String(operation)) ->
          ids.parse_op_id(operation)
          |> result.map_error(fn(_) {
            agent.PlaneFailed("invalid original async child operation")
          })
        Some(_) ->
          Error(agent.PlaneFailed("invalid original async child record"))
        None ->
          accept_async_brief(
            config,
            runtime,
            caller,
            request,
            name,
            tools,
            owner,
          )
      }
    }
    None ->
      recover_ordinary_brief(
        config,
        runtime,
        caller,
        source,
        request,
        name,
        tools,
        state,
      )
  }
}

fn recover_ordinary_brief(
  config: Config,
  runtime: api.Runtime,
  caller: Caller,
  source: Source,
  request: agent.SpawnRequest,
  name: String,
  tools: List(String),
  state: machine_strand.StrandState,
) -> Result(OpId, Refusal) {
  case state.current_operation {
    Some(operation) -> Ok(operation)
    None ->
      case read_last_result(runtime, name) {
        Some(last) -> Ok(api.result_operation(last))
        None ->
          api.adopt_strand(runtime, named: name, brief: [
            brief_message(
              config,
              caller,
              source,
              request,
              ChildFacts(parent: caller.strand, strand: name, tools:),
            ),
          ])
          |> result.map_error(fn(error) {
            agent.PlaneFailed(reason: describe_create(error))
          })
      }
  }
}

fn create(
  config: Config,
  runtime: api.Runtime,
  caller: Caller,
  source: Source,
  request: agent.SpawnRequest,
  name: String,
  parent_configuration: machine_strand.StrandConfiguration,
  tools: List(String),
  custody: Option(api.AsyncCustody),
) -> Result(OpId, Refusal) {
  use configuration <- result.try(child_configuration(
    config,
    parent_configuration,
    tools,
    request.model,
  ))
  use fork_point <- result.try(case request.context {
    agent.Fresh -> Ok(None)
    agent.MyConversation ->
      api.leaf(api.on_strand(runtime, caller.strand))
      |> result.map_error(fn(error) {
        agent.PlaneFailed(reason: describe_api(error))
      })
  })
  case custody {
    Some(owner) -> {
      use Nil <- result.try(
        api.create_idle_strand(
          runtime,
          named: name,
          configuration:,
          at: fork_point,
        )
        |> result.replace(Nil)
        |> result.map_error(fn(error) {
          agent.PlaneFailed(describe_create(error))
        }),
      )
      accept_async_brief(config, runtime, caller, request, name, tools, owner)
    }
    None ->
      api.create_strand(
        runtime,
        named: name,
        configuration:,
        at: fork_point,
        brief: [
          brief_message(
            config,
            caller,
            source,
            request,
            ChildFacts(parent: caller.strand, strand: name, tools:),
          ),
        ],
      )
      |> result.map_error(fn(error) {
        agent.PlaneFailed(describe_create(error))
      })
  }
}

fn accept_async_brief(
  config: Config,
  runtime: api.Runtime,
  caller: Caller,
  request: agent.SpawnRequest,
  name: String,
  tools: List(String),
  owner: api.AsyncCustody,
) -> Result(OpId, Refusal) {
  let attachment = case request.detach {
    True -> api.Detached
    False -> api.Owned
  }
  use delivery <- result.try(
    api.send_to_async_child(
      runtime,
      name,
      brief_message(
        config,
        caller,
        Local,
        request,
        ChildFacts(parent: caller.strand, strand: name, tools:),
      ),
      api.AsyncCustody(..owner, attachment:),
      option.or(request.within_ms, config.default_within_ms),
    )
    |> result.map_error(fn(error) { agent.PlaneFailed(describe_api(error)) }),
  )
  case delivery {
    api.Started(operation) -> Ok(operation)
    api.Steered(_) ->
      Error(agent.PlaneFailed(
        "the initial async brief must start an idle child",
      ))
  }
}

// The configuration a child is seeded with: the parent's, narrowed to the
// child's tool set, with identity and seed thinking from an explicit
// catalogue choice, or the host's `subagent` route when none was named.
//
// Role follows identity, and the identity is chosen once, here, at
// creation — never per request. A child's durable configuration is what
// every later dispatch, admission and compaction reads, so seeding it is
// what makes "subagents run on the subagent model" true across a crash,
// a reboot and a `set_config` the operator makes afterwards. An unrouted
// subagent role inherits rather than refusing: a host that named no
// subagent model has not asked for a different one.
fn child_configuration(
  config: Config,
  parent: machine_strand.StrandConfiguration,
  tools: List(String),
  selection: Option(String),
) -> Result(machine_strand.StrandConfiguration, Refusal) {
  let narrowed =
    machine_strand.StrandConfiguration(..parent, active_tool_names: tools)
  case selection {
    Some(name) -> {
      use selected <- result.try(
        list.find(config.models, fn(entry) { entry.0.provider == name })
        |> result.map_error(fn(_) {
          agent.InvalidArgument(reason: "unknown model name: " <> name)
        }),
      )
      let #(model, thinking_level) = selected
      Ok(
        machine_strand.StrandConfiguration(..narrowed, model:, thinking_level:),
      )
    }
    None -> {
      let inherited = case config.subagent_model() {
        Ok(#(model, thinking_level)) ->
          machine_strand.StrandConfiguration(
            ..narrowed,
            model:,
            thinking_level:,
          )
        Error(Nil) -> narrowed
      }
      Ok(inherited)
    }
  }
}

// A child may narrow its parent's tool set and never widen it: a name the
// parent does not hold is a refusal, not a silent drop. The default is
// the parent's set minus `agent_spawn`, which is the structural half of
// the depth cap and worth more than the numeric check — a tool the model
// cannot see is one it never tries. A child at the cap loses the spawn
// tool whatever it asked for.
//
// An explicit list replaces the default, and a list that omitted
// `agent_send` and `agent_note` left a child unable to report to its
// parent. So the communication floor (`agent.child_floor_tools`) is added
// to any explicit list, limited to what the parent holds: the floor is a
// subset of the parent's own set like everything else here.
//
// The result is sorted and deduplicated because a strand's active tool
// list renders to the wire in that order, ahead of the system prompt, as
// the byte prefix of the provider's cached region.
fn child_tools(
  depth_cap: Int,
  parent_tools: List(String),
  requested: Option(List(String)),
  depth: Int,
) -> Result(List(String), Refusal) {
  use chosen <- result.try(case requested {
    None ->
      Ok(list.filter(parent_tools, fn(name) { name != agent.spawn_tool_name }))
    Some(names) -> {
      use held <- result.map(
        list.try_map(names, fn(name) {
          case list.contains(parent_tools, name) {
            True -> Ok(name)
            False -> Error(agent.UnknownTool(name:))
          }
        }),
      )
      let floor =
        list.filter(agent.child_floor_tools, list.contains(parent_tools, _))
      list.append(held, floor)
    }
  })
  let chosen = case depth >= depth_cap {
    True -> list.filter(chosen, fn(name) { name != agent.spawn_tool_name })
    False -> chosen
  }
  Ok(chosen |> list.sort(string.compare) |> list.unique)
}

// Both caps are read-then-write with no compare-and-set: `put_fact`
// commits with no expectation, so two spawns that genuinely overlap
// could both pass a session-wide check. At the shipped `depth_cap: 1`
// that cannot happen — only the root strand spawns, and `agent_spawn` is
// `Exclusive`, so its calls never overlap within a batch. Raising the cap
// makes it live, and the cap is then **advisory**: the fix is one CAS'd
// counter cell, and it is deliberately not built for a bound nothing
// currently reaches.
fn check_capacity(
  config: Config,
  runtime: api.Runtime,
  ledger: Dict(String, Lineage),
  caller: Caller,
) -> Result(Nil, Refusal) {
  let #(now, _clock) = clock.read(config.clock)
  use stubs <- result.try(live_stubs(runtime, now))
  let live_cells =
    list.filter(dict.values(ledger), fn(cell) { is_live(runtime, cell) })

  // A child on another orchestrator has a stub and no strand, so the strand
  // registers `is_live` reads cannot see it. The stubs are counted beside the
  // cells, under the same caps: a remote child takes a slot of its parent's
  // `fan_out` and of the session's `session_strands` for as long as it may be
  // running.
  let live =
    list.append(
      list.map(live_cells, fn(cell) { #(cell.parent, cell.strand) }),
      list.map(stubs, fn(stub) { #(stub.strand, stub.name) }),
    )
  let mine = list.filter(live, fn(child) { child.0 == caller.strand })

  // Both guards are lazy, and that is not a flourish: the count in the
  // refusal is the one thing here that genuinely has to walk the list,
  // and an eager `return:` would walk it on every admitted spawn to
  // build a message nobody reads. The refusal path pays for its own
  // number; the admission path pays for nothing.
  use <- bool.lazy_guard(when: at_least(mine, config.fan_out), return: fn() {
    Error(agent.FanOutCapReached(live: list.length(mine), cap: config.fan_out))
  })
  use <- bool.lazy_guard(
    when: at_least(live, config.session_strands),
    return: fn() {
      Error(agent.FanOutCapReached(
        live: list.length(live),
        cap: config.session_strands,
      ))
    },
  )
  Ok(Nil)
}

// Whether `values` holds at least `bound` elements, answered at the bound
// instead of by counting: `list.drop` stops as soon as it has dropped
// that many, so a session holding a hundred live strands costs a check
// the same as one holding `bound` of them.
//
// The `bound <= 0` arm is the arithmetic, not a defensive crumple zone.
// "At least none" is true of every list, the empty one included, and the
// drop spelling gets that case wrong twice over: `bound - 1` is negative,
// and `list.drop` hands a negative count the whole list back, so an empty
// ledger would read as *not* at a cap of zero. A host that sets `fan_out`
// to zero means no spawns at all, and this is the line that says so.
fn at_least(values: List(a), bound: Int) -> Bool {
  bound <= 0 || list.drop(values, bound - 1) != []
}

fn deadline_of(
  config: Config,
  now: Int,
  within_ms: Option(Int),
) -> Option(Int) {
  case within_ms, config.default_within_ms {
    Some(budget), _ if budget > 0 -> Some(now + budget)
    Some(_), fallback | None, fallback ->
      option.map(fallback, fn(budget) { now + budget })
  }
}

// The brief is framed the same way a message from another agent is, and
// for the same reason: it is model-authored text that may be a laundered
// quotation of hostile repository content, and the child must be able to
// tell it from its operator's own channel.
fn brief_message(
  config: Config,
  caller: Caller,
  source: Source,
  request: agent.SpawnRequest,
  child: ChildFacts,
) -> AgentMessage {
  let #(now, _clock) = clock.read(config.clock)
  message.UserMessage(
    content: [
      message.UserText(
        text: frame_brief(from: caller.strand, body: request.brief)
          <> child_notice(child, request.result_schema),
        text_signature: None,
      ),
    ],
    timestamp: now,
    // The origin is attribution from the authenticated caller, never from
    // anything the model emitted, and it is not authority: no check may read
    // it to grant or skip anything (protocol-change 059). A remote parent is a
    // peer whose session and strand the receiving host bound, which is what
    // `PeerOrigin` records.
    origin: Some(case source {
      Local -> message.StrandOrigin(strand: caller.strand)
      Delegated(delegation) ->
        message.PeerOrigin(
          session: delegation.parent.session,
          strand: delegation.parent.strand,
        )
    }),
  )
}

/// What the harness tells a child about itself in the trailer of its first
/// message: the name it runs under, who spawned it, and the tools active
/// in its strand.
///
/// The parent is the authenticated caller and the name and tools are the
/// spawn's own persisted inputs, so a replayed or recovered spawn rebuilds
/// the same words. The parent is never parsed back out of the minted name.
pub type ChildFacts {
  ChildFacts(
    /// The strand that spawned the child: the caller of `agent_spawn`.
    parent: String,
    /// The child's own strand name.
    strand: String,
    /// The tools active in the child's strand.
    tools: List(String),
  )
}

/// The harness's trailer to a spawned child's brief: who it is, which
/// tools it can call, how its result reaches its parent, and, when the
/// parent asked for one, the result contract.
///
/// The system prompt cannot say this. It is built once for the session
/// from the full tool registry and is shared by every strand, so a child
/// with a narrowed tool set still reads a tools index that lists tools it
/// cannot call. The incident behind this trailer: such a child kept trying
/// to `agent_send` its report, then issued no-op calls, and only learned
/// from its operator that its final message is what the parent receives.
///
/// The trailer sits after the brief's closing marker, and the placement is
/// the point: the brief is model-authored text framed as data, while this
/// is the harness telling the child what its run owes. Putting it inside
/// the quoted region would file it under the sender's authority, which is
/// the authority the framing exists to withhold. It uses the markers
/// `strand_framing` defines, so the hosts that strip a framed brief remove
/// it with no change. The schema is quoted from `render_result_schema`
/// rather than from whatever the parent typed, so what the child reads is
/// exactly what its notes will be judged against. The tool list is sorted and deduplicated so the same
/// spawn always yields the same bytes.
///
/// ## Examples
///
/// ```gleam
/// // agency.child_notice(
/// //   agency.ChildFacts(parent: "main",
/// //     strand: "sub:main/x-0123456789abcdef",
/// //     tools: ["bash", "agent_note"]),
/// //   option.None,
/// // )
/// ```
///
pub fn child_notice(child: ChildFacts, schema: Option(ResultSchema)) -> String {
  let tools =
    child.tools |> list.sort(string.compare) |> list.unique |> string.join(", ")
  "\n"
  <> strand_framing.contract_open
  <> "\nYou are strand `"
  <> child.strand
  <> "`, a subagent of `"
  <> child.parent
  <> "`. The tools index in the system prompt lists the session's tools; in "
  <> "this strand you can call only: "
  <> tools
  <> ".\nYour final message is your result. Your parent receives it through "
  <> "agent_wait; you do not need to send it."
  <> schema_clause(schema)
  <> "\n"
  <> strand_framing.contract_close
}

// The schema half of the contract, empty when the parent asked for none.
fn schema_clause(schema: Option(ResultSchema)) -> String {
  case schema {
    None -> ""
    Some(schema) ->
      "\nBefore you finish, record your result with agent_note under the "
      <> "key `"
      <> agent.result_note_key
      <> "`, matching this schema exactly:\n"
      <> json.to_string(agent.render_result_schema(schema))
      <> "\nA note that does not match is refused and tells you why, so "
      <> "write it while you still have the work in hand. Write your "
      <> "prose answer as well: the schema is what your parent branches "
      <> "on, the prose is what a human reads."
  }
}

// --- wait ------------------------------------------------------------------

fn wait(
  config: Config,
  caller: Caller,
  handles: List(Handle),
  within_ms: Int,
) -> Result(List(Waited), Refusal) {
  use runtime <- result.try(borrow(config))
  use kept <- result.try(
    remote_child.all(runtime) |> result.map_error(agent.PlaneFailed),
  )
  case remote_targets(kept, handles) {
    [] -> wait_for(config, caller.strand, handles, within_ms)
    targets -> wait_across(config, runtime, caller, handles, targets, within_ms)
  }
}

// A wait needs only the strand that asks, to judge descent from. A remote
// parent has no `Caller` of its own to give, only the reference `^main`.
fn wait_for(
  config: Config,
  waiter: String,
  handles: List(Handle),
  within_ms: Int,
) -> Result(List(Waited), Refusal) {
  use runtime <- result.try(borrow(config))
  use ledger <- result.try(read_ledger(runtime))
  use Nil <- result.try(
    list.try_each(handles, fn(handle) {
      case is_descendant(ledger, waiter, handle.strand) {
        True -> Ok(Nil)
        False -> Error(agent.NotADescendant(strand: handle.strand))
      }
    }),
  )

  // Overdue children are reaped before the wait, not during it: the
  // durable mark is one commit, and re-issuing the abort on every
  // observation is what keeps a reap that landed while no driver was
  // registered from evaporating.
  reap_overdue(config, runtime, ledger)
  let #(started, _clock) = clock.read(config.clock)
  wait_loop(
    config,
    runtime,
    handles,
    started,
    clamp(within_ms, 0, config.max_wait_ms),
  )
}

// One handle's non-blocking settlement check, folded into the running
// `found` map: already-settled handles are left alone, an unsettled one
// is polled once more.
fn settle_handle(
  runtime: api.Runtime,
  found: Dict(String, LastResult),
  handle: Handle,
) -> Dict(String, LastResult) {
  case dict.has_key(found, agent.handle_to_string(handle)) {
    True -> found
    False ->
      case
        api.await_strand_result(
          runtime,
          strand: handle.strand,
          operation: handle.operation,
          within_ms: 0,
        )
      {
        Ok(last) -> dict.insert(found, agent.handle_to_string(handle), last)
        Error(Nil) -> found
      }
  }
}

// One wait, one budget, every handle.
//
// The loop is `weft/poll`'s folding form, and the fold is what earns it:
// the map of handles that have already settled has to reach the next
// attempt, or every slice would re-ask the store about children that
// answered on the first one. Expiry hands that map back (`RanOut`)
// instead of only reporting that time ran out, which is exactly what a
// join needs — the children that did settle are reported as `Ready` and
// only the ones that did not are `Pending`.
//
// The wait runs on `config.clock` rather than on the monotonic clock, so
// a simulated session's join is bounded by logical time its runner steps;
// `client/internal/timebase` has that argument and the ruling on the
// successor clock. The slice still backs off, now as a `Doubling`
// interval, which is what keeps a long join at roughly four store reads a
// second rather than a hundred.
fn wait_loop(
  config: Config,
  runtime: api.Runtime,
  handles: List(Handle),
  started: Int,
  budget: Int,
) -> Result(List(Waited), Refusal) {
  // The probe never reports `Broken`: a handle that cannot be read yet is
  // simply unsettled, so there is no failure to distinguish from waiting.
  let verdict: poll.Verdict(_, Nil, _) =
    poll.fold_until(
      clock: timebase.on(config.clock, config.rest),
      within: budget,
      every: poll.Doubling(from: config.first_slice_ms, to: config.max_slice_ms),
      from: dict.new(),
      attempt: fn(settled) { settle_pass(runtime, handles, settled) },
    )

  let settled = case verdict {
    poll.Answer(settled) | poll.RanOut(settled) -> settled

    // Unreachable: `settle_pass` never reports `Broken`. The arm is
    // written out because that is what makes it checkable, and it answers
    // with what an empty pass would have — every handle still pending.
    poll.Failure(Nil) -> dict.new()
  }

  let #(now, _clock) = clock.read(config.clock)

  // Settled children still need their saved notes read. A failed scan must
  // refuse the join rather than synthesize an empty structured result.
  list.try_map(handles, fn(handle) {
    case dict.get(settled, agent.handle_to_string(handle)) {
      Ok(last) -> ready(runtime, handle, last)
      Error(Nil) ->
        Ok(Pending(handle:, waited_ms: now - started, unanswered: None))
    }
  })
}

// One pass over every handle, and the question of whether that was the
// last one needed.
//
// "Everything has settled" is asked at the bound rather than by counting.
// Every key in `settled` is one of *these* handles' own — the fold below
// inserts under `handle_to_string` and nothing else puts a key in — so
// the dict can never outgrow the list, and "as many settled as there are
// handles" is the same question as "no handle sits past the ones that
// have settled". `dict.size` is a constant-time read of the map's own
// counter; `list.drop` stops at it. The alternative walked the handle
// list on every slice of every wait, which is the one loop in this module
// that runs on a timer.
fn settle_pass(
  runtime: api.Runtime,
  handles: List(Handle),
  settled: Dict(String, LastResult),
) -> poll.Pass(Dict(String, LastResult), Nil, Dict(String, LastResult)) {
  let settled =
    list.fold(handles, settled, fn(found, handle) {
      settle_handle(runtime, found, handle)
    })
  case list.drop(handles, dict.size(settled)) == [] {
    True -> poll.Settled(settled)
    False -> poll.Pending(settled)
  }
}

fn ready(
  runtime: api.Runtime,
  handle: Handle,
  last: LastResult,
) -> Result(Waited, Refusal) {
  use notes <- result.try(notes_under(
    runtime,
    agent.blackboard_prefix <> handle.strand <> "/",
  ))
  let outcome = run_outcome(runtime, handle, last)
  Ok(Ready(
    handle:,
    outcome:,
    report: partial_report(outcome, report_of(runtime, last), notes),
    // The notes are already in hand, so the contract costs one point read
    // for the schema and no second listing: the result cell *is* a note,
    // which is the whole reason the blackboard was the right place to put
    // it rather than a channel of its own.
    result: terminal_result(runtime, handle.strand, notes),
    notes:,
  ))
}

// A failed reviewer can still have useful saved observations. These notes
// are mutable strand state, so they are labelled as such rather than attributed
// to this operation or presented as a completed review.
fn partial_report(
  outcome: Outcome,
  final: String,
  notes: List(#(String, JsonValue)),
) -> String {
  case outcome {
    Completed -> final
    Failed(_)
    | Aborted
    | agent.BudgetExpired
    | agent.ParentFinished
    | agent.Released
    | agent.TokenBudgetSpent -> {
      let heading = case outcome {
        Failed(_) -> "Partial reviewer output (failed)."
        Aborted -> "Partial reviewer output (stopped)."
        agent.BudgetExpired ->
          "Partial reviewer output (wall-clock budget expired)."
        agent.ParentFinished ->
          "Partial reviewer output (owning parent run ended)."
        agent.Released -> "Partial reviewer output (parent session deleted)."
        agent.TokenBudgetSpent ->
          "Partial reviewer output (child token budget spent)."
        Completed -> "Reviewer output."
      }
      case final, notes {
        "", [] -> heading <> " No final answer or saved notes are available."
        "", _ -> {
          let excerpt =
            notes
            |> list.take(8)
            |> list.map(fn(pair) {
              let text = case pair.1 {
                json.String(text) -> text
                value -> json.to_string(value)
              }
              pair.0
              <> ":\n"
              <> string.slice(text, 0, 2048)
              <> case string.length(text) > 2048 {
                True -> "\n[Note excerpt; full value remains in notes.]"
                False -> ""
              }
            })
            |> string.join("\n\n")
          heading
          <> "\n\nLatest saved notes; these may include work from earlier turns:\n\n"
          <> excerpt
        }
        _, _ -> heading <> "\n\n" <> final
      }
    }
  }
}

fn terminal_result(
  runtime: api.Runtime,
  strand: String,
  notes: List(#(String, JsonValue)),
) -> TerminalResult {
  case read_result_schema(runtime, strand) {
    None -> agent.NoResultAsked
    Some(schema) ->
      case list.key_find(notes, result_key(strand)) {
        Error(Nil) -> agent.ResultAbsent(schema:)
        Ok(value) -> judged(schema, value)
      }
  }
}

fn judged(schema: ResultSchema, value: JsonValue) -> TerminalResult {
  case agent.validate_result(schema, value) {
    Ok(Nil) -> agent.ResultGiven(value:)
    Error(mismatch) -> agent.ResultUnusable(schema:, received: value, mismatch:)
  }
}

fn result_key(strand: String) -> String {
  agent.blackboard_prefix <> strand <> "/" <> agent.result_note_key
}

fn outcome_of(last: LastResult) -> Outcome {
  case last {
    operation.RunLastResult(outcome: operation.RunCompleted(..), ..) ->
      Completed
    operation.RunLastResult(outcome: operation.RunFailed(error:), ..) ->
      Failed(reason: error.code <> ": " <> error.message)
    operation.RunLastResult(outcome: operation.RunAborted, ..) -> Aborted
    operation.CompactionLastResult(outcome:, ..) -> structural_outcome(outcome)
    operation.NavigationLastResult(outcome:, ..) -> structural_outcome(outcome)
  }
}

fn structural_outcome(outcome: operation.StructuralOutcome) -> Outcome {
  case outcome {
    operation.StructuralCompleted | operation.StructuralDeclined -> Completed
    operation.StructuralFailed(error:) ->
      Failed(reason: error.code <> ": " <> error.message)
    operation.StructuralAborted -> Aborted
  }
}

// The report is a projection, not a stored field: `LastResult` carries
// only the entry id of the final assistant response, so the text is read
// back through the writer. A run that ended without one — a failure, an
// abort, or a batch every tool terminated — has no final answer. The caller
// may separately present saved notes as explicitly labelled partial work.
fn report_of(runtime: api.Runtime, last: LastResult) -> String {
  case last {
    operation.RunLastResult(final_assistant: Some(entry), ..) ->
      assistant_text(runtime, entry)
    _ -> ""
  }
}

fn assistant_text(runtime: api.Runtime, id: EntryId) -> String {
  case writer.get_entries(runtime.tree.writer, [id]) {
    Error(_error) -> ""
    Ok(found) ->
      case dict.get(found, id) {
        Ok(entry.MessageEntry(
          message: message.AssistantMessage(content:, ..),
          ..,
        )) ->
          content
          |> list.filter_map(fn(block) {
            case block {
              message.AssistantText(text:, ..) -> Ok(text)
              _ -> Error(Nil)
            }
          })
          |> string.join("\n")
        _ -> ""
      }
  }
}

// --- send ------------------------------------------------------------------

fn send(
  config: Config,
  caller: Caller,
  to: String,
  text: String,
  within_ms: Option(Int),
  custody: Option(api.AsyncCustody),
) -> Result(Delivery, Refusal) {
  use runtime <- result.try(borrow(config))
  use ledger <- result.try(read_ledger(runtime))
  use Nil <- result.try(case within_ms {
    Some(ms) if ms <= 0 ->
      Error(agent.InvalidArgument("within_ms must be positive"))
    Some(_) | None -> Ok(Nil)
  })
  let upward = case cell_of(ledger, caller.strand) {
    Some(cell) -> cell.parent == to
    None -> False
  }
  use Nil <- result.try(
    case upward || is_descendant(ledger, caller.strand, to) {
      True -> Ok(Nil)

      // A child whose spawn is unanswered has a stub and no lineage cell yet, so
      // it is not addressable; the model is told it is still starting.
      False ->
        case remote_child.all(runtime) {
          Ok(kept) -> Error(still_starting_or_unknown(kept, to))
          Error(_) -> Error(agent.NotAddressable(strand: to))
        }
    },
  )
  use <- bool.lazy_guard(
    when: upward
      && option.is_some(config.spawner)
      && string.starts_with(to, api.parent_reference_prefix),
    return: fn() { queue_upward(config, runtime, caller, to, text, within_ms) },
  )
  use <- bool.lazy_guard(when: runs_elsewhere(ledger, to), return: fn() {
    send_remote(config, runtime, caller, to, text, within_ms)
  })
  use Nil <- result.try(case upward {
    False -> Ok(Nil)
    True ->
      case within_ms, read_strand_state(runtime, to) {
        Some(_), _ ->
          Error(agent.InvalidArgument("within_ms applies only to an idle child"))
        None, Error(refusal) -> Error(refusal)
        None,
          Ok(Some(machine_strand.StrandState(current_operation: Some(_), ..)))
        -> Ok(Nil)
        None, Ok(_) -> Error(agent.ParentRunEnded(strand: to))
      }
  })

  // The guard above is a read and the send below is a commit, so a parent
  // that finishes in between is still woken. The window is one storage
  // round trip and it is named rather than claimed shut; closing it would
  // need an admission that could refuse to *start* a run, which the queue
  // has no vocabulary for.
  let #(now, _clock) = clock.read(config.clock)
  let payload =
    message.UserMessage(
      content: [
        message.UserText(
          text: frame_message(from: caller.strand, body: text),
          text_signature: None,
        ),
      ],
      timestamp: now,
      // The same attribution as a brief carries: the sender is the
      // authenticated caller, and the framing text above stays the
      // model-facing hint (protocol-change 059).
      origin: Some(message.StrandOrigin(strand: caller.strand)),
    )
  let delivery = case upward, custody {
    True, Some(owner) ->
      api.steer_async(api.on_strand(runtime, to), payload, owner)
    False, Some(owner) ->
      api.send_to_async_child(
        runtime,
        to:,
        message: payload,
        custody: api.AsyncCustody(
          ..owner,
          attachment: case cell_of(ledger, to) {
            Some(lineage) if lineage.detached -> api.Detached
            _ -> api.Owned
          },
        ),
        within_ms:,
      )
    True, None -> api.send_to_strand(runtime, to:, message: payload)
    False, None ->
      api.send_to_child(
        api.on_strand(runtime, caller.strand),
        to:,
        message: payload,
        owner: caller.operation,
        within_ms:,
      )
  }
  case delivery {
    Error(api.AcceptRejected(_)) if within_ms != None ->
      Error(agent.InvalidArgument(
        "within_ms starts a new run only; the child is already active",
      ))
    Error(error) -> Error(agent.PlaneFailed(reason: describe_api(error)))
    Ok(api.Steered(entry:)) -> Ok(agent.Steered(entry:))
    Ok(api.Started(operation:)) -> {
      use deadline_ms <- result.try(run_deadline(
        runtime,
        Handle(strand: to, operation:),
      ))
      Ok(agent.Started(operation:, deadline_ms:))
    }
  }
}

// Whether the strand is a child on another orchestrator, which the lineage cell
// says by naming the orchestrator.
fn runs_elsewhere(ledger: Dict(String, Lineage), to: String) -> Bool {
  case cell_of(ledger, to) {
    Some(Lineage(orchestrator: Some(_), ..)) -> True
    Some(_) | None -> False
  }
}

// A remote child's `agent_send` to its parent. The delegate session cannot
// reach the parent's orchestrator on demand, so the message becomes an outbox row
// and the model is told it is queued. The row is keyed by the sending call site,
// so a replayed call finds its own row, and the drainer sends it when the
// laptop's node is connected (`client/delegate_outbox`).
fn queue_upward(
  config: Config,
  runtime: api.Runtime,
  caller: Caller,
  to: String,
  text: String,
  within_ms: Option(Int),
) -> Result(Delivery, Refusal) {
  use Nil <- result.try(case within_ms {
    Some(_) ->
      Error(agent.InvalidArgument("within_ms applies only to an idle child"))
    None -> Ok(Nil)
  })
  let row =
    delegate_outbox.Mail(
      id: agent.call_site_digest(caller),
      parent_strand: string.drop_start(
        to,
        string.length(api.parent_reference_prefix),
      ),
      child: Handle(strand: caller.strand, operation: caller.operation),
      text:,
      state: delegate_outbox.Pending,
    )
  use Nil <- result.map(
    delegate_outbox.queue_mail(runtime, row)
    |> result.map_error(agent.PlaneFailed),
  )
  config.upward_queued()
  agent.Queued
}

// A parent's `agent_send` to a child on another orchestrator. The orchestrator
// is asked once, here, on the caller's own process. An answer is the delivery or
// a refusal. No answer leaves a `remote-send/{id}` row for the remote drainer and
// tells the model the message is queued: the orchestrator may have delivered it
// and lost the reply, and the message id is what makes the resend safe.
fn send_remote(
  config: Config,
  runtime: api.Runtime,
  caller: Caller,
  to: String,
  text: String,
  within_ms: Option(Int),
) -> Result(Delivery, Refusal) {
  use Nil <- result.try(case within_ms {
    Some(_) ->
      Error(agent.InvalidArgument(
        "within_ms is not available for a child on another orchestrator; a "
        <> "run it starts is bounded by the deadline the child already has",
      ))
    None -> Ok(Nil)
  })
  use kept <- result.try(
    remote_child.all(runtime) |> result.map_error(agent.PlaneFailed),
  )
  use #(stub, placed) <- result.try(
    list.find_map(kept, fn(entry) {
      case placed_of(entry.stub) {
        Some(placed) if placed.handle.strand == to -> Ok(#(entry.stub, placed))
        Some(_) | None -> Error(Nil)
      }
    })
    |> result.replace_error(still_starting_or_unknown(kept, to)),
  )

  // A message must not revive a child: the remote starts a run only inside the
  // deadline the spawn gave the child, so a send after it is refused here, where
  // the model can be told, and not left to the remote.
  let #(now, _clock) = clock.read(config.clock)
  use Nil <- result.try(case placed.deadline_ms <= now {
    True ->
      Error(agent.InvalidArgument(
        "`"
        <> to
        <> "` is past its deadline on the orchestrator `"
        <> stub.orchestrator
        <> "`, so a message cannot start another run on it",
      ))
    False -> Ok(Nil)
  })
  let id = agent.call_site_digest(caller)
  let parent = remote_reach.parent(config.remote, stub.strand)
  case config.remote.send(stub.orchestrator, parent, placed.handle, id, text) {
    Ok(landing) -> Ok(delivery_of(config, landing))
    Error(peer_mail.Refused(reason)) ->
      Error(agent.RemoteRefused(orchestrator: stub.orchestrator, reason:))
    Error(peer_mail.Unreachable) | Error(peer_mail.NotOpen) -> {
      let row =
        remote_send.Row(
          id:,
          orchestrator: stub.orchestrator,
          parent_strand: stub.strand,
          child: placed.handle,
          text:,
        )
      use Nil <- result.map(
        remote_send.queue(runtime, row) |> result.map_error(agent.PlaneFailed),
      )
      config.remote_queued()
      agent.Queued
    }
  }
}

// Why a send found no child: one whose spawn the orchestrator has not answered
// yet is still starting, and anything else is not the caller's to address.
fn still_starting_or_unknown(
  kept: List(remote_child.Kept),
  to: String,
) -> Refusal {
  case
    list.any(kept, fn(entry) {
      entry.stub.name == to && entry.stub.state == remote_child.Requested
    })
  {
    True ->
      agent.InvalidArgument(
        "`"
        <> to
        <> "` is still starting: its orchestrator has not answered the spawn, "
        <> "so a message cannot reach it yet. Try again after agent_wait",
      )
    False -> agent.NotAddressable(strand: to)
  }
}

// How the orchestrator says a message landed, as the delivery the model reads.
// The deadline of a started run is a duration on the other clock, so it is added
// to this one's now.
fn delivery_of(config: Config, landing: remote_mail.Landing) -> Delivery {
  case landing {
    remote_mail.Steered(entry:) -> agent.Steered(entry:)
    remote_mail.Started(operation:, remaining_ms:) -> {
      let #(now, _clock) = clock.read(config.clock)
      agent.Started(
        operation:,
        deadline_ms: option.map(remaining_ms, fn(ms) { now + ms }),
      )
    }
    remote_mail.Admitted -> agent.Queued
  }
}

/// Wraps one agent-to-agent message in a header the sending model cannot
/// forge, naming the sender and framing the body as data.
///
/// This is the rule §5.5 applies to MCP output — results are data, never
/// instructions — and it matters more here, because the sender's text may
/// be a laundered quotation of hostile repository content the sender just
/// read. Framing does not make that safe; it makes the provenance
/// explicit, so the blast radius is the reader's judgement rather than its
/// authority.
///
/// ## Examples
///
/// ```gleam
/// // agency.frame_message(from: "sub:main/x", body: "done")
/// ```
///
pub fn frame_message(from sender: String, body body: String) -> String {
  strand_framing.message_head(sender)
  <> body
  <> "\n"
  <> strand_framing.message_foot
}

/// Wraps a spawn's task brief the same way, for the same reason: a brief
/// is written by a model, not by the operator, and a child that cannot
/// tell the two apart is one prompt injection from acting on the wrong
/// authority.
///
/// ## Examples
///
/// ```gleam
/// // agency.frame_brief(from: "main", body: "review packages/core")
/// ```
///
pub fn frame_brief(from sender: String, body body: String) -> String {
  strand_framing.brief_head(sender) <> body <> "\n" <> strand_framing.brief_foot
}

// --- the blackboard --------------------------------------------------------

fn note(
  config: Config,
  caller: Caller,
  key: String,
  value: JsonValue,
) -> Result(Nil, Refusal) {
  use runtime <- result.try(borrow(config))
  use key <- result.try(validate_key(key, within: 128))
  use Nil <- result.try(refuse_todo_key(key))
  use Nil <- result.try(check_result_contract(runtime, caller, key, value))

  // The prefix is built here and the key is only ever appended to it, so
  // no argument can escape the namespace. `put_fact` refuses every
  // reserved prefix underneath, so forging a lineage cell or an approval
  // record would take two independent failures rather than one.
  let full = agent.blackboard_prefix <> caller.strand <> "/" <> key
  api.put_fact(runtime, full, value)
  |> result.map_error(fn(error) {
    agent.PlaneFailed(reason: describe_api(error))
  })
}

// The todo cell has one writer, the `todo` tool, so that every stored board
// has passed `todo_list.validate` and the TUI's panel never has to explain
// a board it cannot read. `cap/notes.put` reaches this same closure, so the
// refusal covers code mode as well as `agent_note`.
fn refuse_todo_key(key: String) -> Result(Nil, Refusal) {
  case key == todos.note_key {
    True ->
      Error(agent.InvalidArgument(
        reason: "`"
        <> todos.note_key
        <> "` is kept by the todo tool; call `todo` to change the list",
      ))
    False -> Ok(Nil)
  }
}

// The todo tool's read-modify-write. The step is pure, so running it again
// after a lost compare-and-set costs nothing but the read; a conflict can
// only come from a sibling `todo` call in the same batch, so a handful of
// attempts is far more than a real batch needs.
fn update_todos(
  config: Config,
  caller: Caller,
  step: fn(Option(JsonValue)) -> Result(JsonValue, String),
) -> Result(JsonValue, Refusal) {
  use runtime <- result.try(borrow(config))
  let key = agent.blackboard_prefix <> caller.strand <> "/" <> todos.note_key
  update_todo_cell(runtime, key, step, todo_attempts)
}

const todo_attempts = 4

fn update_todo_cell(
  runtime: api.Runtime,
  key: String,
  step: fn(Option(JsonValue)) -> Result(JsonValue, String),
  attempts: Int,
) -> Result(JsonValue, Refusal) {
  use cell <- result.try(
    api.fact_cell(runtime, key) |> result.map_error(plane_failed),
  )
  let #(stored, expected) = case cell {
    None -> #(None, None)
    Some(api.FactCell(value:, seq:)) -> #(Some(value), Some(seq))
  }
  use next <- result.try(
    step(stored)
    |> result.map_error(fn(reason) { agent.InvalidArgument(reason:) }),
  )

  // An unchanged board is not written, so `view` and a replayed no-op
  // leave the cell's sequence, and the register history, alone. An absent
  // cell means the empty board, so a `view` on a strand that never made a
  // list does not create a cell for the notes digest to carry.
  let before =
    option.lazy_unwrap(stored, fn() { todo_list.encode(todo_list.empty()) })
  use <- bool.guard(when: before == next, return: Ok(next))
  case api.put_fact_expecting(runtime, key, next, expected:) {
    Ok(_) -> Ok(next)
    Error(api.FactConflict(..)) if attempts > 1 ->
      update_todo_cell(runtime, key, step, attempts - 1)
    Error(error) -> Error(plane_failed(error))
  }
}

fn plane_failed(error: api.ApiError) -> Refusal {
  agent.PlaneFailed(reason: describe_api(error))
}

// The enforcement point for a result contract — see the module doc for
// why it is the child's own write and not the parent's read. The schema
// is looked up only for the one key that owes one, so an ordinary note
// pays nothing for the feature.
fn check_result_contract(
  runtime: api.Runtime,
  caller: Caller,
  key: String,
  value: JsonValue,
) -> Result(Nil, Refusal) {
  use <- bool.guard(when: key != agent.result_note_key, return: Ok(Nil))
  case read_result_schema(runtime, caller.strand) {
    None -> Ok(Nil)
    Some(schema) ->
      agent.validate_result(schema, value)
      |> result.map_error(fn(mismatch) {
        agent.ResultSchemaUnmet(schema:, received: value, mismatch:)
      })
  }
}

fn notes(
  config: Config,
  _caller: Caller,
  prefix: Option(String),
) -> Result(List(#(String, JsonValue)), Refusal) {
  use runtime <- result.try(borrow(config))

  // An absent prefix is clamped to the agent namespace rather than passed
  // through as `None`: `api.facts(prefix: None)` lists every
  // non-reserved fact in the session, operator writes included, and the
  // schema promises the blackboard, not the session.
  use prefix <- result.try(case prefix {
    None -> Ok(agent.blackboard_prefix)

    // Reads address namespace-qualified keys, so their bound must include
    // the strand name as well as the 128-character caller-owned suffix.
    // A bounded 4 KiB prefix leaves room for nested child strand names.
    Some(text) ->
      validate_key(text, within: 4096)
      |> result.map(fn(key) { agent.blackboard_prefix <> key })
  })
  notes_under(runtime, prefix)
}

// A failed scan is not evidence that the register is empty. Preserve the
// refusal for direct reads and for child joins that include saved notes.
fn notes_under(
  runtime: api.Runtime,
  prefix: String,
) -> Result(List(#(String, JsonValue)), Refusal) {
  api.facts(runtime, prefix: Some(prefix))
  |> result.map_error(fn(error) {
    agent.PlaneFailed(reason: describe_api(error))
  })
}

// A blackboard key is model text that becomes half of a register key, so
// its shape is checked rather than trusted. The containment does not
// depend on this — the prefix is prepended, and reservation is a prefix
// test that `..` cannot defeat — but a key that renders back to the model
// should be readable, and an unbounded one should not.
fn validate_key(
  key: String,
  within max_length: Int,
) -> Result(String, Refusal) {
  case key == "" || string.length(key) > max_length {
    True ->
      Error(agent.InvalidArgument(
        reason: "a key must be between 1 and "
        <> int.to_string(max_length)
        <> " characters",
      ))
    False ->
      case
        list.all(string.to_graphemes(key), fn(character) {
          string.contains(key_alphabet, character)
        })
      {
        True -> Ok(key)
        False ->
          Error(agent.InvalidArgument(
            reason: "a key may hold only letters, digits, `.`, `-`, `_`, `/` "
            <> "and `:`",
          ))
      }
  }
}

const key_alphabet =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_/:"

// --- roster ----------------------------------------------------------------

fn roster(config: Config, caller: Caller) -> Result(List(Peer), Refusal) {
  use runtime <- result.try(borrow(config))
  use ledger <- result.try(read_ledger(runtime))
  reap_overdue(config, runtime, ledger)
  let parent = case cell_of(ledger, caller.strand) {
    None -> []
    Some(cell) -> [
      agent.Peer(
        strand: cell.parent,
        relation: agent.ParentOf,
        handle: None,
        outcome: None,
        deadline_ms: None,
        tools: [],
        placement: agent.Here,
      ),
    ]
  }
  use children <- result.try(
    ledger
    |> dict.values
    |> list.filter(fn(cell) {
      cell.parent == caller.strand && cell.orchestrator == None
    })
    |> list.sort(fn(a, b) { string.compare(a.strand, b.strand) })
    |> list.try_map(fn(cell) { current_peer(runtime, cell) }),
  )
  let #(now, _clock) = clock.read(config.clock)
  use elsewhere <- result.map(remote_peers(runtime, caller, now))
  list.flatten([parent, children, elsewhere])
}

// The caller's children on other orchestrators, from the stubs it wrote. A
// stub is the whole record of such a child: the lineage cell only records the
// edge, and nothing in this session runs the child, so how it stands is how
// the last answer left the stub, read at `now` so that a child whose deadline
// has passed is not shown as running.
fn remote_peers(
  runtime: api.Runtime,
  caller: Caller,
  now: Int,
) -> Result(List(Peer), Refusal) {
  use kept <- result.map(
    remote_child.all(runtime) |> result.map_error(agent.PlaneFailed),
  )
  kept
  |> list.map(fn(entry) { entry.stub })
  |> list.filter(fn(stub) { stub.strand == caller.strand })
  |> list.map(remote_peer(_, now))
  |> list.sort(fn(a, b) { string.compare(a.strand, b.strand) })
}

fn remote_peer(stub: remote_child.Stub, now: Int) -> Peer {
  let orchestrator = stub.orchestrator
  let elsewhere = fn(standing) { agent.Elsewhere(orchestrator:, standing:) }
  case stub.state {
    remote_child.Requested ->
      agent.Peer(
        strand: stub.name,
        relation: agent.ChildOf,
        handle: None,
        outcome: None,
        deadline_ms: None,
        tools: [],
        placement: elsewhere(agent.AwaitingAnswer),
      )
    remote_child.Spawned(placed:) ->
      case remote_child.is_live(stub, now) {
        True -> placed_peer(placed, None, elsewhere(agent.Running))
        False -> placed_peer(placed, None, elsewhere(agent.PastDeadline))
      }
    remote_child.Settled(placed:, outcome:, ..) ->
      placed_peer(placed, Some(outcome), elsewhere(agent.Finished))
    remote_child.Refused(reason:) ->
      agent.Peer(
        strand: stub.name,
        relation: agent.ChildOf,
        handle: None,
        outcome: None,
        deadline_ms: None,
        tools: [],
        placement: elsewhere(agent.Declined(reason:)),
      )
  }
}

fn placed_peer(
  placed: remote_child.Placed,
  outcome: Option(Outcome),
  placement: agent.Placement,
) -> Peer {
  agent.Peer(
    strand: placed.handle.strand,
    relation: agent.ChildOf,
    handle: Some(placed.handle),
    outcome:,
    deadline_ms: Some(placed.deadline_ms),
    tools: placed.tools,
    placement:,
  )
}

// --- reaping ---------------------------------------------------------------

// Enforcement observes current operations, not the immutable spawn handle.
// Each stop is durable before its exact operation is cancelled; an observation
// that races a continuation can never abort the successor on that strand.
fn reap_overdue(
  config: Config,
  runtime: api.Runtime,
  ledger: Dict(String, Lineage),
) -> Nil {
  let #(now, _clock) = clock.read(config.clock)
  list.each(dict.values(ledger), fn(cell) {
    case current_run(runtime, cell) {
      Ok(Some(run)) ->
        case run.record.stop, run.record.deadline {
          child_run.Unstopped, Some(at) if at <= now ->
            reap(config.abort_effects, runtime, run, child_run.BudgetExpired)
          child_run.Unstopped, _ -> Nil
          _, _ -> reap(config.abort_effects, runtime, run, run.record.stop)
        }
      Ok(None) | Error(_) -> Nil
    }
  })
}

fn reap_run(config: Config, operation: OpId) -> Nil {
  case borrow(config) {
    Error(_refusal) -> Nil
    Ok(runtime) -> reap_run_in(config, runtime, operation)
  }
}

// `reap_run` on a runtime already in hand. The holder calls it with its own
// state, since borrowing from inside the holder would wait on itself.
fn reap_run_in(config: Config, runtime: api.Runtime, operation: OpId) -> Nil {
  let _owned =
    drain_owned(config.abort_effects, runtime, child_run.ParentRun(operation))
  case read_ledger(runtime) {
    Error(_refusal) -> Nil
    Ok(ledger) ->
      list.each(dict.values(ledger), fn(cell) {
        case current_run(runtime, cell) {
          Ok(Some(run))
            if run.record.owner == Some(child_run.ParentRun(operation))
          -> reap(config.abort_effects, runtime, run, child_run.ParentFinished)
          Ok(_) | Error(_) -> Nil
        }
      })
  }
}

// A run of a remote parent ended. The fence is written first, and the children
// are stopped second, so a spawn that reaches the holder next finds the fence
// and one that reached it before is a child this reap stops. The count is taken
// before the reap, of the runs this operation owns that nobody had stopped yet,
// so a repeated message counts nothing.
fn run_ended_in(
  config: Config,
  runtime: api.Runtime,
  operation: OpId,
) -> Result(Int, Refusal) {
  use Nil <- result.try(
    api.put_reserved_fact(runtime, ended_key(operation), json.Null)
    |> result.map_error(plane_failed),
  )
  use ledger <- result.map(read_ledger(runtime))
  let stopping =
    list.count(dict.values(ledger), fn(cell) {
      case current_run(runtime, cell) {
        Ok(Some(run)) ->
          run.record.owner == Some(child_run.ParentRun(operation))
          && run.record.stop == child_run.Unstopped
        Ok(None) | Error(_) -> False
      }
    })
  reap_run_in(config, runtime, operation)
  stopping
}

// The parent session of a remote parent was deleted. The fence is written
// first, and every child is stopped second, for the reason `run_ended_in`
// gives: a spawn that reaches the holder next finds the fence, and one that
// reached it before is a child this stop reaches. A child that is running owns
// no lifetime but its own deadline, so every one is stopped whatever started
// it. The count is of runs nobody had stopped yet, so a repeat counts nothing.
fn released_in(config: Config, runtime: api.Runtime) -> Result(Int, Refusal) {
  use Nil <- result.try(
    api.put_reserved_fact(runtime, released_key(), json.Null)
    |> result.map_error(plane_failed),
  )
  use ledger <- result.map(read_ledger(runtime))
  list.fold(dict.values(ledger), 0, fn(stopped, cell) {
    case current_run(runtime, cell) {
      Ok(Some(run)) ->
        case run.record.stop {
          child_run.Unstopped -> {
            reap(config.abort_effects, runtime, run, child_run.Released)
            stopped + 1
          }

          // Stopped already, possibly before its abort was sent: the stop is
          // durable, so sending the abort again is the whole repair.
          _ -> {
            reap(config.abort_effects, runtime, run, run.record.stop)
            stopped
          }
        }
      Ok(None) | Error(_) -> stopped
    }
  })
}

// One child's current run is stopped for `stop`, if nobody has stopped it. A run
// that already holds a stop is left alone, whatever its reason: the first cause
// recorded is the cause, and `reap` would not overwrite it anyway. A strand with
// no cell, or none running, is nothing to stop.
fn stop_child_in(
  config: Config,
  runtime: api.Runtime,
  ledger: Dict(String, Lineage),
  strand: String,
  stop: child_run.Stop,
) -> Nil {
  case dict.get(ledger, strand) {
    Error(Nil) -> Nil
    Ok(cell) ->
      case current_run(runtime, cell) {
        Ok(Some(run)) ->
          case run.record.stop {
            child_run.Unstopped ->
              reap(config.abort_effects, runtime, run, stop)
            _ -> Nil
          }
        Ok(None) | Error(_) -> Nil
      }
  }
}

// A cause is written once for this operation. Losing its CAS leaves the next
// observation to read the winner; it never sends an unrecorded cancellation.
fn reap(
  abort_effects: fn(OpId) -> Nil,
  runtime: api.Runtime,
  run: ObservedRun,
  stop: child_run.Stop,
) -> Nil {
  let recorded = case run.record.stop {
    child_run.Unstopped ->
      api.put_reserved_fact_expecting(
        runtime,
        child_run.key(run.operation),
        child_run.encode(child_run.Run(..run.record, stop:)),
        expected: run.seq,
      )
      |> result.replace(Nil)
    _ -> Ok(Nil)
  }
  case recorded {
    Error(_) -> Nil
    Ok(Nil) -> {
      // Child-owned background work must lose admission before the child's
      // own terminal can satisfy its parent's drain. The async service polls
      // this durable fence, so a lost notification cannot orphan that work.
      case
        api.put_reserved_fact(
          runtime,
          async_execution.abort_key(run.operation),
          json.Null,
        )
      {
        Error(_) -> Nil
        Ok(_) -> {
          api.abort_operation(
            api.on_strand(runtime, run.record.strand),
            run.operation,
          )

          // The runtime's abort stopped only the strand's live effect
          // processes. A default-mode `bash` runs as a job under the jobs
          // actor, so its broker execution and jailed process survive that
          // and keep running until the job's wall deadline unless the
          // broker is told. Sent after the marker is durable and the
          // effects are interrupted, in the order the operator's abort uses.
          abort_effects(run.operation)
        }
      }
    }
  }
}

fn is_live(runtime: api.Runtime, cell: Lineage) -> Bool {
  case cell.orchestrator {
    // The child has no strand here, so its strand state says nothing. It is
    // counted from its stub (`live_stubs`), which is where it is recorded as
    // running.
    Some(_) -> False
    None ->
      case read_strand_state(runtime, cell.strand) {
        Ok(Some(state)) -> state.current_operation != None
        Ok(None) -> False
        Error(_) -> True
      }
  }
}

// The stubs whose child is, or may be, running at `now`. A child whose deadline
// has passed is not counted, whether or not anything has settled its stub.
// Unreadable stubs refuse the spawn: the count is a cap, and a cap that reads
// nothing as zero is no cap.
fn live_stubs(
  runtime: api.Runtime,
  now: Int,
) -> Result(List(remote_child.Stub), Refusal) {
  use kept <- result.map(
    remote_child.all(runtime) |> result.map_error(agent.PlaneFailed),
  )
  kept
  |> list.map(fn(entry) { entry.stub })
  |> list.filter(remote_child.is_live(_, now))
}

// A record and its CAS position travel together. Legacy brief runs have no
// separate record until their first stop, but retain their recorded deadline.
type ObservedRun {
  ObservedRun(operation: OpId, record: child_run.Run, seq: Option(Int))
}

fn original_run(cell: Lineage) -> child_run.Run {
  child_run.Run(
    strand: cell.strand,
    owner: case cell.detached {
      True -> None
      False -> Some(child_run.ParentRun(cell.minted_by.operation))
    },
    deadline: cell.deadline,
    stop: case cell.reaped {
      True -> child_run.LegacyReaped
      False -> child_run.Unstopped
    },
  )
}

fn run_record(
  runtime: api.Runtime,
  handle: Handle,
) -> Result(Option(ObservedRun), Refusal) {
  use cell <- result.try(
    api.fact_cell(runtime, child_run.key(handle.operation))
    |> result.map_error(fn(error) { agent.PlaneFailed(describe_api(error)) }),
  )
  case cell {
    None -> Ok(None)
    Some(api.FactCell(value:, seq:)) -> {
      use record <- result.try(
        child_run.decode(value)
        |> result.map_error(fn(_) {
          agent.PlaneFailed("the child run record is corrupt")
        }),
      )
      case record.strand == handle.strand {
        True ->
          Ok(
            Some(ObservedRun(
              operation: handle.operation,
              record:,
              seq: Some(seq),
            )),
          )
        False ->
          Error(agent.PlaneFailed("the child run belongs to another strand"))
      }
    }
  }
}

fn current_run(
  runtime: api.Runtime,
  cell: Lineage,
) -> Result(Option(ObservedRun), Refusal) {
  use state <- result.try(read_strand_state(runtime, cell.strand))
  case state {
    Some(machine_strand.StrandState(current_operation: Some(operation), ..)) -> {
      use record <- result.try(run_record(
        runtime,
        Handle(strand: cell.strand, operation:),
      ))
      case record {
        Some(_) -> Ok(record)
        None if operation == cell.brief ->
          Ok(
            Some(ObservedRun(operation:, record: original_run(cell), seq: None)),
          )
        None -> Ok(None)
      }
    }
    _ -> Ok(None)
  }
}

fn current_peer(
  runtime: api.Runtime,
  cell: Lineage,
) -> Result(agent.Peer, Refusal) {
  use state <- result.try(read_strand_state(runtime, cell.strand))
  let operation = case state {
    Some(machine_strand.StrandState(current_operation: Some(operation), ..)) ->
      operation
    _ ->
      case read_last_result(runtime, cell.strand) {
        Some(last) -> last.operation
        None -> cell.brief
      }
  }
  let handle = Handle(strand: cell.strand, operation:)
  use deadline_ms <- result.try(run_deadline(runtime, handle))
  let outcome = case
    api.await_strand_result(runtime, cell.strand, operation, 0)
  {
    Ok(last) -> Some(run_outcome(runtime, handle, last))
    Error(Nil) -> None
  }
  Ok(agent.Peer(
    strand: cell.strand,
    relation: agent.ChildOf,
    handle: Some(handle),
    outcome:,
    deadline_ms: case deadline_ms {
      None if operation == cell.brief -> cell.deadline
      _ -> deadline_ms
    },
    tools: cell.tools,
    placement: agent.Here,
  ))
}

fn run_deadline(
  runtime: api.Runtime,
  handle: Handle,
) -> Result(Option(Int), Refusal) {
  use run <- result.map(run_record(runtime, handle))
  option.then(run, fn(run) { run.record.deadline })
}

fn run_outcome(
  runtime: api.Runtime,
  handle: Handle,
  last: LastResult,
) -> Outcome {
  let outcome = outcome_of(last)
  case outcome, run_record(runtime, handle) {
    Aborted,
      Ok(Some(ObservedRun(
        record: child_run.Run(stop: child_run.BudgetExpired, ..),
        ..,
      )))
    -> agent.BudgetExpired
    Aborted,
      Ok(Some(ObservedRun(
        record: child_run.Run(stop: child_run.ParentFinished, ..),
        ..,
      )))
    -> agent.ParentFinished
    Aborted,
      Ok(Some(ObservedRun(
        record: child_run.Run(stop: child_run.Released, ..),
        ..,
      )))
    -> agent.Released
    Aborted,
      Ok(Some(ObservedRun(
        record: child_run.Run(stop: child_run.TokenBudgetSpent, ..),
        ..,
      )))
    -> agent.TokenBudgetSpent
    _, _ -> outcome
  }
}

// --- durable reads and writes ----------------------------------------------

fn write_cell(runtime: api.Runtime, cell: Lineage) -> Result(Nil, Refusal) {
  api.put_reserved_fact(
    runtime,
    lineage.register_key(cell.strand),
    lineage.encode(cell),
  )
  |> result.map_error(fn(error) {
    agent.PlaneFailed(reason: describe_api(error))
  })
}

fn read_configuration(
  runtime: api.Runtime,
  strand: String,
) -> Result(machine_strand.StrandConfiguration, Refusal) {
  case session.strand_configuration(runtime.session, strand) {
    Ok(Some(session.Cell(value:, ..))) -> Ok(value)
    Ok(None) -> Error(agent.NotAddressable(strand:))
    Error(_error) ->
      Error(agent.PlaneFailed(
        reason: "strand.config is unreadable for " <> strand,
      ))
  }
}

fn read_strand_state(
  runtime: api.Runtime,
  strand: String,
) -> Result(Option(machine_strand.StrandState), Refusal) {
  case session.strand_state(runtime.session, strand) {
    Ok(Some(session.Cell(value:, ..))) -> Ok(Some(value))
    Ok(None) -> Ok(None)
    Error(_error) ->
      Error(agent.PlaneFailed(
        reason: "strand.state is unreadable for " <> strand,
      ))
  }
}

fn read_last_result(
  runtime: api.Runtime,
  strand: String,
) -> Option(LastResult) {
  case session.last_result(runtime.session, strand) {
    Ok(Some(session.Cell(value:, ..))) -> Some(value)
    _ -> None
  }
}

fn clamp(value: Int, low: Int, high: Int) -> Int {
  int.min(int.max(value, low), high)
}

fn describe_api(error: api.ApiError) -> String {
  case error {
    api.RuntimeUnavailable -> "the target writer is restarting; try again"
    api.AcceptRejected(reason: _) -> "the target refused the admission"
    api.QueueRejected(reason: _) -> "the target's queue refused the admission"
    api.ReadFailed(reason:) -> reason
    api.CommitFailed(error: _) -> "the commit failed"
    api.SessionStolen(held_by: _) ->
      "another writer holds this session; reopen it"
    api.RaceLost -> "the admission kept losing its race; try again"
    api.ReservedFactKey(key:) -> "the key `" <> key <> "` is reserved"
    api.UnreservedFactKey(key:) ->
      "the key `" <> key <> "` is not a reserved key"
    api.EscalationExists(id:) -> "escalation " <> id <> " already exists"
    api.EscalationNotFound(id:) -> "no escalation " <> id
    api.EscalationWrongStatus(id:, status: _) ->
      "escalation " <> id <> " is in the wrong state"
    api.FactConflict(key:) ->
      "the fact `" <> key <> "` moved under the write; read it again"
  }
}

fn describe_create(error: api.CreateStrandError) -> String {
  case error {
    api.StrandExists(name:) -> "the strand " <> name <> " already exists"
    api.UnknownForkPoint(entry: _) -> "the fork point does not exist"
    api.SeedFailed(reason:) -> reason
    api.StartFailed(reason:) -> reason
    api.BriefRejected(error:) -> describe_api(error)
    api.InvalidStrandName(name:) ->
      "the strand name " <> name <> " is reserved for a parent reference"
  }
}

/// Stops every run owned by a fenced asynchronous execution, including a
/// first admission whose lineage has not yet been published. Returns true
/// only when each exact operation has a durable terminal result.
///
/// ## Examples
///
/// ```gleam
/// // agency.drain_execution(abort_effects, runtime, operation, execution)
/// ```
pub fn drain_execution(
  abort_effects: fn(OpId) -> Nil,
  runtime: api.Runtime,
  operation: OpId,
  execution: String,
) -> Result(Bool, String) {
  drain_owned(
    abort_effects,
    runtime,
    child_run.AsyncExecution(operation, execution),
  )
}

fn drain_owned(
  abort_effects: fn(OpId) -> Nil,
  runtime: api.Runtime,
  owner: child_run.Owner,
) -> Result(Bool, String) {
  use cells <- result.try(
    api.reserved_facts(runtime, child_run.key_prefix)
    |> result.map_error(describe_api),
  )
  use drained <- result.try(
    list.try_map(cells, fn(pair) {
      use record <- result.try(
        child_run.decode(pair.1)
        |> result.replace_error("invalid child custody during execution drain"),
      )
      case record.owner == Some(owner) {
        False -> Ok(True)
        True -> {
          use child <- result.try(
            ids.parse_op_id(string.drop_start(
              pair.0,
              string.length(child_run.key_prefix),
            ))
            |> result.replace_error("invalid child operation key"),
          )
          use observed <- result.try(
            run_record(runtime, Handle(record.strand, child))
            |> result.map_error(string.inspect),
          )
          case observed {
            None -> Error("child custody disappeared during drain")
            Some(run) -> {
              reap(abort_effects, runtime, run, child_run.ParentFinished)
              let child_settled =
                api.await_result(
                  api.on_strand(runtime, record.strand),
                  child,
                  0,
                )
                |> result.is_ok
              use backgrounds_settled <- result.try(backgrounds_settled(
                runtime,
                child,
              ))
              Ok(child_settled && backgrounds_settled)
            }
          }
        }
      }
    }),
  )
  Ok(list.all(drained, fn(value) { value }))
}

/// Projects a small peer endpoint that closes over the registered address.
///
/// ## Examples
///
/// ```gleam
/// // agency.peer_endpoint(config, session_id)
/// ```
pub fn peer_endpoint(config: Config, session_id: String) -> peer_mail.Endpoint {
  let name = config.name
  let timeout = config.holder_timeout_ms
  peer_mail.Endpoint(session_id, fn(command) {
    use subject <- result.try(
      address.lookup(name)
      |> result.replace_error(peer_mail.Refused("peer session unavailable")),
    )
    let reply = process.new_subject()
    process.send(subject, PeerRequest(command:, reply:))
    process.receive(reply, timeout)
    |> result.unwrap(Error("peer session did not answer"))
    |> peer_mail.refused
  })
}

/// Admits one named child using the current execution's custody and the
/// durable step's original identity. Resumption cannot duplicate the child.
///
/// ## Examples
///
/// ```gleam
/// // agency.workflow_child(config, caller, step, assignment, custody)
/// ```
pub fn workflow_child(
  config: Config,
  caller: Caller,
  step: workflow_ledger.Step,
  request: agent.SpawnRequest,
  custody: api.AsyncCustody,
) -> Result(Spawned, Refusal) {
  use subject <- result.try(
    address.lookup(config.name) |> result.replace_error(agent.AgencyUnavailable),
  )

  // A workflow step runs in the background, and `spawn_elsewhere` refuses
  // placement from there. Admitting the step as a local child would answer a
  // request for another machine with a child on this one, so it is refused.
  use <- bool.guard(
    when: option.is_some(request.on),
    return: Error(agent.InvalidArgument(reason: background_refusal)),
  )
  process.call(subject, config.holder_timeout_ms, fn(reply) {
    WorkflowChild(caller, step, request, custody, reply)
  })
}

// Parent settlement includes background executions launched by every owned
// child. Those executions apply the same rule recursively to their children.
fn backgrounds_settled(
  runtime: api.Runtime,
  operation: OpId,
) -> Result(Bool, String) {
  use cells <- result.try(
    api.reserved_facts(runtime, async_execution.prefix <> "record/")
    |> result.map_error(string.inspect),
  )
  use records <- result.try(
    list.try_map(cells, fn(pair) {
      async_execution.decode(pair.1)
      |> result.replace_error("invalid nested execution record")
    }),
  )
  Ok(
    list.all(records, fn(record) {
      record.operation != operation || async_execution.terminal(record.phase)
    }),
  )
}

// --- a child on another orchestrator ----------------------------------------

/// How long one `agent_spawn` keeps resending to an orchestrator that does not
/// answer, in milliseconds. When it runs out the model is told the child may
/// exist, and the stub stays `Requested` for the drainer to resend from.
pub const remote_window_ms = 30_000

// The pause between resends starts short, because a refused connection or a
// dropped link answers at once and the next attempt will probably succeed, and
// doubles to a cap, because an orchestrator that is down should not be asked a
// hundred times in the window.
const remote_first_pause_ms = 50

const remote_last_pause_ms = 2000

// How much longer than its own budget a mixed wait lets its tasks run, in
// milliseconds. Each task bounds itself; this only stops a task that does not.
const remote_join_slack_ms = 10_000

// Starts a child on another orchestrator, or finishes the spawn an earlier
// attempt began. The holder admits the spawn and writes the stub, so the check
// of the caps and the write cannot interleave with another admission, and the
// long part, the network, runs here on the caller's own process, never in the
// holder. Replaying the same call site finds its stub: one still `Requested`
// resumes asking, one already answered returns what it recorded.
fn spawn_elsewhere(
  config: Config,
  subject: Subject(Message),
  caller: Caller,
  request: agent.SpawnRequest,
  orchestrator: String,
  custody: Option(api.AsyncCustody),
) -> Result(Spawned, Refusal) {
  use Nil <- result.try(refuse_unusable_placement(
    config,
    request,
    orchestrator,
    custody,
  ))
  use #(key, stub) <- result.try(
    process.call(subject, config.holder_timeout_ms, fn(reply) {
      AdmitRemote(caller:, request:, orchestrator:, reply:)
    }),
  )
  case stub.state {
    remote_child.Requested -> ask_until_answered(config, key, stub)
    remote_child.Spawned(placed:) | remote_child.Settled(placed:, ..) ->
      Ok(placed_spawn(placed))
    remote_child.Refused(reason:) ->
      Error(agent.RemoteRefused(orchestrator:, reason:))
  }
}

// The reasons a spawn on another orchestrator is refused before anything is
// written, said in words for the model.
const background_refusal =
  "a program that runs in the background cannot start a child on another orchestrator yet"

const forking_refusal =
  "`context: my_conversation` is not available with `on`: it would copy this conversation to another machine"

const shared_refusal =
  "a child can be started on another orchestrator only in a session that you hold alone"

// What cannot be asked of another orchestrator, each said in words for the
// model. A conversation is not copied to another machine, a program that runs in
// the background has no turn to be told in, a name that is not configured has no
// one to ask, and a session with other members may not send its work elsewhere.
fn refuse_unusable_placement(
  config: Config,
  request: agent.SpawnRequest,
  orchestrator: String,
  custody: Option(api.AsyncCustody),
) -> Result(Nil, Refusal) {
  use <- bool.guard(
    when: option.is_some(custody),
    return: Error(agent.InvalidArgument(reason: background_refusal)),
  )
  use <- bool.guard(
    when: request.context == agent.MyConversation,
    return: Error(agent.InvalidArgument(reason: forking_refusal)),
  )
  use <- bool.lazy_guard(
    when: !list.contains(config.remote.orchestrators, orchestrator),
    return: fn() {
      Error(agent.InvalidArgument(
        reason: "`"
        <> orchestrator
        <> "` is not a configured orchestrator"
        <> {
          case config.remote.orchestrators {
            [] -> "; none is configured"
            names -> "; the configured ones are " <> string.join(names, ", ")
          }
        },
      ))
    },
  )
  use <- bool.guard(
    when: !config.remote.offered(),
    return: Error(agent.InvalidArgument(reason: shared_refusal)),
  )
  Ok(Nil)
}

// The holder's half: judge the spawn against the caps and write its stub. A
// call site that already has a stub is returned that stub, after checking it is
// this caller's own, because the stub is keyed by a digest and the digest is not
// an ownership proof any more than a child's name is (`adopt`).
fn admit_remote(
  config: Config,
  runtime: api.Runtime,
  caller: Caller,
  request: agent.SpawnRequest,
  orchestrator: String,
) -> Result(#(String, remote_child.Stub), Refusal) {
  use ledger <- result.try(read_ledger(runtime))
  use <- bool.guard(
    when: parent_depth(ledger, caller) + 1 > config.depth_cap,
    return: Error(agent.DepthCapReached(depth: config.depth_cap)),
  )
  let key = remote_child.stub_key(agent.call_site_digest(caller))
  use found <- result.try(
    remote_child.find(runtime, key) |> result.map_error(agent.PlaneFailed),
  )
  case found {
    Some(stub) ->
      case is_same_call(stub, caller, orchestrator) {
        True -> Ok(#(key, stub))
        False -> Error(agent.NameAlreadyMinted(strand: stub.name))
      }
    None -> write_stub(config, runtime, ledger, caller, request, orchestrator)
  }
}

// How deep the strand that asks stands: zero for a strand no one spawned.
fn parent_depth(ledger: Dict(String, Lineage), caller: Caller) -> Int {
  case cell_of(ledger, caller.strand) {
    None -> 0
    Some(parent) -> parent.depth
  }
}

fn write_stub(
  config: Config,
  runtime: api.Runtime,
  ledger: Dict(String, Lineage),
  caller: Caller,
  request: agent.SpawnRequest,
  orchestrator: String,
) -> Result(#(String, remote_child.Stub), Refusal) {
  let key = remote_child.stub_key(agent.call_site_digest(caller))
  use Nil <- result.try(check_capacity(config, runtime, ledger, caller))
  use configuration <- result.try(read_configuration(runtime, caller.strand))

  // The child's name on the other orchestrator is derived there from its own
  // parent reference, `^main`. The stub records it too, so the roster can name a
  // child that has no handle yet.
  use name <- result.try(child_name(
    agent.Caller(..caller, strand: api.parent_reference_prefix <> caller.strand),
    request.purpose,
  ))
  let stub =
    remote_child.Stub(
      orchestrator:,
      strand: caller.strand,
      site: remote_spawn.CallSite(
        operation: caller.operation,
        step_id: caller.step_id,
        source_index: caller.source_index,
        minter: caller.minter,
      ),
      depth: parent_depth(ledger, caller),
      parent_tools: configuration.active_tool_names,
      request: remote_request(request),
      name:,
      glance: None,
      glance_seen_ms: 0,
      owed: 0,
      state: remote_child.Requested,
    )
  use admission <- result.map(
    remote_child.admit(runtime, key, stub)
    |> result.map_error(agent.PlaneFailed),
  )
  case admission {
    remote_child.Fresh -> #(key, stub)
    remote_child.Existing(found) -> #(key, found)
  }
}

fn is_same_call(
  stub: remote_child.Stub,
  caller: Caller,
  orchestrator: String,
) -> Bool {
  stub.orchestrator == orchestrator
  && stub.strand == caller.strand
  && stub.site
  == remote_spawn.CallSite(
    operation: caller.operation,
    step_id: caller.step_id,
    source_index: caller.source_index,
    minter: caller.minter,
  )
}

// The request as the other orchestrator is sent it. The context is dropped,
// because a remote child's is always fresh, and the placement is the stub's own
// orchestrator.
//
// A remote child is always detached, whatever `detach` the model gave. The
// parent's run end is not sent across, so nothing could stop an attached child
// when the run that asked for it ends, and a child that the other orchestrator
// holds as attached would be reaped by a message that never comes. Sending it
// detached says what will happen: it runs until it finishes or its deadline
// passes, and the other orchestrator's retention sweep removes it after that.
fn remote_request(request: agent.SpawnRequest) -> remote_spawn.Request {
  remote_spawn.Request(
    purpose: request.purpose,
    brief: request.brief,
    model: request.model,
    tools: request.tools,
    within_ms: request.within_ms,
    result_schema: request.result_schema,
    detach: remote_spawn.Detached,
  )
}

// Asks until the orchestrator answers or the window runs out, resending with a
// doubling pause. A resend is safe because the receiver adopts the child the
// call site already made, so an answer lost on the way back is returned again.
// A refusal is recorded on the stub as `Refused` and the stub stays, exactly as
// it does when the drainer hears one. The window running out leaves the stub
// `Requested`, and so does an answer or a refusal that could not be recorded; in
// each of those cases the drainer is rung, and it keeps asking after the model
// has moved on.
fn ask_until_answered(
  config: Config,
  key: String,
  stub: remote_child.Stub,
) -> Result(Spawned, Refusal) {
  let reach = config.remote
  let parent = remote_reach.parent(reach, stub.strand)
  let #(started, _clock) = clock.read(config.clock)
  let asked =
    poll.until_on(
      clock: timebase.on(config.clock, config.rest),
      within: remote_window_ms,
      every: poll.Doubling(
        from: remote_first_pause_ms,
        to: remote_last_pause_ms,
      ),
      attempt: fn() {
        case
          reach.spawn(
            stub.orchestrator,
            parent,
            stub.site,
            stub.depth,
            stub.parent_tools,
            stub.request,
            window_left(config, started),
          )
        {
          Ok(answer) -> poll.Done(answer)
          Error(peer_mail.Refused(reason)) -> poll.Fail(reason)
          Error(peer_mail.Unreachable) | Error(peer_mail.NotOpen) -> poll.Retry
        }
      },
    )
  case asked {
    poll.Answered(answer) -> record_answer(config, key, stub, answer)
    poll.Failed(reason) -> record_refusal(config, key, stub, reason)
    poll.Expired -> {
      config.remote_queued()
      Error(agent.RemoteSilent(orchestrator: stub.orchestrator))
    }
  }
}

// How long one attempt may wait for its answer: what is left of the window the
// spawn started, and never more than a single call is worth. Without the clip
// an attempt begun just before the window closes would wait out its own full
// bound, and the model would be kept for nearly twice the window. The floor of
// one millisecond is the last attempt `poll` still makes at the deadline.
fn window_left(config: Config, started: Int) -> Int {
  let #(now, _clock) = clock.read(config.clock)
  int.max(
    1,
    int.min(remote_reach.spawn_ms, remote_window_ms - { now - started }),
  )
}

// A refusal heard where the model asked. The stub is kept as `Refused`, never
// removed: a refusal can be transient (a cap that clears, a store that
// recovers), and the drainer or a replay of the same call site may still be
// answered with a child. A stub that was deleted here would leave that child
// with a lineage cell and no stub to count it, list it or wait on it. If the
// refusal cannot be recorded the stub stays `Requested` and the drainer is
// rung, which asks again and hears the same refusal. The drainer may have been
// answered with a child first, and then the stub already says `Spawned` or
// `Settled`: the child exists, so the model is given it as `record_answer`
// would, and told no refusal.
fn record_refusal(
  config: Config,
  key: String,
  stub: remote_child.Stub,
  reason: String,
) -> Result(Spawned, Refusal) {
  let recorded = {
    use runtime <- result.try(borrow(config) |> result.replace_error(Nil))
    remote_child.refused(runtime, key, reason) |> result.replace_error(Nil)
  }
  let refusal = agent.RemoteRefused(orchestrator: stub.orchestrator, reason:)
  case recorded {
    Ok(stored) ->
      case stored.state {
        remote_child.Spawned(placed:) | remote_child.Settled(placed:, ..) -> {
          config.remote_queued()
          Ok(placed_spawn(placed))
        }
        remote_child.Requested | remote_child.Refused(..) -> Error(refusal)
      }
    Error(Nil) -> {
      config.remote_queued()
      Error(refusal)
    }
  }
}

// The answer to a spawn is written down before the model sees it. If it cannot
// be written the stub stays `Requested` and the drainer asks again, which
// returns the same answer, so the model is told the spawn failed and the child
// is not lost. The drainer is rung either way: after a `Spawned` write it has a
// running child to ask about, and after a failed one it has the spawn to resend.
fn record_answer(
  config: Config,
  key: String,
  stub: remote_child.Stub,
  answer: remote_spawn.Spawned,
) -> Result(Spawned, Refusal) {
  let recorded = {
    use runtime <- result.try(borrow(config))
    let #(now, _clock) = clock.read(config.clock)
    remote_child.spawned(runtime, key, stub, answer, now)
    |> result.map_error(agent.PlaneFailed)
  }
  config.remote_queued()
  use stored <- result.try(recorded)
  case stored.state {
    remote_child.Spawned(placed:) | remote_child.Settled(placed:, ..) ->
      Ok(placed_spawn(placed))
    remote_child.Requested | remote_child.Refused(..) ->
      Error(agent.PlaneFailed(
        reason: "the answer to the spawn was not recorded; it will be asked "
        <> "again",
      ))
  }
}

fn placed_spawn(placed: remote_child.Placed) -> Spawned {
  Spawned(
    handle: placed.handle,
    strand: placed.handle.strand,
    tools: placed.tools,
    model: placed.model,
    model_id: placed.model_id,
    deadline_ms: Some(placed.deadline_ms),
  )
}

// --- waiting on children across orchestrators -------------------------------

// A handle that names a child on another orchestrator, and where its stub is.
// The stub knows the child's strand and the operation of its first run, and a
// message that started a later run gave the model a handle with the same strand
// and another operation, so a handle belongs to a stub by its strand. The
// receiver judges the operation.
type Target {
  Target(handle: Handle, orchestrator: String, key: String)
}

// What one task of a mixed wait brought back: the local handles' answer, or one
// orchestrator's answer for its handles.
type Part {
  LocalPart(waited: List(Waited))
  RemotePart(
    orchestrator: String,
    handles: List(Handle),
    answer: Result(List(remote_spawn.Joined), peer_mail.Failure),
  )
}

// The handles that name a child on another orchestrator, found by the parent's
// own record of it and not by anything in the handle's text. A handle the stubs
// do not hold is a local one, and the local wait judges it. The match is by
// strand, for the reason `Target` gives.
fn remote_targets(
  kept: List(remote_child.Kept),
  handles: List(Handle),
) -> List(Target) {
  list.filter_map(handles, fn(handle) {
    list.find_map(kept, fn(entry) {
      case placed_of(entry.stub) {
        Some(placed) if placed.handle.strand == handle.strand ->
          Ok(Target(
            handle:,
            orchestrator: entry.stub.orchestrator,
            key: entry.key,
          ))
        Some(_) | None -> Error(Nil)
      }
    })
  })
}

fn placed_of(stub: remote_child.Stub) -> Option(remote_child.Placed) {
  case stub.state {
    remote_child.Spawned(placed:) | remote_child.Settled(placed:, ..) ->
      Some(placed)
    remote_child.Requested | remote_child.Refused(..) -> None
  }
}

// One wait over local and remote handles together, against one budget. The local
// handles are waited on as ever, in one task, and each orchestrator that holds
// some of the handles is sent one `Join`, in a task of its own, so the waits
// overlap and the whole is as long as the longest of them and not their sum. The
// window an orchestrator is asked to wait is the budget cut to what one join may
// ask. An orchestrator that does not answer leaves its handles pending, with its
// name, and a wait is a read, so asking again is always safe.
fn wait_across(
  config: Config,
  runtime: api.Runtime,
  caller: Caller,
  handles: List(Handle),
  targets: List(Target),
  within_ms: Int,
) -> Result(List(Waited), Refusal) {
  use ledger <- result.try(read_ledger(runtime))
  use Nil <- result.try(
    list.try_each(handles, fn(handle) {
      case is_descendant(ledger, caller.strand, handle.strand) {
        True -> Ok(Nil)
        False -> Error(agent.NotADescendant(strand: handle.strand))
      }
    }),
  )
  let budget = clamp(within_ms, 0, config.max_wait_ms)
  let local =
    list.filter(handles, fn(handle) {
      !list.any(targets, fn(target) { target.handle == handle })
    })
  let #(started, _clock) = clock.read(config.clock)
  let outcomes =
    list.append(
      local_task(config, caller, local, within_ms),
      list.map(by_orchestrator(targets), fn(group) {
        remote_task(
          config,
          caller,
          group.0,
          group.1,
          int.min(budget, remote_spawn.join_cap_ms),
        )
      }),
    )
    |> weft.new
    |> weft.deadline(budget + remote_join_slack_ms)
    |> weft.start
  use parts <- result.map(
    list.try_map(outcomes, fn(outcome) {
      part_of(config, runtime, targets, started, outcome)
    }),
  )
  in_order(handles, list.flatten(parts))
}

// The local handles' wait as a task, or none when every handle is remote.
fn local_task(
  config: Config,
  caller: Caller,
  local: List(Handle),
  within_ms: Int,
) -> List(fn() -> Result(Part, Refusal)) {
  let strand = caller.strand
  case local {
    [] -> []
    [_, ..] -> [
      fn() {
        wait_for(config, strand, local, within_ms) |> result.map(LocalPart)
      },
    ]
  }
}

// One `Join` as a task. Its answer, or its silence, is data for `joined_waits`,
// so the task itself cannot fail.
fn remote_task(
  config: Config,
  caller: Caller,
  orchestrator: String,
  handles: List(Handle),
  window_ms: Int,
) -> fn() -> Result(Part, Refusal) {
  let parent = remote_reach.parent(config.remote, caller.strand)
  let join = config.remote.join
  fn() {
    Ok(RemotePart(
      orchestrator:,
      handles:,
      answer: join(orchestrator, parent, handles, window_ms),
    ))
  }
}

// The targets grouped by orchestrator, in the order the orchestrators first
// appear, each group keeping its handles in the order they were given.
fn by_orchestrator(targets: List(Target)) -> List(#(String, List(Handle))) {
  let names =
    targets |> list.map(fn(target) { target.orchestrator }) |> list.unique
  list.map(names, fn(name) {
    #(
      name,
      list.filter_map(targets, fn(target) {
        case target.orchestrator == name {
          True -> Ok(target.handle)
          False -> Error(Nil)
        }
      }),
    )
  })
}

// One task's outcome as the waits it contributes. A local wait that was refused
// refuses the whole call, as it would alone. A task that did not finish at all
// is the plane failing, since the remote tasks cannot fail and the local one
// returns its refusals.
fn part_of(
  config: Config,
  runtime: api.Runtime,
  targets: List(Target),
  started: Int,
  outcome: weft.Outcome(Part, Refusal),
) -> Result(List(Waited), Refusal) {
  case outcome {
    weft.Completed(value: LocalPart(waited:), ..) -> Ok(waited)
    weft.Completed(value: RemotePart(orchestrator:, handles:, answer:), ..) ->
      joined_waits(
        config,
        runtime,
        targets,
        started,
        orchestrator,
        handles,
        answer,
      )
    weft.Failed(error:, ..) -> Error(error)
    weft.Crashed(..)
    | weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.DrainProofLost(..)
    | weft.CancellationUnconfirmed(..) ->
      Error(agent.PlaneFailed(reason: "a wait on a child did not finish"))
  }
}

fn joined_waits(
  config: Config,
  runtime: api.Runtime,
  targets: List(Target),
  started: Int,
  orchestrator: String,
  handles: List(Handle),
  answer: Result(List(remote_spawn.Joined), peer_mail.Failure),
) -> Result(List(Waited), Refusal) {
  case answer {
    Ok(entries) ->
      Ok(list.map(entries, fn(entry) { settle_entry(runtime, targets, entry) }))
    Error(peer_mail.Refused(reason)) ->
      Error(agent.RemoteRefused(orchestrator:, reason:))
    Error(peer_mail.Unreachable) | Error(peer_mail.NotOpen) -> {
      let #(now, _clock) = clock.read(config.clock)
      Ok(
        list.map(handles, fn(handle) {
          Pending(
            handle:,
            waited_ms: now - started,
            unanswered: Some(orchestrator),
          )
        }),
      )
    }
  }
}

// One handle's entry in a join, as the wait the tool renders. A child reported
// finished is recorded on its stub, so the roster and the fan-out count see it
// settled; the record is the parent's own account and the answer does not wait on
// it, since the next wait asks the orchestrator again and gets the same answer.
fn settle_entry(
  runtime: api.Runtime,
  targets: List(Target),
  entry: remote_spawn.Joined,
) -> Waited {
  case entry {
    remote_spawn.Pending(handle:, waited_ms:) ->
      Pending(handle:, waited_ms:, unanswered: None)
    remote_spawn.Ready(
      handle:,
      outcome:,
      report:,
      result:,
      notes:,
      usage:,
      owed:,
    ) -> {
      case list.find(targets, fn(target) { target.handle == handle }) {
        Ok(target) -> {
          let _recorded =
            remote_child.settled(runtime, target.key, outcome, usage, owed)
          Nil
        }
        Error(Nil) -> Nil
      }
      Ready(handle:, outcome:, report:, result:, notes:)
    }
  }
}

// The waits in the order the handles were given. An orchestrator that answered
// for fewer handles than it was asked about leaves the rest pending.
fn in_order(handles: List(Handle), waited: List(Waited)) -> List(Waited) {
  let by_handle =
    waited
    |> list.map(fn(entry) { #(agent.handle_to_string(handle_of(entry)), entry) })
    |> dict.from_list
  list.map(handles, fn(handle) {
    case dict.get(by_handle, agent.handle_to_string(handle)) {
      Ok(entry) -> entry
      Error(Nil) -> Pending(handle:, waited_ms: 0, unanswered: None)
    }
  })
}

fn handle_of(waited: Waited) -> Handle {
  case waited {
    Ready(handle:, ..) -> handle
    Pending(handle:, ..) -> handle
  }
}

// --- a parent on another orchestrator --------------------------------------

/// The strand every session opens with. A delegate session's children are
/// built on its configuration, which the spawner's profile seeded.
const session_main_strand = "main"

/// Starts one child for a parent on another orchestrator, or hands back the one
/// its call site already started.
///
/// The request is judged against the spawner's terms first, outside the holder:
/// a deadline above the cap and a tool outside the ceiling are refused without
/// touching the session. The parent's tools are clamped to the ceiling here, so
/// whatever the parent reports, no child can hold what the ceiling excludes.
/// Everything that must be serialized then runs in the holder with the ended
/// fence.
///
/// ## Examples
///
/// ```gleam
/// // agency.delegate_spawn(config, delegation, site, request)
/// // == Ok(remote_spawn.Spawned(handle:, tools:, model:, model_id:, remaining_ms:))
/// ```
pub fn delegate_spawn(
  config: Config,
  delegation: remote_spawn.Delegation,
  site: remote_spawn.CallSite,
  request: remote_spawn.Request,
) -> Result(remote_spawn.Spawned, remote_spawn.SpawnRefusal) {
  use asked <- result.try(remote_spawn.agent_request(request, delegation.terms))
  use subject <- result.try(holder(config))
  let delegation =
    remote_spawn.Delegation(
      ..delegation,
      parent_tools: remote_spawn.clamp_tools(
        delegation.parent_tools,
        delegation.terms,
      ),
    )
  use answer <- result.try(
    call.try_call(
      subject,
      waiting: config.holder_timeout_ms,
      sending: fn(reply) {
        DelegateSpawn(delegation:, site:, request: asked, reply:)
      },
    )
    |> result.map_error(fn(_) { refused(config, agent.AgencyUnavailable) }),
  )
  answer |> result.map(delegated_spawn(config, _))
}

/// Waits, for at most `within_ms`, for the named children of a remote parent,
/// and answers each handle's position with what the settled ones cost.
///
/// This is `wait` with a different asker, plus the usage ledger. The window is
/// cut to `remote_spawn.join_cap_ms` here, because the sender chooses
/// `within_ms` and the receiver's mailbox, not the sender's good manners, is
/// what bounds how long a task may wait. A handle that is not a descendant of
/// the parent's reference refuses the whole join.
///
/// ## Examples
///
/// ```gleam
/// // agency.delegate_join(config, parent, [handle], 25_000)
/// // == Ok([remote_spawn.Pending(handle:, waited_ms: 25_000)])
/// ```
pub fn delegate_join(
  config: Config,
  parent: remote_spawn.Parent,
  handles: List(Handle),
  within_ms: Int,
) -> Result(List(remote_spawn.Joined), remote_spawn.SpawnRefusal) {
  let window = clamp(within_ms, 0, remote_spawn.join_cap_ms)
  joined(config, parent, handles, window)
  |> result.map_error(refused(config, _))
}

fn joined(
  config: Config,
  parent: remote_spawn.Parent,
  handles: List(Handle),
  window: Int,
) -> Result(List(remote_spawn.Joined), Refusal) {
  use waited <- result.try(wait_for(
    config,
    api.parent_reference_prefix <> parent.strand,
    handles,
    window,
  ))
  use runtime <- result.try(borrow(config))
  let settled =
    list.filter_map(waited, fn(entry) {
      case entry {
        Ready(handle:, ..) -> Ok(handle.strand)
        Pending(..) -> Error(Nil)
      }
    })
  use usage <- result.try(
    child_usage.of_strands(runtime, settled)
    |> result.map_error(fn(reason) { agent.PlaneFailed(reason:) }),
  )
  use owing <- result.map(
    delegate_outbox.mail_rows(runtime)
    |> result.map_error(fn(reason) { agent.PlaneFailed(reason:) }),
  )
  list.map(waited, fn(entry) {
    case entry {
      Ready(handle:, outcome:, report:, result:, notes:) ->
        remote_spawn.Ready(
          handle:,
          outcome:,
          report:,
          result:,
          notes:,
          usage: usage_of(usage, handle.strand),
          owed: undelivered(owing, handle.strand),
        )
      Pending(handle:, waited_ms:, ..) ->
        remote_spawn.Pending(handle:, waited_ms:)
    }
  })
}

// How many of a child's messages the delegate session has not delivered: its
// mail rows that no answer has settled. A parent that is told a child finished
// keeps asking until this is zero, so mail written just before the end is not
// stranded by the end.
fn undelivered(
  rows: List(#(String, delegate_outbox.Mail)),
  strand: String,
) -> Int {
  list.count(rows, fn(row) {
    { row.1 }.child.strand == strand
    && { row.1 }.state == delegate_outbox.Pending
  })
}

// A settled child's usage. `child_usage.of_strands` keys every strand it is
// asked about, so the lookup cannot miss. A `let assert` saying so would be the
// plain form, but lint R4 bars it from `src`, so the miss arm is a zero that is
// built lazily and never reached.
fn usage_of(
  usage: Dict(String, remote_spawn.ChildUsage),
  strand: String,
) -> remote_spawn.ChildUsage {
  result.lazy_unwrap(dict.get(usage, strand), fn() {
    remote_spawn.ChildUsage(
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      cost: 0.0,
    )
  })
}

/// Records that a run of a remote parent ended and stops the children it owns,
/// answering how many it stopped.
///
/// The holder writes the ended fence before it reaps, so a spawn for the run
/// that arrives afterwards is refused and one that arrived before is a child
/// this reap stops. A repeat writes the same fence and stops nothing more.
///
/// ## Examples
///
/// ```gleam
/// // agency.delegate_run_ended(config, operation) == Ok(2)
/// ```
pub fn delegate_run_ended(
  config: Config,
  operation: OpId,
) -> Result(Int, remote_spawn.SpawnRefusal) {
  use subject <- result.try(holder(config))
  use answer <- result.try(
    call.try_call(
      subject,
      waiting: config.holder_timeout_ms,
      sending: fn(reply) { DelegateEnded(operation:, reply:) },
    )
    |> result.map_error(fn(_) { refused(config, agent.AgencyUnavailable) }),
  )
  result.map_error(answer, refused(config, _))
}

/// Records that the parent session of a remote parent was deleted and stops
/// every child still running, answering how many it stopped.
///
/// The holder writes the released fence before it stops anything, so a spawn
/// that arrives afterwards is refused and one that arrived before is a child
/// this stop reaches. A repeat writes the same fence and stops nothing more.
///
/// ## Examples
///
/// ```gleam
/// // agency.delegate_release(config) == Ok(2)
/// ```
pub fn delegate_release(
  config: Config,
) -> Result(Int, remote_spawn.SpawnRefusal) {
  use subject <- result.try(holder(config))
  use answer <- result.try(
    call.try_call(
      subject,
      waiting: config.holder_timeout_ms,
      sending: fn(reply) { DelegateRelease(reply:) },
    )
    |> result.map_error(fn(_) { refused(config, agent.AgencyUnavailable) }),
  )
  use stopped <- result.map(result.map_error(answer, refused(config, _)))
  settle_released(config)
  stopped
}

// How long a release waits for the children it stopped to end their runs, in
// milliseconds.
const release_settle_ms = 3000

// The durable stop reason is written by `reap` before this wait, so nothing here
// orders it. The wait is for the strand driver, which logs `operation.aborted`
// and ends the run when it handles the abort, and for a clean `Normal` drain of
// the slot the registry stops right after this returns. A run that outlasts the
// bound is stopped with the session all the same, and nothing depends on the
// wait having succeeded.
fn settle_released(config: Config) -> Nil {
  case borrow(config) {
    Error(_refusal) -> Nil
    Ok(runtime) -> {
      let _waited =
        poll.until(within: release_settle_ms, every: 25, attempt: fn() {
          case runs_in_flight(runtime) {
            True -> poll.Retry
            False -> poll.Done(Nil)
          }
        })
      Nil
    }
  }
}

// Whether any child of the session has a run that has not ended. A ledger that
// cannot be read says no, since the wait is a courtesy to the drivers.
fn runs_in_flight(runtime: api.Runtime) -> Bool {
  case read_ledger(runtime) {
    Error(_refusal) -> False
    Ok(ledger) ->
      list.any(dict.values(ledger), fn(cell) {
        case current_run(runtime, cell) {
          Ok(Some(_run)) -> True
          Ok(None) | Error(_) -> False
        }
      })
  }
}

/// Whether any child of the delegate session still has a run, for the
/// retention sweep that closes an idle session (protocol-change/084).
///
/// This reads the ledger through a borrowed runtime and writes nothing. It is
/// total: the reads run in a deadline-bounded task, so no fault in the session
/// reaches the caller. It fails closed: a holder that is not up or a ledger or
/// strand that cannot be read answers `Occupied`, because the sweep's mistake
/// in that direction keeps a session for another hour, while the other
/// direction stops a child that is running.
///
/// ## Examples
///
/// ```gleam
/// // agency.delegate_occupancy(config) == agency.Vacant
/// ```
pub fn delegate_occupancy(config: Config) -> Occupancy {
  let outcome =
    [fn() { occupancy_in_task(config) }]
    |> weft.new
    |> weft.deadline(occupancy_budget_ms)
    |> weft.start
  case outcome {
    [weft.Completed(value: Vacant, ..)] -> Vacant
    _ -> Occupied
  }
}

// How long the question may take in all, in milliseconds. A holder busy reaping
// an overdue child is slow to lend the runtime, and the answer for a slow
// session is the safe one.
const occupancy_budget_ms = 8000

// The question itself, run in a task so that a holder that exits mid-call, or a
// writer that is gone, ends the task and not the caller. Every read here can
// fault, and the caller is the sweep, which must outlive any one session. The
// borrow is a `try_call`, which answers an error where `process.call` would
// exit.
fn occupancy_in_task(config: Config) -> Result(Occupancy, Refusal) {
  use subject <- result.try(holder_subject(config))
  use runtime <- result.try(
    call.try_call(subject, waiting: config.holder_timeout_ms, sending: Borrow)
    |> result.replace_error(agent.AgencyUnavailable),
  )
  use ledger <- result.map(read_ledger(runtime))
  case
    list.all(dict.values(ledger), fn(cell) {
      current_run(runtime, cell) == Ok(None)
    })
  {
    True -> Vacant
    False -> Occupied
  }
}

fn holder_subject(config: Config) -> Result(Subject(Message), Refusal) {
  address.lookup(config.name)
  |> result.replace_error(agent.AgencyUnavailable)
}

/// The questions a spawning orchestrator asks of a delegate session's
/// Agency, closed over the holder's name and the few settings a wait needs.
///
/// The daemon's registry keeps one of these per resident session, in the
/// projection it hands the orchestrator port (`serve.Resident`), so that a
/// message from another orchestrator reaches the right session's Agency without
/// the registry holding the runtime. The registry's lookup copies the
/// projection to the process that asks, so the closures must stay small: they
/// hold a trimmed `Config`, which keeps what the four functions read and
/// drops the model routing and the peer outbox bell that only the holder uses.
pub type DelegateEndpoint {
  DelegateEndpoint(
    /// Starts a child, or answers the one this call site already started.
    spawn: fn(
      remote_spawn.Delegation,
      remote_spawn.CallSite,
      remote_spawn.Request,
    ) -> Result(remote_spawn.Spawned, remote_spawn.SpawnRefusal),
    /// Waits for children and reports what they cost.
    join: fn(remote_spawn.Parent, List(Handle), Int) ->
      Result(List(remote_spawn.Joined), remote_spawn.SpawnRefusal),
    /// Records a run end and stops the children the run owned.
    run_ended: fn(OpId) -> Result(Int, remote_spawn.SpawnRefusal),
    /// Records that the parent session was deleted and stops every child.
    release: fn() -> Result(Int, remote_spawn.SpawnRefusal),
    /// Delivers a message from the parent into a child, given the parent, the
    /// child, the message's identity and its text, and answers how it landed
    /// (`remote_mail.encode_landing`). A repeat of an identity is answered from
    /// the receipt.
    send: fn(remote_spawn.Parent, Handle, String, String) ->
      Result(JsonValue, remote_spawn.SpawnRefusal),
    /// Reads one page of a child's transcript for the parent, given the
    /// parent, the child, the sequence the page reads below and the most
    /// entries it holds, and answers the encoded page
    /// (`remote_transcript.encode`). Whether the spawner allows it is the
    /// daemon's question, asked before this one.
    history: fn(remote_spawn.Parent, Handle, Int, Int) ->
      Result(JsonValue, remote_spawn.SpawnRefusal),
    /// Whether any child of the session still has a run, which the retention
    /// sweep asks before it closes an idle session.
    occupancy: fn() -> Occupancy,
  )
}

/// Whether a delegate session has a child with a run that has not ended.
pub type Occupancy {
  /// At least one child has a run, or the ledger could not be read. The sweep
  /// keeps the session, since closing it would stop a child.
  Occupied

  /// Every child's run has ended, or the session has no child.
  Vacant
}

/// Projects the delegate questions of one session.
///
/// ## Examples
///
/// ```gleam
/// // agency.delegate_endpoint(config).run_ended(operation)
/// ```
pub fn delegate_endpoint(config: Config) -> DelegateEndpoint {
  let trimmed =
    Config(
      ..config,
      subagent_model: fn() { Error(Nil) },
      models: [],
      peer_defaults: peer_mail.no_defaults,
      outbox_queued: fn() { Nil },
      remote: remote_reach.none(""),
      remote_queued: fn() { Nil },
    )
  DelegateEndpoint(
    spawn: fn(delegation, site, request) {
      delegate_spawn(trimmed, delegation, site, request)
    },
    join: fn(parent, handles, within_ms) {
      delegate_join(trimmed, parent, handles, within_ms)
    },
    run_ended: fn(operation) { delegate_run_ended(trimmed, operation) },
    release: fn() { delegate_release(trimmed) },
    send: fn(parent, child, message_id, text) {
      delegate_send(trimmed, parent, child, message_id, text)
    },
    history: fn(parent, child, cursor, limit) {
      delegate_history(trimmed, parent, child, cursor, limit)
    },
    occupancy: fn() { delegate_occupancy(trimmed) },
  )
}

// --- messages into a child on this orchestrator -------------------------------

/// The key a delegate session stores the receipt of a message from its parent
/// under. Reserved with the rest of `delegate/`.
const receipt_prefix = "delegate/receipt/"

/// Delivers a message from the remote parent into one of its children, once.
///
/// The message id keys a receipt that is written in the commit that delivers, so
/// a message the parent's orchestrator sends again is answered `Admitted` and
/// reaches the child once. A child with an open run takes the message as a steer.
/// An idle one starts a detached run whose deadline is the budget the child's
/// lineage cell keeps, so a send cannot lengthen what the spawner allowed.
/// Nothing here waits on the network or on the holder: it borrows the runtime and
/// commits.
///
/// ## Examples
///
/// ```gleam
/// // agency.delegate_send(config, parent, child, "7b1c", "also check the tests")
/// // == Ok(remote_mail.encode_landing(remote_mail.Steered(entry)))
/// ```
pub fn delegate_send(
  config: Config,
  parent: remote_spawn.Parent,
  child: Handle,
  message_id: String,
  text: String,
) -> Result(JsonValue, remote_spawn.SpawnRefusal) {
  delivered(config, parent, child, message_id, text)
  |> result.map(remote_mail.encode_landing)
  |> result.map_error(refused(config, _))
}

fn delivered(
  config: Config,
  parent: remote_spawn.Parent,
  child: Handle,
  message_id: String,
  text: String,
) -> Result(remote_mail.Landing, Refusal) {
  use runtime <- result.try(borrow(config))
  use ledger <- result.try(read_ledger(runtime))
  let reference = api.parent_reference_prefix <> parent.strand
  use Nil <- result.try(case is_descendant(ledger, reference, child.strand) {
    True -> Ok(Nil)
    False -> Error(agent.NotADescendant(strand: child.strand))
  })
  use Nil <- result.try(
    case
      string.byte_size(message_id) > 0
      && string.byte_size(message_id) <= 128
      && string.byte_size(text) <= remote_send.max_text_bytes
    {
      True -> Ok(Nil)
      False ->
        Error(agent.InvalidArgument("the message id or text exceeds its bound"))
    },
  )
  let key = receipt_prefix <> message_id
  let request =
    json.Object([
      #("child", json.String(child.strand)),
      #("text", json.String(text)),
    ])
  use existing <- result.try(
    api.fact(runtime, key) |> result.map_error(plane_failed),
  )
  case existing {
    Some(held) -> same_send(held, request)
    None -> {
      let #(now, _clock) = clock.read(config.clock)
      let payload =
        message.UserMessage(
          content: [
            message.UserText(
              text: frame_message(from: reference, body: text),
              text_signature: None,
            ),
          ],
          timestamp: now,
          origin: Some(message.StrandOrigin(strand: reference)),
        )
      let mark = api.Mark(key:, value: json.Object([#("request", request)]))
      case
        api.send_to_strand_marking(
          runtime,
          to: child.strand,
          message: payload,
          mark:,
        )
      {
        Ok(api.Steered(entry:)) -> Ok(remote_mail.Steered(entry:))
        Ok(api.Started(operation:)) -> {
          use deadline <- result.map(run_deadline(
            runtime,
            Handle(strand: child.strand, operation:),
          ))

          // The time left is read after the admission, so it can only be less
          // than the budget the run was given, never more.
          let #(later, _clock) = clock.read(config.clock)
          remote_mail.Started(
            operation:,
            remaining_ms: option.map(deadline, fn(at) { int.max(0, at - later) }),
          )
        }

        // A twin of this message committed between the read and the write. Its
        // receipt is the answer.
        Error(api.FactConflict(..)) -> {
          use held <- result.try(
            api.fact(runtime, key) |> result.map_error(plane_failed),
          )
          case held {
            Some(held) -> same_send(held, request)
            None ->
              Error(agent.PlaneFailed(
                "the send's receipt moved under the write",
              ))
          }
        }
        Error(error) -> Error(agent.PlaneFailed(describe_api(error)))
      }
    }
  }
}

// --- a page of a child's transcript for its remote parent --------------------

/// Reads one page of a child's transcript for the remote parent that started
/// it (protocol-change/090).
///
/// The page is the child's branch: the entries on the path from the child's
/// leaf down its parent links, newest first from the store and oldest first on
/// the page, at most `limit` of them and within the page's byte bound
/// (`remote_transcript.page_of`). `cursor` is the sequence the page reads
/// below, zero for the newest page. A child the parent did not start is not
/// the parent's to read, by the same descent test a send makes, so a parent
/// cannot page through a sibling's branch or a strand of the delegate session
/// itself. Nothing here writes, waits on the network or asks the holder: it
/// borrows the runtime and reads.
///
/// ## Examples
///
/// ```gleam
/// // agency.delegate_history(config, parent, child, 0, 50)
/// // == Ok(remote_transcript.encode(page))
/// ```
pub fn delegate_history(
  config: Config,
  parent: remote_spawn.Parent,
  child: Handle,
  cursor: Int,
  limit: Int,
) -> Result(JsonValue, remote_spawn.SpawnRefusal) {
  history_page(config, parent, child, cursor, limit)
  |> result.map(remote_transcript.encode)
  |> result.map_error(refused(config, _))
}

fn history_page(
  config: Config,
  parent: remote_spawn.Parent,
  child: Handle,
  cursor: Int,
  limit: Int,
) -> Result(remote_transcript.Page, Refusal) {
  use Nil <- result.try(
    case cursor >= 0 && limit >= 1 && limit <= remote_transcript.max_entries {
      True -> Ok(Nil)
      False ->
        Error(agent.InvalidArgument("the cursor or the limit is out of bounds"))
    },
  )
  use runtime <- result.try(borrow(config))
  use ledger <- result.try(read_ledger(runtime))
  let reference = api.parent_reference_prefix <> parent.strand
  use Nil <- result.try(case is_descendant(ledger, reference, child.strand) {
    True -> Ok(Nil)
    False -> Error(agent.NotADescendant(strand: child.strand))
  })
  use leaf <- result.try(
    api.leaf(api.on_strand(runtime, child.strand))
    |> result.map_error(plane_failed),
  )
  case leaf {
    None ->
      Ok(remote_transcript.Page(
        child: child.strand,
        entries: [],
        omitted: 0,
        next: None,
      ))

    // One more entry than the page holds is read, so the page can say whether
    // older entries exist without a second read.
    Some(leaf) -> {
      let query = storage.branch_scan(leaf) |> storage.branch_limit(limit + 1)
      let query = case cursor {
        0 -> query
        before -> storage.branch_cursor(query, before)
      }
      use scanned <- result.map(
        storage.scan_branch(runtime.session.store, query)
        |> result.replace_error(agent.PlaneFailed(
          reason: "the child's branch could not be read",
        )),
      )
      remote_transcript.page_of(child.strand, scanned, limit)
    }
  }
}

// A receipt answers a repeat only if it is a receipt for this message. The id is
// derived from the sender's call site and is not a proof of what was said, so an
// id reused for other content is refused and never answered with the first
// message's receipt.
fn same_send(
  held: JsonValue,
  request: JsonValue,
) -> Result(remote_mail.Landing, Refusal) {
  case held {
    json.Object(fields) ->
      case list.key_find(fields, "request") == Ok(request) {
        True -> Ok(remote_mail.Admitted)
        False ->
          Error(agent.InvalidArgument(
            "the message id was already used for different content",
          ))
      }
    _ -> Error(agent.PlaneFailed("the send's receipt is corrupt"))
  }
}

// --- mail and progress from a child on another orchestrator -------------------

/// The questions the orchestrator port asks of a parent session's Agency about
/// what its children on other orchestrators send (protocol-change/084, phase 2),
/// closed over the holder's name and a trimmed configuration, as
/// `DelegateEndpoint` is for the other direction.
///
/// Each takes `admits`, the daemon's test of whether the message came from the
/// node of the orchestrator a name stands for. The Agency knows which
/// orchestrator a child's stub names and not the node it is configured at, and
/// the daemon knows the roster, so the daemon passes the roster's half as a
/// function and the Agency applies it to the stub it finds.
pub type ChildInbox {
  ChildInbox(
    /// Admits a child's mail into the parent strand and answers the receipt.
    mail: fn(remote_spawn.Parent, Handle, String, String, fn(String) -> Bool) ->
      Result(remote_mail.Receipt, remote_mail.ChildRefusal),
    /// Keeps a child's glance on its stub.
    progress: fn(remote_spawn.Parent, Handle, Glance, fn(String) -> Bool) ->
      Result(Nil, remote_mail.ChildRefusal),
  )
}

/// Projects the inbox of one parent session.
///
/// ## Examples
///
/// ```gleam
/// // agency.child_inbox(config).mail(parent, child, "7b1c", "done", fn(name) { name == "box" })
/// ```
pub fn child_inbox(config: Config) -> ChildInbox {
  let trimmed =
    Config(
      ..config,
      subagent_model: fn() { Error(Nil) },
      models: [],
      peer_defaults: peer_mail.no_defaults,
      outbox_queued: fn() { Nil },
      remote: remote_reach.none(""),
      remote_queued: fn() { Nil },
    )
  ChildInbox(
    mail: fn(parent, child, message_id, text, admits) {
      admit_child_mail(trimmed, parent, child, message_id, text, admits)
    },
    progress: fn(parent, child, glance, admits) {
      child_progress(trimmed, parent, child, glance, admits)
    },
  )
}

// Asks the holder to admit the mail. A holder that is not up, or that does not
// answer in its bound, is a store failure: the box asks again only for
// `ParentSessionNotOpen`, and a store failure settles the row, which is why the
// answer says what it was and nothing is retried on a guess.
fn admit_child_mail(
  config: Config,
  parent: remote_spawn.Parent,
  child: Handle,
  message_id: String,
  text: String,
  admits: fn(String) -> Bool,
) -> Result(remote_mail.Receipt, remote_mail.ChildRefusal) {
  use subject <- result.try(
    holder_subject(config)
    |> result.replace_error(remote_mail.Busy(
      reason: "the parent session's Agency is not running",
    )),
  )
  use answer <- result.try(
    call.try_call(
      subject,
      waiting: config.holder_timeout_ms,
      sending: fn(reply) {
        AdmitChildMail(parent:, child:, message_id:, text:, admits:, reply:)
      },
    )
    |> result.replace_error(remote_mail.Busy(
      reason: "the parent session's Agency did not answer",
    )),
  )
  answer
}

// Finds the stub a message about a child concerns, by the child's name and the
// parent strand it reports to, and checks that the message came from the
// orchestrator that stub names. Nothing here reads the lineage cell or the
// handle: the stub is written before the first `Spawn` leaves, so it exists
// whatever state the spawn has reached.
fn stub_for(
  runtime: api.Runtime,
  parent: remote_spawn.Parent,
  child: Handle,
  admits: fn(String) -> Bool,
) -> Result(remote_child.Kept, remote_mail.ChildRefusal) {
  use kept <- result.try(
    remote_child.all(runtime)
    |> result.map_error(fn(reason) { remote_mail.Busy(reason:) }),
  )
  use entry <- result.try(
    remote_child.find_named(kept, parent.strand, child.strand)
    |> result.replace_error(remote_mail.UnknownChild),
  )
  case admits(entry.stub.orchestrator) {
    True -> Ok(entry)
    False -> Error(remote_mail.OriginMismatch)
  }
}

// The holder's half of a child's mail: the stub, the receipt, and the steer.
fn admit_mail(
  config: Config,
  runtime: api.Runtime,
  parent: remote_spawn.Parent,
  child: Handle,
  message_id: String,
  text: String,
  admits: fn(String) -> Bool,
) -> Result(remote_mail.Receipt, remote_mail.ChildRefusal) {
  use _entry <- result.try(stub_for(runtime, parent, child, admits))
  use Nil <- result.try(
    case
      string.byte_size(message_id) > 0
      && string.byte_size(message_id) <= 128
      && string.byte_size(text) <= remote_send.max_text_bytes
    {
      True -> Ok(Nil)
      False ->
        Error(remote_mail.StoreFailure(
          reason: "the message id or text exceeds its bound",
        ))
    },
  )
  let key = api.remote_mail_fact_prefix <> message_id
  let request =
    json.Object([
      #("child", json.String(child.strand)),
      #("text", json.String(text)),
    ])
  use existing <- result.try(
    api.fact(runtime, key) |> result.map_error(mail_failure),
  )
  case existing {
    Some(held) -> same_mail(held, request)
    None -> steer_mail(config, runtime, parent, child, text, key, request)
  }
}

// Steers the parent strand and writes the receipt in one commit. A parent with
// no run open cannot be steered, and a finished parent is never woken for a
// child's message, so the refusal is written alone as the receipt, and the child
// reads it on its outbox row. Either way the message id is spent.
fn steer_mail(
  config: Config,
  runtime: api.Runtime,
  parent: remote_spawn.Parent,
  child: Handle,
  text: String,
  key: String,
  request: JsonValue,
) -> Result(remote_mail.Receipt, remote_mail.ChildRefusal) {
  let #(now, _clock) = clock.read(config.clock)
  let payload =
    message.UserMessage(
      content: [
        message.UserText(
          text: frame_message(from: child.strand, body: text),
          text_signature: None,
        ),
      ],
      timestamp: now,
      origin: Some(message.StrandOrigin(strand: child.strand)),
    )
  let target = api.on_strand(runtime, parent.strand)
  let mark = api.Mark(key:, value: mail_cell(request, remote_mail.Delivered))
  case api.steer_marking(target, payload, mark) {
    Ok(_entry) -> {
      api.nudge(target)
      Ok(remote_mail.Delivered)
    }
    Error(api.FactConflict(..)) -> {
      use held <- result.try(
        api.fact(runtime, key) |> result.map_error(mail_failure),
      )
      case held {
        Some(held) -> same_mail(held, request)
        None ->
          Error(remote_mail.StoreFailure(
            reason: "the mail's receipt moved under the write",
          ))
      }
    }
    Error(api.QueueRejected(..)) -> {
      let declined =
        remote_mail.Declined(
          reason: "the parent has no run open, and a finished parent is not "
          <> "woken for a child's message",
        )
      case
        api.put_reserved_fact_expecting(
          runtime,
          key,
          mail_cell(request, declined),
          expected: None,
        )
      {
        Ok(_) -> Ok(declined)
        Error(api.FactConflict(..)) -> {
          use held <- result.try(
            api.fact(runtime, key) |> result.map_error(mail_failure),
          )
          case held {
            Some(held) -> same_mail(held, request)
            None ->
              Error(remote_mail.StoreFailure(
                reason: "the mail's receipt moved under the write",
              ))
          }
        }
        Error(error) -> Error(mail_failure(error))
      }
    }
    Error(error) -> Error(mail_failure(error))
  }
}

// The value a mail receipt cell holds: what was asked, so a repeat can be told
// from an id reused for other content, and what became of it.
fn mail_cell(request: JsonValue, receipt: remote_mail.Receipt) -> JsonValue {
  json.Object([
    #("request", request),
    #("receipt", remote_mail.encode_receipt(receipt)),
  ])
}

// A stored receipt answers a repeat only for the same request.
fn same_mail(
  held: JsonValue,
  request: JsonValue,
) -> Result(remote_mail.Receipt, remote_mail.ChildRefusal) {
  case held {
    json.Object(fields) ->
      case list.key_find(fields, "request") == Ok(request) {
        True ->
          list.key_find(fields, "receipt")
          |> result.replace_error(remote_mail.StoreFailure(
            reason: "the mail's receipt is corrupt",
          ))
          |> result.try(fn(stored) {
            remote_mail.decode_receipt(stored)
            |> result.map_error(fn(reason) { remote_mail.StoreFailure(reason:) })
          })
        False ->
          Error(remote_mail.StoreFailure(
            reason: "the message id was already used for different content",
          ))
      }
    _ ->
      Error(remote_mail.StoreFailure(reason: "the mail's receipt is corrupt"))
  }
}

fn mail_failure(error: api.ApiError) -> remote_mail.ChildRefusal {
  remote_mail.Busy(reason: describe_api(error))
}

// A glance from another machine is text a model wrote, and the stub stores it, so
// the title and the summary are cut to the bounds a local glance is written
// under, at a character boundary.
fn bounded_glance(seen: Glance) -> Glance {
  glance.Glance(
    ..seen,
    title: cut(seen.title, glance.max_title_bytes),
    summary: cut(seen.summary, glance.max_summary_bytes),
  )
}

fn cut(text: String, bytes: Int) -> String {
  string.to_graphemes(text)
  |> list.fold_until("", fn(kept, piece) {
    case string.byte_size(kept <> piece) <= bytes {
      True -> list.Continue(kept <> piece)
      False -> list.Stop(kept)
    }
  })
}

// Keeps a child's glance on its stub. A glance for a stub in any state is kept,
// so one that arrives before the answer to the `Spawn` is still there when
// `spawned` writes the state. It runs on the caller's process: the write is one
// compare-and-set on the stub, which does not need the holder's serialization.
fn child_progress(
  config: Config,
  parent: remote_spawn.Parent,
  child: Handle,
  glance: Glance,
  admits: fn(String) -> Bool,
) -> Result(Nil, remote_mail.ChildRefusal) {
  use runtime <- result.try(
    borrow(config)
    |> result.replace_error(remote_mail.Busy(
      reason: "the parent session's Agency is not running",
    )),
  )
  use entry <- result.try(stub_for(runtime, parent, child, admits))
  let #(now, _clock) = clock.read(config.clock)
  remote_child.progressed(runtime, entry.key, bounded_glance(glance), now)
  |> result.map(fn(_stub) { Nil })
  |> result.map_error(fn(reason) { remote_mail.Busy(reason:) })
}

// The holder's mailbox, or the refusal a spawner reads when it is not up.
fn holder(
  config: Config,
) -> Result(Subject(Message), remote_spawn.SpawnRefusal) {
  address.lookup(config.name)
  |> result.map_error(fn(_) { refused(config, agent.AgencyUnavailable) })
}

fn refused(config: Config, refusal: Refusal) -> remote_spawn.SpawnRefusal {
  remote_spawn.refusal_of(
    refusal,
    fan_out: config.fan_out,
    session_strands: config.session_strands,
  )
}

// The caller a remote parent's call site stands for: the reference to its
// strand, and the planned call it is minting under, which are the coordinates a
// local spawn derives the child's name from.
fn delegated_caller(
  parent: remote_spawn.Parent,
  site: remote_spawn.CallSite,
) -> Caller {
  agent.Caller(
    strand: api.parent_reference_prefix <> parent.strand,
    operation: site.operation,
    step_id: site.step_id,
    source_index: site.source_index,
    minter: site.minter,
  )
}

// A spawn as the spawner is told of it. The deadline is an instant on this
// session's clock and clocks never cross as instants, so it becomes the time
// left. A child with no deadline cannot be admitted, since the terms give every
// spawn one, so the zero for that case is never read.
fn delegated_spawn(config: Config, spawned: Spawned) -> remote_spawn.Spawned {
  let #(now, _clock) = clock.read(config.clock)
  remote_spawn.Spawned(
    handle: spawned.handle,
    tools: spawned.tools,
    model: spawned.model,
    model_id: spawned.model_id,
    remaining_ms: case spawned.deadline_ms {
      Some(at) -> int.max(0, at - now)
      None -> 0
    },
  )
}
