//// Original foreground Launch custody and one consumed frame window.
////
//// Whole Launch receives the artifact and token together, so placement belongs
//// to the selected physical adapter. A prepared connection cannot deliver until
//// the host installs its close handle. The trusted host serializes its grant;
//// opaque values are copyable and do not replace the adapter's stale-ref check.
////
//// Each direction charges its wire bytes before body receipt or mailbox delivery.
//// Only exact final-recipient consumption advances its sequence. Timeout keeps
//// the reservation held; cancellation retires it without refund. Native report,
//// socket/resource drain and durable report COMMIT are separate observations.
////
//// ## Flow
////
//// `request` admits the token beside original execution facts. `host_endpoint`
//// names its actual consumer; `new_incarnation` names the original live channel.
//// `prepare_direction` → `activate_direction` → `reserve_frame` →
//// `publish_frame` → `consume_frame` implements its one-window budget.
//// `payload_length`, `finish_payload` and `from_wire` guard exact frame bytes.
//// `write_grant` → `reserve_write` → `consume_write` carries the host's writer.
//// `retire_direction` and `retire_write` make cancellation sticky.

import broker/exec.{type EnforcementDemand}
import broker/framing
import broker/policy.{type SandboxPolicy}
import codemode/compile.{type Artifact}
import codemode/enforcement.{type Report}
import codemode/identity.{type PhaseIdentity}
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/result

/// The payload ceiling excludes its four-byte prefix.
pub const max_payload_bytes = 16_777_216

/// The maximum complete wire frame includes its prefix.
pub const max_wire_bytes = 16_777_220

/// Each direction spends this fixed lifetime wire-byte allowance once.
pub const lifetime_wire_bytes = 67_108_864

/// Exact transport reads never exceed this many bytes.
pub const max_chunk_bytes = 65_536

/// One maximum wire frame needs this many bounded chunks.
pub const max_frame_chunks = 257

/// The logical recipient, including when both roles share one physical host.
pub type Direction {
  /// The actual owner capability host consumes this direction.
  ToHost

  /// The executor socket writer consumes this direction.
  ToNode
}

/// Whether consumed delivery permits another frame from the original producer.
pub type Consumption {
  /// The original direction may admit its next sequence.
  Continue

  /// This consumed frame ends delivery without returning a usable window.
  Final
}

/// An original live channel name, without remote service authority.
pub opaque type Incarnation {
  /// The fresh local reference belongs to one prepared connection.
  Incarnation(
    /// The original local uniqueness witness.
    reference: Reference,
  )
}

/// An exact original directional sequence, not a restart or replay token.
pub opaque type FrameRef {
  /// The original channel and its charged directional sequence.
  FrameRef(
    /// The original prepared connection.
    incarnation: Incarnation,
    /// The actual recipient of these bytes.
    direction: Direction,
    /// The monotonically advancing original admission number.
    sequence: Int,
  )
}

/// A validated u32 declared payload length under the current cap ceiling.
pub opaque type PayloadLength {
  /// A declared body count admitted before body receipt.
  PayloadLength(
    /// The validated nonnegative count under the payload ceiling.
    bytes: Int,
  )
}

/// A checked complete payload with its original wire prefix.
pub opaque type Payload {
  /// Exact complete bytes for one validated declared body.
  Payload(
    /// The original complete body, without its wire prefix.
    bytes: BitArray,
    /// The admitted count that exactly matches these bytes.
    length: PayloadLength,
  )
}

/// Admission-time capacity charged to one original frame.
pub opaque type Reservation {
  /// One original directional charge, before bytes can be published.
  Reservation(
    /// The exact original incarnation, direction and sequence.
    frame: FrameRef,
    /// The original body declaration charged with its four-byte prefix.
    length: PayloadLength,
  )
}

/// An exact consume changed the direction, or was stale and changed nothing.
pub type ConsumptionResult {
  /// The original pending reservation was consumed once.
  Consumed

  /// The notification did not name the pending original reservation.
  Ignored
}

/// Transport failure does not establish native settlement or no-launch proof.
pub type ChannelFailure {
  /// The declared or complete frame violated the fixed byte contract.
  InvalidFrame

  /// Original cumulative wire capacity cannot hold another complete frame.
  AllowanceExhausted

  /// This direction already holds a reservation or has not been activated.
  WindowUnavailable

  /// The original direction is finished or retired.
  ChannelRetired

  /// An admission/publish operation did not name the exact held reservation.
  StaleReservation

  /// A physical transport operation failed or its owner was lost.
  TransportFailed(
    /// The bounded original transport failure description.
    reason: String,
  )
}

/// Whole Launch distinguishes witnessed non-dispatch from possible execution.
pub type LaunchFailure {
  /// The original attempt was witnessed refused before native dispatch.
  LaunchRefused(
    /// The witnessed non-dispatch reason.
    reason: String,
    /// Original preparation is released, or remains held independently.
    preparation: ResourceDrain,
  )

  /// Original resource/native custody remains unresolved after possible dispatch.
  LaunchOutcomeUnknown(
    /// The original attempt whose preparation or dispatch was not settled.
    reason: String,
  )
}

/// Separate observed transport closure, never a native-retirement witness.
pub type TransportDrain {
  /// Actual reader and writer work exited under their original owner.
  TransportJoined

  /// The original transport did not produce its required drain observation.
  TransportUnresolved(
    /// The missing original reader/writer observation.
    reason: String,
  )
}

/// Separate resource closure, never report COMMIT or successful program execution.
pub type ResourceDrain {
  /// Original local resources were released under their original custody.
  ResourcesReleased

  /// Original resource custody remains held.
  ResourcesUnresolved(
    /// The original physical resource observation still absent.
    reason: String,
  )
}

/// The connection's original teardown observations remain individually visible.
pub type CloseResult {
  CloseResult(
    /// The existing report from actual native settlement, or explicit absence.
    node: Report,
    /// The original reader/writer drain observation.
    transport: TransportDrain,
    /// The original resource-release observation.
    resources: ResourceDrain,
  )
}

/// The actual local capability host endpoint, never serialized over distribution.
pub opaque type HostEndpoint {
  /// A trusted local consumer and its bounded-delivery subject.
  HostEndpoint(
    /// The actual host process monitored by the physical owner.
    pid: Pid,
    /// The original consumer subject installed before activation.
    events: Subject(Event),
  )
}

/// Complete checked bytes and the original producer's nonblocking consume handle.
pub opaque type Delivery {
  /// A complete original frame whose exact consumer owns acknowledgement.
  Delivery(
    /// The admitted original directional sequence.
    frame: FrameRef,
    /// The exact complete checked body.
    payload: Payload,
    /// The nonblocking notification to this original producer only.
    consume: fn(Consumption) -> Nil,
  )
}

/// Original local transport notifications; remote adapters authenticate first.
pub type Event {
  /// One reserved complete frame; semantic consumption belongs to the host.
  Frame(
    /// The complete body and exact original consumption callback.
    delivery: Delivery,
  )

  /// The bounded writer consumed this exact original complete frame.
  WriteConsumed(
    /// The exact original frame fully consumed by the writer.
    frame: FrameRef,
  )

  /// Ordered EOF from the one inbound producer, after its prior frames.
  End(
    /// The original channel whose inbound producer ended.
    incarnation: Incarnation,
    /// The bounded original stream-end description.
    reason: String,
  )

  /// Original channel-owner failure retires both windows without refund.
  Fault(
    /// The original channel whose custody is lost.
    incarnation: Incarnation,
    /// The bounded original failure description.
    reason: String,
  )
}

/// Exact execution facts passed before any placement-dependent file effects.
pub opaque type LaunchRequest {
  /// Exact original execution and owner-consumer facts.
  LaunchRequest(
    /// The exact original successful Compile artifact.
    artifact: Artifact,
    /// The original run operation, step, ledger, grants and deadline.
    identity: PhaseIdentity,
    /// The owner-admitted base confinement policy.
    base_policy: SandboxPolicy,
    /// The original trusted enforcement requirement.
    demand: EnforcementDemand,
    /// The original requested environment subject to policy.
    env: List(#(String, String)),
    /// The original requested working directory.
    cwd: String,
    /// The original committed 32-byte capability token.
    token: BitArray,
    /// The actual local owner consumer installed before activation.
    host: HostEndpoint,
  )
}

/// Whole Launch owns placement, submission, prepared transport and cleanup.
pub type Launcher =
  fn(LaunchRequest) -> Result(Connection, LaunchFailure)

/// One original prepared connection; successful offer is admission, not consumption.
pub type Connection {
  Connection(
    /// Names this original live incarnation only.
    incarnation: Incarnation,
    /// The capability host must serialize and retain this writer state.
    initial_write_grant: WriteGrant,
    /// Receives a reservation charged before mailbox delivery; rejects replays.
    offer: fn(Reservation, Payload) -> Result(Nil, ChannelFailure),
    /// Enables first inbound delivery after close custody is installed.
    activate: fn() -> Result(Nil, ChannelFailure),
    /// Independently closes sockets, then joins and gathers original observations.
    close: fn() -> CloseResult,
  )
}

type Phase {
  Prepared
  Available
  Reserved(reservation: Reservation)
  Pending(reservation: Reservation)
  Finished
  Retired
}

type Allowance {
  Allowance(bytes: Int)
}

/// Serial original-owner state; opacity does not make immutable copies linear.
pub opaque type Window {
  /// The one original serialized directional state.
  Window(
    /// The original prepared connection.
    incarnation: Incarnation,
    /// The actual recipient for this direction.
    direction: Direction,
    /// The next original admission number.
    next_sequence: Int,
    /// Original lifetime capacity after every prior charge.
    remaining: Allowance,
    /// The closed ownership and consumption disposition.
    phase: Phase,
  )
}

/// The host's serial outbound state, held until exact writer consumption.
pub opaque type WriteGrant {
  /// The serialized original ToNode direction.
  WriteGrant(
    /// The original charged window, including any pending write.
    window: Window,
  )
}

/// Public observation of the reducer's closed phases for controls and assembly.
pub type WindowStatus {
  /// Prepared delivery cannot begin yet.
  PreparedWindow

  /// One original next sequence is available.
  AvailableWindow

  /// Bytes were charged before body receipt or mailbox delivery.
  ReservedWindow

  /// Complete publication awaits actual final-recipient consumption.
  PendingWindow

  /// Final consumption ended delivery without returning credit.
  FinishedWindow

  /// Original cancellation or loss permanently retired delivery.
  RetiredWindow
}

/// Pins token bytes beside the complete original execution facts.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.request(artifact, phase, policy, demand, env, cwd, token, host)
/// ```
pub fn request(
  artifact: Artifact,
  identity: PhaseIdentity,
  base_policy: SandboxPolicy,
  demand: EnforcementDemand,
  env: List(#(String, String)),
  cwd: String,
  token: BitArray,
  host: HostEndpoint,
) -> Result(LaunchRequest, LaunchFailure) {
  case bit_array.bit_size(token) == 256 {
    True ->
      Ok(LaunchRequest(
        artifact,
        identity,
        base_policy,
        demand,
        env,
        cwd,
        token,
        host,
      ))
    False ->
      Error(LaunchRefused(
        "the original cap token must be exactly 32 bytes",
        ResourcesReleased,
      ))
  }
}

/// Returns original admitted artifact and authority facts without local paths.
///
/// ## Examples
///
/// ```gleam
/// // let #(artifact, phase, policy, demand, env, cwd) = run_channel.execution(request)
/// ```
pub fn execution(
  request: LaunchRequest,
) -> #(
  Artifact,
  PhaseIdentity,
  SandboxPolicy,
  EnforcementDemand,
  List(#(String, String)),
  String,
) {
  #(
    request.artifact,
    request.identity,
    request.base_policy,
    request.demand,
    request.env,
    request.cwd,
  )
}

/// Returns the original committed token bytes to the trusted physical adapter.
///
/// ## Examples
///
/// ```gleam
/// // let token = run_channel.token(request)
/// ```
pub fn token(request: LaunchRequest) -> BitArray {
  request.token
}

/// Returns the actual original host recipient.
///
/// ## Examples
///
/// ```gleam
/// // let host = run_channel.host(request)
/// ```
pub fn host(request: LaunchRequest) -> HostEndpoint {
  request.host
}

/// Constructs a trusted local endpoint for exact consumer monitoring.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.host_endpoint(process.self(), events)
/// ```
pub fn host_endpoint(pid: Pid, events: Subject(Event)) -> HostEndpoint {
  HostEndpoint(pid, events)
}

/// Exposes the actual recipient pid and subject to trusted local transport.
///
/// ## Examples
///
/// ```gleam
/// // let #(pid, events) = run_channel.endpoint(host)
/// ```
pub fn endpoint(host: HostEndpoint) -> #(Pid, Subject(Event)) {
  #(host.pid, host.events)
}

/// Mints an original local incarnation; remote authority is checked separately.
///
/// ## Examples
///
/// ```gleam
/// let incarnation = run_channel.new_incarnation()
/// ```
pub fn new_incarnation() -> Incarnation {
  Incarnation(reference.new())
}

/// Observes exact identity coordinates without granting reservation authority.
///
/// ## Examples
///
/// ```gleam
/// // let #(incarnation, direction, sequence) = run_channel.coordinates(frame)
/// ```
pub fn coordinates(frame: FrameRef) -> #(Incarnation, Direction, Int) {
  #(frame.incarnation, frame.direction, frame.sequence)
}

/// Admits a declared payload size before any body read or complete allocation.
///
/// ## Examples
///
/// ```gleam
/// assert run_channel.payload_length(16_777_217) == Error(run_channel.InvalidFrame)
/// ```
pub fn payload_length(bytes: Int) -> Result(PayloadLength, ChannelFailure) {
  case bytes >= 0 && bytes <= framing.max_frame_bytes {
    True -> Ok(PayloadLength(bytes))
    False -> Error(InvalidFrame)
  }
}

/// Returns the admitted declared body size for exact bounded reads.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(length) = run_channel.payload_length(7)
/// assert run_channel.length_bytes(length) == 7
/// ```
pub fn length_bytes(length: PayloadLength) -> Int {
  length.bytes
}

/// Returns the charged prefix plus payload size.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(length) = run_channel.payload_length(7)
/// assert run_channel.wire_length(length) == 11
/// ```
pub fn wire_length(length: PayloadLength) -> Int {
  length.bytes + 4
}

/// Completes exactly the body reserved before reading; extra/partial bytes refuse.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.finish_payload(reservation, body)
/// ```
pub fn finish_payload(
  reservation: Reservation,
  bytes: BitArray,
) -> Result(Payload, ChannelFailure) {
  case bit_array.bit_size(bytes) == reservation.length.bytes * 8 {
    True -> Ok(Payload(bytes, reservation.length))
    False -> Error(InvalidFrame)
  }
}

/// Admits one complete wire frame before outbound reservation and mailbox delivery.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(payload) = run_channel.from_wire(<<1:32, 0xc0>>)
/// assert run_channel.payload(payload) == <<0xc0>>
/// ```
pub fn from_wire(bytes: BitArray) -> Result(Payload, ChannelFailure) {
  case bytes {
    <<size:size(32), body:bits>> -> {
      use length <- result.try(payload_length(size))
      case bit_array.bit_size(body) == size * 8 {
        True -> Ok(Payload(body, length))
        False -> Error(InvalidFrame)
      }
    }
    _ -> Error(InvalidFrame)
  }
}

/// Returns the original payload for its owning semantic decoder.
///
/// ## Examples
///
/// ```gleam
/// // framing.decode_raw_envelope(run_channel.payload(frame))
/// ```
pub fn payload(payload: Payload) -> BitArray {
  payload.bytes
}

/// Returns one exact complete prefixed frame for its original socket writer.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(payload) = run_channel.from_wire(<<1:32, 0xc0>>)
/// assert run_channel.wire_bytes(payload) == <<1:32, 0xc0>>
/// ```
pub fn wire_bytes(payload: Payload) -> BitArray {
  <<payload.length.bytes:size(32), payload.bytes:bits>>
}

/// Observes the exact charged frame reference and length.
///
/// ## Examples
///
/// ```gleam
/// // let #(frame, length) = run_channel.reservation(reservation)
/// ```
pub fn reservation(reservation: Reservation) -> #(FrameRef, PayloadLength) {
  #(reservation.frame, reservation.length)
}

/// Constructs transport delivery only from exact reserved complete bytes.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.delivery(reservation, payload, consume)
/// ```
pub fn delivery(
  reservation: Reservation,
  payload: Payload,
  consume: fn(Consumption) -> Nil,
) -> Result(Delivery, ChannelFailure) {
  case reservation.length == payload.length {
    True -> Ok(Delivery(reservation.frame, payload, consume))
    False -> Error(InvalidFrame)
  }
}

/// Exposes complete delivery facts to the actual semantic consumer.
///
/// ## Examples
///
/// ```gleam
/// // let #(frame, payload) = run_channel.delivered(delivery)
/// ```
pub fn delivered(delivery: Delivery) -> #(FrameRef, Payload) {
  #(delivery.frame, delivery.payload)
}

/// Notifies the original producer without waiting on that same host's mailbox.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.consume(delivery, run_channel.Final)
/// ```
pub fn consume(delivery: Delivery, disposition: Consumption) -> Nil {
  delivery.consume(disposition)
}

/// Prepares one fixed-budget direction without granting active delivery.
///
/// ## Examples
///
/// ```gleam
/// let window = run_channel.prepare_direction(run_channel.new_incarnation(), run_channel.ToHost)
/// assert run_channel.status(window) == run_channel.PreparedWindow
/// ```
pub fn prepare_direction(
  incarnation: Incarnation,
  direction: Direction,
) -> Window {
  Window(incarnation, direction, 1, Allowance(lifetime_wire_bytes), Prepared)
}

/// Activates the original prepared direction exactly once after custody install.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.activate_direction(prepared)
/// ```
pub fn activate_direction(window: Window) -> Result(Window, ChannelFailure) {
  case window.phase {
    Prepared -> Ok(Window(..window, phase: Available))
    Available | Reserved(_) | Pending(_) -> Error(WindowUnavailable)
    Finished | Retired -> Error(ChannelRetired)
  }
}

/// Charges original bytes before body receipt or mailbox delivery, without refund.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.reserve_frame(active, admitted_length)
/// ```
pub fn reserve_frame(
  window: Window,
  length: PayloadLength,
) -> Result(#(Window, Reservation), ChannelFailure) {
  case window.phase {
    Available -> {
      let bytes = wire_length(length)
      case bytes <= window.remaining.bytes {
        True -> {
          let reservation =
            Reservation(
              FrameRef(
                window.incarnation,
                window.direction,
                window.next_sequence,
              ),
              length,
            )
          Ok(#(
            Window(
              ..window,
              remaining: Allowance(window.remaining.bytes - bytes),
              phase: Reserved(reservation),
            ),
            reservation,
          ))
        }
        False -> Error(AllowanceExhausted)
      }
    }
    Prepared | Reserved(_) | Pending(_) -> Error(WindowUnavailable)
    Finished | Retired -> Error(ChannelRetired)
  }
}

/// Publishes only the exact charged reservation; replay never returns a credit.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.publish_frame(reserved, reservation)
/// ```
pub fn publish_frame(
  window: Window,
  reservation: Reservation,
) -> Result(Window, ChannelFailure) {
  case window.phase {
    Reserved(original) if original == reservation ->
      Ok(Window(..window, phase: Pending(original)))
    Prepared | Available | Reserved(_) | Pending(_) -> Error(StaleReservation)
    Finished | Retired -> Error(ChannelRetired)
  }
}

/// Advances only exact pending consumption; final never returns another window.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.consume_frame(pending, original_ref, run_channel.Final)
/// ```
pub fn consume_frame(
  window: Window,
  frame: FrameRef,
  disposition: Consumption,
) -> #(Window, ConsumptionResult) {
  case window.phase {
    Pending(original) if original.frame == frame -> {
      let phase = case disposition {
        Continue -> Available
        Final -> Finished
      }
      #(
        Window(..window, next_sequence: window.next_sequence + 1, phase:),
        Consumed,
      )
    }
    Prepared | Available | Reserved(_) | Pending(_) | Finished | Retired -> #(
      window,
      Ignored,
    )
  }
}

/// Retires original custody permanently, preserving every charged byte.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.retire_direction(window)
/// ```
pub fn retire_direction(window: Window) -> Window {
  Window(..window, phase: Retired)
}

/// Observes remaining original lifetime capacity, including held reservations.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.remaining_bytes(window)
/// ```
pub fn remaining_bytes(window: Window) -> Int {
  window.remaining.bytes
}

/// Observes the reducer disposition without exposing its private state record.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.status(window) == run_channel.PendingWindow
/// ```
pub fn status(window: Window) -> WindowStatus {
  case window.phase {
    Prepared -> PreparedWindow
    Available -> AvailableWindow
    Reserved(_) -> ReservedWindow
    Pending(_) -> PendingWindow
    Finished -> FinishedWindow
    Retired -> RetiredWindow
  }
}

/// Wraps one active ToNode direction for the serialized capability host.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.write_grant(active_writer)
/// ```
pub fn write_grant(window: Window) -> Result(WriteGrant, ChannelFailure) {
  case window.direction, window.phase {
    ToNode, Available -> Ok(WriteGrant(window))
    ToHost, _ -> Error(StaleReservation)
    ToNode, Prepared | ToNode, Reserved(_) | ToNode, Pending(_) ->
      Error(WindowUnavailable)
    ToNode, Finished | ToNode, Retired -> Error(ChannelRetired)
  }
}

/// Charges and holds the host's sole grant before invoking the adapter's offer.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(#(held, reservation)) = run_channel.reserve_write(grant, payload)
/// ```
pub fn reserve_write(
  grant: WriteGrant,
  payload: Payload,
) -> Result(#(WriteGrant, Reservation), ChannelFailure) {
  use #(window, reservation) <- result.try(reserve_frame(
    grant.window,
    payload.length,
  ))
  use window <- result.try(publish_frame(window, reservation))
  Ok(#(WriteGrant(window), reservation))
}

/// Returns a usable next grant only for exact original consumed-write notification.
///
/// ## Examples
///
/// ```gleam
/// // let #(grant, accepted) = run_channel.consume_write(held, original_ref)
/// ```
pub fn consume_write(
  grant: WriteGrant,
  frame: FrameRef,
) -> #(WriteGrant, ConsumptionResult) {
  let #(window, accepted) = consume_frame(grant.window, frame, Continue)
  #(WriteGrant(window), accepted)
}

/// Cancels the writer independently of data and makes all late ACKs inert.
///
/// ## Examples
///
/// ```gleam
/// // run_channel.retire_write(grant)
/// ```
pub fn retire_write(grant: WriteGrant) -> WriteGrant {
  WriteGrant(retire_direction(grant.window))
}
