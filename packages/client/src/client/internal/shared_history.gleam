//// One published history owner per daemon workspace domain.
////
//// The parked actor opens nothing until domain custody retains its retirement
//// callback. It then owns the index and at most one read-only source. Source
//// work advances by ordinary mailbox messages, one fragment or short indexed
//// operation at a time, so stop and coalesced commit hints remain observable.
//// A timeout never closes a native handle.
////
//// A foreground call that arrives while the owner is still opening its index,
//// or while it is working through a commit hint of its own, is held in a
//// bounded waiting list rather than refused: neither state says anything about
//// the request, and a model told "no" twice in the first seconds of a session
//// stops calling the tool. A held call is admitted the next time the owner
//// reaches `Ready`, and refused with the startup or blocked reason if the owner
//// lands there instead. A call arriving while another *caller's* request is in
//// flight is still refused at once, because that wait has no bound the caller
//// can see.
////
//// Catalogue membership is resolved afresh before source reads and before FTS
//// ranking. Index locators and rows are projections, never authorization. Close
//// failure keeps the original actor blocked and its handles retained.

import broker/internal/call
import client/distill
import core/codec
import core/ids
import core/json
import events/search
import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import storage/internal/history_source as source
import storage/snapshot
import tools/history as tool
import weft/actor

/// Configuration selected by the persisted domain owner, not its first guest.
@internal
pub type Config {
  Config(
    /// Canonical exclusive domain projection path.
    index_path: String,
    /// Fresh authorized catalogue sources; never a directory scan.
    sources: fn() -> Result(List(distill.Source), String),
    /// Foreground wait and connection busy bound, between one and 5000 ms.
    timeout_ms: Int,
    /// Descriptors per source refresh, between one and the existing page cap.
    batch_entries: Int,
  )
}

/// An original actor capability, never a restartable process-name lookup.
@internal
pub opaque type Shared {
  Shared(subject: process.Subject(Message), pid: process.Pid, timeout_ms: Int)
}

/// Publish retirement before unlinking the creator and beginning effects.
@internal
pub type Prepared {
  Prepared(
    /// Original owner used for fatal-child monitoring.
    pid: process.Pid,
    /// Releases the parked owner after cleanup publication.
    begin: fn() -> Result(Shared, String),
    /// Success means native handles closed and this original actor exited.
    retire: fn() -> Result(Nil, String),
  )
}

type Message {
  Begin(process.Subject(Result(Nil, String)))
  Stop(process.Subject(String))
  Notify(ids.SessionId)
  Query(ids.SessionId, String, Int, tool.Scope, process.Subject(Reply))
  Read(ids.SessionId, ids.SessionId, ids.EntryId, process.Subject(Reply))
  Step
}

// A reply carries the tool package's own refusal vocabulary rather than a bare
// string, so the arm that decided the refusal also decides which sentence the
// model reads. `tools/history` renders every variant in one place.
type Reply {
  Hits(Result(List(tool.Hit), tool.Refusal))
  Entry(Result(json.JsonValue, tool.Refusal))
}

/// How many foreground calls may wait at once for the owner to reach `Ready`.
///
/// A held call occupies a caller that is already blocked in `call.try_call`,
/// so the list is really a count of concurrent seams, and eight is more
/// concurrent recall than a workspace produces. Past it the honest answer is
/// that the owner is oversubscribed, which is a refusal the model can act on.
const waiting_limit = 8

type Phase {
  Parked
  Opening(process.Subject(Result(Nil, String)))
  Initializing(process.Subject(Result(Nil, String)))
  Ready
  Busy(Job)
  StartupFailed(String)
  Blocked(String)
}

type Request {
  Background
  SearchRequest(ids.SessionId, String, Int, tool.Scope, process.Subject(Reply))
  EntryRequest(
    ids.SessionId,
    ids.SessionId,
    ids.EntryId,
    process.Subject(Reply),
  )
}

type Completeness {
  Complete
  Partial
}

type Stage {
  NextSource
  InitializeSource(distill.Source)
  InspectSource(distill.Source)
  Describe(source.Cut)
  Fragment(
    source.Cut,
    snapshot.Descriptor,
    List(snapshot.Descriptor),
    Option(search.BatchPlan),
    Int,
    List(BitArray),
  )
}

type Job {
  Job(
    request: Request,
    remaining: List(distill.Source),
    stage: Stage,
    deadline: Int,
    completeness: Completeness,
  )
}

type State {
  State(
    config: Config,
    subject: process.Subject(Message),
    phase: Phase,
    index: Option(search.Search),
    source: Option(source.Source),
    pending: dict.Dict(ids.SessionId, Nil),
    /// Foreground calls held until the owner next reaches `Ready`, in
    /// arrival order and never longer than `waiting_limit`.
    waiting: List(Request),
  )
}

/// Prepares an owner without acquiring any native handle.
///
/// ## Examples
///
/// ```gleam
/// // shared_history.prepare(config)
/// ```
@internal
pub fn prepare(config: Config) -> Result(Prepared, String) {
  use <- bool.guard(
    when: config.timeout_ms <= 0
      || config.timeout_ms > 5000
      || config.batch_entries <= 0
      || config.batch_entries > snapshot.page_limit,
    return: Error("invalid shared history bounds"),
  )
  use started <- result.map(
    actor.new_with_initialiser(1000, fn(subject) {
      actor.initialised(
        State(config, subject, Parked, None, None, dict.new(), []),
      )
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(string.inspect),
  )
  let shared = Shared(started.data, started.pid, config.timeout_ms)
  Prepared(
    pid: started.pid,
    begin: fn() {
      use Nil <- result.try(exchange(shared, Begin) |> result.flatten)
      Ok(shared)
    },
    retire: fn() { retire(shared) },
  )
}

/// Hints this original owner that the selected source committed.
///
/// ## Examples
///
/// ```gleam
/// // shared_history.notify(shared, session_id)
/// ```
@internal
pub fn notify(shared: Shared, session: ids.SessionId) -> Nil {
  process.send(shared.subject, Notify(session))
}

/// Binds ThisSession and exact-read admission to this session's identity.
///
/// ## Examples
///
/// ```gleam
/// // shared_history.seam(shared, session_id)
/// ```
@internal
pub fn seam(shared: Shared, current: ids.SessionId) -> tool.History {
  tool.History(
    search: fn(text, limit, scope) {
      use reply <- result.try(
        exchange(shared, Query(current, text, limit, scope, _))
        |> result.map_error(tool.IndexUnavailable),
      )
      case reply {
        Hits(answer) -> answer
        Entry(_) -> Error(tool.IndexUnavailable("history reply type mismatch"))
      }
    },
    read: fn(session, entry) {
      use reply <- result.try(
        exchange(shared, Read(current, session, entry, _))
        |> result.map_error(tool.IndexUnavailable),
      )
      case reply {
        Entry(answer) -> answer
        Hits(_) -> Error(tool.IndexUnavailable("history reply type mismatch"))
      }
    },
  )
}

fn exchange(shared: Shared, request) {
  call.try_call(shared.subject, waiting: shared.timeout_ms, sending: request)
  |> result.map_error(fn(error) {
    "shared history unavailable: " <> string.inspect(error)
  })
}

fn retire(shared: Shared) {
  let monitor = process.monitor(shared.pid)
  let refused = process.new_subject()
  process.send(shared.subject, Stop(refused))
  let answer =
    process.new_selector()
    |> process.select_map(refused, Error)
    |> process.select_specific_monitor(monitor, fn(down) {
      case down.reason {
        process.Normal -> Ok(Nil)
        reason ->
          Error("history retirement lost proof: " <> string.inspect(reason))
      }
    })
    |> process.selector_receive(shared.timeout_ms)
  process.demonitor_process(monitor)
  answer |> result.unwrap(Error("history retirement remains unconfirmed"))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Stop(reply) -> stop(state, reply)
    Notify(id) -> hint(state, id)
    Begin(reply) ->
      case state.phase {
        Parked -> advance(State(..state, phase: Opening(reply)))
        Ready | Busy(_) -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        Blocked(reason) | StartupFailed(reason) -> {
          process.send(reply, Error(reason))
          actor.continue(state)
        }
        Opening(_) | Initializing(_) -> {
          process.send(reply, Error("history initialization is in progress"))
          actor.continue(state)
        }
      }
    Query(current, text, limit, scope, reply) ->
      admit(state, SearchRequest(current, text, limit, scope, reply))
    Read(current, session, entry, reply) ->
      admit(state, EntryRequest(current, session, entry, reply))
    Step -> step(state)
  }
}

// Native resources enter actor state before the next initialization message.
fn step(state: State) -> actor.Next(State, Message) {
  case state.phase {
    Opening(reply) ->
      case search.acquire(state.config.index_path) {
        Ok(index) ->
          advance(
            State(..state, index: Some(index), phase: Initializing(reply)),
          )
        Error(error) -> {
          let reason = string.inspect(error)
          process.send(reply, Error(reason))
          fail_startup(state, reason)
        }
      }
    Initializing(reply) ->
      case state.index {
        None -> block(state, "history initialization lost its handle")
        Some(index) ->
          case search.initialize(index) {
            Ok(Nil) -> {
              process.send(reply, Ok(Nil))
              advance(State(..state, phase: Ready))
            }
            Error(error) -> {
              let reason = string.inspect(error)
              process.send(reply, Error(reason))
              fail_startup(state, reason)
            }
          }
      }

    // Held calls are served before commit hints. A hint costs nothing by
    // waiting one more turn; a caller is already blocked in `call.try_call`.
    Ready ->
      case state.waiting {
        [] -> next_hint(state)
        [held, ..rest] -> admit(State(..state, waiting: rest), held)
      }
    Busy(job) -> {
      case bootstrap.monotonic_time_ms() >= job.deadline {
        True ->
          fail_job(
            state,
            job,
            "history work deadline expired; committed index progress remains",
          )
        False -> work(state, job)
      }
    }
    Parked | StartupFailed(_) | Blocked(_) -> actor.continue(state)
  }
}

fn advance(state: State) -> actor.Next(State, Message) {
  process.send(state.subject, Step)
  actor.continue(state)
}

fn block(state: State, reason: String) -> actor.Next(State, Message) {
  let state = drain(state, tool.IndexUnavailable(reason))
  actor.continue(State(..state, phase: Blocked(reason)))
}

// Startup and blocking are the two terminal phases: the owner will never
// reach `Ready` again on its own, so anything held has to be answered here
// or it waits for its caller's own deadline instead.
fn fail_startup(state: State, reason: String) -> actor.Next(State, Message) {
  let state = drain(state, tool.IndexUnavailable(reason))
  actor.continue(State(..state, phase: StartupFailed(reason)))
}

fn drain(state: State, refusal: tool.Refusal) -> State {
  list.each(state.waiting, refuse(_, refusal))
  State(..state, waiting: [])
}

fn authorized(config: Config) {
  use sources <- result.try(config.sources())
  use <- bool.guard(
    when: list.length(list.take(sources, 513)) > 512,
    return: Error("history domain source limit exceeded"),
  )
  Ok(sources)
}

fn member(sources, id) {
  list.find(sources, fn(item: distill.Source) { item.session == id })
  |> result.replace_error("session is outside the current history domain")
}

fn hint(state: State, id: ids.SessionId) {
  case state.phase {
    Parked | Opening(_) | Initializing(_) | StartupFailed(_) | Blocked(_) ->
      actor.continue(state)
    Ready | Busy(_) -> {
      // Never retain unbounded arbitrary IDs even before fresh authorization.
      case dict.size(state.pending) < 512 || dict.has_key(state.pending, id) {
        True -> {
          let updated =
            State(..state, pending: dict.insert(state.pending, id, Nil))

          // An active job already owns its next mailbox step. Duplicate hints
          // must not manufacture additional continuation messages.
          case state.phase, dict.size(state.pending) {
            Ready, 0 -> advance(updated)
            _, _ -> actor.continue(updated)
          }
        }
        False -> actor.continue(state)
      }
    }
  }
}

fn next_hint(state: State) {
  case dict.to_list(state.pending) {
    [] -> actor.continue(state)
    [#(id, _), ..] -> {
      let state = State(..state, pending: dict.delete(state.pending, id))
      let source = {
        use sources <- result.try(authorized(state.config))
        member(sources, id)
      }
      case source {
        Error(_) -> advance(state)
        Ok(source) -> begin_job(state, Background, [source])
      }
    }
  }
}

fn admit(state: State, request: Request) {
  case state.phase {
    Ready -> {
      let permitted = {
        use sources <- result.try(authorized(state.config))
        case request {
          SearchRequest(current, _, _, scope, _) -> {
            use _current <- result.try(member(sources, current))
            case scope {
              tool.Repository -> Ok(sources)
              tool.ThisSession ->
                result.map(member(sources, current), fn(item) { [item] })
            }
          }
          EntryRequest(current, target, _, _) -> {
            use _current <- result.try(member(sources, current))
            result.map(member(sources, target), fn(item) { [item] })
          }
          Background -> Ok([])
        }
      }
      case permitted {
        Ok(sources) -> begin_job(state, request, sources)

        // A refusal here ends the chain of self-sent steps, so anything
        // still held would sit until the next hint. One more step costs a
        // mailbox message and stops on an empty waiting list.
        Error(reason) -> {
          refuse(request, tool.IndexRefused(reason))
          advance(state)
        }
      }
    }

    Blocked(reason) | StartupFailed(reason) -> {
      refuse(request, tool.IndexUnavailable(reason))
      actor.continue(state)
    }

    // Nothing has called `begin`, so no later transition will serve this
    // call. Holding it would only spend the caller's deadline.
    Parked -> {
      refuse(request, tool.IndexNotReady("the index owner has not begun"))
      actor.continue(state)
    }

    // Startup and the owner's own commit-hint refresh both end at `Ready`
    // within a step or two, and neither is anything the caller did.
    Opening(_) | Initializing(_) | Busy(Job(request: Background, ..)) ->
      hold(state, request)

    // Another caller's request is in flight. Its work is bounded by that
    // job's deadline, which may be the whole of this caller's window, so
    // the honest answer is a refusal now rather than a wait it cannot see.
    Busy(_) -> {
      refuse(request, tool.IndexBusy("another recall request is in flight"))
      actor.continue(state)
    }
  }
}

fn hold(state: State, request: Request) -> actor.Next(State, Message) {
  // Room for one more is a question about the first `waiting_limit - 1`
  // elements, so it is answered by dropping them rather than by measuring
  // the whole list.
  case list.drop(state.waiting, waiting_limit - 1) == [] {
    True ->
      actor.continue(
        State(..state, waiting: list.append(state.waiting, [request])),
      )
    False -> {
      refuse(
        request,
        tool.IndexBusy(
          "the index owner already has "
          <> int.to_string(waiting_limit)
          <> " calls waiting for it to open",
        ),
      )
      actor.continue(state)
    }
  }
}

fn begin_job(state: State, request: Request, sources: List(distill.Source)) {
  let job =
    Job(
      request,
      sources,
      NextSource,
      bootstrap.monotonic_time_ms() + state.config.timeout_ms,
      Complete,
    )
  advance(State(..state, phase: Busy(job)))
}

fn refuse(request: Request, refusal: tool.Refusal) {
  case request {
    Background -> Nil
    SearchRequest(_, _, _, _, reply) ->
      process.send(reply, Hits(Error(refusal)))
    EntryRequest(_, _, _, reply) -> process.send(reply, Entry(Error(refusal)))
  }
}

// A step of the owner's own work failed. That is the index answering, so the
// model reads it as a refusal of the request it actually made.
fn refuse_job(request: Request, reason: String) {
  refuse(request, tool.IndexRefused(reason))
}

fn work(state: State, job: Job) {
  case job.stage {
    NextSource ->
      case job.remaining {
        [] -> finish_job(state, job)
        [chosen, ..remaining] ->
          case source.acquire(chosen.path) {
            Error(reason) -> fail_job(state, job, reason)
            Ok(opened) ->
              advance(
                State(
                  ..state,
                  source: Some(opened),
                  phase: Busy(
                    Job(..job, remaining:, stage: InitializeSource(chosen)),
                  ),
                ),
              )
          }
      }
    InitializeSource(chosen) ->
      with_source(state, job, fn(opened) {
        case source.initialize(opened, state.config.timeout_ms) {
          Error(reason) -> fail_job(state, job, reason)
          Ok(Nil) ->
            advance(
              State(
                ..state,
                phase: Busy(Job(..job, stage: InspectSource(chosen))),
              ),
            )
        }
      })
    InspectSource(chosen) ->
      with_source(state, job, fn(opened) {
        case source.inspect(opened, chosen.session) {
          Error(reason) -> fail_job(state, job, reason)
          Ok(cut) ->
            advance(
              State(..state, phase: Busy(Job(..job, stage: Describe(cut)))),
            )
        }
      })
    Describe(cut) -> describe_source(state, job, cut)
    Fragment(cut, descriptor, remaining, plan, offset, fragments) ->
      read_fragment(
        state,
        job,
        cut,
        descriptor,
        remaining,
        plan,
        offset,
        fragments,
      )
  }
}

fn with_source(state: State, job: Job, next) {
  case state.source {
    Some(opened) -> next(opened)
    None -> fail_job(state, job, "history source custody was lost")
  }
}

fn describe_source(state: State, job: Job, cut: source.Cut) {
  with_source(state, job, fn(opened) {
    case job.request, state.index {
      EntryRequest(_, _, id, _), _ ->
        case source.entry(opened, cut, id) {
          Error(reason) -> fail_job(state, job, reason)
          Ok(descriptor) -> read_next(state, job, cut, descriptor, [], None)
        }
      _, None -> fail_job(state, job, "history index custody was lost")
      _, Some(index) -> {
        let loaded = {
          use plan <- result.try(
            search.plan_batch(index, cut.session, cut.generation)
            |> result.map_error(string.inspect),
          )
          use descriptors <- result.map(source.page(
            opened,
            cut,
            search.batch_after(plan),
            state.config.batch_entries,
          ))
          #(plan, descriptors)
        }
        case loaded {
          Error(reason) -> fail_job(state, job, reason)
          Ok(#(plan, [])) -> {
            let committed = {
              use Nil <- result.try(validate_source(state, cut))
              search.commit_batch(index, plan, [], requested: 1)
              |> result.map_error(string.inspect)
            }
            case committed {
              Ok(search.Advanced(..)) -> close_source_and_continue(state, job)
              Ok(search.Stale) ->
                fail_job(state, job, "history index changed during refresh")
              Error(reason) -> fail_job(state, job, reason)
            }
          }
          Ok(#(plan, [first, ..rest] as descriptors)) -> {
            let completeness = case
              list.length(descriptors) == state.config.batch_entries
            {
              True -> Partial
              False -> job.completeness
            }
            read_next(
              state,
              Job(..job, completeness:),
              cut,
              first,
              rest,
              Some(plan),
            )
          }
        }
      }
    }
  })
}

fn read_next(state, job: Job, cut, descriptor, remaining, plan) {
  advance(
    State(
      ..state,
      phase: Busy(
        Job(..job, stage: Fragment(cut, descriptor, remaining, plan, 0, [])),
      ),
    ),
  )
}

fn read_fragment(
  state: State,
  job: Job,
  cut,
  descriptor: snapshot.Descriptor,
  remaining,
  plan,
  offset: Int,
  fragments,
) {
  with_source(state, job, fn(opened) {
    case source.fragment(opened, descriptor, offset) {
      Error(reason) -> fail_job(state, job, reason)
      Ok(bytes) -> {
        let amount = bit_array.byte_size(bytes)
        let offset = offset + amount
        let fragments = [bytes, ..fragments]
        case offset == descriptor.byte_length {
          True ->
            publish_record(
              state,
              job,
              cut,
              descriptor,
              remaining,
              plan,
              fragments,
            )
          False if amount > 0 && offset < descriptor.byte_length ->
            advance(
              State(
                ..state,
                phase: Busy(
                  Job(
                    ..job,
                    stage: Fragment(
                      cut,
                      descriptor,
                      remaining,
                      plan,
                      offset,
                      fragments,
                    ),
                  ),
                ),
              ),
            )
          False ->
            fail_job(
              state,
              job,
              "history source fragment made invalid progress",
            )
        }
      }
    }
  })
}

fn publish_record(
  state: State,
  job: Job,
  cut: source.Cut,
  descriptor: snapshot.Descriptor,
  remaining,
  plan,
  fragments,
) {
  let decoded = {
    use text <- result.try(
      fragments
      |> list.reverse
      |> bit_array.concat
      |> bit_array.to_string
      |> result.replace_error("history entry is not UTF-8"),
    )
    use value <- result.try(
      json.parse(text) |> result.map_error(string.inspect),
    )
    use entry <- result.try(
      codec.decode_entry(value) |> result.map_error(string.inspect),
    )
    use Nil <- result.try(validate_source(state, cut))
    case entry.id == descriptor.id && entry.seq == descriptor.seq {
      True -> Ok(entry)
      False -> Error("history entry does not match its descriptor")
    }
  }
  use entry <- or_job(decoded, state, job)
  case job.request, plan, state.index {
    EntryRequest(current, target, _, reply), _, _ -> {
      let permitted = {
        use sources <- result.try(authorized(state.config))
        use _ <- result.try(member(sources, current))
        use _ <- result.try(member(sources, target))
        Ok(Nil)
      }
      use Nil <- or_job(permitted, state, job)
      case close_source(state) {
        Error(reason) -> {
          refuse_job(job.request, reason)
          block(state, "history source retirement unconfirmed: " <> reason)
        }
        Ok(state) -> {
          process.send(reply, Entry(Ok(codec.encode_entry(entry))))
          advance(State(..state, phase: Ready))
        }
      }
    }
    _, Some(plan), Some(index) -> {
      use committed <- or_job(
        search.commit_batch(index, plan, [entry], requested: 1)
          |> result.map_error(string.inspect),
        state,
        job,
      )
      case committed {
        search.Stale ->
          fail_job(state, job, "history index changed during refresh")
        search.Advanced(..) ->
          case remaining {
            [] -> finish_record_page(state, job, cut.session)
            [next, ..rest] -> {
              use plan <- or_job(
                search.plan_batch(index, cut.session, cut.generation)
                  |> result.map_error(string.inspect),
                state,
                job,
              )
              read_next(state, job, cut, next, rest, Some(plan))
            }
          }
      }
    }
    _, _, _ ->
      fail_job(state, job, "history publication lost its cursor or index")
  }
}

// Only successful publication schedules another background page. Refused or
// expired work therefore cannot retry itself forever.
fn finish_record_page(state: State, job: Job, session: ids.SessionId) {
  let state = case job.completeness, job.request {
    Partial, Background ->
      State(..state, pending: dict.insert(state.pending, session, Nil))
    _, _ -> state
  }
  close_source_and_continue(state, job)
}

// Fallible storage steps preserve the same owned cleanup path on refusal.
fn or_job(
  value: Result(a, String),
  state: State,
  job: Job,
  next: fn(a) -> actor.Next(State, Message),
) -> actor.Next(State, Message) {
  case value {
    Ok(value) -> next(value)
    Error(reason) -> fail_job(state, job, reason)
  }
}

// Appends may advance high-water; rewrite, truncation or reassignment refuses.
fn validate_source(state: State, cut: source.Cut) -> Result(Nil, String) {
  use opened <- result.try(case state.source {
    Some(opened) -> Ok(opened)
    None -> Error("history source custody was lost")
  })
  use sources <- result.try(authorized(state.config))
  use selected <- result.try(member(sources, cut.session))
  use <- bool.guard(
    when: selected.path != source.path(opened),
    return: Error("history source canonical path changed"),
  )

  // Inspect after resolving membership so a slow resolver cannot move the last
  // same-handle generation check away from publication unnecessarily.
  use current <- result.try(source.inspect(opened, cut.session))
  use <- bool.guard(
    when: current.generation != cut.generation
      || current.next_seq < cut.next_seq,
    return: Error("history source changed generation or was truncated"),
  )
  Ok(Nil)
}

fn close_source(state: State) {
  case state.source {
    None -> Ok(state)
    Some(opened) -> {
      use Nil <- result.map(source.close(opened))
      State(..state, source: None)
    }
  }
}

fn close_source_and_continue(state, job: Job) {
  case close_source(state) {
    Error(reason) -> {
      refuse_job(job.request, reason)
      block(state, "history source retirement unconfirmed: " <> reason)
    }
    Ok(state) ->
      advance(State(..state, phase: Busy(Job(..job, stage: NextSource))))
  }
}

fn fail_job(state: State, job: Job, reason: String) {
  refuse_job(job.request, reason)
  case close_source(state) {
    Error(close_reason) ->
      block(state, "history source retirement unconfirmed: " <> close_reason)
    Ok(state) -> advance(State(..state, phase: Ready))
  }
}

fn finish_job(state: State, job: Job) {
  case job.request {
    Background -> advance(State(..state, phase: Ready))
    EntryRequest(_, _, _, _) ->
      fail_job(state, job, "history entry was not found")
    SearchRequest(current, text, limit, scope, reply) -> {
      let answer = {
        use sources <- result.try(authorized(state.config))
        use _ <- result.try(member(sources, current))
        use <- bool.guard(
          when: job.completeness == Partial,
          return: Error(
            "history refresh is incomplete; committed progress is retained",
          ),
        )
        use index <- result.try(case state.index {
          Some(index) -> Ok(index)
          None -> Error("history index custody was lost")
        })
        let ids = case scope {
          tool.ThisSession -> [current]
          tool.Repository -> list.map(sources, fn(item) { item.session })
        }
        search.query_authorized(index, ids, text, limit)
        |> result.map_error(string.inspect)
        |> result.map(
          list.map(_, fn(hit) { tool.Hit(hit.session, hit.entry, hit.snippet) }),
        )
      }
      process.send(reply, Hits(answer |> result.map_error(tool.IndexRefused)))
      advance(State(..state, phase: Ready))
    }
  }
}

fn stop(state: State, reply: process.Subject(String)) {
  case state.phase {
    Blocked(reason) -> {
      process.send(reply, reason)
      actor.continue(state)
    }
    _ -> {
      // Retirement is the last transition this owner makes, so a held call
      // has to be answered before the handles close under it.
      let state = drain(state, tool.IndexUnavailable("the index owner retired"))
      let closed = {
        use state <- result.try(close_source(state))
        case state.index {
          None -> Ok(state)
          Some(index) -> {
            use Nil <- result.map(
              search.close(index) |> result.map_error(string.inspect),
            )
            State(..state, index: None)
          }
        }
      }
      case closed {
        Ok(_) -> actor.stop()
        Error(reason) -> {
          process.send(reply, reason)
          block(state, "history retirement unconfirmed: " <> reason)
        }
      }
    }
  }
}
