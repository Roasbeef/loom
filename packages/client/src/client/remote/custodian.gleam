//// One supervised actor owns one session's remote tool journal.
////
//// `execute` asks for an atomic fresh reservation and a bounded final ticket.
//// Only a fresh reservation starts a weft-owned worker. Caller death loses
//// its ticket, never the worker or committed report. `reported` consumes task
//// reports, commits exact final bytes and only then answers the ticket.
//// Exact commit and complete live delivery discharge a durable run marker.
//// A restarted owner with any unreleased run remains recovery-only.
////
//// Requests are typed and byte bounded; task admission is bounded by four
//// active runs. These properties do not bound an OTP mailbox: root must bind
//// the handle to its bounded ingress/effect pool. No unbounded cast writer,
//// observer list, arbitrary SQL closure or process ledger is exposed here.
////
//// ## Flow
////
//// `execute_with_profile` → `begin` → `reported` retains exact final tool outcomes.
//// `retain_report` commits a complete report before its final reference.
//// `read_report_chunk` reads immutable bounded owner-local slices.
//// `fatal_fence` → `unresolved` permanently fences this incarnation's discharge.
//// `answer_once` preserves the first disposition; `fence_admission` blocks reuse.
//// `reserve_service_child` → `admit_offer` → `reserve_command_child` commits
//// service/offer/complete native custody through the same serialized `handle`.
//// `service_child`, `offer`, `command_offer_for_origin` and `command_child`
//// recover original evidence;
//// `cancel_service` fences those links in one transaction. `collect` defers
//// physical-service payload deletion until independent recovery transfer exists.

import broker/internal/call
import client/remote/outcome
import core/command
import core/ids
import core/msgpack
import core/remote_tool
import core/report_value
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/supervision
import gleam/result
import runtime/effects
import storage/owner_custody as custody
import storage/storage
import weft
import weft/actor
import weft/registry

/// Immutable dependencies and bounded worker policy.
pub opaque type Config {
  Config(
    /// Separate owner journal pathname.
    path: String,
    /// Durable session identity bound in SQLite metadata.
    session: ids.SessionId,
    /// Persistent row and byte quotas.
    limits: custody.Limits,
    /// Maximum independently owned active tool bodies.
    active: Int,
    /// Hard lifetime of one live owner task, in milliseconds.
    task_ms: Int,
    /// Trusted host SHA-256 seam, absent for ordinary-only custody.
    sha256: option.Option(fn(BitArray) -> BitArray),
    /// Remote runner receives its pinned custodian and original runtime identity.
    runner: fn(Handle, remote_tool.ToolKey, effects.ToolRun) ->
      effects.ToolOutcome,
  )
}

/// External handles resolve the supervised registry; runner handles pin one owner.
/// Only admission supplies the private pinned destination before spawning work.
pub opaque type Handle {
  Handle(
    address: registry.Address(Message),
    destination: Destination,
    task_ms: Int,
    /// Pre-send quota bound, rechecked against the actor store configuration.
    limits: custody.Limits,
  )
}

// External history follows the registry; an admitted runner retains one incarnation.
type Destination {
  Reclaimable
  Pinned(process.Subject(Message))
}

/// Closed actor vocabulary; no caller can submit a query closure.
pub opaque type Message {
  Execute(
    remote_tool.ToolKey,
    custody.FinalProfile,
    BitArray,
    BitArray,
    effects.ToolRun,
    process.Subject(Result(effects.ToolOutcome, custody.Error)),
    process.Subject(Result(Nil, custody.Error)),
  )
  Lookup(
    remote_tool.ToolKey,
    BitArray,
    BitArray,
    process.Subject(Result(custody.Evidence, custody.Error)),
  )
  ReserveChild(
    remote_tool.ChildOrigin,
    ids.EntryId,
    BitArray,
    process.Subject(Result(#(ids.EntryId, BitArray), custody.Error)),
  )

  /// A configured, byte-bounded semantic invocation reservation.
  ReserveWorkspace(
    remote_tool.ChildOrigin,
    ids.EntryId,
    custody.WorkspaceRequest,
    process.Subject(Result(Nil, custody.Error)),
  )

  /// A configured, byte-bounded semantic completion custody transfer.
  ReceiveWorkspace(
    remote_tool.ChildOrigin,
    ids.EntryId,
    custody.WorkspaceCompletion,
    process.Subject(Result(Nil, custody.Error)),
  )

  /// Exact outer service reservation; no transport or preparation is performed.
  ReserveService(
    custody.ServiceRequest,
    process.Subject(Result(Nil, custody.Error)),
  )

  /// Readback of the original physical service and its independent completion.
  ReadService(
    command.ServiceKey,
    process.Subject(
      Result(
        #(custody.ServiceRequest, option.Option(custody.Payload)),
        custody.Error,
      ),
    ),
  )

  /// Exact immutable command offer admission after original service comparison.
  AdmitOffer(
    custody.ServiceRequest,
    custody.CommandOfferPayload,
    process.Subject(Result(custody.Admission, custody.Error)),
  )

  /// Header-first readback of a retained command offer.
  ReadOffer(
    command.CommandRef,
    process.Subject(Result(custody.CommandOfferPayload, custody.Error)),
  )

  /// Indexed historical offer data, including exact cancelled evidence.
  ReadOfferForOrigin(
    remote_tool.ChildOrigin,
    process.Subject(Result(custody.CommandOfferPayload, custody.Error)),
  )

  /// Complete native content reserved only by the post-clearance caller.
  ReserveCommand(
    custody.CommandOfferPayload,
    ids.EntryId,
    custody.Payload,
    process.Subject(Result(#(ids.EntryId, custody.Payload), custody.Error)),
  )

  /// Readback preserves original native UUID/content and optional receipt.
  ReadCommand(
    command.CommandRef,
    process.Subject(
      Result(
        #(ids.EntryId, custody.Payload, option.Option(custody.Payload)),
        custody.Error,
      ),
    ),
  )

  /// One atomic fence across service, offers and allocated native commands.
  CancelService(command.ServiceKey, process.Subject(Result(Nil, custody.Error)))

  ReadChild(
    remote_tool.ChildOrigin,
    process.Subject(
      Result(#(ids.EntryId, BitArray, option.Option(BitArray)), custody.Error),
    ),
  )
  ReceiveChild(
    remote_tool.ChildOrigin,
    ids.EntryId,
    BitArray,
    process.Subject(Result(Nil, custody.Error)),
  )
  CancelChild(
    remote_tool.ChildOrigin,
    process.Subject(Result(Nil, custody.Error)),
  )
  Collect(
    remote_tool.ToolKey,
    storage.Storage(Nil),
    process.Subject(Result(Nil, custody.Error)),
  )

  /// Only an original pinned live run can commit a bounded complete report.
  RetainReport(
    remote_tool.ToolKey,
    report_value.CompleteReport,
    process.Subject(Result(report_value.ReportRef, custody.Error)),
  )

  /// Authenticated owner assembly supplies the session-bound report reference.
  ReadReportChunk(
    report_value.ReportRef,
    Int,
    process.Subject(Result(custody.ReportChunk, custody.Error)),
  )

  FenceRun(remote_tool.ToolKey, process.Subject(Result(Nil, custody.Error)))
  Reported(String, weft.Pulled(effects.ToolOutcome, Nil))
  Stop(process.Subject(Result(Nil, custody.Error)))
}

type Held {
  Held(
    key: remote_tool.ToolKey,
    original: effects.ToolRun,
    profile: custody.FinalProfile,
    reports: process.Subject(weft.Pulled(effects.ToolOutcome, Nil)),
    cancel: weft.Cancel,
    disposition: Disposition,
    reply: process.Subject(Result(effects.ToolOutcome, custody.Error)),
  )
}

type Disposition {
  AwaitingReport
  FinalCommitted(custody.Payload)
  Unresolved
}

type AdmissionState {
  Admitting
  RecoveryOnly
}

type State {
  State(
    config: Config,
    store: custody.Store,
    live: Dict(String, Held),
    admission: AdmissionState,
    owner: Handle,
    self: process.Subject(Message),
  )
}

/// Checks active capacity and a finite owner task lifetime.
///
/// ## Examples
///
/// ```gleam
/// // custodian.config(path, session, limits, 4, 60_000, remote_runner)
/// ```
pub fn config(
  path: String,
  session: ids.SessionId,
  limits: custody.Limits,
  active: Int,
  task_ms: Int,
  runner: fn(Handle, remote_tool.ToolKey, effects.ToolRun) ->
    effects.ToolOutcome,
) -> Result(Config, custody.Error) {
  case active > 0 && active <= 4 && task_ms > 0 && task_ms <= 86_400_000 {
    True ->
      Ok(Config(
        path:,
        session:,
        limits:,
        active:,
        task_ms:,
        sha256: option.None,
        runner:,
      ))
    False -> Error(custody.Invalid("invalid owner task capacity or lifetime"))
  }
}

/// Allocates an address outside every transport connection.
///
/// ## Examples
///
/// ```gleam
/// // let owner = custodian.new(names, config)
/// ```
pub fn new(names: registry.Registry, config: Config) -> Handle {
  Handle(
    registry.new_address(names),
    Reclaimable,
    config.task_ms,
    config.limits,
  )
}

/// Configures report hashing through the existing trusted host SHA-256 function.
/// This constructor creates no storage-to-host dependency or hashing package.
///
/// ## Examples
///
/// `config_with_reports(path, session, limits, active, ms, runner, bootstrap.sha256)` supports explicit report profiles.
pub fn config_with_reports(
  path: String,
  session: ids.SessionId,
  limits: custody.Limits,
  active: Int,
  task_ms: Int,
  runner: fn(Handle, remote_tool.ToolKey, effects.ToolRun) ->
    effects.ToolOutcome,
  sha256: fn(BitArray) -> BitArray,
) -> Result(Config, custody.Error) {
  config(path, session, limits, active, task_ms, runner)
  |> result.map(fn(config) { Config(..config, sha256: option.Some(sha256)) })
}

/// Starts the actor; production embeds supervised instead.
///
/// ## Examples
///
/// ```gleam
/// // custodian.start(owner, config)
/// ```
pub fn start(
  owner: Handle,
  config: Config,
) -> actor.StartResult(process.Subject(Message)) {
  builder(owner, config) |> actor.start
}

/// Embeds journal custody under the session's existing supervisor.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.add(supervisor, custodian.supervised(owner, config))
/// ```
pub fn supervised(
  owner: Handle,
  config: Config,
) -> supervision.ChildSpecification(process.Subject(Message)) {
  builder(owner, config) |> actor.supervised
}

fn builder(owner: Handle, config: Config) {
  actor.new_with_initialiser(5000, fn(subject) {
    use store <- result.try(
      case config.sha256 {
        option.None -> custody.open(config.path, config.session, config.limits)
        option.Some(sha256) ->
          custody.open_with_reports(
            config.path,
            config.session,
            config.limits,
            sha256,
          )
      }
      |> result.replace_error("owner custody open failed"),
    )
    use Nil <- result.try(
      custody.validate_finals(store, fn(key, profile, reference, payload) {
        case profile {
          custody.OrdinaryFinal -> Ok(Nil)
          custody.CodeModeReportV1 -> {
            use final <- result.try(
              effects.decode_tool_outcome(custody.bytes(payload)),
            )
            use terminal <- result.try(
              custody.report_outcome(store, key)
              |> result.replace_error("report terminal lookup failed"),
            )
            use Nil <- result.try(outcome.validate_final(
              profile,
              reference,
              terminal,
              final,
            ))
            use request <- result.try(
              custody.original_request(store, key)
              |> result.replace_error("original request lookup failed"),
            )
            outcome.validate_original_request(request, final)
          }
        }
      })
      |> result.map_error(fn(_) {
        let _closed = custody.close(store)
        "owner final-report association failed"
      }),
    )
    use outstanding <- result.try(
      custody.unreleased(store)
      |> result.map_error(fn(_) {
        let _closed = custody.close(store)
        "owner custody discharge probe failed"
      }),
    )
    let admission = case outstanding {
      custody.Unreleased -> RecoveryOnly
      custody.Released -> Admitting
    }
    let pinned = Handle(..owner, destination: Pinned(subject))
    Ok(
      actor.initialised(State(
        config:,
        store:,
        live: dict.new(),
        admission:,
        owner: pinned,
        self: subject,
      ))
      |> actor.returning(subject),
    )
  })
  |> actor.addressed(owner.address)
  |> actor.on_message(handle)
  |> actor.trapping_exits(True)
  |> actor.on_shutdown(fn(state, _reason) {
    list.each(dict.values(state.live), fn(held) { weft.cancel(held.cancel) })
    let _closed = custody.close(state.store)
    Nil
  })
}

/// Starts only a fresh admitted task, then awaits a bounded final ticket.
/// A timeout is uncertainty; the supervised owner retains committed evidence.
///
/// ## Examples
///
/// ```gleam
/// // custodian.execute(owner, key, arguments, request, original_run)
/// ```
pub fn execute(
  owner: Handle,
  key: remote_tool.ToolKey,
  arguments: BitArray,
  request: BitArray,
  original: effects.ToolRun,
) -> Result(effects.ToolOutcome, custody.Error) {
  execute_with_profile(
    owner,
    key,
    arguments,
    request,
    original,
    custody.OrdinaryFinal,
  )
}

/// Starts only a Fresh original run under its trusted immutable final profile.
///
/// ## Examples
///
/// `execute_with_profile(owner, key, args, request, original, custody.CodeModeReportV1)` never derives profile from the call name.
pub fn execute_with_profile(
  owner: Handle,
  key: remote_tool.ToolKey,
  arguments: BitArray,
  request: BitArray,
  original: effects.ToolRun,
  profile: custody.FinalProfile,
) -> Result(effects.ToolOutcome, custody.Error) {
  use Nil <- result.try(input_bound(arguments, 262_144))
  use Nil <- result.try(input_bound(request, 262_144))
  let ticket = process.new_subject()
  use Nil <- result.try(
    ask(owner, fn(reply) {
      Execute(key, profile, arguments, request, original, ticket, reply)
    }),
  )
  process.receive(ticket, owner.task_ms + 1000)
  |> result.unwrap(Error(custody.Unavailable("owner final ticket timed out")))
}

/// Checks exact immutable request bytes before exposing final or child evidence.
/// Missing evidence never grants fresh execution permission.
///
/// ## Examples
///
/// ```gleam
/// // custodian.lookup(owner, key, arguments, request)
/// ```
pub fn lookup(
  owner: Handle,
  key: remote_tool.ToolKey,
  arguments: BitArray,
  request: BitArray,
) -> Result(custody.Evidence, custody.Error) {
  use Nil <- result.try(input_bound(arguments, 262_144))
  use Nil <- result.try(input_bound(request, 262_144))
  ask(owner, fn(reply) { Lookup(key, arguments, request, reply) })
}

/// Reserves once or returns the original UUID and exact request on retry.
/// Root mints proposed_id outside connections; retained origins ignore a new
/// candidate only after exact parent identity and request equality checks.
///
/// ## Examples
///
/// ```gleam
/// // custodian.reserve_child(owner, original_origin, proposed_id, request)
/// ```
pub fn reserve_child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
  proposed_id: ids.EntryId,
  request: BitArray,
) -> Result(#(ids.EntryId, BitArray), custody.Error) {
  use Nil <- result.try(input_bound(request, 131_072))
  ask(owner, fn(reply) { ReserveChild(origin, proposed_id, request, reply) })
}

/// Reserves exact workspace invocation bytes with their original UUID.
/// Both semantic and configured byte limits are checked before mailbox send.
/// A concurrent candidate with another UUID conflicts, rather than executing.
///
/// ## Examples
///
/// `reserve_workspace_child(owner, origin, id, bytes)` commits before send.
pub fn reserve_workspace_child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
  id: ids.EntryId,
  request: BitArray,
) -> Result(Nil, custody.Error) {
  use request <- result.try(custody.workspace_request(owner.limits, request))
  ask(owner, fn(reply) { ReserveWorkspace(origin, id, request, reply) })
}

/// Commits exact workspace completion bytes before returning durable custody.
/// The configured byte quota is checked before bytes enter the owner mailbox.
///
/// ## Examples
///
/// `receive_workspace_child(owner, origin, id, bytes)` permits an exact duplicate.
pub fn receive_workspace_child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
  id: ids.EntryId,
  receipt: BitArray,
) -> Result(Nil, custody.Error) {
  use receipt <- result.try(custody.workspace_completion(owner.limits, receipt))
  ask(owner, fn(reply) { ReceiveWorkspace(origin, id, receipt, reply) })
}

/// Commits complete original Compile/Launch input before preparation or send.
/// Bound checks precede the mailbox; the original service UUID is never minted here.
///
/// ## Examples
///
/// `reserve_service_child(owner, key, input)` returns only after the commit.
pub fn reserve_service_child(
  owner: Handle,
  key: command.ServiceKey,
  input: BitArray,
) -> Result(custody.ServiceRequest, custody.Error) {
  use request <- result.try(custody.service_request(owner.limits, key, input))
  use Nil <- result.try(
    ask(owner, fn(reply) { ReserveService(request, reply) }),
  )
  Ok(request)
}

/// Retrieves the exact original service and independent completion custody.
///
/// ## Examples
///
/// `service_child(owner, key)` never grants a second service execution.
pub fn service_child(
  owner: Handle,
  key: command.ServiceKey,
) -> Result(
  #(custody.ServiceRequest, option.Option(custody.Payload)),
  custody.Error,
) {
  ask(owner, fn(reply) { ReadService(key, reply) })
}

/// Commits an exact immutable offer after the original service input comparison.
/// A capacity refusal leaves the executor responsible for retaining its offer.
///
/// ## Examples
///
/// `admit_offer(owner, original, offer)` returns Retained for an exact duplicate.
pub fn admit_offer(
  owner: Handle,
  original: custody.ServiceRequest,
  offer: custody.CommandOfferPayload,
) -> Result(custody.Admission, custody.Error) {
  use _ <- result.try(custody.workspace_request(
    owner.limits,
    custody.service_content(original),
  ))
  let #(ref, digest) = custody.offer_identity(offer)
  use offer <- result.try(custody.command_offer_payload(
    owner.limits,
    ref,
    digest,
    custody.offer_content(offer),
  ))
  ask(owner, fn(reply) { AdmitOffer(original, offer, reply) })
}

/// Retrieves the original retained offer without allocating native identity.
///
/// ## Examples
///
/// `offer(owner, ref)` refuses changed identity and cancelled authority.
pub fn offer(
  owner: Handle,
  ref: command.CommandRef,
) -> Result(custody.CommandOfferPayload, custody.Error) {
  ask(owner, fn(reply) { ReadOffer(ref, reply) })
}

/// Reads a complete historical offer through its original native origin.
/// The existing five-second custodian ask grants no live clearance or reservation.
/// Exact cancellation history remains available; frozen evidence refuses.
///
/// ## Examples
///
/// `command_offer_for_origin(owner, command.native_origin(ref))` reads retained
/// identity and bytes after cancellation without allocating a native UUID.
pub fn command_offer_for_origin(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
) -> Result(custody.CommandOfferPayload, custody.Error) {
  ask(owner, fn(reply) { ReadOfferForOrigin(origin, reply) })
}

/// Reserves COMPLETE post-clearance native content under the original offer.
/// Exact duplicates return the original UUID, even with another candidate.
///
/// ## Examples
///
/// `reserve_command_child(owner, offer, id, prepared)` commits before native send.
pub fn reserve_command_child(
  owner: Handle,
  offer: custody.CommandOfferPayload,
  candidate: ids.EntryId,
  prepared: BitArray,
) -> Result(#(ids.EntryId, custody.Payload), custody.Error) {
  let #(ref, digest) = custody.offer_identity(offer)
  use offer <- result.try(custody.command_offer_payload(
    owner.limits,
    ref,
    digest,
    custody.offer_content(offer),
  ))
  use request <- result.try(custody.payload(owner.limits, prepared))
  ask(owner, fn(reply) { ReserveCommand(offer, candidate, request, reply) })
}

/// Retrieves original complete native evidence for reconciliation after loss.
///
/// ## Examples
///
/// `command_child(owner, ref)` never re-clears uncertain native execution.
pub fn command_child(
  owner: Handle,
  ref: command.CommandRef,
) -> Result(
  #(ids.EntryId, custody.Payload, option.Option(custody.Payload)),
  custody.Error,
) {
  ask(owner, fn(reply) { ReadCommand(ref, reply) })
}

/// Atomically fences outer service, immutable offers and allocated native rows.
/// Persistence failure requires the caller's existing fatal assembly fence.
///
/// ## Examples
///
/// `cancel_service(owner, key)` preserves the original native bytes for late receipt.
pub fn cancel_service(
  owner: Handle,
  key: command.ServiceKey,
) -> Result(Nil, custody.Error) {
  ask(owner, fn(reply) { CancelService(key, reply) })
}

/// Retrieves stable UUID, outgoing bytes and optional exact child receipt.
///
/// ## Examples
///
/// ```gleam
/// // custodian.child(owner, original_origin)
/// ```
pub fn child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
) -> Result(#(ids.EntryId, BitArray, option.Option(BitArray)), custody.Error) {
  ask(owner, fn(reply) { ReadChild(origin, reply) })
}

/// Commits exact child result bytes before the dispatcher advertises receipt.
///
/// ## Examples
///
/// ```gleam
/// // custodian.receive_child(owner, origin, id, receipt)
/// ```
pub fn receive_child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
  id: ids.EntryId,
  receipt: BitArray,
) -> Result(Nil, custody.Error) {
  use Nil <- result.try(input_bound(receipt, 2_097_152))
  ask(owner, fn(reply) { ReceiveChild(origin, id, receipt, reply) })
}

/// Encodes bounded ordered output and terminal bytes without text conversion.
/// Each encoded remote output is retained byte for byte with its boundary.
///
/// ## Examples
///
/// ```gleam
/// // custodian.receipt(outputs, terminal)
/// ```
pub fn receipt(
  outputs: List(BitArray),
  terminal: BitArray,
) -> Result(BitArray, custody.Error) {
  use Nil <- result.try(input_bound(terminal, 32_768))
  let within =
    list.fold(outputs, #(0, 0), fn(acc, bytes) {
      #(acc.0 + 1, acc.1 + bit_array.byte_size(bytes))
    })
  use Nil <- result.try(case within.0 <= 64 && within.1 <= 1_048_576 {
    True -> Ok(Nil)
    False -> Error(custody.Capacity)
  })
  use _ <- result.try(
    list.try_map(outputs, fn(bytes) { input_bound(bytes, 16_384) }),
  )
  msgpack.encode(
    msgpack.ArrayValue([
      msgpack.ArrayValue(list.map(outputs, msgpack.BinaryValue)),
      msgpack.BinaryValue(terminal),
    ]),
  )
  |> result.replace_error(custody.Invalid("invalid exact child receipt"))
}

/// Durably fences the same original origin, including before UUID reservation.
/// A refusal must stop managed dispatch; it is not an acknowledged cancel.
///
/// ## Examples
///
/// ```gleam
/// // custodian.cancel_child(owner, original_origin)
/// ```
pub fn cancel_child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
) -> Result(Nil, custody.Error) {
  ask(owner, fn(reply) { CancelChild(origin, reply) })
}

/// Reads actual reserved session storage and collects only an exact handoff.
/// ToolFailed records stay retained because their synthetic message is not exact.
///
/// ## Examples
///
/// ```gleam
/// // custodian.collect(owner, key, actual_session_storage)
/// ```
pub fn collect(
  owner: Handle,
  key: remote_tool.ToolKey,
  source: storage.Storage(a),
) -> Result(Nil, custody.Error) {
  let erased =
    storage.Storage(
      handle: Nil,
      commit: fn(_, tx) { storage.commit(source, tx) },
      get_entries: fn(_, ids) { storage.get_entries(source, ids) },
      get_register: fn(_, ns, key) { storage.get_register(source, ns, key) },
      list_registers: fn(_, ns, prefix) {
        storage.list_registers(source, ns, prefix)
      },
      scan_branch: fn(_, query) { storage.scan_branch(source, query) },
      scan_entries: fn(_, query) { storage.scan_entries(source, query) },
      scan_entry_heads: fn(_, query) { storage.scan_entry_heads(source, query) },
      scan_usage: fn(_, query) { storage.scan_usage(source, query) },
      stats: fn(_) { storage.stats(source) },
      close: fn(_) { storage.close(source) },
    )
  ask(owner, fn(reply) { Collect(key, erased, reply) })
}

/// Stops journal ownership after requesting cancellation of active weft runs.
/// This is not a native retirement witness and grants no collection authority.
///
/// ## Examples
///
/// ```gleam
/// // custodian.stop(owner)
/// ```
pub fn stop(owner: Handle) -> Result(Nil, custody.Error) {
  ask(owner, Stop)
}

/// Permanently fences the current run after an unresolved consumer failure.
/// A later ordinary outcome can be retained but cannot discharge this incarnation.
///
/// ## Examples
///
/// `fatal_fence(owner, key)` must use the pinned handle supplied to the runner.
pub fn fatal_fence(
  owner: Handle,
  key: remote_tool.ToolKey,
) -> Result(Nil, custody.Error) {
  ask(owner, fn(reply) { FenceRun(key, reply) })
}

/// Commits a checked report through the original live pinned custodian.
/// Any error or lost reply fences the original run before returning uncertainty.
///
/// ## Examples
///
/// `retain_report(pinned_owner, original_key, report)` precedes bounded final rendering.
pub fn retain_report(
  owner: Handle,
  key: remote_tool.ToolKey,
  report: report_value.CompleteReport,
) -> Result(report_value.ReportRef, custody.Error) {
  case owner.destination {
    Reclaimable -> Error(custody.Conflict)
    Pinned(_) -> {
      let retained = ask(owner, fn(reply) { RetainReport(key, report, reply) })
      case retained {
        Ok(reference) -> Ok(reference)
        Error(error) -> {
          let _fenced = fatal_fence(owner, key)
          Error(error)
        }
      }
    }
  }
}

/// Reads one aligned bounded chunk through this session's existing owner door.
/// The caller's authenticated assembly, rather than the URI, grants access.
///
/// ## Examples
///
/// `read_report_chunk(owner, reference, 0)` never contacts an executor filesystem.
pub fn read_report_chunk(
  owner: Handle,
  reference: report_value.ReportRef,
  offset: Int,
) -> Result(custody.ReportChunk, custody.Error) {
  ask(owner, fn(reply) { ReadReportChunk(reference, offset, reply) })
}

fn ask(
  owner: Handle,
  message: fn(process.Subject(Result(a, custody.Error))) -> Message,
) -> Result(a, custody.Error) {
  use subject <- result.try(
    case owner.destination {
      Reclaimable -> registry.lookup(owner.address)
      Pinned(subject) -> Ok(subject)
    }
    |> result.replace_error(custody.Unavailable(
      "owner not supervised or unavailable",
    )),
  )
  call.try_call(subject, waiting: 5000, sending: message)
  |> result.unwrap(Error(custody.Unavailable("owner ask failed")))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Execute(key, profile, args, request, original, ticket, reply) ->
      begin(state, key, profile, args, request, original, ticket, reply)
    Lookup(key, args, request, reply) -> {
      let outcome = {
        use args <- result.try(custody.payload(state.config.limits, args))
        use request <- result.try(custody.payload(state.config.limits, request))
        use Nil <- result.try(custody.validate_request(
          state.store,
          key,
          args,
          request,
        ))
        custody.lookup(state.store, key)
      }
      process.send(reply, outcome)
      resume(state)
    }
    ReserveChild(origin, candidate, request, reply) -> {
      process.send(reply, reserve(state, origin, candidate, request))
      resume(state)
    }
    ReserveWorkspace(origin, id, request, reply) -> {
      process.send(
        reply,
        custody.admit_workspace_child(state.store, origin, id, request),
      )
      resume(state)
    }
    ReceiveWorkspace(origin, id, receipt, reply) -> {
      process.send(
        reply,
        custody.receive_workspace_child(state.store, origin, id, receipt),
      )
      resume(state)
    }
    ReserveService(request, reply) -> {
      process.send(reply, custody.admit_service_child(state.store, request))
      resume(state)
    }
    ReadService(key, reply) -> {
      process.send(reply, custody.service_child(state.store, key))
      resume(state)
    }
    AdmitOffer(original, offer, reply) -> {
      process.send(reply, custody.admit_offer(state.store, original, offer))
      resume(state)
    }
    ReadOffer(ref, reply) -> {
      process.send(reply, custody.offer(state.store, ref))
      resume(state)
    }
    ReadOfferForOrigin(origin, reply) -> {
      process.send(reply, custody.command_offer_for_origin(state.store, origin))
      resume(state)
    }
    ReserveCommand(offer, candidate, request, reply) -> {
      process.send(
        reply,
        custody.admit_command_child(state.store, offer, candidate, request),
      )
      resume(state)
    }
    ReadCommand(ref, reply) -> {
      process.send(reply, custody.command_child(state.store, ref))
      resume(state)
    }
    CancelService(key, reply) -> {
      process.send(reply, custody.cancel_service(state.store, key))
      resume(state)
    }
    ReadChild(origin, reply) -> {
      process.send(
        reply,
        custody.child(state.store, origin)
          |> result.map(fn(row) {
            #(row.0, custody.bytes(row.1), option.map(row.2, custody.bytes))
          }),
      )
      resume(state)
    }
    ReceiveChild(origin, id, bytes, reply) -> {
      let outcome = {
        use payload <- result.try(custody.payload(state.config.limits, bytes))
        custody.receive_child(state.store, origin, id, payload)
      }
      process.send(reply, outcome)
      resume(state)
    }
    CancelChild(origin, reply) -> {
      process.send(reply, custody.cancel_child(state.store, origin))
      resume(state)
    }
    Collect(key, source, reply) -> {
      let outcome = {
        use proof <- result.try(custody.verify_commit(
          state.store,
          key,
          source,
          outcome.validate_commit,
        ))
        custody.collect(state.store, proof)
      }
      process.send(reply, outcome)
      resume(state)
    }
    RetainReport(key, report, reply) -> {
      let address = remote_tool.address(key)
      case dict.get(state.live, address) {
        Ok(held)
          if held.key == key && held.profile == custody.CodeModeReportV1
        -> {
          let result = custody.retain_report(state.store, key, report)
          let next = case result {
            Ok(_) -> state
            Error(_) ->
              unresolved(
                state,
                address,
                held,
                "complete report retention failed",
              )
          }
          process.send(reply, result)
          resume(next)
        }
        Ok(_) | Error(_) -> {
          process.send(reply, Error(custody.Conflict))
          resume(state)
        }
      }
    }
    ReadReportChunk(reference, offset, reply) -> {
      process.send(
        reply,
        custody.read_report_chunk(state.store, reference, offset),
      )
      resume(state)
    }
    FenceRun(key, reply) -> {
      let address = remote_tool.address(key)
      let state = case dict.get(state.live, address) {
        Ok(held) -> {
          process.send(reply, Ok(Nil))
          unresolved(state, address, held, "owner consumer fatal fence")
        }
        Error(Nil) -> {
          process.send(reply, Error(custody.Missing))
          State(..state, admission: RecoveryOnly)
        }
      }
      resume(state)
    }
    Reported(address, report) -> resume(reported(state, address, report))
    Stop(reply) -> {
      process.send(reply, Ok(Nil))
      actor.stop()
    }
  }
}

fn begin(
  state: State,
  key: remote_tool.ToolKey,
  profile: custody.FinalProfile,
  args: BitArray,
  request: BitArray,
  original: effects.ToolRun,
  ticket: process.Subject(Result(effects.ToolOutcome, custody.Error)),
  reply: process.Subject(Result(Nil, custody.Error)),
) -> actor.Next(State, Message) {
  let admitted = {
    use Nil <- result.try(
      outcome.validate_admission(profile, original)
      |> result.map_error(custody.Invalid),
    )
    use Nil <- result.try(case profile {
      custody.OrdinaryFinal -> Ok(Nil)
      custody.CodeModeReportV1 ->
        outcome.validate_request_identity(
          request,
          original.call.id,
          original.call.name,
        )
        |> result.map_error(custody.Invalid)
    })
    use args <- result.try(custody.payload(state.config.limits, args))
    use request <- result.try(custody.payload(state.config.limits, request))
    use Nil <- result.try(
      case
        state.admission == Admitting
        && dict.size(state.live) < state.config.active
      {
        True -> Ok(Nil)
        False -> Error(custody.Capacity)
      },
    )
    custody.admit_fresh_with_profile(state.store, key, args, request, profile)
  }
  case admitted {
    Ok(custody.Fresh) -> {
      let runner = state.config.runner
      let pinned = state.owner
      let owner_pid = process.self()
      let reports = process.new_subject()
      let cancel = weft.cancel_signal()
      let _relay =
        weft.new_prepared([
          weft.managed(fn(_ledger) { Ok(runner(pinned, key, original)) }),
        ])
        |> weft.cancel_when_exits(owner_pid)
        |> weft.cancel_with(cancel)
        |> weft.deadline(state.config.task_ms)
        |> weft.start_relayed(to: reports)
      process.send(reply, Ok(Nil))
      resume(
        State(
          ..state,
          live: dict.insert(
            state.live,
            remote_tool.address(key),
            Held(
              key,
              original,
              profile,
              reports,
              cancel,
              AwaitingReport,
              ticket,
            ),
          ),
        ),
      )
    }
    Ok(custody.Retained) -> {
      process.send(
        reply,
        Error(custody.Invalid("retained admission cannot rerun tool body")),
      )
      resume(state)
    }
    Error(error) -> {
      process.send(reply, Error(error))
      resume(state)
    }
  }
}

fn reserve(
  state: State,
  origin: remote_tool.ChildOrigin,
  candidate: ids.EntryId,
  request: BitArray,
) -> Result(#(ids.EntryId, BitArray), custody.Error) {
  use payload <- result.try(custody.payload(state.config.limits, request))
  case custody.child(state.store, origin) {
    Ok(#(id, original, _)) -> {
      use Nil <- result.try(custody.admit_child(
        state.store,
        origin,
        id,
        payload,
      ))
      Ok(#(id, custody.bytes(original)))
    }
    Error(custody.Missing) -> {
      use Nil <- result.try(custody.admit_child(
        state.store,
        origin,
        candidate,
        payload,
      ))
      Ok(#(candidate, request))
    }
    Error(error) -> Error(error)
  }
}

// The selector retains the report subject until weft confirms all delivery.
// Dropping it at the first result would lose the drain notification and make
// finished task slots appear available before their owner scope has retired.
fn resume(state: State) -> actor.Next(State, Message) {
  let selector =
    list.fold(
      dict.to_list(state.live),
      process.new_selector() |> process.select(state.self),
      fn(selector, row) {
        let #(address, held) = row
        process.select_map(selector, held.reports, fn(report) {
          Reported(address, report)
        })
      },
    )
  actor.continue(state) |> actor.with_selector(selector)
}

fn reported(
  state: State,
  address: String,
  report: weft.Pulled(effects.ToolOutcome, Nil),
) -> State {
  case dict.get(state.live, address) {
    Error(Nil) -> state
    Ok(held) -> report_held(state, address, held, report)
  }
}

fn report_held(
  state: State,
  address: String,
  held: Held,
  report: weft.Pulled(effects.ToolOutcome, Nil),
) -> State {
  case report {
    weft.PulledOutcome(weft.Completed(_, value)) -> {
      let committed = {
        use Nil <- result.try(
          outcome.validate_outcome(held.original, value)
          |> result.map_error(custody.Invalid),
        )
        use reference <- result.try(custody.report_reference(
          state.store,
          held.key,
        ))
        use terminal <- result.try(custody.report_outcome(state.store, held.key))
        use Nil <- result.try(
          outcome.validate_final(held.profile, reference, terminal, value)
          |> result.map_error(custody.Invalid),
        )
        use bytes <- result.try(
          effects.encode_tool_outcome(value)
          |> result.map_error(custody.Invalid),
        )
        use payload <- result.try(custody.final_payload(
          state.config.limits,
          held.profile,
          bytes,
        ))
        use Nil <- result.try(custody.finish_with_reference(
          state.store,
          held.key,
          payload,
          reference,
        ))
        Ok(#(value, payload))
      }
      case committed {
        Ok(#(value, payload)) -> {
          // A generic diagnostic says nothing about whether code ran. The report
          // profile keeps that durable diagnostic without granting live discharge.
          case held.profile, value {
            custody.CodeModeReportV1, effects.ToolFailed(_) ->
              unresolved(
                state,
                address,
                held,
                "complete report absent; generic diagnostic retains uncertainty",
              )
            custody.OrdinaryFinal, _
            | custody.CodeModeReportV1, effects.ToolCompleted(..)
            ->
              answer_once(
                state,
                address,
                held,
                Ok(value),
                FinalCommitted(payload),
              )
          }
        }
        Error(error) ->
          answer_once(state, address, held, Error(error), Unresolved)
          |> fence_admission
      }
    }
    weft.PulledOutcome(weft.Failed(..))
    | weft.PulledOutcome(weft.Crashed(..))
    | weft.PulledOutcome(weft.Abandoned(..))
    | weft.PulledOutcome(weft.NeverStarted(..))
    | weft.PulledOutcome(weft.DrainProofLost(..))
    | weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
      unresolved(
        state,
        address,
        held,
        "owner worker lost; exact final report unknown",
      )

    // Only this live run's complete delivery can release exact committed bytes.
    // Failure leaves the durable marker and the in-memory slot occupied.
    weft.AllDelivered -> {
      case held.disposition {
        FinalCommitted(payload) -> {
          case custody.discharge(state.store, held.key, payload) {
            Ok(Nil) -> State(..state, live: dict.delete(state.live, address))
            Error(_) ->
              unresolved(state, address, held, "owner discharge commit failed")
          }
        }
        AwaitingReport | Unresolved ->
          unresolved(
            state,
            address,
            held,
            "owner completed without releasable report",
          )
      }
    }
    weft.RunLost(_) ->
      unresolved(
        state,
        address,
        held,
        "owner run lost; exact final report unknown",
      )
    weft.NotYet -> state
  }
}

fn answer_once(
  state: State,
  address: String,
  held: Held,
  result: Result(effects.ToolOutcome, custody.Error),
  disposition: Disposition,
) -> State {
  case held.disposition {
    FinalCommitted(_) | Unresolved -> state
    AwaitingReport -> {
      process.send(held.reply, result)
      State(
        ..state,
        live: dict.insert(state.live, address, Held(..held, disposition:)),
      )
    }
  }
}

// The owner holds this sticky fence because a dead worker cannot fence itself.
fn unresolved(
  state: State,
  address: String,
  held: Held,
  reason: String,
) -> State {
  let state =
    answer_once(
      state,
      address,
      held,
      Error(custody.Unavailable(reason)),
      Unresolved,
    )
  State(
    ..state,
    admission: RecoveryOnly,
    live: dict.insert(
      state.live,
      address,
      Held(..held, disposition: Unresolved),
    ),
  )
}

fn fence_admission(state: State) -> State {
  State(..state, admission: RecoveryOnly)
}

fn input_bound(bytes: BitArray, maximum: Int) -> Result(Nil, custody.Error) {
  case
    bit_array.bit_size(bytes) % 8 == 0 && bit_array.byte_size(bytes) <= maximum
  {
    True -> Ok(Nil)
    False -> Error(custody.Capacity)
  }
}
