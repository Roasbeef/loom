//// The triggered-rule scanner: one session-scoped actor that watches
//// the durable commit stream and injects a project rule the first time
//// model output trips one of its triggers.
////
//// ## What feeds it, and why that and not the deltas
////
//// The scanner subscribes to the StorageWriter's post-commit
//// publication, exactly as `client/gateway`'s commit forwarder does, and
//// then pulls its truth from the session store. Hints are lossy and
//// carry nothing; a dropped one costs latency and the next commit —
//// or the next rule that fires — makes it up.
////
//// Design §8 describes a scanner "fed by the streaming parse", and this
//// is deliberately not that. Deltas are ephemeral display data by
//// contract: the runtime's effect process collects and discards them,
//// and the simulation provider emits none at all, so a delta-fed
//// scanner could not be tested by the harness that has to prove it.
//// Worse, it would decide from bytes that exist nowhere durable, which
//// is the one thing the runtime's hooks are forbidden to do. And it
//// would buy nothing: an injection can only reach the model at the next
//// checkpoint, and the settled assistant entry commits *before* that
//// checkpoint — so scanning the entry fires at the same moment scanning
//// the deltas would have delivered.
////
//// ## What it does on a hint
////
//// One pass over every strand the store knows. For each, three cheap
//// questions before any work: has every configured rule already fired
//// here (then the strand is finished, forever); has the branch moved at
//// all since the last pass; and is there a fire still waiting to be
//// retried. Only then does it scan — a branch scan clipped by the
//// strand's cursor, so a pass over a quiet strand fetches nothing.
////
//// A rule fires when any of its triggers occurs literally in the
//// visible text of a new assistant entry (`client/rules`). The fire is
//// a single transaction: the fenced injection joins the strand's open
//// run as a steer item and the rule's write-once fired-mark lands in the
//// same commit, expecting the mark absent. That is the whole
//// at-most-once argument — a scanner that crashed between deciding and
//// writing re-decides after its restart and loses the race to its own
//// earlier self. At-most-once and not exactly-once: an abort that lands
//// after the fire and before the checkpoint that would drain it
//// destroys the queued injection while the mark stands, which spends
//// the rule on text the model never saw. Admission time cannot see an
//// abort coming, so the corner is recorded (`docs/spec-gaps.md`) rather
//// than defended.
////
//// ## An idle strand holds; it does not start a run
////
//// A rule that fires when the strand has no open run is **held, not
//// dropped and not started**. Starting a run would let a project rule
//// wake a session nobody is talking to, turning a note about style into
//// a provider request an operator never asked for — and rules would
//// then be able to keep a session running indefinitely, one fire at a
//// time. Dropping would be worse in the other direction: the rule is
//// spent silently and no mark records it, so an operator would see a
//// configured rule that never fires and nothing saying why.
////
//// Holding is expressed by *not advancing the cursor*: the matching
//// entry stays above it, so the next pass finds it again. The next run
//// on that strand begins by committing the user's own message, which
//// moves the leaf, which brings the scanner back — and by then there is
//// an open run to steer. Nothing extra is needed to remember the hold,
//// which is why it is stored this way.
////
//// ## A dead hold is abandoned, not retried forever
////
//// The section above is honest for a root strand, or for any subagent
//// still capable of receiving a fresh run: retried every pass, forever,
//// at the ordinary cost of one bounded re-scan. It is not honest for a
//// subagent that will *never run again* — issue #113's case — because
//// nothing else here ever un-freezes that cursor: every later pass
//// re-fetches up to `scan_limit` entries and re-attempts the fire
//// through the writer, permanently, for a rule the strand can no longer
//// receive.
////
//// **What "provably dead" means.** A held strand is provably dead when
//// its `runtime/lineage` cell exists, decodes, and its own `reaped`
//// field is `True` — the durable mark `client/agency`'s lazy reap
//// enforcement writes once it has decided, from an overdue deadline or
//// the parent's run ending undetached, to end the child and re-issue
//// the abort until it lands. That is the harness's own record that it
//// will not intentionally hand the strand more work, and it is the only
//// signal this module trusts.
////
//// **Why a terminal `last_result` alone is not this signal.**
//// `runtime/api.send_to_strand` starts a fresh run (`Delivery.Started`)
//// when its target is idle, and `client/agency`'s own module doc rules
//// that a parent handing an idle child more work is a live agent's
//// explicit decision made inside its own run — refused only *upward*,
//// into a finished parent, never downward into a finished child. A
//// strand with a terminal result can still be one a live ancestor sends
//// fresh work to tomorrow, so treating "finished" alone as dead would
//// silence a rule on a strand that might fire again — exactly what FAIL
//// OPEN exists to prevent. Only the ledger's own decision to end a
//// strand counts, never the machine layer's record of what it last did.
////
//// The `reaped` mark is not a mechanical guarantee either — nothing in
//// `client/agency`'s downward `send` checks it, so a live ancestor that
//// still remembers the child's name (from an earlier `agent_roster`,
//// say) could in principle hand it fresh work after the reap. That
//// residual is real and named rather than defended: it needs a model to
//// deliberately address a strand its own tooling already reports as
//// finished, and the alternative — trusting nothing short of provable
//// impossibility — is the unbounded, permanent re-scan this module
//// exists to end. What the residual costs is precise: the rule that
//// was already matched and held stays silent on that fresh run, since
//// the strand is abandoned and the match is never re-judged. It is not
//// mitigated by `scannable_text`'s exclusion of `Aborted` entries —
//// that bounds *new* matches, and the harm here needs no new history,
//// only an open run.
////
//// **Fail open at every branch.** No lineage cell (a root strand, or a
//// subagent whose cell has not landed yet) and a cell that fails to
//// decode both keep the hold ordinary — retried, never abandoned. Only
//// a cleanly decoded `reaped: True` moves a strand out of the pass.
////
//// **Abandoned, not finished.** Judging a strand dead does not empty
//// its pending rule list — that would claim the rules fired, and they
//// never did. `Progress` instead carries a third `Hold` state,
//// `Abandoned`, beside `Holding` and `NotHeld`, so the scanner can
//// short-circuit the strand exactly where a genuinely finished one
//// already is (every rule fired) without lying about which case this
//// is. The one transition into it is logged once, `rule.hold_abandoned`,
//// naming the strand and the rules left forever pending: the
//// operator-facing record that a rule's silence here is a verdict, not
//// a bug.
////
//// **What this costs.** The lineage read happens only on the pass a
//// hold *begins* — `NotHeld` to `Holding` — never on a pass that finds a
//// hold already open, and never on a strand that is not currently held.
//// So a strand pays it at most once per scanner incarnation: zero for a
//// strand that never holds, one for a strand that holds and turns out
//// still alive (after which the ordinary per-pass hold-retry cost
//// resumes, unrelated to this check), and one — followed by nothing at
//// all, ever again this incarnation — for a strand judged dead.
//// Amortized over the life of a hold that never resolves, which is the
//// shape #113 is about, that one read is the entire cost.
////
//// ## Isolation
////
//// Every read here goes straight to the session store, never through
//// the writer's mailbox, so a slow pass cannot sit in front of a
//// settlement. The only thing the scanner sends the writer is the fire
//// itself, which is an ordinary queue admission on the scanner's own
//// process. It is a restartable service (`client/serve`'s service
//// supervisor): killing it mid-turn costs the pass in flight and
//// nothing else, and the replacement rebuilds its cursors from the
//// durable marks.

import client/rules.{type Rule}
import core/clock
import core/entry.{type Entry}
import core/ids.{type EntryId, type Seq}
import core/json.{type JsonValue}
import core/message
import core/register
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import runtime/api.{type Runtime}
import runtime/lineage
import runtime/writer
import session/session
import storage/storage
import telemetry/field
import telemetry/log.{type Logger}
import weft/actor
import weft/registry as address

/// The most new entries one strand contributes to one pass.
///
/// A bound on the work a single hint can cause, not on what the scanner
/// will eventually see: whatever the limit leaves behind stays above the
/// cursor and is judged by the next pass, and a session generates far
/// more hints than it does assistant entries. It matters on a cold start
/// against a long existing history, which is the one place an unbounded
/// pass would fetch and decode thousands of rows before the first hint
/// was answered.
pub const default_scan_limit = 256

/// How far the in-memory cursor may run ahead of the durable one before
/// the scanner writes a checkpoint.
///
/// The durable cursor is a checkpoint, not a position of record — the
/// fired-marks are what make a replay safe, so a cursor that lags costs
/// a bounded re-scan and nothing else. Checkpointing every entry would
/// put an extra commit behind every assistant message for a feature that
/// usually never fires, which is precisely the cost design §8 says a
/// dormant rule must not have.
pub const default_checkpoint_every = 64

/// What the scanner watches for and how loudly it works.
///
/// Constructor invariants: `rules` is the parsed, validated rule list
/// (`client/rules.parse`) — an empty list makes every pass a no-op;
/// `scan_limit` and `checkpoint_every` are positive.
pub type Options {
  Options(
    rules: List(Rule),
    logger: Logger,
    scan_limit: Int,
    checkpoint_every: Int,
  )
}

/// The shipped options for a rule list: a silent logger and the two
/// bounds above.
///
/// ## Examples
///
/// ```gleam
/// // rulescan.default_options(parsed_rules)
/// ```
///
pub fn default_options(rules: List(Rule)) -> Options {
  Options(
    rules:,
    logger: log.discard(),
    scan_limit: default_scan_limit,
    checkpoint_every: default_checkpoint_every,
  )
}

/// Sets the logger the scanner reports fires and refusals on.
///
/// ## Examples
///
/// ```gleam
/// // rulescan.default_options(rules) |> rulescan.with_logger(logger)
/// ```
///
pub fn with_logger(options: Options, logger: Logger) -> Options {
  Options(..options, logger:)
}

// What one strand's scanning knows between passes. Held in the actor
// rather than in a process per strand: with the commit stream as the
// feed there is no streaming load to shard, and "per-strand" in design
// §8 was about the scanning, which stays per-strand by key.
type Progress {
  // The newest entry seq this scanner has judged on this strand.
  Progress(
    scanned: Seq,
    // The newest seq written to the durable checkpoint.
    checkpointed: Seq,
    // The leaf the last pass saw, so an unmoved branch is skipped
    // without a scan. `None` on a strand first seen this incarnation,
    // which is why a fresh `Progress` never skips.
    leaf: Option(EntryId),
    // Whether a rule currently sits matched-and-unfired here, and — see
    // `Hold` — whether the scanner has already judged that hold dead.
    hold: Hold,
    // The names of the rules that have not yet fired here. Empty means
    // the strand is finished and costs nothing from now on. Non-empty
    // under `Abandoned` on purpose: those rules never fired and this
    // list says so honestly.
    pending: List(String),
  )
}

// A held rule's strand, and whether the scanner still owes it a retry.
//
// `Abandoned` is not "finished" — `Progress.pending` stays non-empty,
// because the rules genuinely never fired. It exists purely to buy back
// the short-circuit `finished` already gives a strand every rule has
// fired on. See the module doc's "A dead hold is abandoned" section for
// what makes a hold provably dead and why a terminal `last_result` alone
// does not.
type Hold {
  // No rule is currently matched-and-unfired here.
  NotHeld

  // A rule matched and could not be admitted; the strand may yet open a
  // run, so the next pass retries.
  Holding

  // The held strand was judged dead on the pass its hold began — the one
  // lineage read this incarnation pays for it. No later pass looks at
  // this strand again.
  Abandoned
}

type State {
  State(options: Options, runtime: Runtime, progress: Dict(String, Progress))
}

/// Starts the scanner under `name`, watching `runtime`'s session.
///
/// Register it as a writer subscriber **by name**
/// (`api.Options.subscribers`), not by the subject this returns: a
/// restart re-registers under the same name and keeps the subscription,
/// and the writer skips a subscriber whose name is momentarily
/// unregistered, so the restart window costs hints rather than commits.
///
/// ## Examples
///
/// ```gleam
/// // rulescan.start(rulescan.default_options(rules), runtime, name)
/// ```
///
pub fn start(
  options: Options,
  runtime: Runtime,
  name: address.Address(writer.Event),
) -> actor.StartResult(Subject(writer.Event)) {
  actor.new(State(options:, runtime:, progress: dict.new()))
  |> actor.on_message(handle)
  |> actor.addressed(name)
  |> actor.start
}

/// The scanner as a supervision child, which is how a host should wire
/// it — in the restartable tier, beside the commit forwarder.
///
/// ## Examples
///
/// ```gleam
/// // sup.add(builder, rulescan.supervised(options, runtime, name))
/// ```
///
pub fn supervised(
  options: Options,
  runtime: Runtime,
  name: address.Address(writer.Event),
) -> ChildSpecification(Subject(writer.Event)) {
  supervision.worker(fn() { start(options, runtime, name) })
}

fn handle(
  state: State,
  _event: writer.Event,
) -> actor.Next(State, writer.Event) {
  actor.continue(pass(state))
}

// One pass over every strand. A store read that fails is not an error
// worth stopping for: hints are lossy by contract, so the pass simply
// ends and the next commit brings the scanner back.
fn pass(state: State) -> State {
  use <- bool.guard(when: state.options.rules == [], return: state)
  case session.register_keys(state.runtime.session, register.StrandLeaf, "") {
    Error(_reason) -> state
    Ok(names) -> list.fold(names, state, scan_strand)
  }
}

fn scan_strand(state: State, strand: String) -> State {
  let known = dict.get(state.progress, strand)
  use <- bool.guard(when: finished(known), return: state)
  case leaf_of(state, strand) {
    Error(Nil) | Ok(None) -> state
    Ok(Some(leaf)) -> scan_from(state, strand, leaf, progress_for(known))
  }
}

// A strand every configured rule has already fired on, or a held strand
// the scanner has judged provably dead (`Abandoned`). Nothing further
// can happen at either — the first because nothing is left to fire, the
// second because the strand it was waiting on will not run again — so
// both are dropped from the pass entirely, without even a leaf read.
// That is what keeps a long session's steady-state cost at one register
// read per strand and then zero, and an abandoned hold's cost at the one
// lineage read that abandoned it and then zero as well.
fn finished(known: Result(Progress, Nil)) -> Bool {
  case known {
    Error(Nil) -> False
    Ok(progress) -> progress.pending == [] || progress.hold == Abandoned
  }
}

// A strand first seen this incarnation gets the blank progress, whose
// `None` leaf is the flag `scan_from` reads as "load me from the store".
// Nothing else can produce a `None` leaf there: every pass that reaches
// `judge` records the leaf it scanned.
fn progress_for(known: Result(Progress, Nil)) -> Progress {
  case known {
    Ok(progress) -> progress
    Error(Nil) ->
      Progress(
        scanned: 0,
        checkpointed: 0,
        leaf: None,
        hold: NotHeld,
        pending: [],
      )
  }
}

fn scan_from(
  state: State,
  strand: String,
  leaf: EntryId,
  progress: Progress,
) -> State {
  let progress = case progress.leaf {
    Some(_seen) -> progress
    None -> load_progress(state, strand, progress)
  }

  // Nothing new on this branch, and nothing waiting to be retried.
  // `progress.hold` is `NotHeld` or `Holding` here — never `Abandoned`,
  // which `finished` already keeps out of `scan_from` entirely.
  use <- bool.guard(
    when: progress.leaf == Some(leaf) && progress.hold == NotHeld,
    return: state,
  )
  case new_entries(state, leaf, progress.scanned) {
    Error(Nil) -> state
    Ok(entries) -> judge(state, strand, leaf, progress, entries)
  }
}

// The durable half of a strand's state, read once per incarnation: how
// far the last scanner got, and which rules it had already spent.
fn load_progress(state: State, strand: String, blank: Progress) -> Progress {
  let scanned = rules.cursor_seq(read_fact(state, rules.cursor_key(strand:)))
  let pending =
    state.options.rules
    |> list.filter(fn(rule) {
      read_fact(state, rules.fired_key(strand:, rule: rule.name)) == None
    })
    |> list.map(fn(rule) { rule.name })
  Progress(..blank, scanned:, checkpointed: scanned, pending:)
}

fn judge(
  state: State,
  strand: String,
  leaf: EntryId,
  progress: Progress,
  entries: List(Entry),
) -> State {
  let texts = list.filter_map(entries, scannable)
  let firing =
    list.filter(state.options.rules, fn(rule) {
      list.contains(progress.pending, rule.name)
      && list.any(texts, rules.fires_on(rule, _))
    })
  let #(spent, held) = fire_all(state, strand, firing)
  let pending =
    list.filter(progress.pending, fn(name) { !list.contains(spent, name) })
  let hold = next_hold(state, strand, progress.hold, held, pending)

  // A held or abandoned fire freezes the cursor: the entry that matched
  // must still be above it on the next pass, or the rule is lost — and
  // an abandoned strand never gets a next pass to lose it on, but the
  // cursor stays honest regardless of which case this is.
  let scanned = case hold {
    Holding | Abandoned -> progress.scanned
    NotHeld -> newest(entries, progress.scanned)
  }
  let checkpointed =
    checkpoint(state, strand, scanned, progress.checkpointed, pending)
  let progress =
    Progress(scanned:, checkpointed:, leaf: Some(leaf), hold:, pending:)
  State(..state, progress: dict.insert(state.progress, strand, progress))
}

// The hold transition for one pass, and the one place a fresh hold pays
// for a lineage read. `was` is `Holding` or `NotHeld` on every call that
// can reach here — `finished` keeps `Abandoned` out of `judge` entirely —
// so the only transition that can newly enter `Abandoned` is `NotHeld`
// to `Holding`. A hold already open on the last pass this incarnation
// saw is never rechecked, which is the whole of "once per incarnation
// per strand" (see the module doc). `Abandoned` itself is handled only
// so this `case` is exhaustive over `Hold`, not because it is reachable.
fn next_hold(
  state: State,
  strand: String,
  was: Hold,
  held: Bool,
  pending: List(String),
) -> Hold {
  case was {
    Abandoned -> Abandoned
    Holding ->
      case held {
        True -> Holding
        False -> NotHeld
      }
    NotHeld ->
      case held {
        False -> NotHeld
        True -> begin_hold(state, strand, pending)
      }
  }
}

// A hold that begins is the one state an operator cannot read off the
// fired-marks: the rule is configured, matched, and waiting on a run
// that may never open. Judged once, here, against the lineage ledger —
// see `provably_dead` for what "dead" means and why FAIL OPEN keeps
// every doubtful case merely held.
fn begin_hold(state: State, strand: String, pending: List(String)) -> Hold {
  case provably_dead(state, strand) {
    True -> {
      // The rule names travel with the verdict: this line is the only
      // record an operator gets that these rules will never fire here,
      // and a verdict that does not say what it silenced is not one.
      log.info(state.options.logger, "rule.hold_abandoned", [
        field.text(key: "strand", value: strand),
        field.text(key: "rules", value: string.join(pending, with: ", ")),
      ])
      Abandoned
    }
    False -> {
      log.info(state.options.logger, "rule.holding", [
        field.text(key: "strand", value: strand),
      ])
      Holding
    }
  }
}

// Whether the ledger itself says this strand was reaped — the honest
// signal a held strand will never run again (module doc). FAIL OPEN at
// both branches: no cell (a root strand, or a subagent whose cell has
// not landed yet) and a cell that will not decode both answer `False`,
// because an operator's rule must never be silenced on a strand that
// might still be given a run.
fn provably_dead(state: State, strand: String) -> Bool {
  case read_fact(state, lineage.register_key(strand)) {
    None -> False
    Some(payload) ->
      case lineage.decode(payload) {
        Ok(cell) -> cell.reaped
        Error(_report) -> False
      }
  }
}

fn scannable(entry: Entry) -> Result(String, Nil) {
  option.to_result(rules.scannable_text(entry), Nil)
}

fn newest(entries: List(Entry), floor: Seq) -> Seq {
  list.fold(entries, floor, fn(highest, entry: Entry) {
    int.max(highest, entry.seq)
  })
}

// --- firing ----------------------------------------------------------------

type Fire {
  // The injection and the mark landed together.
  Fired

  // The mark was already there: an earlier incarnation, or a concurrent
  // pass, did this. The rule is spent either way.
  AlreadyFired

  // No open run to steer. The cursor stays put and the next run gets it.
  Held

  // Anything else — a stolen lease, an unreadable register. Treated like
  // a hold, so the next pass tries again rather than losing the rule.
  Failed(reason: String)
}

fn fire_all(
  state: State,
  strand: String,
  firing: List(Rule),
) -> #(List(String), Bool) {
  list.fold(firing, #([], False), fn(outcome, rule) {
    let #(spent, held) = outcome
    case fire(state, strand, rule) {
      Fired | AlreadyFired -> #([rule.name, ..spent], held)
      Held | Failed(..) -> #(spent, True)
    }
  })
}

fn fire(state: State, strand: String, rule: Rule) -> Fire {
  let target = api.on_strand(state.runtime, strand)
  let mark =
    api.Mark(
      key: rules.fired_key(strand:, rule: rule.name),
      value: rules.fired_value(rule),
    )
  let admitted = api.steer_marking(target, injection(state, rule), mark:)
  let verdict = classify(admitted)
  report(state, strand, rule, verdict)
  verdict
}

// The injected turn. A user-role message because that is the only shape
// a provider API has for context the harness supplies; the text itself
// says whose it is, which is `client/rules.injection`'s whole job.
fn injection(state: State, rule: Rule) -> message.AgentMessage {
  let #(now, _clock) = clock.read(state.runtime.effects.clock)
  message.UserMessage(
    content: [
      message.UserText(text: rules.injection(rule), text_signature: None),
    ],
    timestamp: now,
  )
}

fn classify(admitted: Result(EntryId, api.ApiError)) -> Fire {
  case admitted {
    Ok(_entry) -> Fired

    // The mark moved between the read and the commit: somebody already
    // fired this rule on this strand, which is exactly what the
    // write-once expectation was asked to find out.
    Error(api.FactConflict(..)) -> AlreadyFired
    Error(api.QueueRejected(..)) | Error(api.RuntimeUnavailable) -> Held
    Error(api.AcceptRejected(..))
    | Error(api.ReadFailed(..))
    | Error(api.CommitFailed(..))
    | Error(api.SessionStolen(..))
    | Error(api.RaceLost)
    | Error(api.ReservedFactKey(..))
    | Error(api.UnreservedFactKey(..))
    | Error(api.EscalationExists(..))
    | Error(api.EscalationNotFound(..))
    | Error(api.EscalationWrongStatus(..)) ->
      Failed(reason: string.inspect(admitted))
  }
}

fn report(state: State, strand: String, rule: Rule, verdict: Fire) -> Nil {
  let where = [
    field.text(key: "rule", value: rule.name),
    field.text(key: "strand", value: strand),
  ]
  case verdict {
    Fired -> log.info(state.options.logger, "rule.fired", where)

    // Neither of these is a fault: one is another incarnation having
    // won, the other is a rule waiting for a run to exist.
    AlreadyFired | Held -> Nil
    Failed(reason:) ->
      log.warn(state.options.logger, "rule.injection_refused", [
        field.text(key: "reason", value: reason),
        ..where
      ])
  }
}

// --- durable reads and the checkpoint --------------------------------------

// The cursor checkpoint, written only when the scanner has run far
// enough ahead of it to be worth the commit, and never on a strand whose
// rules have all fired (nothing will read it again).
fn checkpoint(
  state: State,
  strand: String,
  scanned: Seq,
  checkpointed: Seq,
  pending: List(String),
) -> Seq {
  let due =
    pending != [] && scanned - checkpointed >= state.options.checkpoint_every
  use <- bool.guard(when: !due, return: checkpointed)
  case
    api.put_reserved_fact(
      state.runtime,
      rules.cursor_key(strand:),
      rules.cursor_value(scanned),
    )
  {
    Ok(Nil) -> scanned

    // A checkpoint that would not commit is not worth a retry: the next
    // pass will be further ahead and try again, and the fired-marks are
    // what a restart actually depends on.
    Error(_reason) -> checkpointed
  }
}

fn leaf_of(state: State, strand: String) -> Result(Option(EntryId), Nil) {
  case session.strand_leaf(state.runtime.session, strand) {
    Ok(Some(session.Cell(value: leaf, ..))) -> Ok(leaf)
    Ok(None) -> Ok(None)
    Error(_reason) -> Error(Nil)
  }
}

// New entries on the strand's branch, oldest first, clipped by the
// cursor before anything is fetched or decoded. Read straight from the
// store rather than through the writer: this runs on the scanner's own
// process, and a settlement must never queue behind a scan.
fn new_entries(
  state: State,
  leaf: EntryId,
  after: Seq,
) -> Result(List(Entry), Nil) {
  let q =
    storage.branch_scan(from: leaf)
    |> storage.branch_kind(storage.Message)
    |> storage.branch_order(storage.OldestFirst)
    |> storage.branch_cursor(after)
    |> storage.branch_limit(state.options.scan_limit)
  storage.scan_branch(state.runtime.session.store, q)
  |> result.replace_error(Nil)
}

fn read_fact(state: State, key: String) -> Option(JsonValue) {
  storage.get_register(state.runtime.session.store, register.FactCustom, key)
  |> result.unwrap(None)
  |> option.map(fn(cell: storage.Register) { cell.value.payload })
}
