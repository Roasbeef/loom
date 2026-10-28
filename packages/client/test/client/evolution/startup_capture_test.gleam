//// The notice runner borrows a live owner without copying its stage inputs.
//// Only children linked to this test are measured, before any message can
//// collect their startup garbage. Other concurrently running tests are outside
//// that set. The state check distinguishes the runner from the actual owner.

import client/evolution/live
import client/evolution/store
import core/clock
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/otp/system
import gleam/string
import support/internal/ffi_soak as vm

pub fn notice_startup_does_not_copy_generation_callbacks_test() {
  let small = runner_bytes(0)
  let large = runner_bytes(8192)
  io.println(
    "evolution notice startup bytes: "
    <> int.to_string(small)
    <> "/"
    <> int.to_string(large),
  )
  assert large <= small + 65_536
    as "notice startup must not copy stage or recovery configuration"
}

/// Samples startup capacity before reading state, then proves both children
/// retire through the ordinary live owner. No collection is forced.
fn runner_bytes(padding: Int) -> Int {
  let payload = list.repeat(#("stage-only", 1, 2, 3), padding)
  let before = links()
  let assert Ok(owner) =
    live.start(
      live.Config(
        clock: clock.fixed(0),
        stage: fn(_) {
          Error(store.Bounds(int.to_string(list.length(payload))))
        },
        adopt: fn(_) { Ok(Nil) },
        recover: fn() {
          case list.is_empty(payload) {
            True -> Ok(None)
            False -> Error(store.Bounds("stage-only"))
          }
        },
      ),
    )
    as "the fixture starts a generation owner and its notice runner"
  let after = links()
  let children =
    vm.processes()
    |> list.filter(fn(pid) {
      let value = string.inspect(pid)
      list.contains(after, value) && !list.contains(before, value)
    })
  let sizes =
    list.map(children, fn(pid) {
      let assert Ok(bytes) =
        decode.run(
          vm.process_info(pid, atom.create("memory")),
          decode.at([1], decode.int),
        )
        as "each measured child is alive"
      #(pid, bytes)
    })

  // The large configuration belongs to the owner. Identify the runner only
  // after its startup allocation has been recorded, since sys can trigger GC.
  let runners =
    list.filter(sizes, fn(row) {
      let assert Ok(tag) =
        decode.run(system.get_state(row.0), decode.at([0], decode.dynamic))
        as "both live actors expose a record-shaped application state"
      tag == atom.to_dynamic(atom.create("live"))
    })
  let retired = live.close(owner, 1000)
  assert retired == Ok(Nil)
  assert list.length(children) == 2
    as "the census includes exactly this start's two linked children"
  let assert [#(_, bytes)] = runners as "exactly one child is the notice runner"
  bytes
}

/// Reads only the caller's links, so sibling fixtures cannot enter the census.
fn links() -> List(String) {
  let assert Ok(links) =
    decode.run(
      vm.process_info(process.self(), atom.create("links")),
      decode.at([1], decode.list(decode.dynamic)),
    )
    as "the test process has an OTP link census"
  list.map(links, string.inspect)
}
