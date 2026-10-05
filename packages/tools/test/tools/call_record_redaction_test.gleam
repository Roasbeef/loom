//// The redaction allowlist, checked against the arguments the real `cap`
//// package writes.
////
//// A hand-built `args` map would only prove that the summariser reads the
//// keys its author remembered. These tests drive the actual public `cap`
//// functions (`fs.read`, `proc.run`, `job.start`, ...) through a fake
//// channel that captures what each puts on the wire, and hand that to
//// `call_record`. A key the encoders write and the allowlist does not read,
//// `job` against `job_id` or `argv` against `command`, then fails here
//// rather than becoming a silent `args: None` in production.
////
//// Every case also checks the other half of redaction: the secrets the
//// same call carried (an environment value, `stdin`, a file body, the
//// tail of an `argv`) appear nowhere in the encoded record.

import cap/fs
import cap/internal/channel
import cap/internal/dispatch
import cap/job
import cap/kv
import cap/proc
import core/json
import core/msgpack.{type MsgPackValue}
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/string
import tools/call_record

const secret = "hunter2-SECRET"

// Runs `perform` against a channel that records the one call it makes and
// answers it with a transport failure, and returns what was recorded.
fn captured(perform: fn() -> a) -> #(String, MsgPackValue) {
  let seen = process.new_subject()
  dispatch.install(
    channel.Channel(call: fn(cap, args, _deadline) {
      process.send(seen, #(cap, args))
      Error(channel.Unreachable("captured"))
    }),
  )
  let _result = perform()
  let assert Ok(call) = process.receive(seen, 1000)
    as "the cap function made one call"
  dispatch.reset()
  call
}

// The record `call_record` would keep for that call, encoded.
fn record_text(call: #(String, MsgPackValue)) -> String {
  let ledger = call_record.start(0)
  let #(ledger, _seq) = call_record.admit(ledger, call.0, call.1, 1)
  json.to_string(call_record.to_json(call_record.finish(ledger, [0], 2)))
}

fn summary(call: #(String, MsgPackValue)) -> Option(String) {
  call_record.summarise(call.0, call.1)
}

fn never_contains(text: String, needles: List(String)) -> Nil {
  case needles {
    [] -> Nil
    [needle, ..rest] -> {
      assert !string.contains(text, needle)
      never_contains(text, rest)
    }
  }
}

pub fn fs_calls_summarise_to_their_path_only_test() {
  let read = captured(fn() { fs.read("src/app.gleam") })
  assert read.0 == "fs.read"
  assert summary(read) == Some("src/app.gleam")

  let write = captured(fn() { fs.write("out/report.txt", secret) })
  assert write.0 == "fs.write"
  assert summary(write) == Some("out/report.txt")
  never_contains(record_text(write), [secret])

  let edit =
    captured(fn() {
      fs.edit("src/a.gleam", [
        fs.Replacement(find: "old", replace_with: secret),
      ])
    })
  assert edit.0 == "fs.edit"
  assert summary(edit) == Some("src/a.gleam")
  never_contains(record_text(edit), [secret, "old"])

  let listing = captured(fn() { fs.list("src") })
  assert listing.0 == "fs.list"
  assert summary(listing) == Some("src")
}

pub fn kv_calls_summarise_to_their_key_only_test() {
  let get = captured(fn() { kv.get("cache/entry") })
  assert get.0 == "kv.get"
  assert summary(get) == Some("cache/entry")

  let set = captured(fn() { kv.set("cache/entry", <<secret:utf8>>) })
  assert set.0 == "kv.set"
  assert summary(set) == Some("cache/entry")
  never_contains(record_text(set), [secret])

  let delete = captured(fn() { kv.delete("cache/entry") })
  assert delete.0 == "kv.delete"
  assert summary(delete) == Some("cache/entry")
}

pub fn a_process_summarises_to_its_executable_and_an_argument_count_test() {
  let command =
    proc.command(["/usr/bin/curl", "--token=" <> secret, "https://x.invalid"])
    |> proc.with_env("API_KEY", secret)
    |> proc.with_stdin(secret)
  let call = captured(fn() { proc.run(command) })
  assert call.0 == "proc.run"
  assert summary(call) == Some("curl +2 args")
  never_contains(record_text(call), [secret, "API_KEY", "x.invalid"])
}

pub fn a_job_start_summarises_to_the_first_token_of_its_command_test() {
  let call =
    captured(fn() { job.start("deploy --password " <> secret <> " --now") })
  assert call.0 == "job.start"
  assert summary(call) == Some("deploy")
  never_contains(record_text(call), [secret, "--password"])

  let session =
    captured(fn() { job.start_for_session("watch --token " <> secret) })
  assert summary(session) == Some("watch")
  never_contains(record_text(session), [secret])
}

pub fn a_job_start_skips_inline_assignments_test() {
  let one = captured(fn() { job.start("API_KEY=" <> secret <> " ./deploy") })
  assert summary(one) == Some("./deploy")
  never_contains(record_text(one), [secret, "API_KEY"])

  let two = captured(fn() { job.start("A=1 B=2 make") })
  assert summary(two) == Some("make")

  let only = captured(fn() { job.start("X=" <> secret) })
  assert only.0 == "job.start"
  assert summary(only) == None
  never_contains(record_text(only), [secret, "X="])
}

pub fn job_calls_summarise_to_their_job_id_only_test() {
  let assert Ok(id) = job.parse_job_id("job-one")
  let poll = captured(fn() { job.poll(id, 0, job.from_start()) })
  assert poll.0 == "job.poll"
  assert summary(poll) == Some("job-one")

  let kill = captured(fn() { job.kill(id) })
  assert kill.0 == "job.kill"
  assert summary(kill) == Some("job-one")

  let send = captured(fn() { job.send(id, <<secret:utf8>>) })
  assert send.0 == "job.send"
  assert summary(send) == Some("job-one")
  never_contains(record_text(send), [secret])
}

pub fn a_capability_off_the_allowlist_has_no_summary_test() {
  let list = captured(fn() { job.list() })
  assert list.0 == "job.list"
  assert summary(list) == None
}
