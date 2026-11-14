//// The pure rules of `executors.reload` (protocol-change/115): the plan from a
//// held set and a wanted set, the `[executor_link]` rule, the refusals and the
//// reply's codec.
////
//// The properties draw each of eight names as an optional held row with a
//// liveness and an optional wanted row, from small pools of hosts, ports and
//// pins, so that every pair of states a row can be in (absent, present and
//// equal, present and different, alive, dead) is reached many times in one run.

import client/executor_reload.{
  type Held, type Row, Alive, Dead, Entry, Failed, Held, Reply, Restarted, Row,
  Started, Stopped, Unchanged,
}
import client/internal/ffi_tls_stream.{type Credentials, Credentials}
import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck

const seed = 115

fn config() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(300)
  |> qcheck.with_seed(qcheck.seed(seed))
}

// A row for name number `slot`, with its address and pin drawn from pools of
// two and three, so a held row and a wanted row agree about a third of the time.
fn row_of(slot: Int, address: Int, pin: Int) -> Row {
  Row(
    name: "box-" <> string.inspect(slot),
    host: "10.0.0." <> string.inspect(address % 2),
    port: 7000 + address % 3,
    pin: <<{ pin % 2 }>>,
  )
}

// One slot: whether the daemon holds the row and whether its link is alive,
// whether the file wants it, and the address and pin of each.
type Slot {
  Slot(
    held: Int,
    alive: Int,
    held_address: Int,
    held_pin: Int,
    wanted: Int,
    wanted_address: Int,
    wanted_pin: Int,
  )
}

fn slots_generator() -> qcheck.Generator(List(Slot)) {
  let one =
    qcheck.map2(
      qcheck.tuple4(
        qcheck.bounded_int(0, 1),
        qcheck.bounded_int(0, 1),
        qcheck.bounded_int(0, 5),
        qcheck.bounded_int(0, 1),
      ),
      qcheck.tuple3(
        qcheck.bounded_int(0, 1),
        qcheck.bounded_int(0, 5),
        qcheck.bounded_int(0, 1),
      ),
      fn(held, wanted) {
        Slot(held.0, held.1, held.2, held.3, wanted.0, wanted.1, wanted.2)
      },
    )
  qcheck.fixed_length_list_from(one, 8)
}

fn held_of(slots: List(Slot)) -> List(Held) {
  list.index_map(slots, fn(slot, index) {
    case slot.held {
      1 -> {
        let link = case slot.alive {
          1 -> Alive
          _ -> Dead
        }
        [Held(row_of(index, slot.held_address, slot.held_pin), link)]
      }
      _ -> []
    }
  })
  |> list.flatten
}

fn wanted_of(slots: List(Slot)) -> List(Row) {
  list.index_map(slots, fn(slot, index) {
    case slot.wanted {
      1 -> [row_of(index, slot.wanted_address, slot.wanted_pin)]
      _ -> []
    }
  })
  |> list.flatten
}

fn sorted(rows: List(Row)) -> List(Row) {
  list.sort(rows, fn(a, b) { string.compare(a.name, b.name) })
}

pub fn applying_the_plan_yields_the_wanted_set_test() {
  qcheck.run(config(), slots_generator(), fn(slots) {
    let steps = executor_reload.plan(held_of(slots), wanted_of(slots))
    assert executor_reload.applied(steps) == sorted(wanted_of(slots))
  })
}

pub fn an_unchanged_live_row_is_never_replaced_test() {
  qcheck.run(config(), slots_generator(), fn(slots) {
    let held = held_of(slots)
    let steps = executor_reload.plan(held, wanted_of(slots))
    list.each(held, fn(found) {
      let assert Ok(step) =
        list.find(steps, fn(step) { step.name == found.row.name })
        as "every held row has a step"
      let same = list.contains(wanted_of(slots), found.row)
      case same, found.link {
        True, Alive -> {
          assert step.change == Unchanged
        }
        True, Dead -> {
          assert step.change == Restarted
        }
        False, _ -> {
          assert step.change == Restarted || step.change == Stopped
        }
      }
    })
  })
}

pub fn a_new_row_starts_and_a_missing_row_stops_test() {
  qcheck.run(config(), slots_generator(), fn(slots) {
    let held = held_of(slots)
    let wanted = wanted_of(slots)
    let steps = executor_reload.plan(held, wanted)
    list.each(steps, fn(step) {
      let was = list.any(held, fn(found) { found.row.name == step.name })
      let is = list.any(wanted, fn(row) { row.name == step.name })
      case was, is {
        False, True -> {
          assert step.change == Started
        }
        True, False -> {
          assert step.change == Stopped
        }
        True, True | False, False -> {
          assert step.change != Started && step.change != Stopped
        }
      }
    })
  })
}

pub fn the_reply_is_sorted_unique_and_survives_the_codec_test() {
  qcheck.run(config(), slots_generator(), fn(slots) {
    let steps = executor_reload.plan(held_of(slots), wanted_of(slots))
    let reply = executor_reload.reply_of(steps)
    let names = list.map(reply.executors, fn(entry) { entry.name })
    assert names == list.unique(names)
    assert names == list.sort(names, string.compare)
    assert executor_reload.decode(executor_reload.encode(reply)) == Ok(reply)
  })
}

pub fn decoding_arbitrary_json_never_crashes_test() {
  let strings =
    qcheck.map(qcheck.string(), fn(text) {
      case json.parse(text) {
        Ok(value) -> value
        Error(_) -> json.String(text)
      }
    })
  qcheck.run(config(), strings, fn(value) {
    let _ = executor_reload.decode(value)
    Nil
  })
}

pub fn a_failed_step_leaves_the_held_row_test() {
  let old = Row("box", "10.0.0.1", 7000, <<1>>)
  let new = Row("box", "10.0.0.2", 7000, <<1>>)
  let step = executor_reload.Step("box", Failed, Some(old), Some(new))
  assert executor_reload.applied([step]) == [old]
}

pub fn decode_refuses_what_a_daemon_never_sends_test() {
  let entry = fn(name, change) {
    json.Object([#("name", json.String(name)), #("change", json.String(change))])
  }
  let body = fn(items) { json.Object([#("executors", json.Array(items))]) }

  // Unsorted, duplicated, unknown word, bad name, wrong shape.
  assert executor_reload.decode(
      body([entry("b", "started"), entry("a", "started")]),
    )
    |> result_is_error
  assert executor_reload.decode(
      body([entry("a", "started"), entry("a", "started")]),
    )
    |> result_is_error
  assert executor_reload.decode(body([entry("a", "restored")]))
    |> result_is_error
  assert executor_reload.decode(body([entry("A B", "started")]))
    |> result_is_error
  assert executor_reload.decode(json.Array([])) |> result_is_error

  // More entries than the bound.
  let many =
    list.repeat(0, executor_reload.max_rows + 1)
    |> list.index_map(fn(_zero, index) { entry("n" <> pad(index), "started") })
  assert executor_reload.decode(body(many)) |> result_is_error
  assert executor_reload.decode(body(list.take(many, executor_reload.max_rows)))
    != Error("")
}

// Zero-padded so that names ascend as their numbers do.
fn pad(index: Int) -> String {
  string.pad_start(string.inspect(index), 4, "0")
}

fn result_is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

pub fn the_reply_of_one_entry_encodes_as_documented_test() {
  let reply = Reply([Entry("review-pod", Unchanged)])
  assert json.to_string(executor_reload.encode(reply))
    == "{\"executors\":[{\"name\":\"review-pod\",\"change\":\"unchanged\"}]}"
}

fn credentials(dir: String) -> Credentials {
  Credentials(
    ca: dir <> "/ca.pem",
    certificate: dir <> "/cert.pem",
    key: dir <> "/key.pem",
  )
}

pub fn a_started_table_is_kept_and_never_changed_test() {
  let started = Some(credentials("/elsewhere"))
  let allowed = ["/h/.loom/vm"]
  assert executor_reload.link_rule(started, started, allowed) == Ok(Nil)
  assert executor_reload.link_rule(started, None, allowed) |> result_is_error
  assert executor_reload.link_rule(
      started,
      Some(credentials("/h/.loom/vm/link")),
      allowed,
    )
    |> result_is_error
}

pub fn a_new_table_must_lie_under_an_allowed_directory_test() {
  let allowed = ["/h/.loom/vm", "/state/vm"]
  assert executor_reload.link_rule(None, None, allowed) == Ok(Nil)
  assert executor_reload.link_rule(
      None,
      Some(credentials("/h/.loom/vm/link")),
      allowed,
    )
    == Ok(Nil)
  assert executor_reload.link_rule(
      None,
      Some(credentials("/state/vm/link")),
      allowed,
    )
    == Ok(Nil)

  // A sibling with the same prefix, a parent, and one stray file all refuse.
  assert executor_reload.link_rule(
      None,
      Some(credentials("/h/.loom/vm-other")),
      allowed,
    )
    |> result_is_error
  assert executor_reload.link_rule(None, Some(credentials("/h/.loom")), allowed)
    |> result_is_error
  let stray = Credentials("/h/.loom/vm/ca", "/h/.loom/vm/c", "/etc/key")
  assert executor_reload.link_rule(None, Some(stray), allowed)
    |> result_is_error
}

pub fn the_caps_are_exact_test() {
  assert executor_reload.check_rows(512) == Ok(Nil)
  assert executor_reload.check_rows(513) |> result_is_error
  assert executor_reload.check_names(1024) == Ok(Nil)
  assert executor_reload.check_names(1025) |> result_is_error
}
