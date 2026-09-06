//// Real v2 upgrades use the scripted gateway, never native effects. These
//// checks establish identity, original-gateway lifetime fencing and credited
//// fragments without legacy history reads. Native retirement is covered by
//// the separate real SQLite reader-failure integration test.

import broker/token
import client/daemon/domain as domain_service
import client/daemon/manager
import client/daemon/root
import client/daemon/server
import client/daemon/session_socket
import client/daemon_server_test as wire
import client/gateway_test
import client/internal/ffi_os
import core/clock
import core/codec
import core/entry
import core/ids
import core/json
import core/message
import core/register
import core/tx
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import mist
import runtime/api
import runtime/escalation
import runtime/writer
import storage/domain
import support/internal/ffi_daemon_socket
import support/internal/ffi_ws
import weft
import weft/poll
import weft/registry

/// Runs a real v2 listener with a scripted, native-effect-free resident session.
///
/// ## Examples
///
/// ```gleam
/// // fixture(fn(port, credential, session_id, epoch, harness) { check(...) })
/// ```
@internal
pub fn fixture(run) {
  let directory =
    "build/test_db/session-socket-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "the wire fixture has a private state root"
  let assert Ok(daemon) =
    root.start(
      root.Config(directory, "Owner", 2),
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _) {
          let assert Ok(id) = ids.parse_session_id(record.id)
            as "reserved IDs are canonical"
          Ok(gateway_test.reserved_fixture(id))
        },
        fatal: fn(_) { [] },
      ),
    )
    as "the daemon root starts without native effects"
  let assert Ok(ready) = root.ready(daemon, within: 5000) as "the root is ready"
  let assert Ok(credential) = root.listener_credential(daemon)
    as "the owner credential exists"
  let assert Ok(view) =
    manager.create_scoped(
      ready.registry,
      manager.Creation("socket-fixture", ready.state_root, "socket", ""),
      directory: ready.sessions_directory,
      generator: ids.generator(clock.fixed(1_700_000_000_000), 981),
      scope: domain.SessionOnly,
      configuration: "",
    )
    as "explicit creation is admitted"
  let assert poll.Answered(harness) =
    poll.until(within: 5000, every: 1, attempt: fn() {
      case manager.resolve(ready.registry, view.registration.id) {
        Ok(instance) -> poll.Done(instance)
        Error(_) -> poll.Retry
      }
    })
    as "the scripted runtime becomes resident"
  let config =
    server.Config(
      daemon,
      "",
      fn() {
        ids.generator(
          clock.from_function(ffi_os.system_time_ms),
          ffi_os.unique_positive_integer(),
        )
      },
      fn(request, attachment) {
        session_socket.upgrade(
          daemon,
          request,
          attachment,
          attachment.instance.hub,
        )
      },
    )
  let ports = process.new_subject()
  let assert Ok(listener) =
    mist.new(fn(request) { server.handle(config, request) })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
    as "one loopback listener serves the real adapter"
  process.unlink(listener.pid)
  let assert Ok(port) = process.receive(ports, within: 1000)
    as "the bound port arrives"

  // The body runs on its own task because a failed assertion kills the process
  // running it. The listener is unlinked, so on the eunit test process that
  // failure left the listener, the daemon root, its lock and the SQLite writer
  // lease alive for the rest of the VM, beside every later test. A task turns
  // that death into an outcome and lets the teardown below run either way.
  let outcomes =
    weft.new([
      fn() {
        Ok(run(port, credential, view.registration.id, ready.epoch, harness))
      },
    ])
    |> weft.deadline(40_000)
    |> weft.start
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
  let _ = api.close(harness.runtime)
  process.kill(listener.pid)

  // The outcome is read only once every owner has retired, so a failing test
  // reports its own assertion rather than a teardown that never happened.
  let assert [weft.Completed(0, _)] = outcomes
    as "the fixture body ran to completion inside its own deadline"
  Nil
}

fn field(value, name) {
  let assert json.Object(fields) = value as "the wire value is an object"
  let assert Ok(value) = list.key_find(fields, name)
    as "the expected field exists"
  value
}

/// Collects a fixture transfer under an explicit finite credit budget.
///
/// ## Examples
///
/// ```gleam
/// // session_socket_test.drain(socket, id, 0, [], 32)
/// ```
@internal
pub fn drain(socket, snapshot_id, index, chunks, remaining) {
  assert remaining > 0 as "the fixture supplies a finite credit budget"
  let frame =
    wire.send(
      socket,
      index + 2,
      "snapshot_next",
      json.Object([
        #("snapshot_id", json.String(snapshot_id)),
        #("index", json.Int(index)),
      ]),
    )
  assert string.byte_size(json.to_string(frame)) <= 65_536
  case field(frame, "event") {
    json.String("snapshot_chunk") ->
      drain(
        socket,
        snapshot_id,
        index + 1,
        [field(frame, "body"), ..chunks],
        remaining - 1,
      )
    json.String("snapshot_end") -> list.reverse(chunks)
    other ->
      panic as {
        "a credited transfer yields a chunk or its end, not "
        <> string.inspect(other)
      }
  }
}

/// Starts an independent server-codec subscription without a TUI decoder.
///
/// ## Examples
///
/// ```gleam
/// // session_socket_test.begin(socket, selected_session)
/// ```
@internal
pub fn begin(socket, id) {
  let frame =
    wire.send(
      socket,
      1,
      "subscribe",
      json.Object([#("session", json.String(id))]),
    )
  let body = field(frame, "body")
  let assert json.String(snapshot_id) = field(body, "snapshot_id")
    as "begin identifies its transfer"
  #(body, snapshot_id)
}

pub fn coalesced_socket_frames_cannot_queue_multiple_gateway_requests_test() {
  fixture(fn(port, credential, id, _, harness) {
    let #(socket, _) =
      wire.connect(port, credential, "/v2/sessions/" <> id <> "/ws")
    let #(_, snapshot_id) = begin(socket, id)
    let assert Ok(subject) = registry.lookup(harness.hub.name)
      as "the original gateway subject is available"
    let assert Ok(pid) = process.subject_owner(subject)
      as "the subject names the original actor"
    let assert True = suspend_gateway(pid) as "block gateway admission"
    let text =
      json.to_string(
        json.Object([
          #("v", json.Int(2)),
          #("id", json.Int(2)),
          #("cmd", json.String("snapshot_next")),
          #(
            "body",
            json.Object([
              #("snapshot_id", json.String(snapshot_id)),
              #("index", json.Int(0)),
            ]),
          ),
        ]),
      )
    let bytes = bit_array.from_string(text)
    let size = bit_array.byte_size(bytes)
    let frame = case size < 126 {
      True -> <<0x81, 1:1, size:7, 0:32, bytes:bits>>
      False -> <<0x81, 0xfe, size:16, 0:32, bytes:bits>>
    }
    assert ffi_daemon_socket.send(
        socket,
        bit_array.concat(list.repeat(frame, 100)),
      )
      == Ok(Nil)
    let ready =
      poll.until(within: 1000, every: 5, attempt: fn() {
        case queued_gateway_requests(pid) {
          0 -> poll.Retry
          count -> poll.Done(count)
        }
      })
    process.sleep(50)
    let retained = queued_gateway_requests(pid)
    let assert True = resume_gateway(pid)
      as "release the original gateway before assertions"
    assert ready == poll.Answered(1)
    assert retained == 1
    let response = wire.frame(socket)
    assert field(response, "event") == json.String("snapshot_chunk")
    ffi_ws.tcp_close(socket)
  })
}

fn queued_gateway_requests(pid) {
  let assert Ok(messages) =
    decode.run(
      gateway_process_info(pid, atom.create("messages")),
      decode.at([1], decode.list(decode.dynamic)),
    )
    as "the stalled gateway mailbox is inspectable"
  list.count(messages, fn(message) {
    decode.run(message, decode.at([1, 0], decode.dynamic))
    == Ok(atom.to_dynamic(atom.create("request")))
  })
}

@external(erlang, "erlang", "process_info")
fn gateway_process_info(pid: process.Pid, item: atom.Atom) -> Dynamic

@external(erlang, "erlang", "suspend_process")
fn suspend_gateway(pid: process.Pid) -> Bool

@external(erlang, "erlang", "resume_process")
fn resume_gateway(pid: process.Pid) -> Bool

fn decoded_record(chunks, record_id) {
  let bytes =
    chunks
    |> list.filter(fn(chunk) {
      field(chunk, "record_id") == json.String(record_id)
    })
    |> list.map(fn(chunk) {
      let assert json.String(data) = field(chunk, "data")
        as "fragment data is base64"
      let assert Ok(bytes) = bit_array.base64_decode(data)
        as "fragment data decodes"
      bytes
    })
    |> bit_array.concat
  let assert Ok(text) = bit_array.to_string(bytes)
    as "the complete record is UTF-8"
  let assert Ok(value) = json.parse(text) as "the complete record is JSON"
  value
}

fn insert_entry(harness: gateway_test.Harness, seed, text) {
  let #(id, _) =
    ids.mint_entry(ids.generator(clock.fixed(1_700_000_000_001), seed))
  let row =
    entry.CustomEntry(id, None, 0, 0, "wire-test", Some(json.String(text)))
  let assert Ok(commit) =
    writer.commit(harness.runtime.tree.writer, tx.Tx([tx.InsertEntry(row)], []))
    as "the immutable fixture entry commits"
  #(id, commit.first_seq)
}

pub fn exact_escalation_resolution_captures_author_without_prefix_neighbors_test() {
  fixture(fn(port, credential, id, _, harness) {
    let pending =
      escalation.raised("esc-1", json.Object([]), action: None, scope: None)
    let assert Ok(_) =
      writer.commit(
        harness.runtime.tree.writer,
        tx.Tx(
          [
            tx.SetRegister(
              register.FactCustom,
              escalation.register_key(pending.id),
              register.value(escalation.encode(pending)),
            ),
          ],
          [],
        ),
      )
      as "the pending question commits"
    let #(socket, _) =
      wire.connect(port, credential, "/v2/sessions/" <> id <> "/ws")
    let #(initial, snapshot_id) = begin(socket, id)
    let initial_metadata =
      drain(socket, snapshot_id, 0, [], 20) |> decoded_record("metadata")
    let assert json.Array(initial_cells) = field(initial_metadata, "cells")
      as "the pending question is in the coherent cut"
    assert list.any(initial_cells, fn(cell) {
      field(cell, "key") == json.String("escalation/esc-1")
    })

    // Only metadata changes. The resolved row and its neighboring pending key
    // must not be confused by the exact lookup that follows reconciliation.
    let author = message.Origin("bob", "Bob")
    let decided = escalation.reject(pending, Some(author))
    let neighbor =
      escalation.raised(
        "esc-1-neighbor",
        json.Object([]),
        action: None,
        scope: None,
      )
    let assert Ok(commit) =
      writer.commit(
        harness.runtime.tree.writer,
        tx.Tx(
          [
            tx.SetRegister(
              register.FactCustom,
              escalation.register_key(decided.id),
              register.value(escalation.encode(decided)),
            ),
            tx.SetRegister(
              register.FactCustom,
              escalation.register_key(neighbor.id),
              register.value(escalation.encode(neighbor)),
            ),
          ],
          [],
        ),
      )
      as "resolution and a prefix neighbor commit without new entries"
    let caught =
      wire.send(
        socket,
        60,
        "catch_up",
        json.Object([#("from_seq", field(initial, "next_seq"))]),
      )
    let assert json.String(catch_id) =
      field(field(caught, "body"), "snapshot_id")
      as "metadata-only changes still start reconciliation"
    let metadata =
      drain(socket, catch_id, 0, [], 20) |> decoded_record("metadata")
    let assert json.Array(pending_cells) = field(metadata, "cells")
      as "the next coherent cut contains current pending questions"
    assert !list.any(pending_cells, fn(cell) {
      field(cell, "key") == json.String("escalation/esc-1")
    })
    assert list.any(pending_cells, fn(cell) {
      field(cell, "key") == json.String("escalation/esc-1-neighbor")
    })

    let resolved =
      wire.send(
        socket,
        70,
        "escalations_get",
        json.Object([
          #("ids", json.Array([json.String("esc-1"), json.String("missing")])),
        ]),
      )
    let body = field(resolved, "body")
    assert field(body, "window") == json.String("escalations")
    let assert json.String(resolution_id) = field(body, "snapshot_id")
      as "exact lookup uses the same credit protocol"
    let metadata =
      drain(socket, resolution_id, 0, [], 20) |> decoded_record("metadata")
    assert field(metadata, "missing") == json.Array([json.String("missing")])
    let assert json.Array([cell]) = field(metadata, "cells")
      as "the prefix neighbor is not part of the exact query"
    assert field(cell, "seq") == json.Int(commit.first_seq)
    let assert Ok(record) = escalation.decode(field(cell, "value"))
      as "the exact raw payload retains its resolution author"
    assert record.status == escalation.Rejected
    assert record.origin == Some(author)
    ffi_ws.tcp_close(socket)
  })
}

pub fn real_metadata_and_large_entry_are_fragmented_without_legacy_reads_test() {
  fixture(fn(port, credential, id, _, harness) {
    let metadata_text = string.repeat("m", 100_000)
    let assert Ok(_) =
      writer.commit(
        harness.runtime.tree.writer,
        tx.Tx(
          [
            tx.SetRegister(
              register.FactCustom,
              "client/large-fixture",
              register.value(json.String(metadata_text)),
            ),
          ],
          [],
        ),
      )
      as "metadata exceeds one observer frame"
    let text = string.repeat("entry", 60_000)
    let #(entry_id, _) = insert_entry(harness, 818, text)
    let #(socket, _) =
      wire.connect(port, credential, "/v2/sessions/" <> id <> "/ws")
    let #(_, snapshot_id) = begin(socket, id)
    let chunks = drain(socket, snapshot_id, 0, [], 100)
    let metadata = decoded_record(chunks, "metadata")
    let assert json.Array(cells) = field(metadata, "cells")
      as "metadata retains coherent cells"
    assert list.any(cells, fn(cell) {
      field(cell, "key") == json.String("client/large-fixture")
      && field(cell, "value") == json.String(metadata_text)
    })
    let assert Ok(entry.CustomEntry(data: Some(json.String(decoded)), ..)) =
      codec.decode_entry(decoded_record(
        chunks,
        ids.entry_id_to_string(entry_id),
      ))
      as "large records reassemble through the core decoder"
    assert decoded == text
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn writes_during_transfer_wait_for_credited_reconciliation_test() {
  fixture(fn(port, credential, id, _, harness) {
    let #(socket, _) =
      wire.connect(port, credential, "/v2/sessions/" <> id <> "/ws")
    let #(body, snapshot_id) = begin(socket, id)
    let assert json.Int(next_seq) = field(body, "next_seq")
      as "the cut names its first unseen sequence"
    let #(entry_id, seq) = insert_entry(harness, 819, "after cut")
    assert seq == next_seq
    let assert Error(_) = ffi_ws.tcp_receive(socket, 1, 50)
      as "without credit no live payload enters the socket"
    let initial = drain(socket, snapshot_id, 0, [], 20)
    assert !list.any(initial, fn(chunk) {
      field(chunk, "record_id") == json.String(ids.entry_id_to_string(entry_id))
    })
    let response =
      wire.send(
        socket,
        100,
        "catch_up",
        json.Object([#("from_seq", json.Int(next_seq))]),
      )
    let assert json.String(snapshot_id) =
      field(field(response, "body"), "snapshot_id")
      as "catch-up owns a new fixed cut"
    let caught_up = drain(socket, snapshot_id, 0, [], 20)
    let assert Ok(entry.CustomEntry(seq: observed, ..)) =
      codec.decode_entry(decoded_record(
        caught_up,
        ids.entry_id_to_string(entry_id),
      ))
      as "the first entry at old next_seq must not be skipped"
    assert observed == seq
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn real_session_upgrade_carries_authoritative_identity_test() {
  fixture(fn(port, credential, id, epoch, _) {
    let #(socket, headers) =
      wire.connect(port, credential, "/v2/sessions/" <> id <> "/ws")
    assert string.contains(headers, "101 Switching Protocols")
    let metadata =
      wire.send(
        socket,
        1,
        "subscribe",
        json.Object([#("session", json.String(id))]),
      )
    assert field(metadata, "v") == json.Int(2)
    assert field(metadata, "event") == json.String("snapshot_begin")
    let body = field(metadata, "body")
    assert field(body, "session_id") == json.String(id)
    assert field(body, "epoch") == json.String(epoch)
    assert field(body, "role") == json.String("owner")
    assert field(field(body, "origin"), "name") == json.String("Owner")
    let assert json.String(snapshot_id) = field(body, "snapshot_id")
      as "transfer identity is present"
    let chunks = drain(socket, snapshot_id, 0, [], 20)
    assert chunks != []
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn original_gateway_death_closes_real_socket_test() {
  fixture(fn(port, credential, id, _, harness) {
    let #(socket, headers) =
      wire.connect(port, credential, "/v2/sessions/" <> id <> "/ws")
    assert string.contains(headers, "101 Switching Protocols")
    let _ =
      wire.send(
        socket,
        1,
        "subscribe",
        json.Object([#("session", json.String(id))]),
      )
    // The test host attachment exposes no restartable network handle. Killing
    // this original actor must terminate the upgraded connection immediately.
    let assert Ok(subject) = registry.lookup(harness.hub.name)
      as "the original hub is registered"
    let assert Ok(pid) = process.subject_owner(subject)
      as "the original gateway owns its subject"
    process.kill(pid)
    let assert Ok(<<0x88, size>>) = ffi_ws.tcp_receive(socket, 2, 1000)
      as "original gateway death sends the socket's close frame"
    assert size <= 125
    case size {
      0 -> Nil
      _ -> {
        let assert Ok(_) = ffi_ws.tcp_receive(socket, size, 1000)
          as "the bounded close payload arrives"
        Nil
      }
    }
    let assert Error(_) = ffi_ws.tcp_receive(socket, 1, 1000)
      as "the original socket is closed, not retargeted by name"
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}
