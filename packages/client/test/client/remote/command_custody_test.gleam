//// Supervised owner custody exposes only bounded complete service/offer asks.
//// Reopen and racing cancellation operate against the real SQLite journal.

import client/remote/custodian
import core/clock
import core/command
import core/ids
import core/remote_tool
import core/workspace
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import simplifile
import sqlight
import storage/owner_custody as custody
import weft/registry

fn parent() -> remote_tool.ToolKey {
  let generator = ids.generator(clock.fixed(1000), 77)
  let #(session, generator) = ids.mint_session(generator)
  let #(operation, generator) = ids.mint_op(generator)
  let #(entry, _) = ids.mint_entry(generator)
  let assert Ok(parent) =
    remote_tool.key(
      session,
      operation,
      "parent",
      2,
      string.repeat("a", 64),
      entry,
    )
    as "Complete original runtime provenance validates."
  parent
}

fn id(seed: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(2000), seed)).0
}

fn service() -> command.ServiceKey {
  let parent = parent()
  let assert Ok(scope) =
    workspace.scope_from_fields(
      ids.session_id_to_string(remote_tool.session(parent)),
      "repo",
      "executor",
      2,
      3,
    )
    as "The immutable scope validates."
  let assert Ok(step) = workspace.step("compile:physical")
    as "The derived physical step validates."
  let assert Ok(key) =
    command.service_key(
      parent,
      command.CompileService,
      scope,
      remote_tool.operation(parent),
      step,
      id(1),
      string.repeat("a", 64),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "The exact original Compile service validates."
  key
}

fn ref() -> command.CommandRef {
  let assert Ok(ref) = command.command_ref(service(), command.CompileCommand)
    as "The fixed outer/native pair agrees."
  ref
}

fn limits() -> custody.Limits {
  let assert Ok(limits) = custody.limits(4, 32, 1_048_576, 4096)
    as "Persisted fixture bounds validate."
  limits
}

fn offer(text: String) -> custody.CommandOfferPayload {
  let assert Ok(offer) =
    custody.command_offer_payload(
      limits(),
      ref(),
      string.repeat("d", 64),
      bit_array.from_string(text),
    )
    as "Bounded immutable proposal validates before the mailbox."
  offer
}

fn fixture(name: String) {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let directory =
    "/private/tmp/loom-command-custodian-"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory_all(directory) == Ok(Nil)
  let path = directory <> "/owner.db"
  let assert Ok(store) =
    custody.open(path, remote_tool.session(parent()), limits())
    as "Fixture seeds actual SQLite parent custody."
  let assert Ok(payload) = custody.payload(limits(), <<"parent":utf8>>)
    as "Parent content is bounded."
  assert custody.admit(store, parent(), payload, payload) == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(names) = registry.start()
    as "Fixture registry owns the stable custodian address."
  let assert Ok(config) =
    custodian.config(
      path,
      remote_tool.session(parent()),
      limits(),
      1,
      5000,
      fn(_, _, _) {
        panic as "Child custody cannot run a tool or launch a command."
      },
    )
    as "Finite actor configuration validates."
  let owner = custodian.new(names, config)
  let assert Ok(started) = custodian.start(owner, config)
    as "The real actor reopens the journal."
  #(owner, config, started.pid, path)
}

fn stop(owner: custodian.Handle, pid: process.Pid) {
  let monitor = process.monitor(pid)
  assert custodian.stop(owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "The old SQLite handle is closed before reopen."
  Nil
}

pub fn actor_reopen_preserves_exact_service_offer_and_original_native_uuid_test() {
  let #(owner, config, pid, _path) = fixture("reopen")
  let assert Ok(original) =
    custodian.reserve_service_child(owner, service(), <<
      "exact service input":utf8,
    >>)
    as "Complete original service custody precedes any hypothetical send."
  assert custodian.admit_offer(owner, original, offer("exact command"))
    == Ok(custody.Fresh)
  assert custodian.reserve_command_child(
      owner,
      offer("changed command"),
      id(2),
      <<"complete Prepared":utf8>>,
    )
    == Error(custody.Conflict)
  assert custodian.child(owner, command.native_origin(ref()))
    == Error(custody.Missing)
  let assert Ok(#(native_id, native)) =
    custodian.reserve_command_child(owner, offer("exact command"), id(2), <<
      "complete Prepared":utf8,
    >>)
    as "Only complete native content receives a UUID reservation."
  assert native_id == id(2)
  assert custody.bytes(native) == <<"complete Prepared":utf8>>
  assert custodian.reserve_command_child(owner, offer("exact command"), id(3), <<
      "complete Prepared":utf8,
    >>)
    == Ok(#(id(2), native))
  stop(owner, pid)
  let assert Ok(started) = custodian.start(owner, config)
    as "The new actor recovers only retained evidence."
  assert custodian.service_child(owner, service()) == Ok(#(original, None))
  assert custodian.offer(owner, ref()) == Ok(offer("exact command"))
  assert custodian.command_offer_for_origin(owner, command.native_origin(ref()))
    == Ok(offer("exact command"))
  assert custodian.command_child(owner, ref()) == Ok(#(id(2), native, None))
  assert custodian.cancel_service(owner, service()) == Ok(Nil)
  assert custodian.command_offer_for_origin(owner, command.native_origin(ref()))
    == Ok(offer("exact command"))
  assert custodian.reserve_command_child(owner, offer("exact command"), id(3), <<
      "complete Prepared":utf8,
    >>)
    == Error(custody.Frozen)
  assert custodian.receive_child(owner, command.native_origin(ref()), id(2), <<
      "late terminal":utf8,
    >>)
    == Ok(Nil)
  let assert Ok(#(same, _, Some(receipt))) =
    custodian.command_child(owner, ref())
    as "Cancellation still reconciles the original native receipt."
  assert same == id(2)
  assert custody.bytes(receipt) == <<"late terminal":utf8>>
  stop(owner, started.pid)
}

pub fn actor_cancel_races_native_reservation_without_replacement_or_partial_content_test() {
  let #(owner, _, pid, _path) = fixture("cancel-race")
  let assert Ok(original) =
    custodian.reserve_service_child(owner, service(), <<
      "exact service input":utf8,
    >>)
    as "Original service is retained."
  assert custodian.admit_offer(owner, original, offer("exact command"))
    == Ok(custody.Fresh)
  let reservation = process.new_subject()
  let cancellation = process.new_subject()
  let _reserve =
    process.spawn_unlinked(fn() {
      process.send(
        reservation,
        custodian.reserve_command_child(owner, offer("exact command"), id(2), <<
          "complete Prepared":utf8,
        >>),
      )
    })
  let _cancel =
    process.spawn_unlinked(fn() {
      process.send(cancellation, custodian.cancel_service(owner, service()))
    })
  assert process.receive(cancellation, 2000) == Ok(Ok(Nil))
  let assert Ok(reserved) = process.receive(reservation, 2000)
    as "Each bounded actor ask returns its atomic disposition."
  case reserved {
    Error(custody.Frozen) -> {
      assert custodian.child(owner, command.native_origin(ref()))
        == Error(custody.Missing)
    }
    Ok(#(original_id, payload)) -> {
      assert original_id == id(2)
      assert custody.bytes(payload) == <<"complete Prepared":utf8>>
      assert custodian.command_child(owner, ref())
        == Ok(#(id(2), payload, None))
    }
    Error(_) ->
      panic as "The serialized cancellation race has only its before/after outcomes."
  }
  assert custodian.reserve_command_child(owner, offer("exact command"), id(3), <<
      "complete Prepared":utf8,
    >>)
    == Error(custody.Frozen)
  assert custodian.cancel_service(owner, service()) == Ok(Nil)
  stop(owner, pid)
}

pub fn actor_input_bounds_refuse_before_unavailable_mailbox_test() {
  let #(owner, _, pid, _path) = fixture("bounds")
  let assert Ok(original) =
    custodian.reserve_service_child(owner, service(), <<"input":utf8>>)
    as "Original identity is retained."
  let assert Ok(large_limits) = custody.limits(4, 32, 1_048_576, 262_144)
    as "A larger caller quota is independently valid."
  let assert Ok(oversized) =
    custody.command_offer_payload(
      large_limits,
      ref(),
      string.repeat("d", 64),
      bit_array.from_string(string.repeat("x", 4097)),
    )
    as "A caller cannot enlarge the owner's configured mailbox bound."
  stop(owner, pid)
  assert custodian.admit_offer(owner, original, oversized)
    == Error(custody.Capacity)
  assert custodian.reserve_command_child(
      owner,
      offer("exact command"),
      id(2),
      bit_array.from_string(string.repeat("x", 4097)),
    )
    == Error(custody.Capacity)
}

pub fn old_owner_format_refuses_missing_run_discharge_proof_test() {
  let #(owner, _, pid, path) = fixture("old-format")
  let assert Ok(_) =
    custodian.reserve_service_child(owner, service(), <<
      "exact service input":utf8,
    >>)
    as "The prior format may contain unfinished service custody."
  stop(owner, pid)
  let assert Ok(db) = sqlight.open(path) as "The fixture owns this journal."
  assert sqlight.exec("PRAGMA user_version=2", db) == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  assert custody.open(path, remote_tool.session(parent()), limits())
    == Error(custody.Invalid("unsupported owner custody database"))
}

pub fn actor_cancel_races_offer_admission_and_never_allocates_native_uuid_test() {
  let #(owner, _, pid, _path) = fixture("offer-cancel-race")
  let assert Ok(original) =
    custodian.reserve_service_child(owner, service(), <<
      "exact service input":utf8,
    >>)
    as "Original service is retained before either racing ask."
  let admitted = process.new_subject()
  let cancelled = process.new_subject()
  let _a =
    process.spawn_unlinked(fn() {
      process.send(
        admitted,
        custodian.admit_offer(owner, original, offer("exact command")),
      )
    })
  let _b =
    process.spawn_unlinked(fn() {
      process.send(cancelled, custodian.cancel_service(owner, service()))
    })
  assert process.receive(cancelled, 2000) == Ok(Ok(Nil))
  let assert Ok(outcome) = process.receive(admitted, 2000)
    as "Offer reservation returns an atomic disposition."
  case outcome {
    Ok(custody.Fresh) | Error(custody.Frozen) -> Nil
    Ok(custody.Retained) | Error(_) ->
      panic as "The first offer has only before/after cancellation outcomes."
  }
  assert custodian.offer(owner, ref()) == Error(custody.Frozen)
  assert custodian.child(owner, command.native_origin(ref()))
    == Error(custody.Missing)
  assert custodian.reserve_command_child(owner, offer("exact command"), id(2), <<
      "complete Prepared":utf8,
    >>)
    == Error(custody.Frozen)
  stop(owner, pid)
}

pub fn indexed_offer_actor_missing_wrong_role_and_unavailable_are_distinct_test() {
  let #(owner, _, pid, _path) = fixture("indexed-missing")
  assert custodian.command_offer_for_origin(owner, command.native_origin(ref()))
    == Error(custody.Missing)
  assert custodian.command_offer_for_origin(
      owner,
      command.service_origin(service()),
    )
    == Error(custody.Invalid("origin is not a physical command"))
  stop(owner, pid)
  let assert Error(custody.Unavailable(_)) =
    custodian.command_offer_for_origin(owner, command.native_origin(ref()))
    as "Lost actor addressing cannot invent Missing historical evidence."
}
