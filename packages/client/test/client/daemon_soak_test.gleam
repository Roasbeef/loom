//// A bounded lifecycle soak combines real SQLite, shared history, native
//// helper custody and authenticated credited transfers in one daemon root.
//// Session B keeps its original runtime while A repeatedly opens and closes
//// with an outstanding unread large-record reply. RSS and FD counts are
//// observations, never guessed safety thresholds; counters cover the entire
//// test VM. This is not a maximum-image or external-provider network test.

import broker/exec
import client/catalog
import client/daemon/domain
import client/daemon/main as daemon_main
import client/daemon/manager
import client/daemon/root
import client/daemon/session_socket
import client/daemon_server_test as wire
import client/history
import client/owned_assembly_test
import client/serve
import client/session_socket_test as transfer
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/tx
import filepath
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import machine/operation
import provider/http
import provider/secret
import runtime/api
import runtime/writer
import simplifile
import support/addresses
import support/internal/ffi_daemon_socket as tcp
import support/internal/ffi_proc
import support/internal/ffi_soak
import support/internal/ffi_ws
import support/provider as provider_test
import telemetry/log
import weft
import weft/poll

const large_bytes = 4_194_304

type SnapshotTiming {
  SnapshotTiming(
    total: Int,
    http: Int,
    subscribe: Int,
    drain: Int,
    credits: Int,
    started: Int,
    connected: Int,
    subscribed: Int,
    completed: Int,
    credit_timings: List(#(Int, Int)),
    probes: List(Probe),
    probe_end: ProbeEnd,
  )
}

// This call site selects a fixed allowlist; the underlying FFI is unrestricted.
// Formatting happens after transfer timing, never between its credits. The
// 25 ms cadence targets coarse stalls; tighter sampling would add perturbation.
// Queue, reduction and GC trends narrow the next investigation, not its verdict.
// Heap growth alone is not a collection, and coarse samples neither measure GC
// pause duration nor distinguish host descheduling from waiting on native I/O.
type Probe {
  Probe(
    started: Int,
    completed: Int,
    owners: List(#(String, List(#(String, Dynamic)))),
  )
}

type Observation {
  Probes(List(Probe), ProbeEnd)
}

type ProbeEnd {
  Complete
  SampleLimit
  TimeLimit
  NotStarted
}

fn settings() {
  let settings = owned_assembly_test.settings()
  let assert Ok(here) = simplifile.current_directory()
    as "the soak runs from the client package"
  let gateway =
    catalog.gateway(
      settings.catalog,
      provider_test.transport(fn(_, events) {
        process.send(
          events,
          http.ResponseStatus(200, [
            #("content-type", "text/event-stream"),
          ]),
        )
        process.send(
          events,
          http.ResponseChunk(bit_array.from_string(
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"soak\",\"model\":\"test\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
            <> "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"B completed while A was unread\"}}\n\n"
            <> "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n"
            <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
          )),
        )
        process.send(events, http.ResponseEnd)
      }),
      secret.from_list([#("UNUSED", "fixture")]),
      clock.fixed(0),
    )
  serve.Settings(
    ..settings,
    gateway:,
    helper_path: here <> "/../sandbox/loom-exec",
  )
}

fn start(settings: serve.Settings) {
  let directory = filepath.directory_name(settings.session_path)
  let assert Ok(config) =
    daemon_main.parse(["--state-dir", directory <> "/daemon"])
    as "one private catalogue and listener are selected"
  let assert Ok(daemon) =
    root.start(
      root.Config(config.state_root, "Soak owner", 2),
      manager.Assembly(
        domain_build: fn(selected, sources, owner) {
          let assert Ok(Nil) =
            bootstrap.ensure_private_directory(filepath.directory_name(
              selected.index_path,
            ))
            as "the shared history directory is private"
          domain.build(
            domain.Config(
              history: history.SharedConfig(
                selected.index_path,
                sources,
                5000,
                100,
              ),
              maintenance: fn(_) { Ok(None) },
            ),
            owner,
          )
        },
        build: fn(record, selected, services, owner) {
          let assert Ok(id) = ids.parse_session_id(record.id)
            as "the catalogue reserves canonical identities"
          serve.assemble_in_domain(
            serve.Settings(
              ..settings,
              session_path: record.path,
              session_id: record.id,
              domain_paths: Some(serve.DomainPaths(
                selected.memory_path,
                selected.index_path,
              )),
            ),
            id,
            log.discard(),
            owner,
            services,
          )
        },
        fatal: serve.instance_children,
      ),
    )
    as "the original root owns the real assembly and shared domain"
  #(daemon, config, directory)
}

fn resident(registry, id) {
  let assert poll.Answered(instance) =
    poll.until(within: 5000, every: 5, attempt: fn() {
      case manager.resolve(registry, id) {
        Ok(instance) -> poll.Done(instance)
        Error(_) -> poll.Retry
      }
    })
    as "explicit admission becomes resident within its deadline"
  instance
}

fn create(serving: daemon_main.Serving(serve.Instance), workspace, seed) {
  let assert Ok(view) =
    manager.create(
      serving.ready.registry,
      manager.Creation("soak-" <> int.to_string(seed), workspace, "Soak", ""),
      directory: serving.ready.sessions_directory,
      generator: ids.generator(clock.fixed(1000), seed),
    )
    as "each session is explicitly created once"
  #(
    view.registration.id,
    resident(serving.ready.registry, view.registration.id),
  )
}

fn helper(instance: serve.Instance) {
  let assert Ok(helper) = exec.checkout(instance.pool, waiting: 3000)
    as "every incarnation owns a real handshaken native helper"
  let owner = exec.pid(helper)
  exec.checkin(instance.pool, helper)
  owner
}

fn field(value, key) {
  let assert json.Object(fields) = value as "the frame body is an object"
  let assert Ok(value) = list.key_find(fields, key)
    as "the bounded frame field exists"
  value
}

fn attach(serving: daemon_main.Serving(serve.Instance), token, id) {
  let #(socket, headers) =
    wire.connect(serving.listener.port, token, "/v2/sessions/" <> id <> "/ws")
  assert string.contains(headers, "101 Switching Protocols")
  let #(begin, snapshot) = transfer.begin(socket, id)
  assert field(begin, "session_id") == json.String(id)
  assert field(begin, "epoch") == json.String(serving.ready.epoch)
  #(socket, snapshot)
}

// Measure the entire authenticated transfer through the existing wire driver.
// Each prior turn adds entry credits, so a fixed total deadline would conflate
// growing history with interference from A. Individual receives and the total
// credit count retain their existing finite limits.
fn measure_snapshot(
  serving: daemon_main.Serving(serve.Instance),
  token,
  id,
  owners,
) {
  let worker = process.self()
  let ready = process.new_subject()
  let replies = process.new_subject()

  // Both conditions pay the same diagnostic overhead. A shared-test-VM sampler
  // perturbs scheduling; it supplies hypotheses, not a correction to latency.
  // Caller death cancels the linked relay's scope; AllDelivered witnesses the
  // sampler's retirement on success. Measurement keeps its original process.
  let _relay =
    weft.new([
      fn() {
        let stopped = process.new_subject()
        process.send(ready, stopped)
        let result =
          poll.fold_until(
            clock: poll.monotonic(),
            within: 3200,
            every: poll.Fixed(25),
            from: #(0, []),
            attempt: fn(state) {
              let #(count, probes) = state
              case process.receive(stopped, 0), count >= 128 {
                Ok(Nil), True | Ok(Nil), False ->
                  poll.Settled(Probes(list.reverse(probes), Complete))
                Error(Nil), True ->
                  poll.Settled(Probes(list.reverse(probes), SampleLimit))
                Error(Nil), False -> {
                  // Bracket the complete batch so observation cost is visible.
                  let began = bootstrap.monotonic_time_ms()
                  let values =
                    list.map([#("measurement", worker), ..owners], fn(owner) {
                      let #(name, pid) = owner
                      #(
                        name,
                        list.map(
                          [
                            "status",
                            "current_function",
                            "reductions",
                            "message_queue_len",
                            "garbage_collection",
                            "total_heap_size",
                          ],
                          fn(item) {
                            #(
                              item,
                              ffi_soak.process_info(pid, atom.create(item)),
                            )
                          },
                        ),
                      )
                    })
                  poll.Pending(
                    #(count + 1, [
                      Probe(began, bootstrap.monotonic_time_ms(), values),
                      ..probes
                    ]),
                  )
                }
              }
            },
          )

        // Cooperative limits retain the bounded prefix and name its truncation.
        case result {
          poll.Answer(value) -> Ok(value)
          poll.RanOut(#(_, probes)) ->
            Ok(Probes(list.reverse(probes), TimeLimit))
          poll.Failure(reason) -> Error(reason)
        }
      },
    ])
    |> weft.deadline(5000)
    |> weft.start_relayed(replies)
  let assert Ok(stopped) = process.receive(ready, 1000)
    as "the sampler publishes its own stop inbox before timing begins"
  let #(timing, entries) = snapshot_measurement(serving, token, id)
  process.send(stopped, Nil)
  let assert Ok(weft.PulledOutcome(weft.Completed(0, Probes(probes, ended)))) =
    process.receive(replies, 6000)
    as "the bounded sampler completes without losing its observation"
  let assert Ok(weft.AllDelivered) = process.receive(replies, 1000)
    as "the sampler has retired before the pair is evaluated"
  #(SnapshotTiming(..timing, probes:, probe_end: ended), entries)
}

fn snapshot_measurement(
  serving: daemon_main.Serving(serve.Instance),
  token,
  id,
) {
  let began = bootstrap.monotonic_time_ms()
  let #(socket, headers) =
    wire.connect(serving.listener.port, token, "/v2/sessions/" <> id <> "/ws")
  let connected = bootstrap.monotonic_time_ms()
  assert string.contains(headers, "101 Switching Protocols")
  let #(begin, snapshot) = transfer.begin(socket, id)
  let subscribed = bootstrap.monotonic_time_ms()
  assert field(begin, "session_id") == json.String(id)
  assert field(begin, "epoch") == json.String(serving.ready.epoch)

  let #(chunks, credit_timings) =
    timed_drain(socket, snapshot, 0, #([], []), 64)
  let completed = bootstrap.monotonic_time_ms()
  assert chunks != []
  let _ = ffi_ws.tcp_close(socket)
  let timing =
    SnapshotTiming(
      completed - began,
      connected - began,
      subscribed - connected,
      completed - subscribed,
      list.length(chunks) + 1,
      began,
      connected,
      subscribed,
      completed,
      credit_timings,
      [],
      NotStarted,
    )
  let entries =
    chunks
    |> list.filter(fn(chunk) { field(chunk, "kind") == json.String("entry") })
    |> list.map(fn(chunk) { field(chunk, "record_id") })
  #(timing, entries)
}

// This is the shared wire driver's drain with two clock reads per credit.
// Keep its request sequence, frame assertion and finite budget unchanged.
// Retain raw times until the transfer ends so JSON formatting cannot delay
// the next credit. The final sample includes the snapshot_end exchange.
fn timed_drain(socket, snapshot_id, index, accumulated, remaining) {
  assert remaining > 0 as "the fixture supplies a finite credit budget"
  let began = bootstrap.monotonic_time_ms()
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
  let completed = bootstrap.monotonic_time_ms()
  assert string.byte_size(json.to_string(frame)) <= 65_536
  let #(chunks, timings) = accumulated
  let timings = [#(began, completed), ..timings]

  case field(frame, "event") {
    json.String("snapshot_chunk") ->
      timed_drain(
        socket,
        snapshot_id,
        index + 1,
        #([field(frame, "body"), ..chunks], timings),
        remaining - 1,
      )
    json.String("snapshot_end") -> #(
      list.reverse(chunks),
      list.reverse(timings),
    )
    other ->
      panic as {
        "a credited transfer yields a chunk or its end, not "
        <> string.inspect(other)
      }
  }
}

fn timing_json(timing: SnapshotTiming) {
  json.Object([
    #("total_ms", json.Int(timing.total)),
    #("http_ms", json.Int(timing.http)),
    #("subscribe_ms", json.Int(timing.subscribe)),
    #("drain_ms", json.Int(timing.drain)),
    #("credits", json.Int(timing.credits)),
    #("started_monotonic_ms", json.Int(timing.started)),
    #("connected_monotonic_ms", json.Int(timing.connected)),
    #("subscribed_monotonic_ms", json.Int(timing.subscribed)),
    #("completed_monotonic_ms", json.Int(timing.completed)),
    #(
      "probe_end",
      json.String(case timing.probe_end {
        Complete -> "completed"
        SampleLimit -> "sample_limit"
        TimeLimit -> "time_limit"
        NotStarted -> "not_started"
      }),
    ),
    #(
      "probes",
      json.Array(
        list.map(timing.probes, fn(probe) {
          json.Object([
            #("started_monotonic_ms", json.Int(probe.started)),
            #("completed_monotonic_ms", json.Int(probe.completed)),
            #(
              "owners",
              json.Object(
                list.map(probe.owners, fn(owner) {
                  let #(name, values) = owner
                  #(
                    name,
                    json.Object(
                      list.map(values, fn(value) {
                        let #(key, observed) = value
                        #(key, json.String(string.inspect(observed)))
                      }),
                    ),
                  )
                }),
              ),
            ),
          ])
        }),
      ),
    ),
    #(
      "credit_timings",
      json.Array(
        list.map(timing.credit_timings, fn(sample) {
          let #(started, completed) = sample
          json.Object([
            #("started_monotonic_ms", json.Int(started)),
            #("completed_monotonic_ms", json.Int(completed)),
            #("roundtrip_ms", json.Int(completed - started)),
          ])
        }),
      ),
    ),
  ])
}

// Emit before the comparison so a failing cycle survives EUnit's captured
// output and the fixture JSONL. This diagnoses future failures; it does not
// establish which stage caused the earlier CI aggregate of 3070 milliseconds.
fn report_pair(directory, cycle, baseline, stressed) {
  let encoded =
    json.to_string(
      json.Object([
        #("stage", json.String("paired_wire")),
        #("cycle", json.Int(cycle)),
        #("baseline", timing_json(baseline)),
        #("stressed", timing_json(stressed)),
      ]),
    )
  io.println(encoded)
  assert simplifile.append(directory <> "/daemon-soak.jsonl", encoded <> "\n")
    == Ok(Nil)
}

// Read through metadata and one entry fragment, then leave the next credited
// body unread. Receiving only its first header byte proves this is an actual
// outstanding reply, not a connection that merely stopped issuing credits.
fn stall_entry(socket, snapshot, index, remaining) {
  assert remaining > 0 as "metadata cannot consume unbounded fixture credits"
  let frame =
    wire.send(
      socket,
      index + 2,
      "snapshot_next",
      json.Object([
        #("snapshot_id", json.String(snapshot)),
        #("index", json.Int(index)),
      ]),
    )
  assert field(frame, "event") == json.String("snapshot_chunk")
  let body = field(frame, "body")
  case field(body, "kind") {
    json.String("metadata") ->
      stall_entry(socket, snapshot, index + 1, remaining - 1)
    json.String("entry") -> {
      let assert json.Int(total) = field(body, "total_bytes")
        as "entry size is exact"
      assert total > large_bytes
      let command =
        json.to_string(
          json.Object([
            #("v", json.Int(2)),
            #("id", json.Int(index + 3)),
            #("cmd", json.String("snapshot_next")),
            #(
              "body",
              json.Object([
                #("snapshot_id", json.String(snapshot)),
                #("index", json.Int(index + 1)),
              ]),
            ),
          ]),
        )
      let bytes = bit_array.from_string(command)
      let size = bit_array.byte_size(bytes)
      let frame = case size < 126 {
        True -> <<0x81, 1:1, size:7, 0:32, bytes:bits>>
        False -> <<0x81, 0xfe, size:16, 0:32, bytes:bits>>
      }
      assert tcp.send(socket, frame) == Ok(Nil)
      assert ffi_ws.tcp_receive(socket, 1, 1000) == Ok(<<0x81>>)
    }
    _ -> panic as "the captured durable record must follow metadata"
  }
}

fn count(name) {
  let assert Ok(value) =
    decode.run(ffi_soak.system_info(atom.create(name)), decode.int)
    as "the requested stock OTP counter exists"
  value
}

fn mailbox(pid) {
  let assert Ok(value) =
    decode.run(
      ffi_soak.process_info(pid, atom.create("message_queue_len")),
      decode.at([1], decode.int),
    )
    as "the original live owner's mailbox is observable"
  value
}

// ps supplies OS RSS in KiB. OTP may parent port programs through its existing
// erl_child_setup process, so include that one documented launch layer. Missing
// platform tools are reported, never converted into zero.
fn os_metrics(directory) {
  let pid = bootstrap.current_process_id()
  let observed =
    ffi_proc.run("/bin/ps", ["-axo", "pid=,ppid=,rss=,comm="], directory)
  case observed {
    Ok(#(0, text)) -> {
      let rows =
        string.split(text, "\n")
        |> list.filter_map(fn(line) {
          case
            string.split(string.trim(line), " ")
            |> list.filter(fn(word) { word != "" })
          {
            [id, parent, rss, ..command] -> {
              use id <- result.try(int.parse(id))
              use parent <- result.try(int.parse(parent))
              use rss <- result.map(int.parse(rss))
              #(id, parent, rss, string.join(command, " "))
            }
            _ -> Error(Nil)
          }
        })
      let launchers =
        rows
        |> list.filter(fn(row) {
          row.1 == pid && string.ends_with(row.3, "erl_child_setup")
        })
        |> list.map(fn(row) { row.0 })
      let helpers =
        list.filter(rows, fn(row) {
          list.contains([pid, ..launchers], row.1)
          && string.ends_with(row.3, "loom-exec")
        })
      let own = list.find(rows, fn(row) { row.0 == pid })
      [
        #("vm_rss_kib", case own {
          Ok(row) -> json.Int(row.2)
          Error(_) -> json.Null
        }),
        #("native_helpers", json.Int(list.length(helpers))),
        #(
          "helper_rss_kib",
          json.Int(list.fold(helpers, 0, fn(total, row) { total + row.2 })),
        ),
      ]
    }
    _ -> [#("os_metrics", json.String("unavailable"))]
  }
}

fn fd_count(directory, stage, cycle) {
  let pid = int.to_string(bootstrap.current_process_id())
  case simplifile.read_directory("/proc/" <> pid <> "/fd") {
    Ok(entries) -> json.Int(list.length(entries))
    Error(_) ->
      {
        use executable <- result.map(ffi_proc.which("lsof"))
        ffi_proc.run(executable, ["-a", "-p", pid, "-F", "fn"], directory)
      }
      |> fn(observed) {
        case observed {
          Ok(Ok(#(0, text))) -> {
            // File names identify retained resources without reading their
            // contents. Bound this diagnostic and retain only warm/final cuts.
            case stage == "retired" && { cycle == 1 || cycle == 17 } {
              True -> {
                assert simplifile.write(
                    directory
                      <> "/daemon-soak-fds-"
                      <> int.to_string(cycle)
                      <> ".txt",
                    string.slice(text, 0, 65_536),
                  )
                  == Ok(Nil)
              }
              False -> Nil
            }
            json.Int(
              list.count(string.split(text, "\n"), fn(line) {
                case string.pop_grapheme(line) {
                  Ok(#("f", number)) -> result.is_ok(int.parse(number))
                  _ -> False
                }
              }),
            )
          }
          _ -> json.Null
        }
      }
  }
}

fn sample(
  directory,
  stage,
  cycle,
  daemon,
  b: serve.Instance,
  a_queue,
  latency,
) {
  let atoms = count("atom_count")
  let fields = [
    #("scope", json.String("shared_test_vm")),
    #("stage", json.String(stage)),
    #("cycle", json.Int(cycle)),
    #("atoms", json.Int(atoms)),
    #("beam_processes", json.Int(count("process_count"))),
    #("beam_ports", json.Int(count("port_count"))),
    #("beam_allocated_bytes", json.Int(ffi_soak.memory(atom.create("total")))),
    #("fds", fd_count(directory, stage, cycle)),
    #("root_mailbox", json.Int(mailbox(root.pid(daemon)))),
    #("b_runtime_mailbox", json.Int(mailbox(b.runtime.tree.supervisor))),
    #("a_gateway_mailbox", json.Int(a_queue)),
    #("b_wire_latency_ms", json.Int(latency)),
  ]
  let encoded =
    json.to_string(json.Object(list.append(fields, os_metrics(directory))))
  assert simplifile.append(directory <> "/daemon-soak.jsonl", encoded <> "\n")
    == Ok(Nil)
  atoms
}

fn close_a(
  serving: daemon_main.Serving(serve.Instance),
  id,
  a: serve.Instance,
  helper_owner,
) {
  let children = list.map(serve.instance_children(a), fn(child) { child.1 })
  let helper_watch = process.monitor(helper_owner)
  let watches = list.map(children, process.monitor)
  let assert Ok(manager.Stopping(_)) =
    manager.stop_session(serving.ready.registry, id)
    as "each stop targets the current incarnation exactly once"
  let assert Ok(helper_down) =
    process.new_selector()
    |> process.select_specific_monitor(helper_watch, fn(down) { down })
    |> process.selector_receive(5000)
    as "the helper owner retains native exit proof before normal retirement"
  assert helper_down.reason == process.Normal
  list.each(watches, fn(watch) {
    let assert Ok(down) =
      process.new_selector()
      |> process.select_specific_monitor(watch, fn(down) { down })
      |> process.selector_receive(5000)
      as "every original helper and instance child retires before reuse"
    case down.reason {
      process.Normal -> Nil
      process.Abnormal(reason) -> {
        assert decode.run(reason, atom.decoder()) == Ok(atom.create("shutdown"))
          as "OTP supervisors retire with their orderly shutdown reason"
      }
      _ ->
        panic as "a killed or missing original child is not orderly retirement"
    }
  })
  let assert poll.Answered(Nil) =
    poll.until(within: 5000, every: 5, attempt: fn() {
      case manager.get(serving.ready.registry, id) {
        Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
        Ok(manager.View(status: manager.RecoveryBlocked(reason), ..)) ->
          poll.Fail(reason)
        _ -> poll.Retry
      }
    })
    as "Saved is reported only after original custody releases the slot"
  list.each([helper_owner, ..children], fn(pid) {
    assert !process.is_alive(pid)
  })
}

fn drive(
  daemon: root.Root(serve.Instance),
  config: daemon_main.Config,
  directory,
  settings: serve.Settings,
) -> Result(Nil, Nil) {
  let assert Ok(serving) =
    daemon_main.listen(config, daemon, fn(request, attachment) {
      session_socket.upgrade(
        daemon,
        request,
        attachment,
        attachment.instance.gateway,
      )
    })
    as "the original root owns one real listener"
  let assert Ok(token) = root.listener_credential(daemon)
    as "the owner credential exists"
  let #(b_id, b) = create(serving, settings.workspace, 881)
  let b_helper = helper(b)
  let #(a_id, a) = create(serving, settings.workspace, 882)
  let a_helper = helper(a)
  let #(entry_id, _) = ids.mint_entry(ids.generator(clock.fixed(1001), 883))
  let durable =
    entry.CustomEntry(
      entry_id,
      None,
      0,
      0,
      "soak-record",
      Some(json.String(string.repeat("x", large_bytes))),
    )
  let assert Ok(_) =
    writer.commit(a.runtime.tree.writer, tx.Tx([tx.InsertEntry(durable)], []))
    as "the large transfer comes from a valid immutable durable record"
  close_a(serving, a_id, a, a_helper)
  let _ = sample(directory, "prewarm", -1, daemon, b, 0, 0)
  let baseline =
    int.range(from: 0, to: 18, with: None, run: fn(baseline, cycle) {
      let assert Ok(manager.Opening(_)) =
        manager.open(serving.ready.registry, a_id)
        as "one explicit open begins the next A incarnation"
      let a = resident(serving.ready.registry, a_id)
      let helper_owner = helper(a)
      let assert Ok(a_gateway) = addresses.owner(a.gateway.name)
        as "the sampler pins A's original gateway"
      let assert Ok(b_gateway) = addresses.owner(b.gateway.name)
        as "the sampler pins B's original gateway"
      let owners = [
        #("registry", manager.pid(serving.ready.registry)),
        #("a_gateway", a_gateway),
        #("b_gateway", b_gateway),
      ]
      let #(unstalled, baseline_entries) =
        measure_snapshot(serving, token, b_id, owners)
      let #(slow, snapshot) = attach(serving, token, a_id)
      stall_entry(slow, snapshot, 0, 32)
      let assert Ok(gateway_pid) = addresses.owner(a.gateway.name)
        as "A's original gateway is alive"
      let queue = mailbox(gateway_pid)
      assert queue <= 2
        as "the unread peer cannot build a gateway request backlog"
      let #(stressed, stressed_entries) =
        measure_snapshot(serving, token, b_id, owners)
      report_pair(directory, cycle, unstalled, stressed)
      assert stressed_entries == baseline_entries
        as "both measurements transfer the same immutable B history"

      // No B mutation separates these full snapshots. The paired budget bounds
      // the unread peer's penalty, not a universal full-snapshot latency SLA.
      assert stressed.total <= 2 * unstalled.total + 250
        as "an unread peer stays within the paired full-snapshot slowdown budget"
      let latency = stressed.total

      // Exercise durable provider progress, not only reads, while A retains its
      // large captured record and an actual unread credited reply.
      let assert Ok(op) =
        api.prompt(b.runtime, [
          message.UserMessage(
            [message.UserText("complete while A is unread", None)],
            0,
            None,
          ),
        ])
        as "B admits a real scripted provider turn during the stalled transfer"
      let assert Ok(operation.RunLastResult(
        outcome: operation.RunCompleted(_),
        ..,
      )) = api.await_result(b.runtime, op, within_ms: 5000)
        as "B's original runtime durably settles while A remains unread"
      let _ = sample(directory, "unread", cycle, daemon, b, queue, latency)
      close_a(serving, a_id, a, helper_owner)
      let _ = ffi_ws.tcp_close(slow)
      let assert Ok(current) = manager.resolve(serving.ready.registry, b_id)
        as "B remains resident through every A retirement"
      assert current.runtime.tree.supervisor == b.runtime.tree.supervisor
      assert process.is_alive(b_helper)
      let atoms = sample(directory, "retired", cycle, daemon, b, 0, latency)
      case baseline, cycle >= 2 {
        Some(warmed), True -> {
          assert atoms == warmed
            as "warmed incarnation churn creates no permanent atoms"
          baseline
        }
        _, False -> Some(atoms)
        None, True -> panic as "two warmup cycles establish the atom baseline"
      }
    })
  assert baseline != None
  Ok(Nil)
}

/// Runs two warmups and sixteen measured real incarnations with finite waits.
///
/// ## Examples
///
/// `scripts/test.sh client --match daemon_soak` writes daemon-soak.jsonl beside
/// its fresh fixture directory. OS RSS and FD values are observations only.
pub fn daemon_soak_reclaims_incarnations_while_unread_peer_isolated_test_() -> EunitTest {
  Timeout(30, fn() {
    let settings = settings()
    let #(daemon, config, directory) = start(settings)
    let outcomes =
      weft.new([fn() { drive(daemon, config, directory, settings) }])
      |> weft.deadline(150_000)
      |> weft.start
    let retired = root.shutdown(daemon, within: 15_000)
    assert retired == Ok(Nil)
      as "the original root proves all native and SQLite retirement"
    assert outcomes == [weft.Completed(0, Nil)]
      as "all measured lifecycle assertions completed"
  })
}
