//// An in-process fake satellite peer for the host's deterministic tests.
////
//// It stands in for the jailed `erl` node on the far end of the cap
//// channel: `launcher(script)` builds a `satellite.Launcher` that, on
//// launch, reads the cap token the host wrote and spawns a peer process
//// running `script`. The peer speaks the real wire — it frames `cap_call`
//// and `cancel` with `broker/framing`, deframes the host's `cap_result`
//// frames, and writes the terminal `outcome` frame with its own encoder
//// (the kind `broker/framing` does not know). No live socket, no jail.
////
//// Each `script` computes its own verdict and reports it *through the
//// program outcome*, so a test that calls the blocking `satellite.run`
//// reads the peer's findings straight out of the returned `Outcome`.

import broker/framing.{type CapOutcome}
import codemode/enforcement
import codemode/run_channel
import codemode/satellite
import core/msgpack.{type MsgPackValue}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/result
import simplifile
import weft/state_machine as sm

/// Bytes and lifecycle delivered to the peer by the host's connection.
pub type Inbound {
  InboundBytes(data: BitArray)
  InboundClose

  /// The foreground writer releases custody only when the script reads this frame.
  InboundConsumedFrame(data: BitArray, consume: fn() -> Nil)
}

/// What a peer script runs against: the cap token the host minted, the
/// host's inbound-frame subject, and the peer's own inbox of `cap_result`
/// bytes.
pub type PeerCtx {
  PeerCtx(
    token: BitArray,
    wire: Subject(satellite.WireIn),
    inbox: Subject(Inbound),
  )
}

/// Builds a `satellite.Launcher` that drives `script` as the peer. The
/// launcher reads the token from the spec's token file, so the peer
/// presents the genuine token (a script may deliberately present a bogus
/// one instead).
///
/// Its `destroy` reports honestly that nothing was jailed: an in-process
/// peer is not a node, and a test seam that returned layers it never
/// applied would be the exact lie the report exists to prevent. Use
/// `reporting_launcher` to stand in for a helper that did report.
pub fn launcher(script: fn(PeerCtx) -> Nil) -> satellite.Launcher {
  reporting_launcher(
    script,
    enforcement.Unreported(
      "an in-process test peer runs no jailed node, so no helper reported",
    ),
  )
}

/// A peer launcher whose `destroy` hands back `report`, standing in for a
/// real launcher that collected one from its node's helper.
pub fn reporting_launcher(
  script: fn(PeerCtx) -> Nil,
  report: enforcement.Report,
) -> satellite.Launcher {
  fn(spec: satellite.LaunchSpec) {
    let token = read_token(spec.token_path)
    let handoff = process.new_subject()
    process.spawn(fn() {
      let inbox = process.new_subject()
      process.send(handoff, inbox)
      script(PeerCtx(token:, wire: spec.wire, inbox:))
    })
    case process.receive(handoff, 1000) {
      Error(Nil) -> Error("peer failed to start")
      Ok(inbox) ->
        Ok(
          satellite.CapConnection(
            send: fn(bytes) { process.send(inbox, InboundBytes(data: bytes)) },
            destroy: fn() {
              process.send(inbox, InboundClose)
              report
            },
          ),
        )
    }
  }
}

fn read_token(path: String) -> BitArray {
  simplifile.read_bits(from: path) |> result.unwrap(<<>>)
}

/// Builds a paused foreground peer. Its script reads the original minted token
/// directly because physical token placement belongs to the local adapter.
///
/// ## Examples
///
/// ```gleam
/// // satellite_peer.foreground_launcher(script)
/// ```
pub fn foreground_launcher(script: fn(PeerCtx) -> Nil) -> run_channel.Launcher {
  foreground_reporting_launcher(
    script,
    enforcement.Unreported("the fixture owns no jailed node"),
  )
}

/// Supplies explicit fixture evidence while retaining actual read-consumption ACKs.
///
/// ## Examples
///
/// ```gleam
/// // satellite_peer.foreground_reporting_launcher(script, injected_report)
/// ```
pub fn foreground_reporting_launcher(
  script: fn(PeerCtx) -> Nil,
  report: enforcement.Report,
) -> run_channel.Launcher {
  fn(request) {
    let incarnation = run_channel.new_incarnation()
    let #(_host, events) = run_channel.endpoint(run_channel.host(request))
    use bridge <- result.try(
      start_foreground_bridge(events, incarnation)
      |> result.map_error(fn(_) {
        run_channel.LaunchOutcomeUnknown("fixture bridge did not prepare")
      }),
    )
    let #(commands, wire) = bridge.data
    let handoff = process.new_subject()
    process.spawn(fn() {
      let inbox = process.new_subject()
      let gate = process.new_subject()
      process.send(handoff, #(inbox, gate))
      case process.receive(gate, 60_000) {
        Ok(Nil) ->
          script(PeerCtx(token: run_channel.token(request), wire:, inbox:))
        Error(Nil) -> Nil
      }
    })
    case process.receive(handoff, 1000) {
      Error(Nil) ->
        Error(run_channel.LaunchOutcomeUnknown("fixture peer did not prepare"))
      Ok(#(inbox, gate)) -> {
        let active =
          run_channel.prepare_direction(incarnation, run_channel.ToNode)
          |> run_channel.activate_direction
          |> result.try(run_channel.write_grant)
        let assert Ok(grant) = active
          as "fixture creates one original write window"
        Ok(
          run_channel.Connection(
            incarnation:,
            initial_write_grant: grant,
            activate: fn() {
              process.send(commands, PeerActivate)
              process.send(gate, Nil)
              Ok(Nil)
            },
            offer: fn(reservation, payload) {
              let #(frame, _) = run_channel.reservation(reservation)
              process.send(
                inbox,
                InboundConsumedFrame(run_channel.wire_bytes(payload), fn() {
                  process.send(events, run_channel.WriteConsumed(frame))
                }),
              )
              Ok(Nil)
            },
            close: fn() {
              process.send(inbox, InboundClose)
              process.send(commands, PeerStop)
              run_channel.CloseResult(
                node: report,
                transport: run_channel.TransportJoined,
                resources: run_channel.ResourcesReleased,
              )
            },
          ),
        )
      }
    }
  }
}

// Existing finite scripts retain their raw-wire probes. The bridge admits one
// complete frame and postpones the scripts' bounded test traffic while held.
// Production adapters never accept this fixture's arbitrary WireBytes surface.
type PeerPhase {
  PeerPrepared
  PeerAvailable
  PeerHeld
}

type PeerCommand {
  PeerActivate
  PeerBytes(event: satellite.WireIn)
  PeerConsumed(
    frame: run_channel.FrameRef,
    disposition: run_channel.Consumption,
  )
  PeerStop
}

type PeerBridge {
  PeerBridge(
    window: run_channel.Window,
    commands: Subject(PeerCommand),
    events: Subject(run_channel.Event),
    incarnation: run_channel.Incarnation,
  )
}

fn start_foreground_bridge(
  events: Subject(run_channel.Event),
  incarnation: run_channel.Incarnation,
) -> Result(
  sm.Started(#(Subject(PeerCommand), Subject(satellite.WireIn))),
  sm.StartError,
) {
  sm.new_with_initialiser(1000, fn(commands) {
    let wire = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(commands)
      |> process.select_map(wire, PeerBytes)
    sm.initialised(
      PeerPrepared,
      PeerBridge(
        window: run_channel.prepare_direction(incarnation, run_channel.ToHost),
        commands:,
        events:,
        incarnation:,
      ),
    )
    |> sm.selecting(selector)
    |> sm.returning(#(commands, wire))
    |> Ok
  })
  |> sm.on_event(peer_bridge_step)
  |> sm.start
}

fn peer_bridge_step(
  phase: PeerPhase,
  bridge: PeerBridge,
  event: PeerCommand,
) -> sm.Next(PeerPhase, PeerBridge, PeerCommand) {
  case phase, event {
    PeerPrepared, PeerActivate -> {
      let assert Ok(window) = run_channel.activate_direction(bridge.window)
        as "fixture activates once"
      sm.transition(to: PeerAvailable, data: PeerBridge(..bridge, window:))
    }
    PeerAvailable, PeerBytes(satellite.WireBytes(bytes)) -> {
      let checked = {
        use payload <- result.try(run_channel.from_wire(bytes))
        use length <- result.try(
          run_channel.payload_length(
            bit_array.byte_size(run_channel.payload(payload)),
          ),
        )
        use #(window, reservation) <- result.try(run_channel.reserve_frame(
          bridge.window,
          length,
        ))
        use window <- result.try(run_channel.publish_frame(window, reservation))
        let #(frame, _) = run_channel.reservation(reservation)
        let commands = bridge.commands
        use delivery <- result.try(
          run_channel.delivery(reservation, payload, fn(disposition) {
            process.send(commands, PeerConsumed(frame, disposition))
          }),
        )
        Ok(#(window, delivery))
      }
      case checked {
        Error(_) -> {
          process.send(
            bridge.events,
            run_channel.Fault(bridge.incarnation, "malformed cap frame"),
          )
          sm.stop()
        }
        Ok(#(window, delivery)) -> {
          process.send(bridge.events, run_channel.Frame(delivery))
          sm.transition(to: PeerHeld, data: PeerBridge(..bridge, window:))
        }
      }
    }
    PeerHeld, PeerConsumed(frame, disposition) -> {
      let #(window, consumed) =
        run_channel.consume_frame(bridge.window, frame, disposition)
      case consumed, disposition {
        run_channel.Ignored, _ -> sm.keep(bridge)
        run_channel.Consumed, run_channel.Final -> sm.stop()
        run_channel.Consumed, run_channel.Continue ->
          sm.transition(to: PeerAvailable, data: PeerBridge(..bridge, window:))
      }
    }
    _, PeerStop -> sm.stop()
    _, PeerBytes(satellite.WireClosed(reason)) -> {
      process.send(bridge.events, run_channel.End(bridge.incarnation, reason))
      sm.stop()
    }
    PeerPrepared, PeerBytes(_) | PeerHeld, PeerBytes(_) ->
      sm.keep(bridge) |> sm.postpone
    PeerAvailable, PeerActivate
    | PeerHeld, PeerActivate
    | PeerPrepared, PeerConsumed(..)
    | PeerAvailable, PeerConsumed(..)
    -> sm.keep(bridge)
  }
}

// --- sending -------------------------------------------------------------

/// Frames and sends a `cap_call` carrying `token`, `cap`, and `argv`.
pub fn send_proc_run(
  ctx: PeerCtx,
  token: BitArray,
  id: Int,
  argv: List(String),
) -> Nil {
  let args =
    msgpack.MapValue([
      #(
        msgpack.StringValue("argv"),
        msgpack.ArrayValue(list.map(argv, msgpack.StringValue)),
      ),
    ])
  send_cap_call(ctx, token, id, "proc.run", args)
}

/// Frames and sends a `cap_call` for an arbitrary capability name, so a
/// test can drive a router of its own.
pub fn send_cap_call(
  ctx: PeerCtx,
  token: BitArray,
  id: Int,
  cap: String,
  args: MsgPackValue,
) -> Nil {
  send_frame(
    ctx,
    framing.Frame(
      id:,
      body: framing.CapCall(token:, cap:, args:, deadline_ms: 5000),
    ),
  )
}

/// Frames and sends a `cancel` correlated to a `cap_call` id.
pub fn send_cancel(ctx: PeerCtx, id: Int) -> Nil {
  send_frame(ctx, framing.Frame(id:, body: framing.Cancel))
}

/// Writes the terminal `outcome` frame with a `Completed` value (the J3a
/// shape `{v:1, id:0, kind:"outcome", body:{ok:true, value}}`), encoded
/// with the peer's own encoder since `broker/framing` does not know the
/// kind.
pub fn send_outcome(ctx: PeerCtx, value: MsgPackValue) -> Nil {
  send_envelope(ctx, [
    #("v", msgpack.IntValue(1)),
    #("id", msgpack.IntValue(0)),
    #("kind", msgpack.StringValue(satellite.outcome_kind)),
    #("body", completed_body(value)),
  ])
}

/// The `{ok: true, value}` body of a `Completed` outcome.
pub fn completed_body(value: MsgPackValue) -> MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("ok"), msgpack.BoolValue(True)),
    #(msgpack.StringValue("value"), value),
  ])
}

/// Frames and sends an arbitrary envelope map, so a test can present the
/// frame a satellite speaking a different protocol version — or omitting a
/// required envelope key — would write.
pub fn send_envelope(
  ctx: PeerCtx,
  entries: List(#(String, MsgPackValue)),
) -> Nil {
  let envelope =
    msgpack.MapValue(
      list.map(entries, fn(entry) { #(msgpack.StringValue(entry.0), entry.1) }),
    )
  let assert Ok(payload) = msgpack.encode(envelope)
  let size = bit_array.byte_size(payload)
  process.send(
    ctx.wire,
    satellite.WireBytes(data: <<size:size(32), payload:bits>>),
  )
}

fn send_frame(ctx: PeerCtx, frame: framing.Frame) -> Nil {
  let assert Ok(bytes) = framing.encode(frame)
  process.send(ctx.wire, satellite.WireBytes(data: bytes))
}

// --- receiving -----------------------------------------------------------

/// Collects up to `need` `cap_result`s in arrival order, or fewer if the
/// per-receive `timeout` elapses first.
pub fn collect_results(
  ctx: PeerCtx,
  need: Int,
  timeout: Int,
) -> List(#(Int, CapOutcome)) {
  collect_loop(ctx.inbox, framing.deframer(), [], need, timeout)
}

/// Drains every `cap_result` that arrives within `window` milliseconds of
/// quiet, in arrival order.
pub fn drain_results(ctx: PeerCtx, window: Int) -> List(#(Int, CapOutcome)) {
  collect_loop(ctx.inbox, framing.deframer(), [], -1, window)
}

fn collect_loop(
  inbox: Subject(Inbound),
  deframer: framing.Deframer,
  acc: List(#(Int, CapOutcome)),
  need: Int,
  timeout: Int,
) -> List(#(Int, CapOutcome)) {
  case need >= 0 && list.length(acc) >= need {
    True -> list.reverse(acc)
    False ->
      case receive_consumed(inbox, timeout) {
        Error(Nil) -> list.reverse(acc)
        Ok(InboundClose) -> list.reverse(acc)
        Ok(InboundBytes(data:)) | Ok(InboundConsumedFrame(data:, consume: _)) -> {
          let framing.Pushed(deframer:, inbound:, fault: _) =
            framing.push(deframer, data)
          let acc =
            list.fold(inbound, acc, fn(acc, item) {
              case item {
                framing.Known(frame: framing.Frame(
                  id:,
                  body: framing.CapResult(outcome:, usage: _),
                )) -> [#(id, outcome), ..acc]
                _ -> acc
              }
            })
          collect_loop(inbox, deframer, acc, need, timeout)
        }
      }
  }
}

/// Blocks until the host closes the connection (its teardown). Used by the
/// silent peer that never reports an outcome, so the host's wall deadline
/// is what settles the execution.
pub fn wait_for_close(ctx: PeerCtx) -> Nil {
  case receive_consumed(ctx.inbox, 60_000) {
    Ok(InboundClose) -> Nil
    Ok(_) -> wait_for_close(ctx)
    Error(Nil) -> Nil
  }
}

// --- the persistent host's direction --------------------------------------
//
// A `Host` (as against a `run`) speaks first: it sends `hook_call` and
// waits for `hook_result`. A peer script for one is therefore a loop over
// inbound frames rather than a straight line, so it needs a deframer it
// can carry between reads — which `collect_results` hides inside its own
// recursion and cannot lend out.

/// A peer's read cursor over the host's outbound frames, carried between
/// reads so a script can act on one frame and then wait for the next.
pub opaque type Reading {
  Reading(deframer: framing.Deframer, seen: List(framing.Frame))
}

/// A fresh cursor.
pub fn reading() -> Reading {
  Reading(deframer: framing.deframer(), seen: [])
}

/// The next frame the host wrote, or `Error(Nil)` if none arrived inside
/// `timeout` (or the host closed the connection).
pub fn next_frame(
  ctx: PeerCtx,
  cursor: Reading,
  timeout: Int,
) -> Result(#(Reading, framing.Frame), Nil) {
  case cursor.seen {
    [frame, ..rest] -> Ok(#(Reading(..cursor, seen: rest), frame))
    [] ->
      case receive_consumed(ctx.inbox, timeout) {
        Error(Nil) -> Error(Nil)
        Ok(InboundClose) -> Error(Nil)
        Ok(InboundBytes(data:)) | Ok(InboundConsumedFrame(data:, consume: _)) -> {
          let framing.Pushed(deframer:, inbound:, fault: _) =
            framing.push(cursor.deframer, data)
          let frames =
            list.filter_map(inbound, fn(item) {
              case item {
                framing.Known(frame:) -> Ok(frame)
                framing.UnknownInbound(..) -> Error(Nil)
              }
            })
          next_frame(ctx, Reading(deframer:, seen: frames), timeout)
        }
      }
  }
}

/// The next `hook_call` the host wrote, skipping anything else on the way.
pub fn next_hook_call(
  ctx: PeerCtx,
  cursor: Reading,
  timeout: Int,
) -> Result(#(Reading, framing.Frame), Nil) {
  use #(cursor, frame) <- result.try(next_frame(ctx, cursor, timeout))
  case frame.body {
    framing.HookCall(..) -> Ok(#(cursor, frame))
    _other -> next_hook_call(ctx, cursor, timeout)
  }
}

/// Answers a `hook_call` under the same frame id.
pub fn send_hook_result(ctx: PeerCtx, id: Int, outcome: CapOutcome) -> Nil {
  send_frame(ctx, framing.Frame(id:, body: framing.HookResult(outcome:)))
}

/// The token, name and arguments a `hook_call` carried.
pub fn hook_call_parts(frame: framing.Frame) -> #(BitArray, String, String) {
  case frame.body {
    framing.HookCall(token:, kind:, name:, ..) -> #(token, kind, name)
    _other -> #(<<>>, "", "")
  }
}

// Receiving a complete bounded reply is the fixture's consumption witness.
fn receive_consumed(
  inbox: Subject(Inbound),
  timeout: Int,
) -> Result(Inbound, Nil) {
  process.receive(inbox, timeout)
  |> result.map(fn(inbound) {
    case inbound {
      InboundConsumedFrame(data, consume) -> {
        consume()
        InboundBytes(data)
      }
      InboundBytes(_) | InboundClose -> inbound
    }
  })
}

/// Receives one foreground frame without returning its transport consumption.
/// The fixture uses this to hold the original writer credit deliberately.
///
/// ## Examples
///
/// ```gleam
/// // let Ok(#(wire_bytes, consume)) = satellite_peer.receive_unconsumed(ctx, 3000)
/// // consume() is the later original writer acknowledgement.
/// ```
pub fn receive_unconsumed(
  ctx: PeerCtx,
  timeout: Int,
) -> Result(#(BitArray, fn() -> Nil), Nil) {
  case process.receive(ctx.inbox, timeout) {
    Ok(InboundConsumedFrame(data, consume)) -> Ok(#(data, consume))
    Ok(InboundBytes(_)) | Ok(InboundClose) | Error(Nil) -> Error(Nil)
  }
}
