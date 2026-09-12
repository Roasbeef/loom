//// The advisor loop: the three hook slots, the verdict-to-acknowledgement
//// mapping, and the feed against a real session store.
////
//// The hook tests need no runtime at all — every slot decides what to do
//// from the operation's own `op.meta` cell — so they run against a bare
//// memory session with no actor registered, which is also the production
//// state while the service supervisor is restarting one. The feed tests
//// open a real runtime over an in-memory session, because what the feed
//// does is scan a branch, commit a durable message onto another strand
//// and write a cursor cell, and none of those can be faked without
//// testing the fake.

import client/advisor
import client/advisorguard
import client/agency
import core/clock
import core/entry.{type Entry}
import core/ids.{type EntryId, type OpId}
import core/json
import core/message
import core/register
import core/tx.{SetRegister, Tx}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor as otp_actor
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import runtime/hooks
import runtime/lineage
import session/session.{type Session}
import storage/storage
import support/addresses
import telemetry/log
import tools/advise
import tools/agent
import weft/registry as address

// --- the run-start slot ----------------------------------------------------

// One `Effects` record serves every strand, so the nudges drain has to be
// keyed on the operation's own strand. A subagent's run start must cost
// exactly what it cost before advisors existed.
pub fn a_foreign_strand_run_start_is_left_alone_test() {
  let opened = a_session()
  let wiring = a_wiring(opened)
  let operation = an_operation(opened, "sub:main/reviewer-1", 3)
  let hooked =
    advisor.hooks(
      hooks.new()
        |> hooks.with_run_start(fn(_operation) { [user("a house rule")] })
        |> hooks.build,
      wiring,
    )

  let assert [only] = hooked.run_start(operation)
    as "a foreign strand must be handed the inner list unchanged"
  assert text_of(only) == "a house rule"
}

// The primary's run start with no actor registered: the drain degrades to
// no nudges rather than to a crashed driver. This is the state a restart
// of the service supervisor leaves behind.
pub fn an_absent_actor_yields_no_nudges_test() {
  let opened = a_session()
  let wiring = a_wiring(opened)
  let operation = an_operation(opened, advisor.primary, 5)
  let hooked = advisor.hooks(hooks.build(hooks.new()), wiring)

  assert hooked.run_start(operation) == []
}

// --- the context slot ------------------------------------------------------

// The advisor's standing instructions lead its own requests and appear in
// nobody else's.
pub fn the_advisor_is_handed_its_instructions_test() {
  let opened = a_session()
  let wiring = a_wiring(opened)
  let operation = an_operation(opened, advisor.strand, 7)
  let hooked = advisor.hooks(hooks.build(hooks.new()), wiring)

  let assert [first, second] = hooked.context(operation, [user("the feed")])
    as "the instructions must lead the projection"
  assert text_of(first) == advisor.brief
  assert text_of(second) == "the feed"
}

pub fn the_primary_is_not_handed_the_instructions_test() {
  let opened = a_session()
  let wiring = a_wiring(opened)
  let operation = an_operation(opened, advisor.primary, 9)
  let hooked = advisor.hooks(hooks.build(hooks.new()), wiring)

  let assert [only] = hooked.context(operation, [user("the prompt")])
    as "the primary's projection must be handed back unchanged"
  assert text_of(only) == "the prompt"
}

// --- the run-end slot ------------------------------------------------------

// The notification is a side effect beside the slot's contract, never
// instead of it: an earlier layer's follow-up must still be what the
// driver reads.
pub fn the_run_end_answer_is_passed_through_test() {
  let opened = a_session()
  let wiring = a_wiring(opened)
  let operation = an_operation(opened, advisor.primary, 11)
  let hooked =
    advisor.hooks(
      hooks.new()
        |> hooks.with_run_end(fn(_operation) { Some(user("carry on")) })
        |> hooks.build,
      wiring,
    )

  let assert Some(placed) = hooked.run_end(operation)
    as "the inner follow-up must survive the notification"
  assert text_of(placed) == "carry on"
}

// --- what the advisor is told ----------------------------------------------

// Only a `Deliver` sends anything. The other four decisions have already
// happened inside the guard, and a send evaluated to produce an argument
// they ignore would emit advice the guard just dropped.
pub fn only_a_delivery_sends_test() {
  let exploding = fn(_text) { panic as "no send is allowed on this arm" }

  assert advisor.outcome(advisorguard.Silent, exploding)
    == Ok(advise.Acknowledged)
  assert advisor.outcome(advisorguard.Queued(text: "a nit"), exploding)
    == Ok(advise.Queued)
  assert advisor.outcome(
      advisorguard.Downgraded(text: "too soon", reason: "one run left"),
      exploding,
    )
    == Ok(advise.Downgraded(reason: "one run left"))
  assert advisor.outcome(
      advisorguard.Dropped(reason: "said already"),
      exploding,
    )
    == Ok(advise.Dropped(reason: "said already"))
}

// The advisor is told which door the message went through, because that
// is what it decides its next verdict from.
pub fn a_delivery_names_the_door_test() {
  let steered = fn(_text) { Ok(api.Steered(entry: an_entry_id())) }
  let assert Ok(advise.Delivered(how:)) =
    advisor.outcome(advisorguard.Deliver(text: "stop"), steered)
    as "a steer must be reported as a delivery"
  assert string.contains(how, "open run")

  let started = fn(_text) { Ok(api.Started(operation: an_op_id(1))) }
  let assert Ok(advise.Delivered(how: how_started)) =
    advisor.outcome(advisorguard.Deliver(text: "stop"), started)
    as "a fresh run must be reported as a delivery"
  assert string.contains(how_started, "idle")
}

pub fn a_refused_delivery_is_an_error_outcome_test() {
  let refused = fn(_text) { Error("the primary would not take it") }

  assert advisor.outcome(advisorguard.Deliver(text: "stop"), refused)
    == Error("the primary would not take it")
}

// --- the active tool list --------------------------------------------------

// A tool the operator named that this host does not build is dropped
// rather than refused, and `advise` is added whatever the table says.
pub fn the_advisor_gets_the_tools_this_host_built_test() {
  let settings = some_settings(["grep", "curl"])

  assert advisor.active_tools(settings, ["bash", "fs_read", "grep"])
    == ["advise", "grep"]
}

// An operator who names `advise` gets one of it, not two: the list is the
// provider's tool array, and a repeated name is a malformed request.
pub fn advise_is_granted_once_test() {
  let settings = some_settings(["advise"])

  assert advisor.active_tools(settings, ["advise", "bash"]) == ["advise"]
}

// A host that deactivated `advise` would otherwise get an advisor strand
// with a driver, a model and no way to say anything. It is refused by
// name at boot instead.
pub fn an_unregistered_advise_tool_refuses_the_strand_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Error(reason) =
    advisor.ensure_strand(rig.runtime, some_settings([]), ["bash", "grep"])
    as "a host with no `advise` tool must refuse the strand"
  assert string.contains(reason, "advise")
  stop(rig)
}

// --- the loop against a real store -----------------------------------------

// The whole feed path: the primary's branch is scanned from the root, the
// entries are rendered into one message the advisor receives, and the
// cursor advances to the newest entry the scan saw.
pub fn a_primary_run_end_feeds_the_advisor_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [
      user("write the migration"),
      user("and its down step"),
      user("then run the gate"),
    ])
    as "the primary must accept the fixture run"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  process.send(subject, advisor.PrimaryRunEnded(operation: an_op_id(2)))
  let _drained = settle(subject)

  let assert [fed] = advisor_texts(rig.opened)
    as "exactly one feed must reach the advisor"
  assert string.contains(fed, "write the migration")
  assert string.contains(fed, "and its down step")
  assert string.contains(fed, "then run the gate")
  assert cursor(rig.runtime) != None
  stop(rig)
}

// Coalescing is the whole backpressure story: an advisor with a run open
// is left alone, and the cursor stays where it was so the stretch it has
// not seen is still owed to it at the next run end.
pub fn a_busy_advisor_is_not_fed_again_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"

  // The advisor is reviewing something already. Nothing here is the
  // actor's doing, which is the point: the actor has to read the
  // advisor's durable state rather than remember what it last sent.
  let assert Ok(_busy) =
    api.send_to_strand(
      rig.runtime,
      to: advisor.strand,
      message: user("an earlier feed"),
    )
    as "the advisor must take the fixture feed"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  process.send(subject, advisor.PrimaryRunEnded(operation: an_op_id(2)))
  let _drained = settle(subject)

  let assert [only] = advisor_texts(rig.opened)
    as "the busy advisor must have been left alone"
  assert only == "an earlier feed"
  assert cursor(rig.runtime) == None
  stop(rig)
}

// The catch-up, which is why `AdvisorRunEnded` exists at all. The
// driver resolves `run_end` before the run closes, so the advisor still
// reads as busy at exactly the moment its review is finishing; a feed
// that yielded to that would never catch up on anything.
//
// The debt is what the catch-up answers, so the primary's run end has to
// be coalesced away first: that skipped feed is the thing being caught
// up on.
pub fn the_advisors_own_run_end_catches_up_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"
  let assert Ok(_busy) =
    api.send_to_strand(
      rig.runtime,
      to: advisor.strand,
      message: user("an earlier feed"),
    )
    as "the advisor must take the fixture feed"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  process.send(subject, advisor.PrimaryRunEnded(operation: an_op_id(2)))
  let _skipped = settle(subject)
  assert cursor(rig.runtime) == None

  process.send(subject, advisor.AdvisorRunEnded(operation: an_op_id(4)))
  let _drained = settle(subject)

  // The feed lands on the closing run as a steer, so it is off the
  // advisor's branch until that run consumes it. The cursor is the
  // observable that says it was sent: nothing else writes that cell, and
  // a send that failed leaves it alone.
  assert cursor(rig.runtime) != None
  stop(rig)
}

// A review that ended with nothing owed reviews nothing, even though the
// primary's branch has moved.
//
// Without the debt the catch-up would send any delta past the cursor,
// and the primary appends assistant turns and tool results throughout
// its own run — so every advisor run end would find something, send it,
// and be asked again when that review ended. The loop would sustain
// itself for as long as the primary kept working, at one inference per
// iteration against a primary that has not decided anything yet.
pub fn an_idle_review_end_does_not_poll_the_primary_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  process.send(subject, advisor.AdvisorRunEnded(operation: an_op_id(4)))
  let _quiet = settle(subject)

  assert advisor_texts(rig.opened) == []
  assert cursor(rig.runtime) == None
  stop(rig)
}

// A primary that has appended nothing has nothing to review. No message
// is sent and no cursor is written, so the next run end starts from the
// root rather than from a position nothing was ever read at.
pub fn an_empty_primary_branch_sends_nothing_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  process.send(subject, advisor.PrimaryRunEnded(operation: an_op_id(2)))
  let _drained = settle(subject)

  assert advisor_texts(rig.opened) == []
  assert cursor(rig.runtime) == None
  stop(rig)
}

// The verdict is judged against the caller's durable strand name, which
// the driver sets from its own coordinates. A strand that is not the
// advisor is refused whatever it asks for.
pub fn only_the_advisor_may_advise_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let refused =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.primary,
        verdict: advise.Block(text: "stop what you are doing"),
        reply:,
      )
    })

  assert refused == Error("only the advisor strand may advise")
  stop(rig)
}

// A block from the advisor reaches the primary, and the nudge that
// follows it inside the cooldown window is downgraded rather than
// delivered — the guard's decision, taken on the actor's own state and
// visible to the model in the acknowledgement it gets back.
pub fn a_block_reaches_the_primary_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let assert Ok(advise.Delivered(..)) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.strand,
        verdict: advise.Block(text: "the migration has no down step"),
        reply:,
      )
    })
    as "the first block must be delivered"

  let assert Ok(advise.Downgraded(..)) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.strand,
        verdict: advise.Block(text: "and the gate was never run"),
        reply:,
      )
    })
    as "a second block inside the window must be downgraded"

  let drained = settle(subject)
  assert drained == ["and the gate was never run"]
  stop(rig)
}

// A queued nudge is folded into the primary's next run start, after
// whatever the inner layers injected, and into nobody else's. This is the
// drain the run-start slot exists for, over a live actor rather than over
// an absent one.
pub fn a_queued_nudge_reaches_the_primarys_next_run_start_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  let assert Ok(advise.Queued) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.strand,
        verdict: advise.Nudge(text: "the helper is still unclosed"),
        reply:,
      )
    })
    as "the nudge must be queued"

  let hooked =
    advisor.hooks(
      hooks.build(hooks.new()),
      a_wiring_named(rig.opened, rig.name),
    )
  let foreign = an_operation(rig.opened, "sub:main/reviewer-1", 21)
  assert hooked.run_start(foreign) == []

  let mine = an_operation(rig.opened, advisor.primary, 23)
  let assert [folded] = hooked.run_start(mine)
    as "the primary must be handed its queued nudge"
  assert string.contains(text_of(folded), "the helper is still unclosed")

  // Draining is what the slot does: the same run start twice must not
  // fold the same nudge in twice.
  assert hooked.run_start(mine) == []
  stop(rig)
}

// The hook and the actor, joined: the primary's run end is what drives
// the whole loop in production, and nothing else casts that message. A
// run end on another strand drives nothing at all.
pub fn the_primarys_run_end_drives_the_feed_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  let hooked =
    advisor.hooks(
      hooks.build(hooks.new()),
      a_wiring_named(rig.opened, rig.name),
    )

  let foreign = an_operation(rig.opened, "sub:main/reviewer-1", 31)
  assert hooked.run_end(foreign) == None
  let _quiet = settle(subject)
  assert advisor_texts(rig.opened) == []

  let mine = an_operation(rig.opened, advisor.primary, 33)
  assert hooked.run_end(mine) == None
  let _drained = settle(subject)

  let assert [fed] = advisor_texts(rig.opened)
    as "the primary's run end must have fed the advisor"
  assert string.contains(fed, "write the migration")
  stop(rig)
}

// --- the isolation the design rests on -------------------------------------

// The advisor is made with `create_idle_strand` and never through the
// Agency, so it has no lineage cell. That absence is what the whole
// design rests on: the ledger is the only thing `agent_send` consults
// before one strand may address another, and it is what `strand.roster`
// lists, so a primary cannot argue its reviewer out of a verdict and is
// never prompted to reason about a strand it has no business managing.
pub fn the_advisor_is_outside_the_lineage_ledger_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"

  let assert Ok(cells) =
    api.reserved_facts(rig.runtime, prefix: lineage.key_prefix)
    as "the lineage ledger must be readable"
  assert !list.any(cells, fn(cell) {
    cell.0 == lineage.register_key(advisor.strand)
  })

  // And the seam that reads that ledger refuses the name, which is the
  // property the absent cell is there to produce.
  let name = addresses.new()
  let config = agency.default_config(name, clock.fixed(at: 1000))
  let assert Ok(_holder) = agency.start(config, rig.runtime)
    as "the agency holder must start"
  let seam = agency.seam(config)

  assert seam.send(a_caller(advisor.primary), advisor.strand, "reconsider")
    == Error(agent.NotAddressable(strand: advisor.strand))
  stop(rig)
}

fn a_caller(strand: String) -> agent.Caller {
  agent.Caller(
    strand:,
    operation: an_op_id(41),
    step_id: "turn-1:tools",
    source_index: 0,
    minter: agent.ToolCall,
  )
}

// --- the rig ---------------------------------------------------------------

type Rig {
  Rig(
    opened: Session,
    runtime: api.Runtime,
    name: address.Address(advisor.Message),
  )
}

fn a_rig() -> Result(Rig, String) {
  use opened <- result.try(
    session.open_memory(clock.fixed(at: 1_756_000_000_000))
    |> result.replace_error("the memory session did not open"),
  )
  use entropy <- result.try(start_entropy())
  use runtime <- result.try(
    api.open(
      opened,
      effects.Effects(
        clock: clock.fixed(at: 1_756_000_000_000),
        entropy:,
        timers: effects.real_timers(),
        provider: hanging_provider(),
        tools: refusing_tools(),
        hooks: effects.default_hooks(),
      ),
      api.default_options(a_configuration()),
    )
    |> result.map_error(string.inspect),
  )
  let settings = some_settings([])
  use Nil <- result.try(advisor.ensure_strand(runtime, settings, [advise.name]))

  let name = addresses.new()
  let wiring =
    advisor.Wiring(
      session: opened,
      runtime: fn() { Ok(runtime) },
      settings:,
      clock: clock.fixed(at: 1_756_000_000_000),
      logger: log.discard(),
      name:,
    )
  use _started <- result.try(
    advisor.start(wiring)
    |> result.replace_error("the advisor actor did not start"),
  )
  Ok(Rig(opened:, runtime:, name:))
}

fn stop(rig: Rig) -> Nil {
  process.kill(rig.runtime.tree.supervisor)
}

// A call after a cast, to the same actor and from the same process, is
// answered only once the cast has been handled: the mailbox is FIFO per
// sender. That is what makes this a barrier rather than a sleep.
fn settle(subject: process.Subject(advisor.Message)) -> List(String) {
  process.call(subject, waiting: 5000, sending: fn(reply) {
    advisor.TakePending(reply:)
  })
}

fn cursor(runtime: api.Runtime) -> Option(json.JsonValue) {
  api.fact(runtime, advisor.cursor_key) |> result.unwrap(None)
}

fn some_settings(tools: List(String)) -> advisor.Settings {
  advisor.Settings(
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking: machine_strand.ThinkingOff,
    tools:,
    block_cooldown_runs: 2,
  )
}

fn a_configuration() -> machine_strand.StrandConfiguration {
  machine_strand.StrandConfiguration(
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: machine_strand.ThinkingOff,
    active_tool_names: [],
  )
}

// --- reading the advisor's branch ------------------------------------------

// The text of every user message on the advisor's branch, oldest first:
// what the advisor was actually handed, read back out of the store rather
// than out of anything this test built.
fn advisor_texts(opened: Session) -> List(String) {
  case advisor_leaf(opened) {
    None -> []

    Some(leaf) ->
      storage.branch_scan(from: leaf)
      |> storage.branch_order(storage.OldestFirst)
      |> storage.scan_branch(opened.store, _)
      |> result.unwrap([])
      |> list.filter_map(entry_text)
  }
}

fn advisor_leaf(opened: Session) -> Option(EntryId) {
  let assert Ok(Some(session.Cell(value: leaf, ..))) =
    session.strand_leaf(opened, advisor.strand)
    as "the advisor strand must be seeded"
  leaf
}

fn entry_text(each: Entry) -> Result(String, Nil) {
  case each {
    entry.MessageEntry(message: message.UserMessage(content:, ..), ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.UserText(text:, ..) -> Ok(text)
          message.UserImage(..) -> Error(Nil)
        }
      })
      |> string.join("\n")
      |> Ok

    entry.MessageEntry(..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> Error(Nil)
  }
}

// --- fixtures --------------------------------------------------------------

fn a_session() -> Session {
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 1000))
    as "the memory session must open"
  opened
}

// A wiring whose runtime never answers and whose actor is not registered:
// the state every hook slot has to tolerate, since the slots run on the
// strand driver and a run is never held up for a review.
fn a_wiring(opened: Session) -> advisor.Wiring {
  advisor.Wiring(
    session: opened,
    runtime: fn() { Error(Nil) },
    settings: some_settings([]),
    clock: clock.fixed(at: 1000),
    logger: log.discard(),
    name: addresses.new(),
  )
}

// The same wiring the hook tests use, pointed at a running actor.
fn a_wiring_named(
  opened: Session,
  name: address.Address(advisor.Message),
) -> advisor.Wiring {
  advisor.Wiring(..a_wiring(opened), name:)
}

// Writes an `op.meta` cell, which is where every hook slot learns whose
// run this is.
fn an_operation(opened: Session, strand: String, seed: Int) -> OpId {
  let id = an_op_id(seed)
  let assert Ok(_committed) =
    storage.commit(
      opened.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.OpMeta,
            key: ids.op_id_to_string(id),
            value: register.RegisterValue(
              payload: codec.encode_operation(operation.Operation(
                id:,
                strand:,
                source_leaf: None,
                started_at: 0,
                intent: operation.RunIntent(prompt_entries: []),
              )),
            ),
          ),
        ],
        expected: [],
      ),
    )
    as "the fixture operation must commit"
  id
}

fn an_op_id(seed: Int) -> OpId {
  let #(id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 1000), seed:))
  id
}

fn an_entry_id() -> EntryId {
  let #(id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 1000), seed: 13))
  id
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

fn text_of(injected: message.AgentMessage) -> String {
  case injected {
    message.UserMessage(content: [message.UserText(text:, ..)], ..) -> text
    _other -> ""
  }
}

fn hanging_provider() -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 30_000, request: fn(_spec) {
    stream.immediate(events: process.new_subject(), cancel: fn() { Nil })
  })
}

fn refusing_tools() -> effects.ToolSurface {
  effects.ToolSurface(
    clear: fn(_query) {
      effects.ClearanceRefused(reason: "no tools in this harness")
    },
    run: fn(_run) { effects.ToolFailed(reason: "no tools in this harness") },
    replay_still_safe: fn(_name) { False },
    execution_mode: fn(_name) { effects.ExclusiveExecution },
  )
}

fn start_entropy() -> Result(fn() -> Int, String) {
  otp_actor.new(1)
  |> otp_actor.on_message(fn(next, reply) {
    process.send(reply, next)
    otp_actor.continue(next + 1)
  })
  |> otp_actor.start
  |> result.map(fn(counter) {
    fn() { process.call(counter.data, waiting: 1000, sending: fn(r) { r }) }
  })
  |> result.replace_error("the entropy counter did not start")
}
