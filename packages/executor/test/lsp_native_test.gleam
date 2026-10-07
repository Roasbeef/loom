//// Native component A crosses real Service actors, SQL, Broker and credited pools.
//// Deterministic peers attest ordering only; the separate real-helper gate keeps
//// FullEnforcement and requires the actual Linux positive or Darwin refusal.

import broker/broker
import broker/dispatch
import broker/exec
import broker/executor as local
import broker/framing
import broker/internal/ffi_os
import core/clock
import core/ids
import core/json
import core/lsp_command as id
import core/msgpack as mp
import executor/remote/admission
import executor/remote/identity
import executor/remote/internal/lsp_native_plan as native_plan
import executor/remote/internal/lsp_output_join as output_join
import executor/remote/journal
import executor/remote/lsp_journal as custody
import executor/remote/lsp_native
import executor/remote/lsp_wire
import executor/remote/payload
import executor/remote/service
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import lsp/client
import lsp/internal/consumed_channel as consumed
import lsp/protocol
import lsp/transport
import sqlight
import support/lsp_native_fixture as fixture
import weft
import weft/poll

@external(erlang, "executor_launch_socket_fixture", "lsp_credit_signals")
fn lsp_credit_signals(
  attachment: lsp_native.LspProtocolAttachment,
) -> Result(
  #(
    option.Option(process.Pid),
    option.Option(process.Pid),
    option.Option(process.Pid),
  ),
  Nil,
)

fn close_wire(rig: fixture.Rig) -> Nil {
  list.each(rig.peers, fn(peer) {
    process.send(exec.wire(peer.helper), exec.WireClosed(0))
  })
  let assert poll.Answered(Nil) =
    poll.until(5000, 10, fn() {
      case service.shutdown(rig.service) {
        Ok(Nil) -> poll.Done(Nil)
        Error(service.Uncertain) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "The original Service joins actual pool retirement before shutdown."
  assert custody.release(rig.store) == Ok(Nil)
  assert journal.release(rig.book) == Ok(Nil)
}

pub fn copied_startup_claim_is_placed_once_across_two_actual_services_test() {
  let first = fixture.start(fixture.WirePeer)
  let second = fixture.competing(first)
  let #(claim, lease, key, operation) = fixture.lease(first, 1)
  let replies = process.new_subject()
  let runs =
    weft.new_prepared(
      list.map([first.service, second.service], fn(service) {
        weft.managed(fn(_) {
          let release = process.new_subject()
          let answer =
            lsp_native.install_pending(
              service,
              first.store,
              claim,
              first.plan,
              first.era,
            )
          process.send(replies, #(answer, release))
          process.receive_forever(release)
          Ok(Nil)
        })
      }),
    )
    |> weft.deadline(10_000)
    |> weft.start_detached
  let assert Ok(one) = process.receive(replies, 2000)
    as "The first original placement ask answers."
  let assert Ok(two) = process.receive(replies, 2000)
    as "The competing actual Service answers."
  assert list.length(list.filter([one.0, two.0], result.is_ok)) == 1
  assert lsp_native.install_pending(
      first.service,
      first.store,
      claim,
      first.plan,
      first.era,
    )
    |> result.is_error
  assert lsp_native.install_pending(
      second.service,
      first.store,
      claim,
      first.plan,
      first.era,
    )
    |> result.is_error

  // A copied first token and a retained offer cannot reconstruct a lost pending reply.
  let assert Ok(ref) = id.lsp_startup_command(lease, id.ServerLease)
    as "The original parent remains exact."
  let assert Ok(command) =
    custody.inspect_command(
      first.store,
      first.binding,
      ref,
      executor_request(),
      None,
    )
    as "Readback names the original command and exact semantic input."
  assert custody.command_disposition(command) == custody.CommandOffered
  assert custody.unretired_lease_count(first.store, first.binding) == Ok(1)
  list.each(first.peers, fn(peer) {
    assert process.receive(peer.outbound, 0) == Error(Nil)
  })
  list.each(second.peers, fn(peer) {
    assert process.receive(peer.outbound, 0) == Error(Nil)
  })
  let assert Ok(pending) =
    list.find_map([one.0, two.0], fn(answer) {
      answer |> result.replace_error(Nil)
    })
    as "Exactly one Service retains native startup ownership."
  let #(prepared, owner, _) = fixture.cleared(first, operation)
  let assert Ok(attachment) = lsp_native.submit(pending, key, prepared)
    as "Only the winner can submit the exact original Broker clearance."
  let assert transport.ConsumedChannelTransport(connect) =
    lsp_native.transport(attachment)
    as "The winning original attachment owns its consumed sink."
  let assert Ok(window) = consumed.open(connect, process.new_subject())
    as "Only the winner can Begin its actual native server."
  let peer = first_started(list.append(first.peers, second.peers))
  let assert framing.ProtocolStart(mode: framing.ServerProtocol, ..) =
    fixture.next(peer).body
    as "The copied token produces exactly one native start."
  assert lsp_native.submit(pending, key, prepared) == Error(service.Invalid)
  process.send(one.1, Nil)
  process.send(two.1, Nil)
  let assert weft.PulledOutcome(_) = weft.pull(runs, 1000)
    as "The first original fixture owner completes."
  let assert weft.PulledOutcome(_) = weft.pull(runs, 1000)
    as "The second original fixture owner completes."
  assert weft.pull(runs, 1000) == weft.AllDelivered
  let assert framing.Cancel = fixture.next(peer).body
    as "The winning original owner's death cancels its one native start."
  window.close()
  broker.stop(owner)
  process.send(exec.wire(peer.helper), exec.WireClosed(0))
  let assert poll.Answered(Nil) =
    poll.until(3000, 5, fn() {
      case lsp_native.cleanup(attachment) {
        Ok(service.LspCleanup(
          native: service.LspPositiveNative,
          drain: service.LspDrained,
          ..,
        )) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "The winning Service retains its exact observer after its original owner dies."
  close_wire(first)
  close_wire(second)
}

fn executor_request() {
  // ServerLease retains the DAL's exact closed startup request discriminant.
  lsp_wire.Diagnostics(None)
}

pub fn exact_plan_store_era_and_one_consumed_pending_context_precede_request_test() {
  let rig = fixture.start(fixture.WirePeer)
  let other = fixture.start(fixture.WirePeer)
  let #(claim, lease, key, operation) = fixture.lease(rig, 2)
  let assert Ok(era) = id.clock_era("00000000-0000-4000-8000-000000000002")
    as "A distinct original clock incarnation is valid."
  assert lsp_native.install_pending(
      rig.service,
      rig.store,
      claim,
      rig.plan,
      era,
    )
    == Error(service.Invalid)
  assert lsp_native.install_pending(
      rig.service,
      other.store,
      claim,
      rig.plan,
      rig.era,
    )
    == Error(service.Invalid)
  assert lsp_native.install_pending(
      rig.service,
      rig.store,
      claim,
      other.plan,
      rig.era,
    )
    == Error(service.Invalid)
  let assert Ok(pending) =
    lsp_native.install_pending(rig.service, rig.store, claim, rig.plan, rig.era)
    as "Only the exact live original installs its pending door."
  let #(prepared, owner, dispatch) = fixture.cleared(rig, operation)
  let changed =
    wire.Prepared(
      ..prepared,
      request: exec.ExecRequest(..prepared.request, env: [
        #("OTHER", "changed"),
        ..prepared.request.env
      ]),
    )
  assert lsp_native.submit(pending, key, changed) == Error(service.Invalid)
  assert lsp_native.submit(pending, key, prepared) == Error(service.Invalid)
  let assert Ok(digest) = wire.prepared_digest(prepared)
    as "Original native bytes are canonical."
  assert journal.payloads(rig.book, key, digest) == Ok([])
  let assert Ok(readback) = custody.inspect_lease(rig.store, rig.binding, lease)
    as "The original slot remains retained after failure."
  assert custody.lease_disposition(readback) == custody.Closing
  dispatch.settle(dispatch.Failed(exec.NotReady))
  broker.stop(owner)
  close_wire(rig)
  close_wire(other)
}

pub fn successful_service_credits_reap_their_exact_original_signals_test() {
  let rig = fixture.start(fixture.WirePeer)
  let #(claim, _, key, operation) = fixture.lease(rig, 17)
  let assert Ok(pending) =
    lsp_native.install_pending(rig.service, rig.store, claim, rig.plan, rig.era)
    as "The original lease owns this actual Service credit lifecycle."
  let #(prepared, owner, _) = fixture.cleared(rig, operation)
  let assert Ok(attachment) = lsp_native.submit(pending, key, prepared)
    as "Actual owner clearance precedes native admission."
  let assert transport.ConsumedChannelTransport(connect) =
    lsp_native.transport(attachment)
    as "The original attachment supplies the actual consumed window."
  let events = process.new_subject()
  let assert Ok(window) = consumed.open(connect, events)
    as "The actual sink precedes original Begin."
  let peer = first_started(rig.peers)
  let start = fixture.next(peer)
  let assert framing.ProtocolStart(mode: framing.ServerProtocol, ..) =
    start.body
    as "The original helper receives real ServerProtocol dispatch."
  let assert Ok(#(Some(start_signal), None, None)) =
    lsp_credit_signals(attachment)
    as "Only the exact original Service task supplies its signal PID."
  assert process.is_alive(start_signal)
  let start_watch = process.monitor(start_signal)

  // Each actual ACK and consumed output barrier must reap its own signal before
  // a subsequent successful credit can replace the bounded original task row.
  let originals =
    list.map([1, 2, 3], fn(ordinal) {
      assert window.send("credit") == Ok(Nil)
      let assert framing.ProtocolInput(
        id,
        input_ordinal,
        input_sequence,
        <<"credit">>,
        framing.InputContinues,
      ) = fixture.next(peer).body
        as "The original input credit reaches the actual helper."
      assert id == start.id
      assert input_ordinal == ordinal
      assert input_sequence == ordinal
      let assert Ok(#(Some(same_start), Some(input_signal), None)) =
        lsp_credit_signals(attachment)
        as "The blocked ACK retains this exact original input signal."
      assert same_start == start_signal
      assert process.is_alive(input_signal)
      let input_watch = process.monitor(input_signal)
      fixture.inbound(
        peer,
        framing.Frame(
          start.id,
          framing.ProtocolInputAccepted(start.id, ordinal, ordinal),
        ),
      )
      let assert poll.Answered(Nil) =
        poll.until(1000, 5, fn() {
          case lsp_credit_signals(attachment) {
            Ok(#(_, None, None)) -> poll.Done(Nil)
            Ok(_) -> poll.Retry
            Error(error) -> poll.Fail(error)
          }
        })
        as "Actual input AllDelivered clears only the completed original task."
      assert_signal_reaped(input_signal, input_watch)

      fixture.inbound(
        peer,
        framing.Frame(
          start.id,
          framing.ProtocolOutput(
            start.id,
            ordinal,
            framing.Stdout,
            <<"ok">>,
            ordinal * 2,
            framing.OutputComplete,
          ),
        ),
      )
      let assert Ok(consumed.Output(consumed.Stdout, <<"ok">>, grant)) =
        process.receive(events, 1000)
        as "The real output grant keeps its original consumption barrier."
      let assert Ok(#(Some(same_start), None, Some(output_signal))) =
        lsp_credit_signals(attachment)
        as "Only the exact original retained output task supplies its signal."
      assert same_start == start_signal
      assert process.is_alive(output_signal)
      let output_watch = process.monitor(output_signal)
      assert consumed.consume(grant) == Ok(Nil)
      let assert framing.ProtocolOutputConsumed(id, output_ordinal) =
        fixture.next(peer).body
        as "Actual consumption and AllDelivered precede native output credit."
      assert id == start.id
      assert output_ordinal == ordinal
      assert_signal_reaped(output_signal, output_watch)
      #(input_signal, output_signal)
    })
  assert lsp_credit_signals(attachment) == Ok(#(Some(start_signal), None, None))
  lsp_native.close(attachment)
  assert_signal_reaped(start_signal, start_watch)
  retire_peer(peer)
  let assert poll.Answered(Nil) =
    poll.until(5000, 10, fn() {
      case lsp_native.cleanup(attachment) {
        Ok(service.LspCleanup(
          drain: service.LspDrained,
          native: service.LspPositiveNative,
          ..,
        )) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "Original cancellation and retirement deliver the actual start drain."
  assert lsp_credit_signals(attachment) == Ok(#(None, None, None))
  list.each(originals, fn(pair) {
    assert !process.is_alive(pair.0)
    assert !process.is_alive(pair.1)
  })
  assert !process.is_alive(start_signal)
  window.close()
  broker.stop(owner)
  close_wire(rig)
}

fn assert_signal_reaped(signal: process.Pid, watch: process.Monitor) {
  let assert Ok(process.ProcessDown(_, same, process.Killed)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "Actual AllDelivered must terminate this exact original task signal."
  assert same == signal
  assert !process.is_alive(signal)
}

pub fn blocked_native_input_and_output_keep_exact_credit_while_cancel_stays_live_test() {
  let rig = fixture.start(fixture.WirePeer)
  let #(claim, lease, key, operation) = fixture.lease(rig, 3)
  let assert Ok(pending) =
    lsp_native.install_pending(rig.service, rig.store, claim, rig.plan, rig.era)
    as "The original Service wins placement."
  let #(prepared, owner, cleared) = fixture.cleared(rig, operation)
  let assert Ok(attachment) = lsp_native.submit(pending, key, prepared)
    as "Actual Broker-cleared native admission creates one parked attachment."
  let assert transport.ConsumedChannelTransport(connect) =
    lsp_native.transport(attachment)
    as "The original native attachment selects the consumed transport."
  let events = process.new_subject()
  let assert Ok(window) = consumed.open(connect, events)
    as "The real consumed window is installed before Begin."
  let peer = first_started(rig.peers)
  let start = fixture.next(peer)
  let assert framing.ProtocolStart(mode: framing.ServerProtocol, ..) =
    start.body
    as "The existing retiring dispatcher selects ServerProtocol."
  assert window.send("first") == Ok(Nil)
  let feed = fixture.next(peer)
  let assert framing.ProtocolInput(
    id,
    1,
    1,
    <<"first">>,
    framing.InputContinues,
  ) = feed.body
    as "The first actual credit has the original 1-based identity."
  assert id == start.id
  assert window.send("second") == Ok(Nil)
  assert process.receive(peer.outbound, 0) == Error(Nil)

  // Native queue admission is insufficient: only the actual helper ACK releases input.
  fixture.inbound(
    peer,
    framing.Frame(start.id, framing.ProtocolInputAccepted(start.id, 1, 1)),
  )
  let second = fixture.next(peer)
  let assert framing.ProtocolInput(
    id,
    2,
    2,
    <<"second">>,
    framing.InputContinues,
  ) = second.body
    as "The first ACK and both managed drains release one next credit."
  assert id == start.id
  fixture.inbound(
    peer,
    framing.Frame(
      start.id,
      framing.ProtocolOutput(
        start.id,
        1,
        framing.Stdout,
        <<"held">>,
        4,
        framing.OutputComplete,
      ),
    ),
  )
  let assert Ok(consumed.Output(consumed.Stdout, <<"held">>, grant)) =
    process.receive(events, 1000)
    as "Output reaches the original consumer with its opaque one-shot grant."
  assert process.receive(peer.outbound, 0) == Error(Nil)
  assert consumed.consume(grant) == Ok(Nil)
  let let_output = fixture.next(peer)
  let assert framing.ProtocolOutputConsumed(id, 1) = let_output.body
    as "Actual consumption and AllDelivered precede the helper ACK."
  assert id == start.id
  assert process.receive(peer.outbound, 0) == Error(Nil)
  let assert Error(_) = consumed.consume(grant)
    as "The old grant cannot renew credit."

  // The second input ACK remains held while cancellation uses the original control.
  lsp_native.close(attachment)
  let cancel = fixture.next(peer)
  let assert framing.Cancel = cancel.body
    as "Cancellation remains live while physical input is blocked."
  let assert Ok(cleanup) = lsp_native.cleanup(attachment)
    as "Original cleanup remains observable."
  assert cleanup.input == service.LspClosed
  assert cleanup.native == service.LspAwaitingNative
  let assert Ok(lease) = custody.inspect_lease(rig.store, rig.binding, lease)
    as "Custody is retained."
  assert custody.lease_disposition(lease) == custody.UncertainLease
  // WireClosed is fixture native evidence; terminal, consumed grant and drain were not.
  process.send(exec.wire(peer.helper), exec.WireClosed(0))
  let assert poll.Answered(Nil) =
    poll.until(5000, 10, fn() {
      case lsp_native.cleanup(attachment) {
        Ok(service.LspCleanup(
          native: service.LspPositiveNative,
          drain: service.LspDrained,
          ..,
        )) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "The actual original pool witness and managed drains are independently joined."
  let _ = cleared
  broker.stop(owner)
  close_wire(rig)
}

fn first_started(peers: List(fixture.Peer)) -> fixture.Peer {
  let assert poll.Answered(peer) =
    poll.until(3000, 5, fn() {
      case
        list.find(peers, fn(peer) {
          case exec.status(peer.helper, waiting: 1000) {
            exec.StatusBusy(_) -> True
            _ -> False
          }
        })
      {
        Ok(peer) -> poll.Done(peer)
        Error(_) -> poll.Retry
      }
    })
    as "The original borrowed helper is observed for fixture wiring only."
  peer
}

pub fn malformed_or_truncated_stdout_closes_real_client_without_prefix_success_test() {
  client_failure_control(framing.OutputComplete, <<
    "Content-Length: 1\r\n\r\n{",
  >>)
  client_failure_control(framing.OutputTruncated, <<
    "Content-Length: 0\r\n\r\n",
  >>)
}

fn client_failure_control(
  disposition: framing.OutputDisposition,
  bytes: BitArray,
) -> Nil {
  let rig = fixture.start(fixture.WirePeer)
  let #(claim, _, key, operation) = fixture.lease(rig, 4)
  let assert Ok(pending) =
    lsp_native.install_pending(rig.service, rig.store, claim, rig.plan, rig.era)
    as "Original fresh custody installs once."
  let #(prepared, owner, _) = fixture.cleared(rig, operation)
  let assert Ok(attachment) = lsp_native.submit(pending, key, prepared)
    as "Actual cleared Session creates the parked original."
  let result = process.new_subject()
  let run =
    weft.new_prepared([
      weft.managed(fn(_) {
        let answer =
          client.start(
            lsp_native.transport(attachment),
            client.Options(
              ..client.options("server", rig.path <> "/w", "fixture"),
              initialize_ms: 1000,
            ),
          )
        process.send(result, answer)
        Ok(Nil)
      }),
    ])
    |> weft.deadline(3000)
    |> weft.start_detached
  let peer = first_started(rig.peers)
  let start = fixture.next(peer)
  let input = fixture.next(peer)
  let assert framing.ProtocolInput(id, ordinal, frame, _, _) = input.body
    as "The production client sends its actual initialize request."
  assert id == start.id
  fixture.inbound(
    peer,
    framing.Frame(id, framing.ProtocolInputAccepted(id, ordinal, frame)),
  )
  fixture.inbound(
    peer,
    framing.Frame(
      id,
      framing.ProtocolOutput(
        id,
        1,
        framing.Stdout,
        bytes,
        bit_array.byte_size(bytes),
        disposition,
      ),
    ),
  )
  let assert Ok(Error(_)) = process.receive(result, 2000)
    as "Malformed or truncated stdout cannot acknowledge successful initialization."
  let cancel = fixture.next(peer)
  let assert framing.Cancel = cancel.body
    as "Protocol failure cancels the original helper."
  let assert framing.Shutdown = fixture.next(peer).body
    as "Failure retires the same original helper without consuming failed stdout."
  assert process.receive(peer.outbound, 0) == Error(Nil)
  let assert Ok(cleanup) = lsp_native.cleanup(attachment)
    as "Original cleanup remains separate."
  assert cleanup.input == service.LspClosed
  assert cleanup.native == service.LspAwaitingNative
  let assert Some(bytes) = cleanup.terminal
    as "The local protocol failure is retained before native proof."
  assert wire.decode_value(bytes)
    == Ok(mp.ArrayValue([mp.IntValue(3), mp.IntValue(0)]))
  let assert weft.PulledOutcome(weft.Completed(_, Nil)) = weft.pull(run, 1000)
    as "The original client start owner completes."
  assert weft.pull(run, 1000) == weft.AllDelivered
  broker.stop(owner)
  close_wire(rig)
}

pub fn original_owner_death_retains_its_native_borrow_and_durable_slot_test() {
  let rig = fixture.start(fixture.WirePeer)
  let #(claim, lease, key, operation) = fixture.lease(rig, 5)
  let #(prepared, owner, _) = fixture.cleared(rig, operation)
  let installed = process.new_subject()
  let run =
    weft.new_prepared([
      weft.managed(fn(_) {
        let assert Ok(pending) =
          lsp_native.install_pending(
            rig.service,
            rig.store,
            claim,
            rig.plan,
            rig.era,
          )
          as "The actual original managed owner installs fresh custody."
        let assert Ok(attachment) = lsp_native.submit(pending, key, prepared)
          as "The actual original owner submits the exact cleared request once."
        let release = process.new_subject()
        process.send(installed, #(attachment, release))
        process.receive_forever(release)
        Ok(Nil)
      }),
    ])
    |> weft.deadline(3000)
    |> weft.start_detached
  let assert Ok(#(attachment, release)) = process.receive(installed, 1000)
    as "The original attachment reaches its fixture consumer."
  let assert transport.ConsumedChannelTransport(connect) =
    lsp_native.transport(attachment)
    as "The original seam uses the consumed window."
  let events = process.new_subject()
  let assert Ok(window) = consumed.open(connect, events)
    as "The original sink precedes Begin."
  let peer = first_started(rig.peers)
  let _ = fixture.next(peer)
  process.send(release, Nil)
  let assert weft.PulledOutcome(weft.Completed(_, Nil)) = weft.pull(run, 1000)
    as "The actual original owner exits without replacing its native caller."
  assert weft.pull(run, 1000) == weft.AllDelivered
  let assert framing.Cancel = fixture.next(peer).body
    as "Original owner DOWN cancels the exact original native borrow."
  let assert Ok(cleanup) = lsp_native.cleanup(attachment)
    as "The independent Service observer remains live."
  assert cleanup.input == service.LspClosed
  assert cleanup.native == service.LspAwaitingNative
  assert lsp_native.install_pending(
      rig.service,
      rig.store,
      claim,
      rig.plan,
      rig.era,
    )
    |> result.is_error
  assert custody.unretired_lease_count(rig.store, rig.binding) == Ok(1)
  let assert Ok(history) = custody.inspect_lease(rig.store, rig.binding, lease)
    as "Uncertainty retains the exact durable lease."
  assert custody.lease_disposition(history) != custody.Retired
  window.close()
  broker.stop(owner)
  close_wire(rig)
}

pub fn real_helper_server_keeps_full_enforcement_and_original_retirement_test() {
  let rig = fixture.start(fixture.RealHelper)
  let #(claim, lease, key, operation) = fixture.lease(rig, 7)
  let assert Ok(pending) =
    lsp_native.install_pending(rig.service, rig.store, claim, rig.plan, rig.era)
    as "The exact live lease installs its original plan."
  let #(prepared, owner, _) = fixture.cleared(rig, operation)
  let assert Ok(attachment) = lsp_native.submit(pending, key, prepared)
    as "The actual Broker clearance precedes native Request and Admit."
  let started =
    client.start(
      lsp_native.transport(attachment),
      client.Options(
        ..client.options("server", rig.path <> "/w", "fixture"),
        initialize_ms: 3000,
      ),
    )
  case ffi_os.os_name() {
    "linux" -> {
      let assert Ok(client) = started
        as "The real FullEnforcement server answers the actual initialize handshake."
      assert client.request(
          client,
          protocol.HoverFeature,
          "textDocument/hover",
          Some(json.Object([])),
          1000,
        )
        == Ok(json.Null)
      assert client.stop(client, 1000) == client.Graceful
    }
    "darwin" -> {
      // The Darwin report settles FullEnforcement at the native terminal. An
      // answered initialize cannot substitute for that eventual refusal.
      case started {
        Ok(client) -> {
          // This fixture method exits its child after replying. Native settlement
          // therefore precedes local transport close and retains the real report.
          let _ =
            client.request(client, protocol.HoverFeature, "exit", None, 1000)
          Nil
        }
        Error(_) -> Nil
      }
    }
    other ->
      panic as {
        "This native fixture requires the supported Linux or Darwin jail: "
        <> other
      }
  }
  let assert poll.Answered(cleanup) =
    poll.until(5000, 10, fn() {
      case lsp_native.cleanup(attachment) {
        Ok(
          service.LspCleanup(
            native: service.LspPositiveNative,
            drain: service.LspDrained,
            ..,
          ) as cleanup,
        ) -> poll.Done(cleanup)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "Actual helper exit, ForgetRetired, original normal DOWN and managed drain join separately."
  assert cleanup.input == service.LspClosed
  let assert Some(bytes) = cleanup.terminal
    as "The original bounded failure or protocol terminal is retained."
  case ffi_os.os_name() {
    "darwin" -> {
      let assert Ok(native_plan.NativeTerminal(
        dispatch.Failed(failure),
        framing.ProtocolFailed,
      )) = native_plan.decode_witness(bytes)
        as "The actual helper refusal retains its own native failure and failed protocol disposition."
      let assert exec.DegradedExecution(_) = failure
        as "The real Darwin report refuses the unchanged FullEnforcement demand."
      Nil
    }
    _ -> {
      assert bit_array.byte_size(bytes) <= 32_768
    }
  }
  let assert Ok(history) = custody.inspect_lease(rig.store, rig.binding, lease)
    as "Native evidence does not retire semantic custody."
  assert custody.lease_disposition(history) != custody.Retired
  assert service.shutdown(rig.service) == Ok(Nil)
  broker.stop(owner)
  assert custody.release(rig.store) == Ok(Nil)
  assert journal.release(rig.book) == Ok(Nil)
}

pub fn real_helper_terminal_preserves_full_enforcement_without_local_close_test() {
  let rig = fixture.start(fixture.RealHelper)
  let #(claim, lease, key, operation) = fixture.lease(rig, 16)
  let assert Ok(pending) =
    lsp_native.install_pending(rig.service, rig.store, claim, rig.plan, rig.era)
    as "The exact original live lease owns this separate terminal control."
  let #(prepared, owner, _) = fixture.cleared(rig, operation)
  let assert Ok(attachment) = lsp_native.submit(pending, key, prepared)
    as "Actual original Broker clearance precedes native effects."
  let assert Ok(client) =
    client.start(
      lsp_native.transport(attachment),
      client.Options(
        ..client.options("server", rig.path <> "/w", "fixture"),
        initialize_ms: 3000,
      ),
    )
    as "The actual fixture answers initialize before its native terminal."
  assert client.request(client, protocol.HoverFeature, "shutdown", None, 1000)
    == Ok(json.Null)

  // The fixture exits after replying to this raw request. Unlike client.stop,
  // this path leaves the original transport open until actual native settlement.
  assert client.request(client, protocol.HoverFeature, "exit", None, 1000)
    == Ok(json.Null)
  let assert poll.Answered(cleanup) =
    poll.until(5000, 10, fn() {
      case lsp_native.cleanup(attachment) {
        Ok(
          service.LspCleanup(
            native: service.LspPositiveNative,
            drain: service.LspDrained,
            ..,
          ) as cleanup,
        ) -> poll.Done(cleanup)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "Actual native terminal and original retirement drain precede local close."
  let assert Some(bytes) = cleanup.terminal
    as "The native witness cannot be replaced by local protocol closure."
  case ffi_os.os_name() {
    "linux" -> {
      let assert Ok(native_plan.NativeTerminal(
        dispatch.Completed(result),
        framing.ProtocolComplete,
      )) = native_plan.decode_witness(bytes)
        as "Actual FullEnforcement completion and consumed protocol success are required."
      assert result.code == 0
      assert !result.degraded
      assert !result.timed_out
      assert !result.cancelled
      assert !result.stdout_truncated
      assert !result.stderr_truncated
    }
    "darwin" -> {
      let assert Ok(native_plan.NativeTerminal(
        dispatch.Failed(exec.DegradedExecution(_)),
        framing.ProtocolFailed,
      )) = native_plan.decode_witness(bytes)
        as "Darwin's actual report refuses the unchanged FullEnforcement demand."
      Nil
    }
    other ->
      panic as {
        "This native fixture requires the supported Linux or Darwin jail: "
        <> other
      }
  }
  assert cleanup.input == service.LspClosed
  let assert Ok(history) = custody.inspect_lease(rig.store, rig.binding, lease)
    as "Actual terminal and native proof remain distinct from semantic retirement."
  assert custody.lease_disposition(history) != custody.Retired
  let _ = client.stop(client, 1000)
  assert service.shutdown(rig.service) == Ok(Nil)
  broker.stop(owner)
  assert custody.release(rig.store) == Ok(Nil)
  assert journal.release(rig.book) == Ok(Nil)
}

pub fn output_join_retains_consumed_drain_until_exact_original_handle_test() {
  let rig = fixture.start(fixture.WirePeer)
  let #(_, _, _, operation) = fixture.lease(rig, 8)
  let #(prepared, owner, _) = fixture.cleared(rig, operation)
  let retired = process.new_subject()
  let assert Ok(dispatcher) =
    local.dispatcher_protocol_retiring_with_native_deadline(
      rig.native,
      fn(_, verdict) { process.send(retired, verdict) },
    )
    as "The actual original retiring constructor supplies the execution."
  let native_events = process.new_subject()
  let now = poll.monotonic().now
  let assert Ok(execution) =
    local.start_protocol(
      dispatcher,
      local.ProtocolDispatch(
        71,
        prepared.request,
        clock.from_function(now),
        now() + 10_000,
        native_events,
        process.self(),
      ),
    )
    as "Actual helper Run constructs the opaque original handle."
  let assert Ok(uncertain) =
    native_plan.encode_start_failure(local.ProtocolStartUnknown(
      execution,
      exec.HelperUnresponsive,
    ))
    as "An exact unknown original preserves the existing failure codec without reissuing its handle."
  assert native_plan.decode_witness(uncertain)
    == Ok(native_plan.StartupUnknown(exec.HelperUnresponsive))
  let peer = first_started(rig.peers)
  let start = fixture.next(peer)
  let events = process.new_subject()
  let sinks = process.new_subject()
  let assert Ok(window) =
    consumed.open(
      fn(sink) {
        process.send(sinks, sink)
        Ok(consumed.Session(fn(_) { Error(Nil) }, fn() { Nil }))
      },
      events,
    )
    as "The existing consumed actor owns actual grants."
  let assert Ok(sink) = process.receive(sinks, 1000)
    as "Only the original connection receives the sink."
  list.each([1, 2], fn(ordinal) {
    fixture.inbound(
      peer,
      framing.Frame(
        start.id,
        framing.ProtocolOutput(
          start.id,
          ordinal,
          framing.Stdout,
          <<"joined">>,
          ordinal * 6,
          framing.OutputComplete,
        ),
      ),
    )
    let assert Ok(exec.ProtocolOutput(
      actual_ordinal,
      framing.Stdout,
      bytes,
      _,
      framing.OutputComplete,
    )) = process.receive(native_events, 1000)
      as "The actual original helper output reaches its checked receiver."
    assert actual_ordinal == ordinal
    let credit = output_join.new(ordinal)
    let credit = case ordinal {
      1 -> credit
      2 -> {
        let #(credit, action) = output_join.original(credit, execution)
        assert action == output_join.Hold
        credit
      }
      _ -> panic as "The fixed control has exactly two arrival orders."
    }
    let run =
      weft.new_prepared([
        weft.managed(fn(_) {
          consumed.publish(sink, consumed.Stdout, bytes, consumed.Intact)
          |> result.replace_error(Nil)
        }),
      ])
      |> weft.deadline(1000)
      |> weft.start_detached
    let assert Ok(consumed.Output(consumed.Stdout, <<"joined">>, grant)) =
      process.receive(events, 1000)
      as "The original window grants actual output consumption."
    assert consumed.consume(grant) == Ok(Nil)
    let assert weft.PulledOutcome(weft.Completed(_, Nil)) = weft.pull(run, 1000)
      as "Actual publish success is the retained consumption witness."
    assert weft.pull(run, 1000) == weft.AllDelivered
    let #(credit, first_action) = output_join.consumed(credit)
    let #(credit, action) = case ordinal {
      1 -> {
        assert first_action == output_join.Hold
        assert process.receive(peer.outbound, 0) == Error(Nil)
        let #(retained, duplicate) = output_join.consumed(credit)
        assert duplicate == output_join.Hold
        assert retained == credit
        output_join.original(credit, execution)
      }
      2 -> #(credit, first_action)
      _ -> panic as "The fixed control has exactly two arrival orders."
    }
    let assert output_join.Release(original, exact_ordinal) = action
      as "Both witnesses release the same exact original credit once."
    assert original == execution
    assert exact_ordinal == ordinal
    local.protocol_output_consumed(original, exact_ordinal)
    let assert framing.ProtocolOutputConsumed(_, exact) =
      fixture.next(peer).body
      as "The actual helper receives one credit after the checked join."
    assert exact == ordinal
    assert output_join.original(credit, execution).1 == output_join.Hold
    assert output_join.consumed(credit).1 == output_join.Hold
    assert process.receive(peer.outbound, 0) == Error(Nil)
  })
  let #(held, _) = output_join.consumed(output_join.new(3))
  let #(spent, dropped) = output_join.drop(held)
  assert dropped == output_join.Dropped
  assert output_join.original(spent, execution).1 == output_join.Hold
  window.close()
  local.cancel_protocol(execution)
  local.release_protocol_execution(execution)
  let assert framing.Cancel = fixture.next(peer).body
    as "The exact original protocol execution is cancelled."
  let assert framing.Shutdown = fixture.next(peer).body
    as "The released original borrow requests helper retirement."
  process.send(exec.wire(peer.helper), exec.WireClosed(0))
  assert process.receive(retired, 1000) == Ok(Ok(Nil))
  broker.stop(owner)
  close_wire(rig)
}

pub fn three_profiles_reserve_three_helpers_and_uncertainty_stays_charged_test() {
  let rig = fixture.start(fixture.WirePeer)
  let originals =
    list.map([#("server", 11), #("second", 12)], fn(profile) {
      let #(claim, _, key, operation) =
        fixture.lease_for(rig, profile.1, profile.0)
      let assert Ok(#(_, plan, _)) =
        list.find(rig.variants, fn(item) { item.0 == profile.0 })
        as "The actual checked descriptor declares this distinct profile."
      let assert Ok(pending) =
        lsp_native.install_pending(rig.service, rig.store, claim, plan, rig.era)
        as "The incoming FreshLease is already charged, so the available slot is admitted."
      start_profile(rig, pending, key, operation, profile.0)
    })
  let #(claim, _, key, operation) = fixture.lease_for(rig, 13, "third")
  let assert Ok(#(_, plan, _)) =
    list.find(rig.variants, fn(item) { item.0 == "third" })
    as "The last legitimate slot retains its own actual profile."
  let replies = process.new_subject()
  let owners =
    weft.new_prepared(
      list.map([1, 2], fn(_) {
        weft.managed(fn(_) {
          let release = process.new_subject()
          process.send(replies, #(
            lsp_native.install_pending(
              rig.service,
              rig.store,
              claim,
              plan,
              rig.era,
            ),
            release,
          ))
          process.receive_forever(release)
          Ok(Nil)
        })
      }),
    )
    |> weft.deadline(10_000)
    |> weft.start_detached
  let assert Ok(one) = process.receive(replies, 1000)
    as "The first concurrent last-slot ask answers."
  let assert Ok(two) = process.receive(replies, 1000)
    as "The competing last-slot ask answers."
  assert list.length(list.filter([one.0, two.0], result.is_ok)) == 1
  let assert Ok(pending) =
    list.find_map([one.0, two.0], fn(answer) {
      answer |> result.replace_error(Nil)
    })
    as "The serialized original Service grants exactly one remaining placement."
  let third = start_profile(rig, pending, key, operation, "third")
  let all = [third, ..originals]
  let assert Ok(snapshot) = local.snapshot(rig.native, waiting: 1000)
    as "The actual pool census measures the three occupied LSP slots."
  let assert Ok(pool) = snapshot.pool
    as "The original pool owns its bounded census."
  assert pool.census.size == 6
  assert pool.census.borrowed == 3
  assert pool.census.size - pool.census.borrowed == 3
  assert custody.unretired_lease_count(rig.store, rig.binding) == Ok(3)
  lsp_native.close(third.0)
  let assert Ok(cleanup) = lsp_native.cleanup(third.0)
    as "Cancellation leaves the original slot uncertain until exact native proof."
  assert cleanup.native == service.LspAwaitingNative
  let #(fourth, _, _fourth_key, _) = fixture.lease_for(rig, 14, "fourth")
  let assert Ok(#(_, fourth_plan, _)) =
    list.find(rig.variants, fn(item) { item.0 == "fourth" })
    as "The fourth profile is declared but has no permitted helper slot."
  assert lsp_native.install_pending(
      rig.service,
      rig.store,
      fourth,
      fourth_plan,
      rig.era,
    )
    == Error(service.Capacity)
  assert custody.unretired_lease_count(rig.store, rig.binding) == Ok(4)
  list.each(all, fn(item) {
    item.1.close()
    broker.stop(item.2)
    retire_peer(item.3)
  })
  process.send(one.1, Nil)
  process.send(two.1, Nil)
  let assert weft.PulledOutcome(_) = weft.pull(owners, 1000)
    as "The first original placement owner joins."
  let assert weft.PulledOutcome(_) = weft.pull(owners, 1000)
    as "The second original placement owner joins."
  assert weft.pull(owners, 1000) == weft.AllDelivered
  list.each(rig.peers, fn(peer) {
    process.send(exec.wire(peer.helper), exec.WireClosed(0))
  })
  let joined =
    poll.until(3000, 5, fn() {
      case
        list.all(all, fn(item) {
          case lsp_native.cleanup(item.0) {
            Ok(service.LspCleanup(
              native: service.LspPositiveNative,
              drain: service.LspDrained,
              ..,
            )) -> True
            _ -> False
          }
        })
      {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  let assert poll.Answered(Nil) = joined
    as "Every original attachment requires its independent exact observer and managed drain."
  close_wire(rig)
}

fn start_profile(
  rig: fixture.Rig,
  pending: lsp_native.PendingServerLease,
  key: identity.RequestKey,
  operation: ids.OpId,
  name: String,
) {
  let #(prepared, owner, _) = fixture.cleared_for(rig, operation, name)
  let assert Ok(attachment) = lsp_native.submit(pending, key, prepared)
    as "The actual named profile is cleared before native admission."
  let assert transport.ConsumedChannelTransport(connect) =
    lsp_native.transport(attachment)
    as "The original attachment installs its actual consumed sink."
  let assert Ok(window) = consumed.open(connect, process.new_subject())
    as "Begin follows the real consumed sink."
  let #(peer, start) = first_unread_start(rig.peers)
  let assert framing.ProtocolStart(mode: framing.ServerProtocol, ..) =
    start.body
    as "The actual credited dispatcher starts this original profile once."
  #(attachment, window, owner, peer)
}

fn first_unread_start(
  peers: List(fixture.Peer),
) -> #(fixture.Peer, framing.Frame) {
  let assert poll.Answered(frame) =
    poll.until(1000, 5, fn() {
      case
        list.find_map(peers, fn(peer) {
          process.receive(peer.outbound, 0)
          |> result.map(fn(bytes) { #(peer, bytes) })
        })
      {
        Ok(#(peer, bytes)) -> {
          let assert [framing.Known(frame)] =
            framing.push(framing.deframer(), bytes).inbound
            as "The actual peer emits one canonical original frame."
          poll.Done(#(peer, frame))
        }
        Error(_) -> poll.Retry
      }
    })
    as "The deterministic peer's original wire owns one pending start."
  frame
}

fn retire_peer(peer: fixture.Peer) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(1000, 5, fn() {
      case process.receive(peer.outbound, 0) {
        Ok(bytes) -> {
          let assert [framing.Known(frame)] =
            framing.push(framing.deframer(), bytes).inbound
            as "Only the exact original helper's lifecycle wire supplies retirement ordering."
          case frame.body {
            framing.Shutdown -> poll.Done(Nil)
            framing.Cancel -> poll.Retry
            _ -> poll.Fail(Nil)
          }
        }
        Error(_) -> poll.Retry
      }
    })
    as "Actual retirement requests precede original native exit evidence."
  process.send(exec.wire(peer.helper), exec.WireClosed(0))
}

pub fn immutable_witness_codec_distinguishes_start_terminal_and_local_failure_test() {
  list.each(
    [
      #(
        local.ProtocolNotStarted(dispatch.NotStarted),
        native_plan.StartupRefused,
      ),
      #(
        local.ProtocolNotStarted(
          dispatch.NoHelper(exec.SpawnFailed(exec.PortOpenFailed)),
        ),
        native_plan.StartupNoHelper,
      ),
      #(local.ProtocolStartReplyLost, native_plan.StartupReplyLost),
    ],
    fn(pair) {
      let assert Ok(bytes) = native_plan.encode_start_failure(pair.0)
        as "The closed original startup category is canonical."
      assert native_plan.decode_witness(bytes) == Ok(pair.1)
      assert native_plan.decode_terminal(bytes) == Error(wire.Invalid)
    },
  )
  let assert Ok(closed) = native_plan.encode_local_closure()
    as "Local failure has its own immutable schema."
  assert native_plan.decode_witness(closed)
    == Ok(native_plan.LocalProtocolClosed)
  assert native_plan.decode_terminal(closed) == Error(wire.Invalid)
  let assert Ok(terminal) =
    native_plan.encode_terminal(
      dispatch.Failed(exec.HelperUnresponsive),
      framing.ProtocolFailed,
    )
    as "Actual native failure keeps the existing native codec."
  assert native_plan.decode_witness(terminal)
    == Ok(native_plan.NativeTerminal(
      dispatch.Failed(exec.HelperUnresponsive),
      framing.ProtocolFailed,
    ))
  let assert Ok(unknown) =
    wire.encode_value(
      mp.ArrayValue([mp.IntValue(2), mp.IntValue(4), mp.NilValue]),
    )
    as "The fixed unknown tag is a canonical scalar schema control."
  assert native_plan.decode_witness(unknown) == Error(wire.Invalid)
}

pub fn request_commit_before_authority_refusal_keeps_exact_scope_coverage_test() {
  let rig = fixture.start(fixture.WirePeer)
  let #(claim, lease, key, operation) = fixture.lease(rig, 15)
  let assert Ok(pending) =
    lsp_native.install_pending(rig.service, rig.store, claim, rig.plan, rig.era)
    as "Only checked original first placement precedes the refusal control."
  let #(prepared, owner, _) = fixture.cleared(rig, operation)
  let assert Ok(digest) = wire.prepared_digest(prepared)
    as "Coverage retains this exact original cleared digest."
  let assert Ok(bytes) = wire.encode_prepared(prepared)
    as "The original Request body is canonical."
  let assert Ok(connection) = sqlight.open(rig.path <> "/s/native.sqlite")
    as "A separate real SQLite fixture connection installs the bounded refusal."
  assert sqlight.exec(
      "CREATE TRIGGER suppress_authority BEFORE INSERT ON custody_payload WHEN NEW.kind=1 BEGIN SELECT RAISE(IGNORE); END",
      connection,
    )
    == Ok(Nil)
  assert sqlight.close(connection) == Ok(Nil)
  assert lsp_native.submit(pending, key, prepared) == Error(service.Uncertain)
  assert lsp_native.submit(pending, key, prepared) == Error(service.Invalid)
  assert journal.payloads(rig.book, key, digest) == Ok([payload.Request(bytes)])
  list.each(rig.peers, fn(peer) {
    assert process.receive(peer.outbound, 0) == Error(Nil)
  })
  let assert Ok(history) = custody.inspect_lease(rig.store, rig.binding, lease)
    as "A possibly committed native Request cannot reopen original lease input."
  assert custody.lease_disposition(history) == custody.Closing
  // Scope close must refuse success when this covered Request has no launched
  // lifecycle evidence. Its admitted reservation and payload remain charged.
  assert service.shutdown(rig.service) == Error(service.Invalid)
  let assert Ok(evidence) = journal.inspect(rig.book, key, digest)
    as "The exact Request retains its original admitted reservation."
  assert admission.phase(evidence) == admission.Admitted
  assert journal.payloads(rig.book, key, digest) == Ok([payload.Request(bytes)])
  broker.stop(owner)
  assert custody.release(rig.store) == Ok(Nil)
  assert journal.release(rig.book) == Ok(Nil)
}
