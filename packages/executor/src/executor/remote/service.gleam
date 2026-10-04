//// Executor-side execution admission, never owner approval or a budget ledger.
////
//// Configuration binds exactly one peer label, executor label, Scope, generation,
//// journal and scoped broker/executor. The command-preparation adapter's verify
//// callback checks exact materialized paths/env/policy against administrative
//// registration; argv/cwd never choose a workspace. Every Submit verifies scope,
//// step, full digest and registration before reserving exact request/authorization
//// payloads, committing admission, then committing launch intent. Only that live
//// decision may start native work. Existing payloads on restart are reconciled,
//// never launched. A failure after any possible durable submission is uncertain.
////
//// Challenge W=1000 ms, margin=100 ms, at most 32 unused nonces. Nonce binds peer,
//// generation, scope/key/digest and monotonic issue time. B=R-W-margin is positive
//// and at least 1000 ms. First admission freezes receive+B; queue/preparation
//// consume it. The exact cleared helper wall_s must conservatively fit remaining
//// whole seconds, or launch is refused. No policy rewriting occurs after digest.
//// Session authority is explicit, with nonzero original resource/output ceilings.
//// Restart never interprets an old monotonic origin as renewed authorization.
////
//// Output retains exact encoded chunks through bounded journal asks, before
//// Query advertises them. A failed/overquota stream cancels locally and records a
//// terminal protocol failure. Log truncation remains a native result flag; root
//// must configure protocol streams to fail on any truncated bytes (#703).
//// Stdin is ordered/idempotent, 8 KiB/item, 128 items/1 MiB lifetime, checked
//// before forwarding to helper's 16 MiB FIFO. No pending unbounded stdin queue.
//// Receipts name exact terminal payload digest and follow owner durable commit.
//// Exit alone stays NativeUnconfirmed; close permanently fences the epoch and
//// only a witnessed scoped pool drain confirms native retirement.
////
//// ## Flow
////
//// `exchange` -> `handle` -> `apply_envelope` -> `submit` -> `first_submit`
//// -> `launch`; `query` reads retained custody without launching.
////
//// 1. `exchange` admits one bounded service ask outside the network writer.
//// 2. `apply_envelope` fences peer, role, scope and generation before mutation.
//// 3. `submit` compares exact materialization and returns original evidence.
//// 4. `first_submit` persists request, authority and admission before intent.
//// 5. `launch` consumes only a live committed authorization into native custody.
//// 6. `publish_output` and `publish_terminal` ask the separate durable sink.
//// 7. `close_scope` confirms retirement only from scoped witnessed native drain.

import broker/dispatch
import broker/exec
import broker/executor as local
import broker/internal/call
import broker/policy
import core/ids
import core/msgpack as mp
import executor/remote/admission
import executor/remote/identity
import executor/remote/journal
import executor/remote/native
import executor/remote/payload
import executor/remote/wire
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor as otp_actor
import gleam/otp/supervision
import gleam/result
import weft/actor

/// Trusted administrative assembly; remote requests cannot replace these facts.
pub type Config {
  /// Verify must reject unmapped resources and policies exceeding registration.
  Config(
    /// The provisioned owner label bound to the pinned peer certificate.
    owner: String,
    /// The provisioned executor label from the administrative scope.
    executor: String,
    /// The exact session/workspace binding and original authority epochs.
    scope: identity.Scope,
    /// The current monotone transport generation, separate from request identity.
    generation: Int,
    /// The already opened durable admission and exact payload custodian.
    journal: journal.Journal,
    /// The scoped native service whose witnessed pool drain proves retirement.
    native: local.Executor,
    /// Administrative validation of exact scope, registration and policy ceilings.
    verify: fn(identity.RequestKey, wire.Prepared) -> Result(Nil, Nil),
    /// The injected local monotonic elapsed clock, shared with native watchdog.
    now: fn() -> Int,
  )
}

/// A bounded actor owning serialized admission and live request controls.
pub opaque type Service {
  /// The listener owns each asynchronous ask until its actual reply or death.
  Service(config: Config, subject: process.Subject(Message), pid: process.Pid)
}

/// Fixed errors leave possibly committed original evidence retained.
pub type Error {
  /// Authentication/schema/generation or clearance binding failed before mutation.
  Invalid

  /// Lifetime evidence/challenge/output capacity is exhausted.
  Capacity

  /// Finite authorization expired, was reused or cannot fit native seconds.
  Expired

  /// A durable transaction/reply failed; recover the original key.
  Uncertain
}

type Ticket {
  Ticket(
    key: identity.RequestKey,
    digest: identity.Digest,
    generation: Int,
    issued: Int,
    nonce: BitArray,
  )
}

// An ambiguous local control reply is retained as a permanent input fence.
// Replaying that ordinal never forwards bytes again or asserts delivery.
type InputDelivery {
  Delivered(bytes: BitArray, eof: dispatch.Eof)
  DeliveryUncertain(bytes: BitArray, eof: dispatch.Eof)
}

type Row {
  Row(
    digest: identity.Digest,
    deadline: Int,
    native: native.Running,
    stdin: List(InputDelivery),
    stdin_bytes: Int,
  )
}

type AdmissionGate {
  Accepting
  Quiesced
}

type State {
  State(
    config: Config,
    generation: Int,
    tickets: List(Ticket),
    rows: Dict(identity.RequestKey, Row),
    covered: Dict(identity.RequestKey, identity.Digest),
    subject: process.Subject(Message),
    sequence: Int,
    gate: AdmissionGate,
  )
}

type Message {
  Quiesce(reply: process.Subject(Nil))
  Shutdown(reply: process.Subject(Result(Nil, Error)))
  ControlDone(key: identity.RequestKey, digest: identity.Digest)
  Exchange(
    envelope: wire.Envelope,
    reply: process.Subject(Result(wire.Body, Error)),
  )
}

type Sink {
  Sink(subject: process.Subject(SinkMessage))
}

type SinkState {
  SinkState(
    journal: journal.Journal,
    key: identity.RequestKey,
    digest: identity.Digest,
    ordinal: Int,
    bytes: Int,
    terminal: Option(BitArray),
    stream: wire.StreamPolicy,
  )
}

type SinkMessage {
  Chunk(chunk: dispatch.Chunk, reply: process.Subject(Result(Nil, Nil)))
  End(terminal: dispatch.Terminal, reply: process.Subject(Nil))
}

/// Starts admission over an already opened durable journal and scoped native pool.
/// This performs no launch or TLS operation and does not create an owner Broker.
///
/// ## Examples
///
/// ```gleam
/// service.start(config)
/// ```
pub fn start(config: Config) -> Result(Service, Error) {
  use Nil <- result.try(validate(config))
  builder(config)
  |> actor.unlinked
  |> actor.start
  |> result.map(fn(started) { Service(config, started.data, started.pid) })
  |> result.map_error(fn(_) { Uncertain })
}

/// Validates fixed identity before a host creates listening resources.
///
/// ## Examples
///
/// ```gleam
/// // service.validate(config) == Ok(Nil)
/// ```
pub fn validate(config: Config) -> Result(Nil, Error) {
  use _ <- result.try(
    identity.executor_id(config.owner) |> result.map_error(fn(_) { Invalid }),
  )
  case
    identity.scope_fields(config.scope).2 == config.executor
    && config.generation > 0
    && config.generation <= 2_147_483_647
    && journal.scope(config.journal) == config.scope
  {
    True -> Ok(Nil)
    False -> Error(Invalid)
  }
}

/// Describes linked admission custody without automatic same-scope resurrection.
/// The caller owns the returned PID and must explicitly shut down the service.
/// Parent exit stops this actor; native retirement remains a separate witness.
///
/// ## Examples
///
/// ```gleam
/// // service.supervised(config).start() -> Ok(started)
/// ```
pub fn supervised(config: Config) -> supervision.ChildSpecification(Service) {
  supervision.worker(fn() {
    use Nil <- result.try(
      validate(config)
      |> result.replace_error(otp_actor.InitFailed(
        "invalid remote service binding",
      )),
    )
    builder(config)
    |> actor.start
    |> result.map(fn(started) {
      otp_actor.Started(started.pid, Service(config, started.data, started.pid))
    })
  })
  |> supervision.restart(supervision.Temporary)
}

/// Returns the actor owned by the trusted local lifetime assembly.
///
/// ## Examples
///
/// ```gleam
/// // process.monitor(service.pid(remote))
/// ```
pub fn pid(service: Service) -> process.Pid {
  service.pid
}

/// Serializes denial of new challenges and submissions before host drain.
/// Queries, receipts and cancellation retain their existing custody meaning.
///
/// ## Examples
///
/// ```gleam
/// // service.quiesce(remote) == Ok(Nil)
/// ```
pub fn quiesce(service: Service) -> Result(Nil, Error) {
  call.try_call(service.subject, waiting: 2000, sending: Quiesce)
  |> result.replace(Nil)
  |> result.replace_error(Uncertain)
}

/// Closes the durable epoch and drains native custody before actor termination.
/// Failure leaves a quiesced actor and its original evidence retained. A dead
/// actor returns uncertainty; process death never establishes native retirement.
///
/// ## Examples
///
/// ```gleam
/// // service.shutdown(remote) == Ok(Nil), after witnessed scoped drain.
/// ```
pub fn shutdown(service: Service) -> Result(Nil, Error) {
  call.try_call(service.subject, waiting: 30_000, sending: Shutdown)
  |> result.unwrap(Error(Uncertain))
}

fn builder(
  config: Config,
) -> actor.Builder(State, Message, process.Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    Ok(
      actor.initialised(State(
        config,
        config.generation,
        [],
        dict.new(),
        dict.new(),
        subject,
        0,
        Accepting,
      ))
      |> actor.returning(subject),
    )
  })
  |> actor.on_message(handle)
  |> actor.trapping_exits(True)
}

/// Executes one already decoded authenticated envelope via bounded admission ask.
/// A timeout is uncertainty, because the request may already have committed.
///
/// ## Examples
///
/// ```gleam
/// service.exchange(service, envelope)
/// ```
pub fn exchange(
  service: Service,
  envelope: wire.Envelope,
) -> Result(wire.Body, Error) {
  let reply = process.new_subject()
  process.send(service.subject, Exchange(envelope, reply))
  process.receive(reply, 30_000) |> result.unwrap(Error(Uncertain))
}

/// Transfers one concrete exchange to service custody without a caller timeout.
/// The finite listener credit owns reply until consumption or service death.
/// No network worker is allowed to use this door without that custody.
///
/// ## Examples
///
/// `send_exchange(service, envelope, reply)` sends exactly one typed ask.
@internal
pub fn send_exchange(
  service: Service,
  envelope: wire.Envelope,
  reply: process.Subject(Result(wire.Body, Error)),
) -> Nil {
  process.send(service.subject, Exchange(envelope, reply))
}

/// Exposes only the immutable configured identity for transport validation.
///
/// ## Examples
///
/// ```gleam
/// service.configuration(service)
/// ```
pub fn configuration(service: Service) -> Config {
  service.config
}

/// Conservatively authorizes finite duration using only elapsed-clock remaining.
/// Offsets between hosts never enter this arithmetic.
///
/// ## Examples
///
/// ```gleam
/// service.attempt_budget(5000) // -> Ok(3900).
/// ```
pub fn attempt_budget(remaining_ms: Int) -> Result(Int, Error) {
  let budget = remaining_ms - 1000 - 100
  case budget >= 1000 && budget <= 86_400_000 {
    True -> Ok(budget)
    False -> Error(Expired)
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Quiesce(reply) -> {
      process.send(reply, Nil)
      actor.continue(State(..state, gate: Quiesced, tickets: []))
    }
    Shutdown(reply) -> {
      let state = State(..state, gate: Quiesced, tickets: [])
      case close_scope(state) {
        Ok(_) -> {
          process.send(reply, Ok(Nil))
          actor.stop()
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    }
    ControlDone(key, digest) -> {
      let rows = case dict.get(state.rows, key) {
        Ok(row) if row.digest == digest -> dict.delete(state.rows, key)
        _ -> state.rows
      }
      actor.continue(State(..state, rows:))
    }
    Exchange(envelope, reply) -> handle_exchange(state, envelope, reply)
  }
}

fn handle_exchange(
  state: State,
  envelope: wire.Envelope,
  reply: process.Subject(Result(wire.Body, Error)),
) -> actor.Next(State, Message) {
  case apply_envelope(state, envelope) {
    Ok(#(next, body)) -> {
      process.send(reply, Ok(body))
      actor.continue(next)
    }
    Error(error) -> {
      process.send(reply, Error(error))
      actor.continue(state)
    }
  }
}

fn apply_envelope(
  state: State,
  envelope: wire.Envelope,
) -> Result(#(State, wire.Body), Error) {
  let config = state.config
  use Nil <- result.try(
    case
      envelope.role == wire.Owner
      && envelope.owner == config.owner
      && envelope.executor == config.executor
      && envelope.scope == config.scope
      && envelope.generation >= state.generation
      && envelope.generation <= 2_147_483_647
    {
      True -> Ok(Nil)
      False -> Error(Invalid)
    },
  )
  case envelope.body {
    wire.ChallengeRequest(_, _)
      | wire.Submit(_, _, _, _, _)
      if state.gate == Quiesced
    -> Error(Invalid)
    wire.Hello ->
      Ok(#(
        State(
          ..state,
          generation: envelope.generation,
          tickets: case envelope.generation == state.generation {
            True -> state.tickets
            False -> []
          },
        ),
        wire.Hello,
      ))
    _ if envelope.generation != state.generation -> Error(Invalid)
    wire.ChallengeRequest(key, digest) -> challenge(state, key, digest)
    wire.Submit(key, digest, prepared, nonce, budget) ->
      submit(state, key, digest, prepared, nonce, budget)
    wire.Query(key, digest, cursor) -> {
      use body <- result.try(query(state, key, digest, cursor))
      Ok(#(state, body))
    }
    wire.Cancel(key, digest) -> cancel_key(state, key, digest)
    wire.Stdin(key, digest, ordinal, bytes, eof) ->
      feed(state, key, digest, ordinal, bytes, eof)
    wire.DurableReceipt(key, digest, terminal) -> {
      use _ <- result.try(
        journal.apply(
          config.journal,
          key,
          digest,
          admission.ConfirmOwnerReceipt(terminal),
        )
        |> durable,
      )
      use body <- result.try(query(state, key, digest, 64))
      Ok(#(state, body))
    }
    wire.CloseScope -> close_scope(state)
    _ -> Error(Invalid)
  }
}

fn live_row(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(Row, Error) {
  use row <- result.try(
    dict.get(state.rows, key) |> result.map_error(fn(_) { Uncertain }),
  )
  case row.digest == digest {
    True -> Ok(row)
    False -> Error(Invalid)
  }
}

fn challenge(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(#(State, wire.Body), Error) {
  use Nil <- result.try(case identity.key_scope(key) == state.config.scope {
    True -> Ok(Nil)
    False -> Error(Invalid)
  })
  let now = state.config.now()
  let tickets =
    list.filter(state.tickets, fn(ticket) { now - ticket.issued < 1000 })
  use Nil <- result.try(case list.drop(tickets, 31) == [] {
    True -> Ok(Nil)
    False -> Error(Capacity)
  })
  let nonce = crypto.strong_random_bytes(32)
  let ticket = Ticket(key, digest, state.generation, now, nonce)
  Ok(#(
    State(..state, tickets: [ticket, ..tickets]),
    wire.Challenge(key, digest, nonce, 1000),
  ))
}

fn submit(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  prepared: wire.Prepared,
  nonce: BitArray,
  budget: Int,
) -> Result(#(State, wire.Body), Error) {
  use Nil <- result.try(verify(state.config, key, digest, prepared))
  use previous <- result.try(
    journal.payloads(state.config.journal, key, digest) |> durable,
  )
  case previous {
    [] ->
      case journal.inspect(state.config.journal, key, digest) {
        Error(journal.Rejected(admission.UnknownRequest)) ->
          first_submit(state, key, digest, prepared, nonce, budget)
        Ok(_) -> {
          use body <- result.try(query(state, key, digest, 0))
          Ok(#(state, body))
        }
        Error(_) -> Error(Uncertain)
      }
    _ -> existing_submission(state, key, digest, previous)
  }
}

fn existing_submission(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  previous: List(payload.Item),
) -> Result(#(State, wire.Body), Error) {
  case
    list.any(previous, fn(item) {
      case item {
        payload.Cancellation(_) -> True
        _ -> False
      }
    })
  {
    True -> {
      use body <- result.try(query(state, key, digest, 0))
      Ok(#(state, body))
    }
    False -> {
      // A stored payload marks prior possible admission. Restart and lost-ack
      // reconciliation never recreates launch permission or a new deadline.
      use item <- result.try(
        list.find(previous, fn(item) {
          case item {
            payload.Request(_) -> True
            _ -> False
          }
        })
        |> result.map_error(fn(_) { Uncertain }),
      )
      use bytes <- result.try(case item {
        payload.Request(bytes) -> Ok(bytes)
        _ -> Error(Uncertain)
      })
      use original <- result.try(
        wire.decode_prepared(bytes) |> result.map_error(fn(_) { Uncertain }),
      )
      use original_digest <- result.try(
        wire.prepared_digest(original) |> result.map_error(fn(_) { Uncertain }),
      )
      use Nil <- result.try(case original_digest == digest {
        True -> Ok(Nil)
        False -> Error(Invalid)
      })
      use body <- result.try(query(state, key, digest, 0))
      Ok(#(state, body))
    }
  }
}

fn verify(
  config: Config,
  key: identity.RequestKey,
  digest: identity.Digest,
  prepared: wire.Prepared,
) -> Result(Nil, Error) {
  use computed <- result.try(
    wire.prepared_digest(prepared) |> result.map_error(fn(_) { Invalid }),
  )
  use Nil <- result.try(
    case identity.key_scope(key) == config.scope && computed == digest {
      True -> Ok(Nil)
      False -> Error(Invalid)
    },
  )
  use Nil <- result.try(
    config.verify(key, prepared) |> result.map_error(fn(_) { Invalid }),
  )
  case prepared.request.policy {
    None -> Error(Invalid)
    Some(policy) -> {
      use Nil <- result.try(
        policy.validate(policy) |> result.map_error(fn(_) { Invalid }),
      )
      let limits = policy.limits
      case
        limits.output_bytes > 0
        && limits.output_bytes <= 262_144
        && limits.cpu_s > 0
        && limits.mem_bytes > 0
        && limits.pids > 0
        && limits.fsize_bytes > 0
      {
        True -> Ok(Nil)
        False -> Error(Invalid)
      }
    }
  }
}

fn first_submit(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  prepared: wire.Prepared,
  nonce: BitArray,
  budget: Int,
) -> Result(#(State, wire.Body), Error) {
  use Nil <- result.try(case dict.size(state.rows) < 32 {
    True -> Ok(Nil)
    False -> Error(Capacity)
  })
  use deadline <- result.try(authorize(
    state,
    key,
    digest,
    prepared.lifetime,
    nonce,
    budget,
  ))
  use bytes <- result.try(
    wire.encode_prepared(prepared) |> result.map_error(fn(_) { Invalid }),
  )
  use authority <- result.try(
    wire.encode_value(
      mp.ArrayValue([
        mp.IntValue(state.generation),
        mp.IntValue(deadline),
        mp.IntValue(budget),
      ]),
    )
    |> result.map_error(fn(_) { Invalid }),
  )
  use Nil <- result.try(
    journal.put_payload(
      state.config.journal,
      key,
      digest,
      payload.Request(bytes),
    )
    |> durable,
  )
  use Nil <- result.try(
    journal.put_payload(
      state.config.journal,
      key,
      digest,
      payload.Authority(authority),
    )
    |> durable,
  )
  use _ <- result.try(
    journal.admit(state.config.journal, key, digest) |> durable,
  )
  let tickets = list.filter(state.tickets, fn(ticket) { ticket.nonce != nonce })
  let next = State(..state, tickets:, sequence: state.sequence + 1)
  case launch(next, key, digest, prepared, deadline) {
    Ok(answer) -> Ok(answer)
    Error(Expired) | Error(Invalid) -> refuse_admitted(next, key, digest)
    Error(error) -> Error(error)
  }
}

fn authorize(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  lifetime: wire.Lifetime,
  nonce: BitArray,
  budget: Int,
) -> Result(Int, Error) {
  case lifetime {
    wire.Session -> {
      case budget == 0 && nonce == <<0:size(256)>> {
        True -> Ok(0)
        False -> Error(Invalid)
      }
    }
    wire.Finite(ceiling) -> {
      use ticket <- result.try(
        list.find(state.tickets, fn(ticket) {
          ticket.key == key
          && ticket.digest == digest
          && ticket.generation == state.generation
          && ticket.nonce == nonce
        })
        |> result.map_error(fn(_) { Expired }),
      )
      let now = state.config.now()
      case
        now >= ticket.issued
        && now - ticket.issued < 1000
        && budget >= 1000
        && budget < ceiling
        && now + budget != 0
      {
        True -> Ok(now + budget)
        False -> Error(Expired)
      }
    }
  }
}

fn launch(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  prepared: wire.Prepared,
  deadline: Int,
) -> Result(#(State, wire.Body), Error) {
  let config = state.config
  use Nil <- result.try(verify(config, key, digest, prepared))
  let remaining = deadline - config.now()
  use Nil <- result.try(case prepared.request.policy, prepared.lifetime {
    Some(policy), wire.Finite(_) ->
      case
        policy.limits.wall_s > 0
        && remaining >= 1000
        && policy.limits.wall_s * 1000 <= remaining
      {
        True -> Ok(Nil)
        False -> Error(Expired)
      }
    Some(policy), wire.Session ->
      case policy.limits.wall_s == 0 {
        True -> Ok(Nil)
        False -> Error(Invalid)
      }
    None, _ -> Error(Invalid)
  })
  use decision <- result.try(
    journal.apply(config.journal, key, digest, admission.AuthorizeLaunch)
    |> durable,
  )
  case decision.effect {
    admission.NoLaunch -> {
      use body <- result.try(query(state, key, digest, 0))
      Ok(#(state, body))
    }
    admission.Launch(_) -> {
      let #(operation, _) = identity.key_fields(key)
      use operation <- result.try(
        ids.parse_op_id(operation) |> result.map_error(fn(_) { Invalid }),
      )
      let service_subject = state.subject
      let journal = config.journal
      let stream = prepared.stream
      use running <- result.try(
        native.start(
          native.Config(
            config.native,
            operation,
            prepared,
            state.sequence,
            deadline,
            config.now,
            fn() {
              use sink <- result.map(
                output_sink(journal, key, digest, stream)
                |> result.replace_error(Nil),
              )
              native.Publisher(
                fn(chunk) { publish_output(sink, chunk) },
                fn(terminal) { publish_terminal(sink, terminal) },
              )
            },
            fn() { process.send(service_subject, ControlDone(key, digest)) },
          ),
        )
        |> result.map_error(fn(_) { Uncertain }),
      )
      let row = Row(digest, deadline, running, [], 0)
      Ok(#(
        State(
          ..state,
          rows: dict.insert(state.rows, key, row),
          covered: dict.insert(state.covered, key, digest),
        ),
        wire.Evidence(key, digest, 2, deadline),
      ))
    }
  }
}

fn query(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  cursor: Int,
) -> Result(wire.Body, Error) {
  use evidence <- result.try(
    journal.inspect(state.config.journal, key, digest) |> durable,
  )
  use items <- result.try(
    journal.payloads(state.config.journal, key, digest) |> durable,
  )
  case
    list.find(items, fn(item) {
      case item {
        payload.Output(ordinal, _) -> ordinal == cursor
        _ -> False
      }
    })
  {
    Ok(payload.Output(ordinal, bytes)) ->
      Ok(wire.Output(key, digest, ordinal, bytes))
    _ -> query_terminal(state, key, digest, evidence, items)
  }
}

fn query_terminal(
  _state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  evidence: admission.Evidence,
  items: List(payload.Item),
) -> Result(wire.Body, Error) {
  case
    list.find(items, fn(item) {
      case item {
        payload.Terminal(_) -> True
        _ -> False
      }
    })
  {
    Ok(payload.Terminal(bytes)) -> {
      // Payload commit can precede reducer terminal commit. Never advertise a
      // half-committed terminal as receipt-ready evidence.
      case admission.phase(evidence) {
        admission.Terminal(_, _, _)
        | admission.Refused(_, _)
        | admission.Retired(_)
        | admission.RetiredRefusal(_) -> Ok(wire.Terminal(key, digest, bytes))
        _ ->
          Ok(wire.Evidence(
            key,
            digest,
            phase_code(admission.phase(evidence)),
            frozen_deadline(items),
          ))
      }
    }
    _ ->
      Ok(wire.Evidence(
        key,
        digest,
        phase_code(admission.phase(evidence)),
        frozen_deadline(items),
      ))
  }
}

fn frozen_deadline(items: List(payload.Item)) -> Int {
  let found =
    list.find(items, fn(item) {
      case item {
        payload.Authority(_) -> True
        _ -> False
      }
    })
  case found {
    Ok(payload.Authority(bytes)) ->
      case wire.decode_value(bytes) {
        Ok(mp.ArrayValue([mp.IntValue(_), mp.IntValue(deadline), mp.IntValue(_)])) ->
          deadline
        _ -> 0
      }
    _ -> 0
  }
}

fn feed(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  ordinal: Int,
  bytes: BitArray,
  eof: dispatch.Eof,
) -> Result(#(State, wire.Body), Error) {
  use row <- result.try(live_row(state, key, digest))
  case list.first(list.drop(row.stdin, ordinal)) {
    Ok(Delivered(previous, previous_eof))
      if previous == bytes && previous_eof == eof
    -> Ok(#(state, wire.Evidence(key, digest, 2, row.deadline)))
    Ok(DeliveryUncertain(previous, previous_eof))
      if previous == bytes && previous_eof == eof
    -> Error(Uncertain)
    Ok(_) -> Error(Invalid)
    Error(_) -> {
      use Nil <- result.try(
        case
          ordinal >= 0
          && ordinal < 128
          && bit_array.byte_size(bytes) <= 8192
          && row.stdin_bytes + bit_array.byte_size(bytes) <= 1_048_576
        {
          True -> Ok(Nil)
          False -> Error(Capacity)
        },
      )

      use Nil <- result.try(
        case
          ordinal == list.length(row.stdin)
          && !list.any(row.stdin, fn(item) {
            case item {
              Delivered(_, eof) | DeliveryUncertain(_, eof) ->
                eof == dispatch.EndOfInput
            }
          })
        {
          True -> Ok(Nil)
          False -> Error(Invalid)
        },
      )

      // A local ask timeout can follow actual forwarding. Retain the ordinal
      // and its exact bytes even then; a retry must remain uncertain, not write
      // them twice. Rejected(4) returns the updated fence without a delivery ACK.
      let #(delivery, response) = case native.stdin(row.native, bytes, eof) {
        Ok(Nil) -> #(
          Delivered(bytes, eof),
          wire.Evidence(key, digest, 2, row.deadline),
        )
        Error(Nil) -> #(DeliveryUncertain(bytes, eof), wire.Rejected(4))
      }
      let row =
        Row(
          ..row,
          stdin: list.append(row.stdin, [delivery]),
          stdin_bytes: row.stdin_bytes + bit_array.byte_size(bytes),
        )
      Ok(#(State(..state, rows: dict.insert(state.rows, key, row)), response))
    }
  }
}

fn close_scope(state: State) -> Result(#(State, wire.Body), Error) {
  // Durability failure leaves proof uncertain, but cannot prevent local drain.
  // Both attempts run; retirement is advertised only if fence and drain succeed.
  let fenced = journal.close_epoch(state.config.journal)
  let drained = local.close(state.config.native, draining: 2000, helpers: 5000)
  use Nil <- result.try(fenced |> durable)
  use Nil <- result.try(drained |> result.map_error(fn(_) { Uncertain }))
  use Nil <- result.try(
    list.try_each(dict.to_list(state.covered), fn(pair) {
      let #(key, digest) = pair
      journal.apply(
        state.config.journal,
        key,
        digest,
        admission.ConfirmRetirement,
      )
      |> durable
      |> result.replace(Nil)
    }),
  )
  Ok(#(state, wire.ScopeRetirement))
}

fn phase_code(phase: admission.Phase) -> Int {
  case phase {
    admission.Admitted -> 1
    admission.LaunchIntent(_) -> 2
    admission.Refused(_, _) -> 3
    admission.Terminal(_, _, _) -> 4
    admission.Retired(_) -> 5
    admission.RetiredRefusal(_) -> 6
  }
}

fn durable(value: Result(a, journal.Error)) -> Result(a, Error) {
  result.map_error(value, fn(error) {
    case error {
      journal.Rejected(admission.Saturated) -> Capacity
      journal.Rejected(_) -> Invalid
      _ -> Uncertain
    }
  })
}

fn output_sink(
  journal: journal.Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
  stream: wire.StreamPolicy,
) -> Result(Sink, Error) {
  actor.new(SinkState(journal, key, digest, 0, 0, None, stream))
  |> actor.on_message(handle_sink)
  |> actor.trapping_exits(True)
  |> actor.start
  |> result.map(fn(started) { Sink(started.data) })
  |> result.map_error(fn(_) { Uncertain })
}

fn publish_output(sink: Sink, chunk: dispatch.Chunk) -> Result(Nil, Nil) {
  let reply = process.new_subject()
  process.send(sink.subject, Chunk(chunk, reply))
  process.receive(reply, 30_000) |> result.unwrap(Error(Nil))
}

fn publish_terminal(sink: Sink, terminal: dispatch.Terminal) -> Nil {
  let reply = process.new_subject()
  process.send(sink.subject, End(terminal, reply))
  let _ = process.receive(reply, 30_000)
  Nil
}

fn handle_sink(
  state: SinkState,
  message: SinkMessage,
) -> actor.Next(SinkState, SinkMessage) {
  case message {
    Chunk(chunk, reply) -> {
      let outcome = retain_chunks(state, chunk, chunk.data)
      process.send(
        reply,
        result.replace(outcome, Nil) |> result.map_error(fn(_) { Nil }),
      )
      case outcome {
        Ok(next) -> actor.continue(next)
        Error(_) -> {
          let terminal =
            dispatch.Failed(exec.ProtocolViolation(
              "remote output quota or custody failure",
            ))
          let next = retain_terminal(state, terminal) |> result.unwrap(state)
          actor.continue(next)
        }
      }
    }
    End(terminal, reply) -> {
      // The relay serializes this after its final output. Persistence failure
      // leaves durable uncertainty, not a reason to retain an idle actor.
      let _ = retain_terminal(state, terminal)
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn retain_chunk(
  state: SinkState,
  chunk: dispatch.Chunk,
) -> Result(SinkState, Error) {
  use Nil <- result.try(case state.terminal {
    None -> Ok(Nil)
    Some(_) -> Error(Invalid)
  })
  use Nil <- result.try(
    case state.stream == wire.ProtocolStream && chunk.truncated {
      True -> Error(Capacity)
      False -> Ok(Nil)
    },
  )
  use bytes <- result.try(
    native.encode_output(chunk) |> result.map_error(fn(_) { Capacity }),
  )
  use Nil <- result.try(
    case
      state.ordinal < 64
      && state.bytes + bit_array.byte_size(bytes) <= 1_048_576
    {
      True -> Ok(Nil)
      False -> Error(Capacity)
    },
  )
  use Nil <- result.try(
    journal.put_payload(
      state.journal,
      state.key,
      state.digest,
      payload.Output(state.ordinal, bytes),
    )
    |> durable,
  )
  Ok(
    SinkState(
      ..state,
      ordinal: state.ordinal + 1,
      bytes: state.bytes + bit_array.byte_size(bytes),
    ),
  )
}

fn retain_terminal(
  state: SinkState,
  terminal: dispatch.Terminal,
) -> Result(SinkState, Error) {
  case state.terminal {
    Some(_) -> Ok(state)
    None -> {
      use bytes <- result.try(
        native.encode_terminal(terminal)
        |> result.map_error(fn(_) { Uncertain }),
      )
      use digest <- result.try(
        wire.digest(bytes) |> result.map_error(fn(_) { Uncertain }),
      )
      use Nil <- result.try(
        journal.put_payload(
          state.journal,
          state.key,
          state.digest,
          payload.Terminal(bytes),
        )
        |> durable,
      )
      use _ <- result.try(
        journal.apply(
          state.journal,
          state.key,
          state.digest,
          admission.ObserveTerminal(digest),
        )
        |> durable,
      )
      Ok(SinkState(..state, terminal: Some(bytes)))
    }
  }
}

fn retain_chunks(
  state: SinkState,
  chunk: dispatch.Chunk,
  remaining: BitArray,
) -> Result(SinkState, Error) {
  case remaining {
    <<first:bytes-size(8192), rest:bits>> if rest != <<>> -> {
      let total = chunk.total_bytes - bit_array.byte_size(rest)
      use next <- result.try(retain_chunk(
        state,
        dispatch.Chunk(
          ..chunk,
          data: first,
          total_bytes: total,
          truncated: False,
        ),
      ))
      retain_chunks(next, chunk, rest)
    }
    _ -> retain_chunk(state, dispatch.Chunk(..chunk, data: remaining))
  }
}

fn refuse_admitted(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(#(State, wire.Body), Error) {
  // Admission exists but no LaunchIntent was committed. Exact refusal bytes
  // establish absence of native custody, while durable owner receipt is owed.
  use bytes <- result.try(
    native.encode_terminal(
      dispatch.Failed(exec.ProtocolViolation(
        "remote authorization expired before native launch",
      )),
    )
    |> result.map_error(fn(_) { Uncertain }),
  )
  use result_digest <- result.try(
    wire.digest(bytes) |> result.map_error(fn(_) { Uncertain }),
  )
  use Nil <- result.try(
    journal.put_payload(
      state.config.journal,
      key,
      digest,
      payload.Terminal(bytes),
    )
    |> durable,
  )
  use _ <- result.try(
    journal.apply(
      state.config.journal,
      key,
      digest,
      admission.RefuseBeforeLaunch(result_digest),
    )
    |> durable,
  )
  Ok(#(state, wire.Terminal(key, digest, bytes)))
}

fn cancel_key(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(#(State, wire.Body), Error) {
  // A live control is already bound to this exact key and digest. Cancel it
  // before asking durability, so a poisoned journal cannot keep native work live.
  case live_row(state, key, digest) {
    Ok(row) -> native.cancel(row.native)
    Error(_) -> Nil
  }

  // The immutable cancellation reservation is the recovery fence even if the
  // process dies between payload, Admit and Refuse commits. Submit treats any
  // prior payload or bare admission as non-fresh and never authorizes launch.
  use bytes <- result.try(
    native.encode_terminal(
      dispatch.Failed(exec.ProtocolViolation(
        "remote request cancelled before native launch",
      )),
    )
    |> result.map_error(fn(_) { Uncertain }),
  )
  use Nil <- result.try(
    journal.put_payload(
      state.config.journal,
      key,
      digest,
      payload.Cancellation(bytes),
    )
    |> durable,
  )
  use decision <- result.try(
    journal.admit(state.config.journal, key, digest) |> durable,
  )
  case admission.phase(decision.evidence) {
    admission.Admitted -> {
      use result_digest <- result.try(
        wire.digest(bytes) |> result.map_error(fn(_) { Uncertain }),
      )
      use Nil <- result.try(
        journal.put_payload(
          state.config.journal,
          key,
          digest,
          payload.Terminal(bytes),
        )
        |> durable,
      )
      use _ <- result.try(
        journal.apply(
          state.config.journal,
          key,
          digest,
          admission.RefuseBeforeLaunch(result_digest),
        )
        |> durable,
      )
      Ok(#(state, wire.Terminal(key, digest, bytes)))
    }
    _ -> {
      use body <- result.try(query(state, key, digest, 64))
      Ok(#(state, body))
    }
  }
}
