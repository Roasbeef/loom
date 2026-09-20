//// What a session assembly's processes hold, per shape of process, and how
//// much of it hibernation takes back.
////
//// This is the local half of the daemon-memory investigation. The operator's
//// census in `docs/design-notes/daemon-memory.md` could group 2.5 GiB of
//// process heaps by shape and name the term inside them, but it could not
//// separate live state from uncollected garbage, because settling that needs
//// a forced collection and the daemon under observation was holding real
//// sessions. This fixture assembles real sessions locally, drives real turns
//// with real tool calls through a scripted provider, and then does force one
//// — and then goes further, because `runtime/residency` now arms
//// `weft/actor.hibernate_after` on the assembly's idle actors, so the
//// hibernated size is observed rather than derived.
////
//// Two quantities are read per process and they are not the same thing.
//// *Allocated* is `process_info(memory)`, which is what
//// `erlang:memory(processes)` sums and what an operator sees; it includes
//// heap capacity the process is not using. *Used* is the live and fragmented
//// heap out of `garbage_collection_info` — `garbage_collection` is
//// deliberately not asked, because it omits `old_heap_size` and so reports a
//// zero old generation for every process. After a full sweep, used is the
//// live set. The gap between allocated-when-idle and the hibernated size is
//// what the residency interval recovers; what remains is what only removing
//// the copies can.
////
//// The wake reading is taken through `sys:suspend/1`, not through the
//// actor's own protocol. Suspension is one system message the loop must
//// handle before its caller is released, so timing it measures exactly the
//// wake and the handling — and unlike `sys:get_state/1` it copies no state,
//// so a 12 MiB heap does not swamp the number being read.
////
//// The assembly runs in this test's own VM rather than in a separately
//// launched daemon, because a probe needs to be inside the VM it measures
//// and the shipped launcher publishes no distribution name. What that costs
//// is the whole-VM resident figure, which includes this harness; what it
//// does not cost is the per-process attribution, because the assembly code,
//// the effects graph it copies and the collector are the same either way.
////
//// It is opt-in, and the reason is that its reach is node-wide rather than
//// its own. It differences `erlang:processes/0` and then forces a collection
//// and a suspension on everything the difference contains, so beside a
//// concurrent sibling it would collect and freeze another module's actors,
//// and a sibling actor dying between the census and the suspension would
//// answer `noproc`. `scripts/serial-tests` keeps it out of the parallel
//// group, and `LOOM_ASSEMBLY_HEAP_CENSUS=1` is what runs it at all — without
//// the variable it skips, because fifty seconds of residency wait does not
//// belong in every `make check-client`.
////
//// Nothing here asserts a byte count. The assertions are relations that hold
//// on any machine — a sweep does not invent live data, a hibernation does not
//// reclaim a live set, an assembly is never empty — and the numbers are
//// printed for the design note to record.

import client/catalog
import client/gateway
import client/internal/instance_host as host
import client/owned_assembly_test
import client/serve
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/clock
import core/ids
import core/json
import core/message
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/otp/system
import gleam/result
import gleam/set
import gleam/string
import host/bootstrap as native
import provider/http
import provider/secret
import runtime/api
import runtime/residency
import support/internal/ffi_soak as vm
import support/provider as provider_test
import telemetry/log
import weft/registry as address

/// How many turns each session is driven through. Each one is two provider
/// requests and one jailed tool execution, so this is the smallest number
/// that leaves a transcript, a tool result and several rounds of collection
/// behind rather than a freshly admitted session with nothing promoted out
/// of its young generation. Sizing the residency interval on an idle fresh
/// session is the mistake the first attempt at this made.
const turns_per_session = 4

/// Session counts to report, cumulative: the fixture assembles up to the
/// first, censuses, then grows to the next. Three points rather than one,
/// because the operator's census found the cost additive per session and a
/// local run should either agree or say why not.
const session_counts = [1, 3, 6]

/// The bytes a scripted tool call returns, which is what makes each turn
/// allocate a transcript rather than a token.
const tool_output_bytes = 8192

// --------------------------------------------------------- the measurement

/// Whether a process is parked in `erlang:hibernate/3` right now.
type Sleep {
  Hibernating

  Awake
}

/// Whether a session count pays for the hibernation wait.
///
/// Only the last one does. The wait is the residency interval itself, and
/// the earlier counts answer a question — how the cost scales with sessions
/// — that a hibernated reading does not change.
type Observation {
  ObserveHibernation

  SkipHibernation
}

/// One process: its shape, its allocated bytes, its used bytes, and whether
/// it is asleep. Every pid asked for gets a row, so that a caller may line
/// two readings up against each other by position.
type Row {
  Row(role: String, allocated: Int, used: Int, sleep: Sleep)
}

/// One shape of process, summed.
type Group {
  Group(role: String, count: Int, allocated: Int, used: Int, hibernating: Int)
}

/// A row for every pid asked for. A process that died between a snapshot and
/// here reads as zero rather than dropping out, because two readings are
/// compared by position and a shorter list would silently shift them.
fn census(pids: List(Pid)) -> List(Row) {
  list.map(pids, fn(pid) {
    let collection = information(pid, "garbage_collection_info")
    Row(
      role: role(pid),
      allocated: integer(pid, "memory") |> result.unwrap(0),
      used: words(collection, "heap_size")
        + words(collection, "old_heap_size")
        + words(collection, "mbuf_size"),
      sleep: sleep(pid),
    )
  })
}

/// A `process_info/2` answer for a still-living process, or nothing.
///
/// The reply is a two-element tuple whose second element is the value asked
/// for, and it is the atom `undefined` for a process that has died between
/// the snapshot and here, which is not an error in a census.
fn information(pid: Pid, item: String) -> Dynamic {
  vm.process_info(pid, atom.create(item))
}

fn integer(pid: Pid, item: String) -> Result(Int, Nil) {
  decode.run(information(pid, item), decode.at([1], decode.int))
  |> result.replace_error(Nil)
}

/// One key out of the collection proplist, in bytes.
///
/// The proplist is keyed by atoms and its positions are not fixed, so the
/// whole list is decoded and searched. An entry whose value is not an
/// integer, or a key this build does not report, reads as zero rather than
/// failing the census: a missing generation is worth naming in the output,
/// not worth losing every other process over.
fn words(collection: Dynamic, key: String) -> Int {
  let pair =
    decode.at([0], atom.decoder())
    |> decode.then(fn(name) {
      decode.at([1], decode.int) |> decode.map(fn(value) { #(name, value) })
    })
  let found =
    decode.run(collection, decode.at([1], decode.list(pair)))
    |> result.unwrap([])
    |> list.key_find(atom.create(key))
  case found {
    Ok(value) -> value * 8
    Error(Nil) -> 0
  }
}

/// Whether the process is parked in `erlang:hibernate/3` right now.
///
/// Asked rather than assumed. A residency interval that quietly did nothing
/// would leave every other number in this fixture looking the same, which is
/// exactly how the first attempt at sizing this reached a wrong conclusion.
fn sleep(pid: Pid) -> Sleep {
  // Matched exactly, module and function and arity. `erlang` alone would
  // count any process parked in any BEAM primitive as asleep, which is a
  // reading that can pass for the wrong reason.
  let parked =
    decode.run(information(pid, "current_function"), arity_named())
    |> result.unwrap("")
  case parked {
    "erlang:hibernate/3" -> Hibernating
    _ -> Awake
  }
}

/// A `{Module, Function, Arity}` rendered as `Module:Function/Arity`.
fn arity_named() -> decode.Decoder(String) {
  decode.at([1], named())
  |> decode.then(fn(name) {
    decode.at([1, 2], decode.int)
    |> decode.map(fn(arity) { name <> "/" <> int.to_string(arity) })
  })
}

/// The shape of the process, which is the grouping the operator's census
/// used.
///
/// Three sources, in this order, because no one of them answers for every
/// process. `proc_lib` records the real entry point in the process dictionary
/// under `$initial_call`, and every OTP behaviour shares one stub as its raw
/// initial call, so asking `initial_call` first would report `proc_lib:init_p`
/// for a supervisor. A weft actor has no `proc_lib` entry at all: it is
/// spawned as a closure, so its raw initial call says `erlang:apply` and the
/// module it is parked in is the only thing that names it. That last source
/// is also why a hibernating actor's shape has to be read before it goes to
/// sleep — parked in `erlang:hibernate/3`, it would name the VM instead of
/// itself.
fn role(pid: Pid) -> String {
  case recorded_call(pid) {
    Ok(name) -> name

    Error(Nil) ->
      case call(pid, "initial_call") {
        "erlang:apply" -> call(pid, "current_function")
        other -> other
      }
  }
}

/// The `$initial_call` the `proc_lib` entry recorded, if there is one.
///
/// The dictionary is a proplist of arbitrary terms, so it is decoded as a
/// list of opaque entries and each is tried in turn rather than decoded as a
/// uniform shape, which any other key in it would defeat.
fn recorded_call(pid: Pid) -> Result(String, Nil) {
  let entries =
    decode.run(
      information(pid, "dictionary"),
      decode.at([1], decode.list(decode.dynamic)),
    )
    |> result.unwrap([])

  list.fold(entries, Error(Nil), fn(found, entry) {
    case found {
      Ok(_) -> found
      Error(Nil) -> decode.run(entry, recorded()) |> result.replace_error(Nil)
    }
  })
}

fn recorded() -> decode.Decoder(String) {
  decode.at([0], atom.decoder())
  |> decode.then(fn(key) {
    case atom.to_string(key) {
      "$initial_call" -> decode.at([1], named())
      _ -> decode.failure("", "the recorded initial call")
    }
  })
}

/// A `{Module, Function, Arity}` rendered as `Module:Function`.
fn named() -> decode.Decoder(String) {
  decode.at([0], atom.decoder())
  |> decode.then(fn(module) {
    decode.at([1], atom.decoder())
    |> decode.map(fn(function) {
      atom.to_string(module) <> ":" <> atom.to_string(function)
    })
  })
}

fn call(pid: Pid, item: String) -> String {
  decode.run(information(pid, item), decode.at([1], named()))
  |> result.unwrap("unknown")
}

fn grouped(rows: List(Row)) -> List(Group) {
  let totals =
    list.fold(rows, dict.new(), fn(totals: Dict(String, Group), row) {
      let Group(_, count, allocated, used, hibernating) =
        dict.get(totals, row.role) |> or_empty(row.role)
      dict.insert(
        totals,
        row.role,
        Group(
          role: row.role,
          count: count + 1,
          allocated: allocated + row.allocated,
          used: used + row.used,
          hibernating: hibernating + asleep(row.sleep),
        ),
      )
    })

  dict.values(totals)
  |> list.sort(fn(a, b) { int.compare(b.allocated, a.allocated) })
}

fn asleep(sleep: Sleep) -> Int {
  case sleep {
    Hibernating -> 1
    Awake -> 0
  }
}

/// A `dict.get` whose fallback is a value rather than a `Result`, kept
/// separate so the fold above reads as one expression.
fn or_empty(found: Result(Group, Nil), role: String) -> Group {
  case found {
    Ok(group) -> group
    Error(Nil) -> Group(role, 0, 0, 0, 0)
  }
}

fn mib(bytes: Int) -> String {
  let hundredths = bytes * 100 / 1_048_576
  int.to_string(hundredths / 100)
  <> "."
  <> string.pad_start(int.to_string(hundredths % 100), 2, "0")
}

/// Print one cut: every shape of process, heaviest first, then the total.
fn print_cut(label: String, rows: List(Row)) -> #(Int, Int) {
  let groups = grouped(rows)
  let allocated = list.fold(groups, 0, fn(sum, group) { sum + group.allocated })
  let used = list.fold(groups, 0, fn(sum, group) { sum + group.used })

  io.println_error("  cut: " <> label)
  list.each(list.take(groups, 8), fn(group) {
    io.println_error(
      "    "
      <> string.pad_start(mib(group.allocated), 9, " ")
      <> " MiB allocated  "
      <> string.pad_start(mib(group.used), 9, " ")
      <> " MiB used  over "
      <> int.to_string(group.count)
      <> " ("
      <> int.to_string(group.hibernating)
      <> " hibernating)  "
      <> group.role,
    )
  })
  io.println_error(
    "    TOTAL "
    <> mib(allocated)
    <> " MiB allocated, "
    <> mib(used)
    <> " MiB used, over "
    <> int.to_string(list.length(rows))
    <> " processes",
  )
  #(allocated, used)
}

// ------------------------------------------------------ the scripted model

/// A provider that answers every prompt with one tool call and every tool
/// result with a final text answer.
///
/// The choice is keyed on the request body rather than on a counter, so a
/// strand that retries a request gets the same answer it would have got the
/// first time; a counter would slide the whole script by one.
fn scripted_transport() -> http.Transport {
  provider_test.transport(fn(request: http.HttpRequest, events) {
    let response = case string.contains(request.body, "tool_result") {
      True -> text_turn("done")
      False -> tool_turn("census-call")
    }
    process.send(
      events,
      http.ResponseStatus(200, [#("content-type", "text/event-stream")]),
    )
    process.send(events, http.ResponseChunk(bit_array.from_string(response)))
    process.send(events, http.ResponseEnd)
  })
}

fn text_turn(text: String) -> String {
  started()
  <> sse(
    "{\"type\":\"content_block_start\",\"index\":0,"
    <> "\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
  )
  <> sse(
    "{\"type\":\"content_block_delta\",\"index\":0,"
    <> "\"delta\":{\"type\":\"text_delta\",\"text\":\""
    <> text
    <> "\"}}",
  )
  <> sse("{\"type\":\"content_block_stop\",\"index\":0}")
  <> stopped("end_turn")
}

fn tool_turn(id: String) -> String {
  let arguments =
    json.Object([
      #(
        "command",
        json.String("printf '%0" <> int.to_string(tool_output_bytes) <> "d' 7"),
      ),
    ])
  started()
  <> sse(
    "{\"type\":\"content_block_start\",\"index\":0,"
    <> "\"content_block\":{\"type\":\"tool_use\",\"id\":\""
    <> id
    <> "\",\"name\":\"bash\",\"input\":{}}}",
  )
  <> sse(
    "{\"type\":\"content_block_delta\",\"index\":0,"
    <> "\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":"
    <> json.to_string(json.String(json.to_string(arguments)))
    <> "}}",
  )
  <> sse("{\"type\":\"content_block_stop\",\"index\":0}")
  <> stopped("tool_use")
}

fn started() -> String {
  sse(
    "{\"type\":\"message_start\",\"message\":{\"id\":\"census\","
    <> "\"model\":\"test\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}",
  )
}

fn stopped(reason: String) -> String {
  sse(
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\""
    <> reason
    <> "\"},\"usage\":{\"output_tokens\":1}}",
  )
  <> sse("{\"type\":\"message_stop\"}")
}

/// The adapter dispatches on the `data:` record's own `type` field and
/// ignores the `event:` name, so one record per frame is the whole wire.
fn sse(data: String) -> String {
  "data: " <> data <> "\n\n"
}

// -------------------------------------------------------- the assembly

fn settings() -> serve.Settings {
  let base = owned_assembly_test.settings()
  serve.Settings(
    ..base,
    gateway: catalog.gateway(
      base.catalog,
      transport: scripted_transport(),
      secrets: secret.from_list([#("UNUSED", "fixture")]),
      clock: clock.fixed(at: 0),
    ),
  )
}

/// Assemble one real session under its own custody, exactly as the daemon's
/// manager does, and drive it through `turns_per_session` turns.
fn worked_session(seed: Int) -> serve.Instance {
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(at: 1), seed:))
  let results = process.new_subject()
  let assert Ok(prepared) =
    host.prepare(
      build: fn(owner) {
        serve.assemble_owned(settings(), id, log.discard(), owner)
      },
      fatal: serve.instance_children,
      results:,
      faults: process.new_subject(),
      failures: process.new_subject(),
    )
    as "the fixture prepares ownership before beginning assembly"
  host.begin(prepared)
  let assert Ok(Ok(instance)) = process.receive(results, 60_000)
    as "the reserved session assembles under surviving custody"

  list.each(list.repeat(Nil, turns_per_session), fn(_) {
    let assert Ok(operation) =
      api.prompt(instance.runtime, [
        message.UserMessage(
          content: [message.UserText("inspect the tree", None)],
          timestamp: 0,
          origin: None,
        ),
      ])
      as "a prompt is accepted on the primary strand"
    let assert Ok(_) =
      api.await_result(instance.runtime, operation, within_ms: 120_000)
      as "the scripted turn settles within its budget"
    Nil
  })
  instance
}

/// The hub actor of each assembly, which is the one this investigation has
/// to look at separately.
///
/// `client/gateway` is the heaviest weft actor in the operator's census, and
/// it carries `actor.periodic(every: 1000, ...)`. A heartbeat means the
/// mailbox is never quiet for any threshold at or above a second, so the
/// residency interval can never fire on it. Whatever these processes hold is
/// therefore outside what hibernation reaches, and a census that folded them
/// into the weft-actor total would overstate the policy by their share.
fn gateways(instances: List(serve.Instance)) -> List(Pid) {
  list.filter_map(instances, fn(instance) {
    let gateway.Gateway(name:) = instance.gateway
    use subject <- result.try(address.lookup(name))
    process.subject_owner(subject)
  })
}

// --------------------------------------------------------------- the census

/// The local sizing the design note's two options needed.
///
/// One session count at a time, cumulative, each with its own cuts:
/// immediately after the last turn, after a quiet interval, and after a
/// forced full sweep of every process the assemblies own. The sweep is a
/// deliberate experiment on a local fixture and is not production behaviour.
/// The last session count additionally waits past `residency` and reads the
/// hibernated sizes and the wake cost, which no derivation can supply.
pub fn session_assembly_heap_census_test_() -> EunitTest {
  Timeout(900, fn() {
    case native.getenv("LOOM_ASSEMBLY_HEAP_CENSUS") {
      // On *stderr*: eunit rebinds the group leader and captures a passing
      // test's stdout, so a skip announced there is never read.
      Error(Nil) -> {
        io.println_error(
          "SKIP assembly heap census: LOOM_ASSEMBLY_HEAP_CENSUS is unset",
        )
        Nil
      }

      Ok(_) -> run_census()
    }
  })
}

/// The census proper, once the variable has admitted it.
fn run_census() -> Nil {
  {
    let before = set.from_list(vm.processes())
    let #(_, instances) =
      list.fold(session_counts, #(0, []), fn(state, target) {
        let #(built, instances) = state
        let instances =
          list.fold(
            list.repeat(Nil, target - built),
            instances,
            fn(instances, _) {
              [worked_session(list.length(instances) + 1), ..instances]
            },
          )

        io.println_error(
          "\nsession assembly heap census: "
          <> int.to_string(target)
          <> " session(s), "
          <> int.to_string(turns_per_session)
          <> " turns each",
        )
        let observation = case target == last(session_counts) {
          True -> ObserveHibernation
          False -> SkipHibernation
        }
        report(before, gateways(instances), observation)
        #(target, instances)
      })

    // The instances are held to the end of the fixture on purpose: a census
    // of assemblies that had begun retiring would measure teardown.
    assert list.length(instances) == 6
  }
}

fn last(counts: List(Int)) -> Int {
  list.fold(counts, 0, fn(_, count) { count })
}

/// The cuts over whatever the assemblies currently own.
fn report(
  before: set.Set(Pid),
  hubs: List(Pid),
  observation: Observation,
) -> Nil {
  let owned =
    list.filter(vm.processes(), fn(pid) { !set.contains(before, pid) })

  let #(_, _) = print_cut("just worked", census(owned))
  print_hubs("just worked", hubs)

  // Long enough that every strand's checkpoint poll has come round and gone
  // quiet again, and short of the residency interval, so this is the idle
  // reading an operator's census describes rather than a hibernated one.
  process.sleep(5000)
  let #(idle_allocated, _) = print_cut("idle", census(owned))
  print_hubs("idle", hubs)

  case observation {
    SkipHibernation -> Nil
    ObserveHibernation -> observe_hibernation(owned, hubs)
  }

  vm_collect(owned)
  let #(swept_allocated, swept_used) =
    print_cut("after a full sweep", census(owned))
  print_hubs("after a full sweep", hubs)

  // A sweep cannot invent live data, and a session assembly is never empty:
  // these are the two relations that hold on any machine, and they are what
  // keeps the printed numbers honest about what they are.
  assert swept_used > 0
  assert swept_used <= swept_allocated
  assert idle_allocated > 0
}

fn vm_collect(pids: List(Pid)) -> Nil {
  list.each(pids, fn(pid) {
    let _ = vm.garbage_collect(pid)
    Nil
  })
}

/// Wait past the residency interval, read what hibernated, then wake it.
///
/// The wake is one `sys:suspend/1` per process, which the loop must handle
/// before the caller is released; the interval is measured over the whole
/// group rather than per process, because the clock available here is
/// milliseconds and a single wake is well under one. Each process is resumed
/// immediately afterwards, so the assembly is left as it was found.
fn observe_hibernation(owned: List(Pid), hubs: List(Pid)) -> Nil {
  // The shapes are read before anything is asleep, because a hibernating
  // process answers `erlang:hibernate/3` for its current function and so
  // would lose the name that identifies it.
  let shapes = list.map(owned, fn(pid) { #(pid, role(pid)) })

  process.sleep(residency.hibernate_after_ms + 2000)
  let asleep = census(owned)
  let #(_, _) = print_cut("hibernated", relabelled(asleep, shapes, owned))
  print_hubs("hibernated", hubs)

  // Restricted to weft actors on purpose. `owned` is every process the
  // assemblies added, which includes `gleam_otp` supervisors that hibernate
  // on their own account, and a count that included those would report the
  // residency interval working when it had done nothing.
  let slept =
    list.filter_map(list.zip(owned, asleep), fn(pair) {
      let #(pid, row) = pair
      let shape = list.key_find(shapes, pid) |> result.unwrap(row.role)
      case row.sleep, string.starts_with(shape, "weft@actor:") {
        Hibernating, True -> Ok(#(pid, shape))
        Hibernating, False | Awake, _ -> Error(Nil)
      }
    })
  let sleepers = list.map(slept, fn(pair) { pair.0 })

  io.println_error(
    "    slept: "
    <> int.to_string(list.length(sleepers))
    <> " weft actor(s), shapes "
    <> string.inspect(list.unique(list.map(slept, fn(pair) { pair.1 }))),
  )

  // Observed, not assumed. A residency interval that never fired would leave
  // every number above looking exactly as it does now.
  assert sleepers != []

  let before_wake = native.monotonic_time_ms()
  list.each(sleepers, fn(pid) {
    system.suspend(pid)
    system.resume(pid)
  })
  let woke = native.monotonic_time_ms() - before_wake

  // The same round trip on the same processes, now awake, is the comparison
  // that makes the first number mean anything.
  let before_awake = native.monotonic_time_ms()
  list.each(sleepers, fn(pid) {
    system.suspend(pid)
    system.resume(pid)
  })
  let awake = native.monotonic_time_ms() - before_awake

  io.println_error(
    "    wake: "
    <> int.to_string(list.length(sleepers))
    <> " hibernating process(es) suspended and resumed in "
    <> int.to_string(woke)
    <> " ms, the same group awake in "
    <> int.to_string(awake)
    <> " ms",
  )
  let #(_, _) = print_cut("woken", census(owned))
  Nil
}

/// Carry the shapes read while the processes were awake onto the rows read
/// while they were asleep.
fn relabelled(
  rows: List(Row),
  shapes: List(#(Pid, String)),
  owned: List(Pid),
) -> List(Row) {
  list.map(list.zip(owned, rows), fn(pair) {
    let #(pid, row) = pair
    case list.key_find(shapes, pid) {
      Ok(role) -> Row(..row, role:)
      Error(Nil) -> row
    }
  })
}

/// The hub actors' own share of a cut, printed beside the shape totals.
fn print_hubs(label: String, hubs: List(Pid)) -> Nil {
  let rows = census(hubs)
  let allocated = list.fold(rows, 0, fn(sum, row) { sum + row.allocated })
  let used = list.fold(rows, 0, fn(sum, row) { sum + row.used })
  io.println_error(
    "    of which "
    <> int.to_string(list.length(rows))
    <> " gateway hub(s), which never go idle: "
    <> mib(allocated)
    <> " MiB allocated, "
    <> mib(used)
    <> " MiB used  ("
    <> label
    <> ")",
  )
}
