//// Real evolution callbacks retain only the settings their operation reads.
//// The fixture starts the ordinary code-mode-enabled session assembly with
//// its offline seed and helper, then borrows its actual capability door.
//// Flattened words include closure environments that a process copy duplicates;
//// they measure reachable terms rather than resident or retained heap bytes.

import client/evolution/capability
import client/evolution_acceptance_test
import client/owned_assembly_test
import client/secrets
import client/serve
import filepath
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import simplifile
import support/internal/ffi_memory
import telemetry/log

pub fn startup_padding_does_not_grow_evolution_trace_test() {
  let #(small_trace, small_door) = callback_words(0)
  let #(large_trace, large_door) = callback_words(4096)
  io.println(
    "evolution callback flattened words: trace="
    <> int.to_string(small_trace)
    <> "/"
    <> int.to_string(large_trace)
    <> " whole_door="
    <> int.to_string(small_door)
    <> "/"
    <> int.to_string(large_door),
  )
  assert large_trace == small_trace
    as "trace model lookup must not retain unrelated startup diagnostic settings"

  // Prompt evaluation still owns one source Settings snapshot to assemble its
  // isolated trials. Other callbacks must not multiply that unrelated padding.
  let marker = ffi_memory.flat_words(startup_failures(4096))
  assert large_door - small_door <= marker
    as "the whole evolution door must retain at most one source settings snapshot"
}

fn callback_words(padding: Int) -> #(Int, Int) {
  let root =
    filepath.directory_name(owned_assembly_test.settings().session_path)
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/work")
    as "the disposable evolution fixture owns its workspace"
  let settings = evolution_acceptance_test.settings(root, "http://127.0.0.1:1")
  let settings =
    serve.Settings(..settings, secret_failures: startup_failures(padding))
  let assert Ok(instance) = serve.open_instance(settings, log.discard())
    as "the ordinary code-mode-enabled evolution assembly opens"
  let assert Some(cell) = instance.evolution_cell
    as "a missing seed must not silently omit the measured evolution plane"
  let assert Ok(door) = capability.borrow(cell)
    as "the actual assembly publishes its evolution callback door"
  let words = #(ffi_memory.flat_words(door.trace), ffi_memory.flat_words(door))
  let assert Ok(Nil) = serve.retire_instance(instance)
    as "the original fixture owner proves orderly native retirement"
  words
}

fn startup_failures(count: Int) -> List(secrets.Failure) {
  list.repeat(secrets.Failure("fixture", "startup-only"), count)
}
