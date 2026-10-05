//// A fixed test counterpart exercises the real TLS BEAM owner transport.
////
//// The production owner discovers this process through the same literal endpoint
//// and transfers unchanged canonical bytes through acknowledged bounded chunks.
//// The private tagged reservation/frame vocabulary is mirrored here solely to
//// emit the original tests' hostile replies. It creates no native service,
//// Compile Claim, admission evidence or launch authority. A production endpoint
//// cannot intentionally return those substituted references and generations.
////
//// `publish` establishes the fixed rendezvous after real membership boot.
//// `accept` checks the original owner PID, complete binding and command bytes;
//// `respond` waits for actual consumption before another scripted exchange.
//// `await` and `mark` provide finite test barriers, never effect identities.

import core/command
import executor/remote/distribution
import executor/remote/internal/beam_protocol as protocol
import executor/remote/wire
import executor/remote/workspace_transfer as transfer
import gleam/bit_array
import gleam/dynamic
import gleam/erlang/process
import gleam/erlang/reference
import gleam/option.{None, Some}
import simplifile
import weft/poll

// These constructor tags and arities intentionally match the existing endpoint.
// They are test-only representation checks, not exported production interfaces.
type Reservation {
  Reservation(
    header: BitArray,
    correlation: reference.Reference,
    caller: process.Pid,
    reply: process.Subject(Reply),
  )
}

type Reply {
  Granted(reference.Reference, process.Subject(Frame))
  Consumed(reference.Reference, Int)
  Returned(reference.Reference, Int, BitArray)
}

type Frame {
  Input(reference.Reference, Int, BitArray)
  ReplyConsumed(reference.Reference, Int)
}

/// The one local test rendezvous, with no concrete effect owner behind it.
pub opaque type Peer {
  /// Original authenticated owner, exact binding and fixed network mailbox.
  Peer(
    /// Actual peer resolved from successful executor membership.
    owner: distribution.Peer,
    /// Complete original labels, authority epochs and transport generation.
    binding: protocol.Binding,
    /// Literal node-wide endpoint, owned by this test role's original PID.
    mailbox: process.Subject(Reservation),
  )
}

/// One fully transferred command and its original ephemeral response channel.
pub opaque type Exchange {
  /// Immutable canonical command paired with its consumed request transfer.
  Exchange(
    /// Exact full-ref wrapper decoded through the production command codec.
    value: wire.CommandEnvelope,
    /// Original reservation; correlation does not replace any durable identity.
    reservation: Reservation,
    /// Original incoming transfer mailbox, owned by this executor test PID.
    incoming: process.Subject(Frame),
  )
}

/// Publishes only the fixed test counterpart after actual membership admission.
///
/// ## Examples
///
/// ```gleam
/// command_route_beam_peer.publish(owner_peer, binding)
/// // -> peer, after the original local PID owns fixed endpoint discovery.
/// ```
pub fn publish(owner: distribution.Peer, binding: protocol.Binding) -> Peer {
  assert distribution.register_endpoint(process.self()) == Ok(Nil)
  let mailbox =
    process.unsafely_create_subject(
      process.self(),
      dynamic.string("loom.executor.endpoint/1"),
    )
  Peer(owner, binding, mailbox)
}

/// Receives one unchanged command through the actual bounded endpoint protocol.
/// Both the claimed caller and reply Subject must belong to the provisioned
/// owner; the header retains complete scope and original generation.
///
/// ## Examples
///
/// ```gleam
/// command_route_beam_peer.accept(peer, original_ref)
/// // -> exchange, after exact command bytes and their transfer are checked.
/// ```
pub fn accept(peer: Peer, expected: command.CommandRef) -> Exchange {
  let assert Ok(Reservation(..) as reservation) =
    process.receive(peer.mailbox, 10_000)
    as "The fixed owner reserved the original command route."
  let assert Ok(caller) = process.subject_owner(reservation.reply)
    as "The original reply Subject owns a concrete PID."
  assert caller == reservation.caller && distribution.owns(peer.owner, caller)
  let assert Ok(protocol.NativeCommand(lane)) =
    protocol.decode_header(peer.binding, reservation.header)
    as "Original scope, generation and closed command route."

  // The grant belongs to this executor PID, as the production owner checks.
  let incoming = process.new_subject()
  sent(reservation.reply, Granted(reservation.correlation, incoming))
  let header = input(incoming, reservation.correlation, 0)
  let assert Ok(receiver) =
    protocol.receiver(protocol.NativeCommand(lane), transfer.Invocation, header)
    as "Original native aggregate bound, before command materialization."
  sent(reservation.reply, Consumed(reservation.correlation, 0))
  let bytes = receive_chunks(receiver, reservation, incoming, 1)

  // Only the complete bounded transfer enters the canonical command decoder.
  let assert Ok(value) =
    wire.decode_command(
      bytes,
      wire.Owner,
      peer.binding.owner,
      peer.binding.executor,
      peer.binding.scope,
    )
    as "Complete canonical original command crosses real distribution."
  assert wire.command_ref(value) == expected
  assert wire.encode_command(value) == Ok(bytes)
  assert protocol.lane(wire.native_envelope(value).body) == Ok(lane)
  Exchange(value, reservation, incoming)
}

/// Exposes only the checked unchanged command for the fixed script's assertions.
///
/// ## Examples
///
/// ```gleam
/// command_route_beam_peer.command(exchange)
/// // -> the canonical full reference and original native body.
/// ```
pub fn command(exchange: Exchange) -> wire.CommandEnvelope {
  exchange.value
}

/// Returns one fixed test reply and waits for each original consumption signal.
/// The caller supplies only its locally constructed canonical test bytes; the
/// network never supplies a callback, response program or arbitrary serializer.
///
/// ## Examples
///
/// ```gleam
/// command_route_beam_peer.respond(exchange, canonical_reply)
/// // -> Nil after the original owner consumes the final bounded reply chunk.
/// ```
pub fn respond(exchange: Exchange, bytes: BitArray) -> Nil {
  assert bit_array.byte_size(bytes) <= 262_144
  let assert Ok(#(header, sender)) =
    transfer.begin_send(transfer.Completion, bytes)
    as "Existing bounded native completion transfer."
  sent(
    exchange.reservation.reply,
    Returned(exchange.reservation.correlation, 0, header),
  )
  consumed(exchange.incoming, exchange.reservation.correlation, 0)
  output_chunks(sender, exchange, 1)
}

/// Publishes one fixed test barrier after the corresponding actual observation.
///
/// ## Examples
///
/// ```gleam
/// command_route_beam_peer.mark(root, "submitted")
/// // -> Nil after that finite fixture barrier is written.
/// ```
pub fn mark(root: String, name: String) -> Nil {
  assert simplifile.write(root <> "/" <> name, "observed") == Ok(Nil)
}

/// Waits within the original finite test bound for one exact administration mark.
///
/// ## Examples
///
/// ```gleam
/// command_route_beam_peer.await(root, "submitted")
/// // -> Nil when the bounded fixture observes its original submit barrier.
/// ```
pub fn await(root: String, name: String) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 10_000, every: 10, attempt: fn() {
      case simplifile.is_file(root <> "/" <> name) {
        Ok(True) -> poll.Done(Nil)
        Ok(False) | Error(_) -> poll.Retry
      }
    })
    as "The original fixed fixture barrier finishes within its finite bound."
  Nil
}

fn input(
  incoming: process.Subject(Frame),
  correlation: reference.Reference,
  ordinal: Int,
) -> BitArray {
  let assert Ok(Input(ref, index, bytes)) = process.receive(incoming, 5000)
    as "One original bounded input frame."
  assert ref == correlation && index == ordinal
  bytes
}

// A bounded transfer advances only after actual canonical chunk acceptance.
fn receive_chunks(
  receiver: transfer.Receiver,
  reservation: Reservation,
  incoming: process.Subject(Frame),
  ordinal: Int,
) -> BitArray {
  let bytes = input(incoming, reservation.correlation, ordinal)
  let assert Ok(accepted) = transfer.accept(receiver, bytes)
    as "Original ordinal and declared native aggregate remain exact."
  sent(reservation.reply, Consumed(reservation.correlation, ordinal))
  case accepted {
    transfer.Complete(bytes) -> bytes
    transfer.Receiving(receiver) ->
      receive_chunks(receiver, reservation, incoming, ordinal + 1)
  }
}

fn consumed(
  incoming: process.Subject(Frame),
  correlation: reference.Reference,
  ordinal: Int,
) -> Nil {
  let assert Ok(ReplyConsumed(ref, index)) = process.receive(incoming, 5000)
    as "Original owner consumed the exact returned frame."
  assert ref == correlation && index == ordinal
}

fn output_chunks(
  sender: transfer.Sender,
  exchange: Exchange,
  ordinal: Int,
) -> Nil {
  case transfer.next(sender) {
    None -> Nil
    Some(#(bytes, sender)) -> {
      sent(
        exchange.reservation.reply,
        Returned(exchange.reservation.correlation, ordinal, bytes),
      )
      consumed(exchange.incoming, exchange.reservation.correlation, ordinal)
      output_chunks(sender, exchange, ordinal + 1)
    }
  }
}

fn sent(subject: process.Subject(a), value: a) -> Nil {
  assert distribution.send(subject, value) == distribution.Sent
}
