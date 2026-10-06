//// The watcher is bounded independently of TOML and production routing.
//// Real files establish the read budget; a blocked validator establishes the
//// worker deadline and subsequent availability without an injected timer.

import client/config_reload
import client/internal/ffi_os
import core/ids
import gleam/erlang/process
import gleam/int
import gleam/option.{Some}
import gleam/result as gleam_result
import gleam/string
import simplifile
import telemetry/log
import weft/poll
import weft/registry as address

fn path() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test has a working directory"
  here
  <> "/build/reload-"
  <> int.to_string(ffi_os.unique_positive_integer())
  <> ".toml"
}

fn awaited(holder: config_reload.Holder(Int), wanted: Int) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 6000, every: 20, attempt: fn() {
      case config_reload.current(holder) {
        Ok(value) if value == wanted -> poll.Done(Nil)
        Ok(_) | Error(Nil) -> poll.Retry
      }
    })
    as "a real file observation eventually publishes the expected revision"
  Nil
}

pub fn reads_refuse_non_files_and_one_byte_over_the_budget_test() {
  let file = path()
  let assert Ok(_) =
    simplifile.write(file, string.repeat("x", config_reload.max_file_bytes))
    as "the exact-limit file is written"
  let assert Ok(text) = config_reload.read(file)
    as "the byte ceiling itself is accepted"
  assert string.byte_size(text) == config_reload.max_file_bytes
    as "the complete bounded file is returned"
  let assert Ok(_) = simplifile.write(file, text <> "x")
    as "the file grows one byte beyond its ceiling"
  assert config_reload.read(file) == Error(Nil)
    as "growth beyond the bound is refused rather than truncated"
  assert config_reload.read(file <> ".missing") == Error(Nil)
    as "missing edits are availability errors"
  let assert Ok(directory) = simplifile.current_directory()
    as "the fixture directory exists"
  assert config_reload.read(directory) == Error(Nil)
    as "only regular configuration files can be read"
  let _ = simplifile.delete(file)
}

pub fn validator_timeout_retains_the_last_value_and_pins_the_active_operation_test() {
  let file = path()
  let assert Ok(_) = simplifile.write(file, "1") as "the initial source exists"
  let assert Ok(namespace) = address.start()
    as "the holder receives its own namespace"
  let name = address.new_address(namespace)
  let validation_started = process.new_subject()
  let assert Ok(holder) =
    config_reload.start(
      name,
      1,
      Some(
        config_reload.Source(
          path: file,
          initial: "1",
          load: fn(text, _previous) {
            case text {
              "blocked" -> {
                process.send(validation_started, Nil)
                process.sleep(10_000)
                Ok(#(99, []))
              }
              other -> {
                use value <- gleam_result.try(int.parse(other))
                Ok(#(value, []))
              }
            }
          },
        ),
      ),
      fn(_) { False },
      log.discard(),
    )
    as "the linked source holder starts"
  let assert Ok(operation) =
    ids.parse_op_id("0199e9b0-0000-7000-8000-000000000001")
    as "the first operation has a valid durable identity"
  assert config_reload.capture(holder, operation) == Ok(1)
    as "the initial operation captures its revision"
  let assert Ok(_) = simplifile.write(file, "blocked")
    as "a valid read reaches a deliberately stalled validator"
  // A following save must become visible well before the blocked validator's
  // own ten-second return. Removing its deadline makes this test fail.
  let assert Ok(Nil) = process.receive(validation_started, 5000)
    as "the candidate validator actually started before its replacement"
  let assert Ok(_) = simplifile.write(file, "2")
    as "a subsequent complete save replaces the blocked candidate"
  awaited(holder, 2)
  assert config_reload.capture(holder, operation) == Ok(1)
    as "publication does not replace the active operation's captured value"
  let assert Ok(next) = ids.parse_op_id("0199e9b0-0000-7000-8000-000000000002")
    as "the next turn has another durable identity"
  assert config_reload.capture(holder, next) == Ok(2)
    as "the next operation sees the latest valid revision"
  let watch = process.monitor(config_reload.pid(holder))
  assert config_reload.stop(holder) == Ok(Nil)
    as "the holder acknowledges retirement"
  let assert Ok(Nil) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_) { Nil })
    |> process.selector_receive(1000)
    as "stop is proven by the original process monitor"
  assert config_reload.capture(holder, next) == Error(Nil)
    as "a dead holder refuses fetches rather than changing the snapshot"
  let _ = address.stop(namespace)
  let _ = simplifile.delete(file)
}
