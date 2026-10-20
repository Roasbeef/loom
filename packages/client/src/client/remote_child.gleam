//// The parent session's durable record of children that run on another
//// orchestrator (protocol-change/084, slice S3).
////
//// A local child is a strand of the parent's own session, so the Agency learns
//// what it needs from that strand's registers. A remote child has no strand
//// here. What the parent holds instead is a stub per child, in its own session
//// store under the reserved prefix `runtime/api.remote_child_fact_prefix`, and
//// this module is the stub's vocabulary and the rules for moving it.
////
//// ## The stub
////
//// `remote-child/{call site digest}` is written before the first `Spawn` is
//// sent, and it holds the whole request. That is what lets a drainer resend the
//// `Spawn` without the model, routes every retry of the call site to the same
//// orchestrator, and means a failure of the other orchestrator never turns into
//// a local spawn. The stub is itself the pending row: while it is `Requested`
//// the spawn is owed, and nothing else records that. Peer mail's outbox rows have
//// a fixed shape and an hour's time to live, and neither fits (the design note,
//// section 8.4), so these rows are their own facts.
////
//// A stub moves forward only: `Requested` becomes `Spawned` when the
//// orchestrator answers with a handle, or `Refused` when it says no; `Spawned`
//// becomes `Settled` when a join reports the child finished. Every step is a
//// compare-and-set that refuses to move a stub that has already left the state
//// the step starts from, because two writers can race here by design: the
//// effect process that asked and the drainer that resends it both hear the same
//// answer, and a late `Spawned` must not undo a `Settled`. The one move that goes
//// back is `Refused` to `Spawned`: an answer that names a child means the child
//// exists, and a stub must not be left refusing a child that is running.
////
//// A refusal never removes a stub. The effect process that hears one and the
//// drainer that hears one both record `Refused` and leave the stub, because a
//// refusal can be transient (a cap that clears, a store that recovers) and a
//// second asker of the same call site can still be answered with a child. If the
//// stub had been deleted, that child would exist on the other orchestrator with
//// a lineage cell here and no stub to count it, list it or wait on it. A
//// `Refused` stub does not count against the caps and shows in the roster as
//// refused.
////
//// The lineage cell of a remote child is written with the `Spawned` step,
//// before the stub, so that by the time anything shows the model a handle the
//// addressing rule already holds the child as a descendant.
////
//// ## Liveness
////
//// A `Spawned` stub counts against the fan-out caps while its child may be
//// running, and `is_live` says so from the stub and the time alone: a child
//// whose deadline has passed is not running, so a stub frees its slot by
//// deadline without a network call. A child that finishes sooner is settled by a
//// join, which a wait sends or the drainer sends when nobody waits
//// (`client/remote_drain`). The stub does not keep the join's report: a later
//// `agent_wait` reads it again from the other orchestrator.
////
//// ## Flow
////
//// `admit` → `spawned` | `refused` → `settled`
////
//// 1. `admit` writes the stub for a call site, or hands back the one a replay
////    or an earlier attempt already wrote.
//// 2. `spawned` and `refused` apply the orchestrator's answer to a `Requested`
////    stub, whoever heard it.
//// 3. `settled` records a join's report on a `Spawned` stub.
//// 4. `usage_by_orchestrator` and `settled_tokens` read what the settled stubs
////    cost, for the status bar and for a goal's budget, and `agents` projects
////    the stubs into the rows an agent strip lists (protocol-change/090).
////
//// Every write publishes a data-free `RemoteChildrenChanged` on the session's
//// bus after it lands, and the gateway pushes the session's remote children to
//// its clients on hearing it (protocol-change/090).

import client/peer_mail
import client/remote_escalation_store
import client/remote_reach.{type Reach}
import client/remote_spawn.{type ChildUsage, type Parent}
import core/corruption
import core/glance.{type Glance}
import core/ids.{type OpId}
import core/json.{type JsonValue}
import events/bus
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import runtime/lineage
import session_view/remote_agent.{type RemoteAgent}
import session_view/remote_transcript
import tools/agent.{type Handle, type Outcome}

/// How many times a step re-reads and retries after losing a compare-and-set.
/// Two writers race here, so one retry is the usual worst case; the bound only
/// keeps a corrupt cell from looping.
const step_attempts = 4

/// A child as the parent's session records it.
pub type Stub {
  Stub(
    /// The `[orchestrators.<name>]` the child runs on.
    orchestrator: String,
    /// The parent strand that asked, in this session.
    strand: String,
    /// The parent's planned call, which the receiving orchestrator derives the
    /// child's name from.
    site: remote_spawn.CallSite,
    /// The parent's depth, which the receiving spawner's `max_depth` is checked
    /// against.
    depth: Int,
    /// The tools the parent held when it asked.
    parent_tools: List(String),
    /// What the parent asked for.
    request: remote_spawn.Request,
    /// The strand name the child has on the other orchestrator, derived from the
    /// call site. It is what the roster calls a child that has no handle yet.
    name: String,
    /// The newest glance the remote pushed for this child, or `None` before the
    /// first one. It belongs to the stub and not to a state: a glance can arrive
    /// while the stub is still `Requested`, and the answer to the `Spawn` that
    /// follows must not lose it.
    glance: Option(Glance),
    /// When the newest glance reached this session, in Unix milliseconds on
    /// this session's clock, zero before the first one. The glance's own `at`
    /// is the other orchestrator's clock and is never compared with this one;
    /// the roster says how old the glance is from this figure alone
    /// (protocol-change/090).
    glance_seen_ms: Int,
    /// How many messages a settled child still had undelivered on its
    /// orchestrator when a join last said, zero until then. See
    /// `remote_spawn.Joined`.
    owed: Int,
    /// How far the spawn has got.
    state: State,
  )
}

/// How far a spawn has got.
pub type State {
  /// The `Spawn` is owed: it was sent or is about to be, and no answer has been
  /// recorded. The child may exist.
  Requested

  /// The orchestrator started the child, or adopted the one this call site had
  /// already started.
  Spawned(placed: Placed)

  /// A join reported the child's run finished.
  Settled(placed: Placed, outcome: Outcome, usage: ChildUsage)

  /// The orchestrator refused the spawn and created nothing. The reason is its
  /// own, worded for the model.
  Refused(reason: String)
}

/// What the orchestrator answered when it started a child.
pub type Placed {
  Placed(
    /// The child's strand and the operation that runs it.
    handle: Handle,
    /// The tools the child holds.
    tools: List(String),
    /// The child's catalogue name on the other orchestrator.
    model: String,
    /// The provider model identifier behind that name.
    model_id: String,
    /// When the child's deadline falls, as an instant on this session's clock.
    /// The other orchestrator reports a duration and clocks never cross as
    /// instants, so this is the time left at the moment of the answer added to
    /// the time the answer was read. It is later than the other orchestrator's
    /// own deadline by the time the answer took to arrive, which errs toward
    /// counting the child as running for a moment too long. It is what shows in
    /// the roster, and `is_live` reads it to stop counting a child that can no
    /// longer be running.
    deadline_ms: Int,
  )
}

/// A stub with the key it is stored under.
pub type Kept {
  Kept(key: String, stub: Stub)
}

/// Whether the stub the caller asked for was already there.
pub type Admission {
  /// The stub was written now.
  Fresh

  /// A stub for this call site already existed, and is what a replay or an
  /// earlier attempt wrote.
  Existing(stub: Stub)
}

/// The key of the stub for one call site, from `agent.call_site_digest`.
///
/// ## Examples
///
/// ```gleam
/// assert remote_child.stub_key("7b1c0a4e2d95f318") == "remote-child/7b1c0a4e2d95f318"
/// ```
pub fn stub_key(digest: String) -> String {
  api.remote_child_fact_prefix <> digest
}

/// Whether a stub still counts against the fan-out caps at `now`: its child is,
/// or may be, running. A stub whose remote has not answered counts, which errs
/// toward refusing a spawn. A `Spawned` stub counts until its child's deadline
/// passes, and after that it does not, whatever the other orchestrator says or
/// cannot be asked: the deadline is the bound on how long a child runs, so a
/// stub frees its slot by the clock alone, with no message to a machine that may
/// be down.
///
/// ## Examples
///
/// ```gleam
/// assert remote_child.is_live(stub_in_state(remote_child.Requested), 1000)
/// ```
pub fn is_live(stub: Stub, now: Int) -> Bool {
  case stub.state {
    Requested -> True
    Spawned(placed:) -> placed.deadline_ms > now
    Settled(..) | Refused(..) -> False
  }
}

/// The parent a message about this stub names, given the session it is in.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.parent_of(stub, "0198c0de-0000-7000-8000-000000000001")
/// ```
pub fn parent_of(stub: Stub, session: String) -> Parent {
  remote_spawn.Parent(session:, strand: stub.strand)
}

// --- the records ------------------------------------------------------------

/// Writes the stub for a call site unless one is there.
///
/// The write expects the cell to be absent, so two attempts that race through
/// the gap cannot both write: the loser reads what the winner wrote and returns
/// it as `Existing`. A replayed `agent_spawn` and the first attempt that was
/// interrupted both arrive here and both get the same stub.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.admit(runtime, remote_child.stub_key(digest), stub) == Ok(remote_child.Fresh)
/// ```
pub fn admit(
  runtime: api.Runtime,
  key: String,
  stub: Stub,
) -> Result(Admission, String) {
  case
    api.put_reserved_fact_expecting(runtime, key, encode(stub), expected: None)
  {
    Ok(_) -> {
      changed(runtime)
      Ok(Fresh)
    }
    Error(api.FactConflict(..)) -> {
      use found <- result.try(read(runtime, key))
      case found {
        Some(#(existing, _seq)) -> Ok(Existing(existing))
        None -> Error("the remote child stub moved under the write")
      }
    }
    Error(error) -> Error(describe(error))
  }
}

/// Reads one stub.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.find(runtime, remote_child.stub_key(digest))
/// ```
pub fn find(runtime: api.Runtime, key: String) -> Result(Option(Stub), String) {
  read(runtime, key) |> result.map(option.map(_, fn(found) { found.0 }))
}

/// Every stub the session holds, with its key. A cell that does not decode is
/// left out: the listing feeds the fan-out count and the roster, and a corrupt
/// cell is a loss of information that no read can repair, while a listing that
/// faulted on it would refuse every spawn and every roster for the rest of the
/// session.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.all(runtime) == Ok([remote_child.Kept(key, stub)])
/// ```
pub fn all(runtime: api.Runtime) -> Result(List(Kept), String) {
  use cells <- result.map(
    api.reserved_facts(runtime, prefix: api.remote_child_fact_prefix)
    |> result.map_error(describe),
  )
  kept_of(cells)
}

/// The stubs among a session's reserved cells, in the order given. A cell that
/// does not decode is left out, for the reason `all` gives.
///
/// This is the half of `all` that needs no runtime, so a closed session file
/// read directly (`client/remote_release`) is decoded by the same rule.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.kept_of([#(key, remote_child.encode(stub))]) == [remote_child.Kept(key, stub)]
/// ```
pub fn kept_of(cells: List(#(String, JsonValue))) -> List(Kept) {
  list.filter_map(cells, fn(pair) {
    decode(pair.1) |> result.map(Kept(pair.0, _)) |> result.replace_error(Nil)
  })
}

/// The orchestrators that may hold a child for the session: those of every stub
/// that is not `Refused`, each once, in name order.
///
/// A `Requested` stub counts because its orchestrator may have started the child
/// and lost the reply, and a `Settled` one because the orchestrator still holds
/// the session the child ran in. A `Refused` stub made no child. Deleting the
/// parent session owes each of these a `Release`.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.holders([requested_on_box, refused_on_desk, settled_on_box]) == ["box"]
/// ```
pub fn holders(kept: List(Kept)) -> List(String) {
  kept
  |> list.filter_map(fn(entry) {
    case entry.stub.state {
      Requested | Spawned(..) | Settled(..) -> Ok(entry.stub.orchestrator)
      Refused(..) -> Error(Nil)
    }
  })
  |> list.unique
  |> list.sort(string.compare)
}

/// What the settled children of the session cost, one entry for each
/// orchestrator that ran one, in name order.
///
/// A stub keeps the usage its join reported when the child settled and nothing
/// before then, so a child that is still running adds nothing and a settled one
/// adds the same figure however often this is read. That is what lets a
/// total built from it be recomputed without counting a child twice.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.usage_by_orchestrator([settled_on_box]) == [#("box", usage)]
/// ```
pub fn usage_by_orchestrator(kept: List(Kept)) -> List(#(String, ChildUsage)) {
  kept
  |> list.filter_map(fn(entry) {
    case entry.stub.state {
      Settled(usage:, ..) -> Ok(#(entry.stub.orchestrator, usage))
      Requested | Spawned(..) | Refused(..) -> Error(Nil)
    }
  })
  |> list.group(fn(pair) { pair.0 })
  |> dict.to_list
  |> list.map(fn(group) {
    #(
      group.0,
      list.fold(group.1, no_usage(), fn(total, pair) {
        add_usage(total, pair.1)
      }),
    )
  })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

/// The tokens the settled children used, input plus output, over every
/// orchestrator. This is the figure a goal's budget counts, as the usage ledger's
/// rows count for the children that ran here.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.settled_tokens([settled_on_box, settled_on_desk]) == 1_300
/// ```
pub fn settled_tokens(kept: List(Kept)) -> Int {
  usage_by_orchestrator(kept)
  |> list.fold(0, fn(total, pair) { total + pair.1.input + pair.1.output })
}

fn no_usage() -> ChildUsage {
  remote_spawn.ChildUsage(
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cost: 0.0,
  )
}

fn add_usage(total: ChildUsage, more: ChildUsage) -> ChildUsage {
  remote_spawn.ChildUsage(
    input: total.input + more.input,
    output: total.output + more.output,
    cache_read: total.cache_read + more.cache_read,
    cache_write: total.cache_write + more.cache_write,
    cost: total.cost +. more.cost,
  )
}

/// The session's remote children as an agent strip lists them
/// (protocol-change/090), in the order the stubs are kept, at most
/// `remote_agent.max_children` of them and within the list's byte bound
/// (`remote_agent.within_bound`), with each row's words clipped to a strip's
/// line (`remote_agent.max_text_bytes`).
///
/// The standing is the stub's state, with a `Spawned` stub past its deadline
/// shown as expired, since `is_live` no longer counts it and no join has said
/// how it ended. The title is the newest glance's when there is one, and the
/// purpose the spawn asked for before it. A glance's age is measured on this
/// session's clock from when it arrived (`Stub.glance_seen_ms`), never from the
/// other orchestrator's `at`, so `now` is this session's clock. Nothing here
/// asks the other orchestrator: the strip shows what the stubs hold, however
/// long ago it arrived.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.agents([spawned_on_box], now)
/// // == [RemoteAgent(id: "sub:^main/build-turn-1-0", orchestrator: "box", standing: Running, ..)]
/// ```
pub fn agents(kept: List(Kept), now: Int) -> List(RemoteAgent) {
  kept
  |> list.take(remote_agent.max_children)
  |> list.map(fn(entry) { agent_of(entry.stub, now) })
  |> remote_agent.within_bound
}

fn agent_of(stub: Stub, now: Int) -> RemoteAgent {
  let standing = case stub.state {
    Requested -> remote_agent.Starting
    Spawned(..) ->
      case is_live(stub, now) {
        True -> remote_agent.Running
        False -> remote_agent.Expired
      }
    Settled(outcome: agent.Completed, ..) -> remote_agent.Completed
    Settled(..) -> remote_agent.Stopped
    Refused(..) -> remote_agent.Refused
  }
  let model = case stub.state {
    Spawned(placed:) | Settled(placed:, ..) -> placed.model
    Requested | Refused(..) -> ""
  }
  let title = case stub.glance {
    Some(seen) if seen.title != "" -> seen.title
    Some(_) | None -> stub.request.purpose
  }
  remote_agent.RemoteAgent(
    id: stub.name,
    parent: stub.strand,
    orchestrator: stub.orchestrator,
    standing:,
    title: glance.clip(title, remote_agent.max_text_bytes),
    summary: case stub.glance {
      Some(seen) -> glance.clip(seen.summary, remote_agent.max_text_bytes)
      None -> ""
    },
    tokens: case stub.glance {
      Some(seen) -> int.max(0, seen.tokens)
      None -> 0
    },
    model: glance.clip(model, remote_agent.max_text_bytes),
    age_ms: case stub.glance, stub.glance_seen_ms {
      Some(_), seen if seen > 0 -> Some(int.max(0, now - seen))
      Some(_), _ | None, _ -> None
    },
  )
}

/// The reader a session's gateway asks for a page of a remote child's
/// transcript (protocol-change/090), given the child's name as `agents` lists
/// it and the cursor. It finds the child's stub by that name, so a name that is
/// not a child of this session reads nothing, and asks the child's
/// orchestrator through `reach`. The answer is the page as its wire object, or
/// the reason there is none in words for a person: a spawn that was not
/// answered or was refused has no transcript, and a refusal from the other
/// orchestrator, such as a spawner that keeps transcripts there, is passed on.
///
/// It is called in the gateway's observation task and waits on the network
/// there, never in the hub or the Agency's holder.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.history_reader(runtime, reach)("sub:^main/build-turn-1-0", 0)
/// ```
pub fn history_reader(
  runtime: api.Runtime,
  reach: Reach,
) -> fn(String, Int) -> Result(JsonValue, String) {
  fn(child, before) {
    use kept <- result.try(all(runtime))
    use entry <- result.try(
      list.find(kept, fn(entry) { entry.stub.name == child })
      |> result.map_error(fn(_) {
        "no child of this session is named " <> child
      }),
    )
    use handle <- result.try(case entry.stub.state {
      Spawned(placed:) | Settled(placed:, ..) -> Ok(placed.handle)
      Requested -> Error("the child has not started yet")
      Refused(..) -> Error("the spawn was refused, so there is no transcript")
    })
    reach.history(
      entry.stub.orchestrator,
      parent_of(entry.stub, reach.session),
      handle,
      before,
      remote_transcript.max_entries,
    )
    |> result.map(remote_transcript.encode)
    |> result.map_error(fn(failure) {
      case failure {
        peer_mail.Refused(reason) ->
          entry.stub.orchestrator <> " refused: " <> reason
        peer_mail.Unreachable | peer_mail.NotOpen ->
          entry.stub.orchestrator <> " could not be reached"
      }
    })
  }
}

/// The first orchestrator, in name order, that holds a child of the session which
/// is or may be running at `now`, or `None` when no stub is live.
///
/// A session with a live child cannot be moved to another orchestrator, because
/// the child reports to this one.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.live_on([spawned_on_box], now) == Some("box")
/// ```
pub fn live_on(kept: List(Kept), now: Int) -> Option(String) {
  kept
  |> list.filter(fn(entry) { is_live(entry.stub, now) })
  |> list.map(fn(entry) { entry.stub.orchestrator })
  |> list.sort(string.compare)
  |> list.first
  |> option.from_result
}

/// Finds the stub of the child a remote orchestrator names, by the strand name
/// it gave the child and the parent strand it reports to.
///
/// A message from the remote concerns a child it may have started a moment ago,
/// and the answer to the `Spawn` that started it may not have reached this side
/// yet. The name is derived from the call site and written on the stub before
/// the first `Spawn` leaves, so the lookup finds the stub in any state. Nothing
/// here reads the lineage cell, which is written only with `Spawned`, or the
/// handle, which exists only after it.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.find_named(kept, "main", "sub:^main/build-turn-1-0")
/// ```
pub fn find_named(
  kept: List(Kept),
  strand: String,
  name: String,
) -> Result(Kept, Nil) {
  list.find(kept, fn(entry) {
    entry.stub.name == name && entry.stub.strand == strand
  })
}

/// Records a glance the remote pushed for a child, unless the stub already holds
/// a newer one.
///
/// A glance is a view and not a fact the parent acts on, so the rule is the
/// simplest that cannot go backwards: the glance with the larger `at` wins, an
/// equal or older one is ignored, and the stub's state is left as it is. The
/// write is a compare-and-set like every other step, so a glance and an answer
/// to a `Spawn` that race both land. `now` is this session's clock when the
/// glance arrived, kept beside it so the roster can say how old it is.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.progressed(runtime, key, glance, now)
/// ```
pub fn progressed(
  runtime: api.Runtime,
  key: String,
  glance: Glance,
  now: Int,
) -> Result(Stub, String) {
  advance_with(runtime, key, fn(stub) {
    case stub.glance {
      Some(held) if held.at >= glance.at -> None
      Some(_) | None ->
        Some(Stub(..stub, glance: Some(glance), glance_seen_ms: now))
    }
  })
}

/// Records the orchestrator's answer to a `Spawn`: the child exists.
///
/// The lineage cell is written first, so that no one is shown the handle before
/// the addressing rule holds the child as a descendant, and the stub moves to
/// `Spawned` second. A stub that is `Spawned` or `Settled` is returned as it is:
/// a second writer got the same answer first, or the child has since settled.
/// A `Refused` stub does move: an answer that names a child means the child
/// exists, and that outranks a refusal an earlier ask was given, so the stub is
/// never left saying no to a child that is running.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.spawned(runtime, key, stub, answer, now)
/// ```
pub fn spawned(
  runtime: api.Runtime,
  key: String,
  stub: Stub,
  answer: remote_spawn.Spawned,
  now: Int,
) -> Result(Stub, String) {
  let placed =
    Placed(
      handle: answer.handle,
      tools: answer.tools,
      model: answer.model,
      model_id: answer.model_id,
      deadline_ms: now + answer.remaining_ms,
    )
  use Nil <- result.try(
    api.put_reserved_fact(
      runtime,
      lineage.register_key(placed.handle.strand),
      lineage.encode(lineage_cell(stub, placed)),
    )
    |> result.map_error(describe),
  )
  advance(runtime, key, fn(state) {
    case state {
      Requested | Refused(..) -> Some(Spawned(placed))
      Spawned(..) | Settled(..) -> None
    }
  })
}

/// Records the orchestrator's refusal of a `Spawn`, whoever heard it: the effect
/// process the model is waiting on, or the drainer that learned it after the
/// model had been told the orchestrator did not answer. The stub stays, in
/// `Refused`, so the roster can show the reason, and it stops counting against
/// the caps. It is never removed, because the refusal may be transient and a
/// second asker of the same call site can still be answered with a child, which
/// `spawned` then records over the refusal.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.refused(runtime, key, stub, "the cap max_sessions is 4")
/// ```
pub fn refused(
  runtime: api.Runtime,
  key: String,
  reason: String,
) -> Result(Stub, String) {
  advance(runtime, key, fn(state) {
    case state {
      Requested -> Some(Refused(reason))
      Spawned(..) | Settled(..) | Refused(..) -> None
    }
  })
  |> result.map(clear_requests(runtime, _))
}

// A refused spawn made no child, so the requests filed for its name have nobody
// to answer for and are removed, and their cards clear (protocol-change/089). A
// failure to remove them leaves a card that answers `Stale`, which is the harm
// already accepted for a card that outlives its record, so it does not fail the
// write of the stub.
//
// A settled child keeps its requests. Its call stopped waiting after the short
// grace, but the box keeps the record decidable: a decision steers a child that
// is still running and opens a run on one that went idle, within the child's
// deadline (`escalate.notify_spawner_decision`), where re-issuing the call
// spends an approval. A child
// that gives up and reports within seconds of being refused is the common case,
// and clearing on its settle would take the card away before its operator could
// read it, and answer the approval `unknown_escalation`. The card clears when the box sends the decided
// state, or when the laptop's own decision files the record the box answered.
fn clear_requests(runtime: api.Runtime, stub: Stub) -> Stub {
  case stub.state {
    Refused(..) -> {
      let _ =
        remote_escalation_store.clear(runtime, stub.orchestrator, stub.name)
      stub
    }
    Requested | Spawned(..) | Settled(..) -> stub
  }
}

/// Records a join's report that a child finished, with what it cost. The cost is
/// the other orchestrator's own pricing and is kept as reported.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.settled(runtime, key, outcome, usage)
/// ```
pub fn settled(
  runtime: api.Runtime,
  key: String,
  outcome: Outcome,
  usage: ChildUsage,
  owed: Int,
) -> Result(Stub, String) {
  advance_with(runtime, key, fn(stub) {
    case stub.state {
      Spawned(placed) ->
        Some(Stub(..stub, owed:, state: Settled(placed:, outcome:, usage:)))

      // A later join says how much mail is still undelivered. It only ever goes
      // down in practice, and the stub keeps what the newest join said.
      Settled(..) if stub.owed != owed -> Some(Stub(..stub, owed:))
      Requested | Settled(..) | Refused(..) -> None
    }
  })
}

/// How long after a child's deadline a settled child that still owes mail is
/// asked about, in milliseconds. A box that cannot deliver for longer than this
/// has lost its place; the mail is not worth a connection held for ever.
pub const owing_grace_ms = 3_600_000

/// Whether the connection to the stub's orchestrator is needed at `now`: the
/// child may be running, or it has finished and the orchestrator still holds
/// mail it sent, within `owing_grace_ms` of the child's deadline.
///
/// ## Examples
///
/// ```gleam
/// assert remote_child.needs_link(stub_in_state(remote_child.Requested), 1000)
/// ```
pub fn needs_link(stub: Stub, now: Int) -> Bool {
  case is_live(stub, now) {
    True -> True
    False -> owes_mail(stub, now)
  }
}

/// Whether the stub is settled and its orchestrator reported undelivered mail
/// from the child, inside the grace period.
///
/// ## Examples
///
/// ```gleam
/// assert !remote_child.owes_mail(stub_in_state(remote_child.Requested), 1000)
/// ```
pub fn owes_mail(stub: Stub, now: Int) -> Bool {
  case stub.state {
    Settled(placed:, ..) ->
      stub.owed > 0 && now < placed.deadline_ms + owing_grace_ms
    Requested | Spawned(..) | Refused(..) -> False
  }
}

// A step from one state, as a single compare-and-set. The stub is read with the
// seq it was written at, the step names the state to move to (or `None` when it
// does not apply to where the stub stands), and the write expects that seq. A
// stub that is no longer where the step starts is returned unchanged. A lost
// race re-reads and decides again, so the loser of two writers that heard the
// same answer ends by agreeing with the winner.
fn advance(
  runtime: api.Runtime,
  key: String,
  next: fn(State) -> Option(State),
) -> Result(Stub, String) {
  advance_with(runtime, key, fn(stub) {
    option.map(next(stub.state), fn(state) { Stub(..stub, state:) })
  })
}

// A step that may change any part of the stub, as a single compare-and-set. The
// step is given the stub as read and returns the stub to write, or `None` when
// it does not apply to where the stub stands.
fn advance_with(
  runtime: api.Runtime,
  key: String,
  next: fn(Stub) -> Option(Stub),
) -> Result(Stub, String) {
  advance_attempts(runtime, key, next, step_attempts)
}

fn advance_attempts(
  runtime: api.Runtime,
  key: String,
  next: fn(Stub) -> Option(Stub),
  attempts: Int,
) -> Result(Stub, String) {
  use found <- result.try(read(runtime, key))
  case found {
    None -> Error("the remote child stub is missing")
    Some(#(stub, seq)) ->
      case next(stub) {
        None -> Ok(stub)
        Some(moved) -> store(runtime, key, moved, seq, next, attempts)
      }
  }
}

// The write half of a step. Losing the compare-and-set re-enters the step with
// one attempt fewer, and the re-read decides whether the step still applies.
fn store(
  runtime: api.Runtime,
  key: String,
  moved: Stub,
  seq: Int,
  next: fn(Stub) -> Option(Stub),
  attempts: Int,
) -> Result(Stub, String) {
  case
    api.put_reserved_fact_expecting(
      runtime,
      key,
      encode(moved),
      expected: Some(seq),
    )
  {
    Ok(_) -> {
      changed(runtime)
      Ok(moved)
    }
    Error(api.FactConflict(..)) if attempts > 1 ->
      advance_attempts(runtime, key, next, attempts - 1)
    Error(error) -> Error(describe(error))
  }
}

// Tells the session's subscribers that a stub changed (protocol-change/090),
// after the write that changed it, so a gateway that reads the stubs on hearing
// it finds the change. The event carries nothing: the stubs are the truth. A
// lost publication leaves a client's strip stale until the next change.
fn changed(runtime: api.Runtime) -> Nil {
  bus.publish(
    bus.start(),
    session: bus.key(of: api.session_id(runtime)),
    event: bus.RemoteChildrenChanged,
  )
}

fn read(
  runtime: api.Runtime,
  key: String,
) -> Result(Option(#(Stub, Int)), String) {
  use cell <- result.try(
    api.fact_cell(runtime, key) |> result.map_error(describe),
  )
  case cell {
    None -> Ok(None)
    Some(api.FactCell(value:, seq:)) ->
      decode(value) |> result.map(fn(stub) { Some(#(stub, seq)) })
  }
}

// The lineage cell a remote child is held under. It records the edge from the
// parent strand to a child that has no strand here, so that addressing, waiting
// and the roster see it as the parent's descendant, and `orchestrator` marks it
// as a cell nothing may ask the local strand registers about.
fn lineage_cell(stub: Stub, placed: Placed) -> lineage.Lineage {
  lineage.Lineage(
    strand: placed.handle.strand,
    parent: stub.strand,
    depth: stub.depth + 1,
    minted_by: lineage.CallSite(
      operation: stub.site.operation,
      step_id: minting_step(stub),
      source_index: stub.site.source_index,
    ),
    brief: placed.handle.operation,
    tools: placed.tools,
    default_within_ms: None,
    deadline: Some(placed.deadline_ms),
    detached: stub.request.detach == remote_spawn.Detached,
    reaped: False,
    orchestrator: Some(stub.orchestrator),
  )
}

// The step id the lineage ledger records for this call site, which carries a
// code-mode program's ordinal the same way a local spawn's does.
fn minting_step(stub: Stub) -> String {
  agent.minting_step(agent.Caller(
    strand: stub.strand,
    operation: stub.site.operation,
    step_id: stub.site.step_id,
    source_index: stub.site.source_index,
    minter: stub.site.minter,
  ))
}

// --- the codec --------------------------------------------------------------

fn describe(error: api.ApiError) -> String {
  case error {
    api.ReadFailed(reason:) -> reason
    api.FactConflict(key:) -> "the fact `" <> key <> "` moved under the write"
    api.SessionStolen(..) -> "another writer holds this session; reopen it"
    api.RuntimeUnavailable -> "the target writer is restarting; try again"
    api.ReservedFactKey(key:) | api.UnreservedFactKey(key:) ->
      "the key `" <> key <> "` is not usable here"
    api.AcceptRejected(..)
    | api.QueueRejected(..)
    | api.CommitFailed(..)
    | api.RaceLost
    | api.EscalationExists(..)
    | api.EscalationNotFound(..)
    | api.EscalationWrongStatus(..) -> "the session store refused the write"
  }
}

/// A stub's payload, the value of its cell.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.decode(remote_child.encode(stub)) == Ok(stub)
/// ```
pub fn encode(stub: Stub) -> JsonValue {
  json.Object(list.append(
    [
      #("orchestrator", json.String(stub.orchestrator)),
      #("strand", json.String(stub.strand)),
      #("site", encode_site(stub.site)),
      #("depth", json.Int(stub.depth)),
      #("parentTools", strings(stub.parent_tools)),
      #("request", encode_request(stub.request)),
      #("name", json.String(stub.name)),
      #("glance", optional(stub.glance, glance.encode)),
      #("glanceSeenMs", json.Int(stub.glance_seen_ms)),
      #("owed", json.Int(stub.owed)),
    ],
    encode_state(stub.state),
  ))
}

fn encode_state(state: State) -> List(#(String, JsonValue)) {
  case state {
    Requested -> [#("state", json.String("requested"))]
    Spawned(placed:) -> [
      #("state", json.String("spawned")),
      #("placed", encode_placed(placed)),
    ]
    Settled(placed:, outcome:, usage:) -> [
      #("state", json.String("settled")),
      #("placed", encode_placed(placed)),
      #("outcome", encode_outcome(outcome)),
      #("usage", encode_usage(usage)),
    ]
    Refused(reason:) -> [
      #("state", json.String("refused")),
      #("reason", json.String(reason)),
    ]
  }
}

fn encode_site(site: remote_spawn.CallSite) -> JsonValue {
  json.Object([
    #("operation", json.String(ids.op_id_to_string(site.operation))),
    #("stepId", json.String(site.step_id)),
    #("sourceIndex", json.Int(site.source_index)),
    #("minter", case site.minter {
      agent.ToolCall -> json.Object([#("kind", json.String("tool"))])
      agent.Program(ordinal:) ->
        json.Object([
          #("kind", json.String("program")),
          #("ordinal", json.Int(ordinal)),
        ])
    }),
  ])
}

fn encode_request(request: remote_spawn.Request) -> JsonValue {
  json.Object([
    #("purpose", json.String(request.purpose)),
    #("brief", json.String(request.brief)),
    #("model", optional(request.model, json.String)),
    #("tools", optional(request.tools, strings)),
    #("withinMs", optional(request.within_ms, json.Int)),
    #(
      "resultSchema",
      optional(request.result_schema, agent.render_result_schema),
    ),
    #("detach", json.Bool(request.detach == remote_spawn.Detached)),
  ])
}

fn encode_placed(placed: Placed) -> JsonValue {
  json.Object([
    #("strand", json.String(placed.handle.strand)),
    #("operation", json.String(ids.op_id_to_string(placed.handle.operation))),
    #("tools", strings(placed.tools)),
    #("model", json.String(placed.model)),
    #("modelId", json.String(placed.model_id)),
    #("deadlineMs", json.Int(placed.deadline_ms)),
  ])
}

fn encode_outcome(outcome: Outcome) -> JsonValue {
  json.Object(case outcome {
    agent.Completed -> [#("kind", json.String("completed"))]
    agent.Failed(reason:) -> [
      #("kind", json.String("failed")),
      #("reason", json.String(reason)),
    ]
    agent.Aborted -> [#("kind", json.String("aborted"))]
    agent.BudgetExpired -> [#("kind", json.String("budget_expired"))]
    agent.ParentFinished -> [#("kind", json.String("parent_finished"))]
    agent.Released -> [#("kind", json.String("released"))]
    agent.TokenBudgetSpent -> [#("kind", json.String("token_budget_spent"))]
  })
}

fn encode_usage(usage: ChildUsage) -> JsonValue {
  json.Object([
    #("input", json.Int(usage.input)),
    #("output", json.Int(usage.output)),
    #("cacheRead", json.Int(usage.cache_read)),
    #("cacheWrite", json.Int(usage.cache_write)),
    #("cost", json.Float(usage.cost)),
  ])
}

fn strings(values: List(String)) -> JsonValue {
  json.Array(list.map(values, json.String))
}

fn optional(value: Option(a), render: fn(a) -> JsonValue) -> JsonValue {
  case value {
    Some(present) -> render(present)
    None -> json.Null
  }
}

/// Decodes a stub's payload. Total: anything malformed is an error that names
/// what was wrong, never a crash.
///
/// ## Examples
///
/// ```gleam
/// assert remote_child.decode(json.Null)
///   == Error("expected a remote child stub, got null")
/// ```
pub fn decode(value: JsonValue) -> Result(Stub, String) {
  use fields <- result.try(object(value, "a remote child stub"))
  use orchestrator <- result.try(text(fields, "orchestrator"))
  use strand <- result.try(text(fields, "strand"))
  use site <- result.try(member(fields, "site") |> result.try(decode_site))
  use depth <- result.try(number(fields, "depth"))
  use parent_tools <- result.try(texts(fields, "parentTools"))
  use request <- result.try(
    member(fields, "request") |> result.try(decode_request),
  )
  use name <- result.try(text(fields, "name"))
  use glance <- result.try(
    maybe(fields, "glance", fn(value) {
      glance.decode(value) |> result.map_error(corruption.describe)
    }),
  )
  use glance_seen_ms <- result.try(case list.key_find(fields, "glanceSeenMs") {
    Error(Nil) -> Ok(0)
    Ok(found) -> expect_number(found)
  })
  use owed <- result.try(case list.key_find(fields, "owed") {
    Error(Nil) -> Ok(0)
    Ok(found) -> expect_number(found)
  })
  use state <- result.try(decode_state(fields))
  Ok(Stub(
    orchestrator:,
    strand:,
    site:,
    depth:,
    parent_tools:,
    request:,
    name:,
    glance:,
    glance_seen_ms:,
    owed:,
    state:,
  ))
}

fn decode_state(fields: List(#(String, JsonValue))) -> Result(State, String) {
  use word <- result.try(text(fields, "state"))
  case word {
    "requested" -> Ok(Requested)
    "spawned" -> {
      use placed <- result.map(
        member(fields, "placed") |> result.try(decode_placed),
      )
      Spawned(placed)
    }
    "settled" -> {
      use placed <- result.try(
        member(fields, "placed") |> result.try(decode_placed),
      )
      use outcome <- result.try(
        member(fields, "outcome") |> result.try(decode_outcome),
      )
      use usage <- result.map(
        member(fields, "usage") |> result.try(decode_usage),
      )
      Settled(placed:, outcome:, usage:)
    }
    "refused" -> text(fields, "reason") |> result.map(Refused)
    other -> Error("unknown remote child state `" <> other <> "`")
  }
}

fn decode_site(value: JsonValue) -> Result(remote_spawn.CallSite, String) {
  use fields <- result.try(object(value, "a call site"))
  use operation <- result.try(operation_id(fields, "operation"))
  use step_id <- result.try(text(fields, "stepId"))
  use source_index <- result.try(number(fields, "sourceIndex"))
  use minter <- result.try(
    member(fields, "minter")
    |> result.try(object(_, "a minter"))
    |> result.try(decode_minter),
  )
  Ok(remote_spawn.CallSite(operation:, step_id:, source_index:, minter:))
}

fn decode_minter(
  fields: List(#(String, JsonValue)),
) -> Result(agent.Minter, String) {
  use kind <- result.try(text(fields, "kind"))
  case kind {
    "tool" -> Ok(agent.ToolCall)
    "program" -> number(fields, "ordinal") |> result.map(agent.Program)
    other -> Error("unknown minter `" <> other <> "`")
  }
}

fn decode_request(value: JsonValue) -> Result(remote_spawn.Request, String) {
  use fields <- result.try(object(value, "a spawn request"))
  use purpose <- result.try(text(fields, "purpose"))
  use brief <- result.try(text(fields, "brief"))
  use model <- result.try(maybe(fields, "model", expect_text))
  use tools <- result.try(maybe(fields, "tools", expect_texts))
  use within_ms <- result.try(maybe(fields, "withinMs", expect_number))
  use result_schema <- result.try(maybe(
    fields,
    "resultSchema",
    agent.parse_result_schema,
  ))
  use detach <- result.try(case list.key_find(fields, "detach") {
    Ok(json.Bool(True)) -> Ok(remote_spawn.Detached)
    Ok(json.Bool(False)) -> Ok(remote_spawn.Attached)
    Ok(_) | Error(Nil) -> Error("expected `detach` to be a boolean")
  })
  Ok(remote_spawn.Request(
    purpose:,
    brief:,
    model:,
    tools:,
    within_ms:,
    result_schema:,
    detach:,
  ))
}

fn decode_placed(value: JsonValue) -> Result(Placed, String) {
  use fields <- result.try(object(value, "a placed child"))
  use strand <- result.try(text(fields, "strand"))
  use operation <- result.try(operation_id(fields, "operation"))
  use tools <- result.try(texts(fields, "tools"))
  use model <- result.try(text(fields, "model"))
  use model_id <- result.try(text(fields, "modelId"))
  use deadline_ms <- result.try(number(fields, "deadlineMs"))
  Ok(Placed(
    handle: agent.Handle(strand:, operation:),
    tools:,
    model:,
    model_id:,
    deadline_ms:,
  ))
}

fn decode_outcome(value: JsonValue) -> Result(Outcome, String) {
  use fields <- result.try(object(value, "an outcome"))
  use kind <- result.try(text(fields, "kind"))
  case kind {
    "completed" -> Ok(agent.Completed)
    "failed" -> text(fields, "reason") |> result.map(agent.Failed)
    "aborted" -> Ok(agent.Aborted)
    "budget_expired" -> Ok(agent.BudgetExpired)
    "parent_finished" -> Ok(agent.ParentFinished)
    "released" -> Ok(agent.Released)
    "token_budget_spent" -> Ok(agent.TokenBudgetSpent)
    other -> Error("unknown outcome `" <> other <> "`")
  }
}

fn decode_usage(value: JsonValue) -> Result(ChildUsage, String) {
  use fields <- result.try(object(value, "a usage"))
  use input <- result.try(number(fields, "input"))
  use output <- result.try(number(fields, "output"))
  use cache_read <- result.try(number(fields, "cacheRead"))
  use cache_write <- result.try(number(fields, "cacheWrite"))
  use cost <- result.try(case list.key_find(fields, "cost") {
    Ok(json.Float(cost)) -> Ok(cost)
    Ok(json.Int(cost)) -> Ok(int.to_float(cost))
    Ok(_) | Error(Nil) -> Error("expected `cost` to be a number")
  })
  Ok(remote_spawn.ChildUsage(input:, output:, cache_read:, cache_write:, cost:))
}

fn object(
  value: JsonValue,
  what: String,
) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    other -> Error("expected " <> what <> ", got " <> json.to_string(other))
  }
}

fn member(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(JsonValue, String) {
  list.key_find(fields, name)
  |> result.map_error(fn(_) { "missing `" <> name <> "`" })
}

fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, String) {
  member(fields, name) |> result.try(expect_text)
}

fn number(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(Int, String) {
  member(fields, name) |> result.try(expect_number)
}

fn texts(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(List(String), String) {
  member(fields, name) |> result.try(expect_texts)
}

fn operation_id(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(OpId, String) {
  use raw <- result.try(text(fields, name))
  ids.parse_op_id(raw)
  |> result.map_error(fn(report) { corruption.describe(report) })
}

fn expect_text(value: JsonValue) -> Result(String, String) {
  case value {
    json.String(text) -> Ok(text)
    other -> Error("expected text, got " <> json.to_string(other))
  }
}

fn expect_number(value: JsonValue) -> Result(Int, String) {
  case value {
    json.Int(number) -> Ok(number)
    other -> Error("expected an integer, got " <> json.to_string(other))
  }
}

fn expect_texts(value: JsonValue) -> Result(List(String), String) {
  case value {
    json.Array(items) -> list.try_map(items, expect_text)
    other -> Error("expected a list of text, got " <> json.to_string(other))
  }
}

// A member that may be null or absent, decoded when it is present.
fn maybe(
  fields: List(#(String, JsonValue)),
  name: String,
  read_one: fn(JsonValue) -> Result(a, String),
) -> Result(Option(a), String) {
  case list.key_find(fields, name) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(present) -> read_one(present) |> result.map(Some)
  }
}
