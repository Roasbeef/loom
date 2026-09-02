//// The workspace seam's harness-side router: what an `fs.*`, `kv.*` or
//// `report.emit` frame becomes, what the injected closure is asked, what
//// comes back, and what the seam refuses.
////
//// These drive `workspace.routing` directly, against scripted closures,
//// because everything worth proving *here* is carriage — the arguments a
//// call arrives with, the shape of the answer, and the code a refusal
//// keeps. The closures themselves are `client/codemode`'s and are tested
//// against a real temporary workspace on that side
//// (`client/test/client/codemode_test.gleam`), which is where the
//// containment claim belongs: it is `tools/fs.resolve_real`'s, and a
//// scripted closure could only prove that this module forwards it.
////
//// The emit ceiling is at the bottom, driven through the real satellite
//// host and a real in-process peer, because a ceiling is the *host's* and
//// a test of the router alone could not see it.

import broker/broker
import broker/budget
import broker/exec
import broker/framing
import broker/policy
import broker/token
import codemode/artifact
import codemode/compile
import codemode/identity.{type PhaseIdentity}
import codemode/internal/args
import codemode/satellite
import codemode/workspace
import core/clock
import core/ids
import core/msgpack.{type MsgPackValue}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import support/fake_helper
import support/satellite_peer.{type PeerCtx}
import tools/fs
import tools/tool

const t = 1_700_000_000_000

// --- the scripted seam -------------------------------------------------------

// What the scripted closures were asked, in order, so a test can prove
// that a refused call never reached one.
type Seen {
  ReadAsked(path: String)
  ListAsked(path: String)
  GetAsked(key: String)
  SetAsked(key: String, bytes: Int)
  DeleteAsked(key: String)
  EmitAsked(name: String, bytes: Int)
  WriteAsked(path: String, contents: String)
  EditAsked(path: String, edits: Int)
  ScheduleCreateAsked(name: String)
  ScheduleListAsked
  ScheduleCancelAsked(name: String)
}

const file_contents = "the file's own bytes\n"

const emitted_id = "sha256-4c5f2a"

fn recorder() -> Subject(Seen) {
  process.new_subject()
}

fn drain(seen: Subject(Seen)) -> List(Seen) {
  case process.receive(seen, within: 0) {
    Error(Nil) -> []
    Ok(one) -> [one, ..drain(seen)]
  }
}

// A seam whose every closure succeeds, recording what it was asked. The
// answers are fixed values: what this suite is about is the wire shape
// they come back in.
fn answering(seen: Subject(Seen)) -> workspace.Workspace {
  workspace.Workspace(
    fs_read: fn(path) {
      process.send(seen, ReadAsked(path))
      Ok(file_contents)
    },
    fs_list: fn(path) {
      process.send(seen, ListAsked(path))
      Ok([
        workspace.DirEntry(name: "src", is_directory: True),
        workspace.DirEntry(name: "gleam.toml", is_directory: False),
      ])
    },
    kv_get: fn(key) {
      process.send(seen, GetAsked(key))
      case key {
        "absent" -> Ok(None)
        _ -> Ok(Some(<<"stored":utf8>>))
      }
    },
    kv_set: fn(key, value) {
      process.send(seen, SetAsked(key, bit_array.byte_size(value)))
      Ok(Nil)
    },
    kv_delete: fn(key) {
      process.send(seen, DeleteAsked(key))
      Ok(Nil)
    },
    fs_write: fn(path, contents) {
      process.send(seen, WriteAsked(path, contents))
      Ok(Nil)
    },
    fs_edit: fn(path, edits) {
      process.send(seen, EditAsked(path, list.length(edits)))
      Ok(Nil)
    },
    emit: fn(art: artifact.Artifact) {
      process.send(seen, EmitAsked(art.name, bit_array.byte_size(art.bytes)))
      Ok(emitted_id)
    },
    schedule_create: fn(request: workspace.ScheduleRequest) {
      process.send(seen, ScheduleCreateAsked(request.name))
      Ok(workspace.ScheduleCreated(
        name: request.name,
        // The host resolves an absent target to the execution's own
        // strand; this fake stands in for the one the bridge binds.
        target: option.unwrap(request.target, "main"),
        when: "every 60s, at most 1000 times",
        wake: request.wake,
      ))
    },
    schedule_list: fn() {
      process.send(seen, ScheduleListAsked)
      Ok([
        workspace.ScheduleRow(
          name: "poll",
          target: "main",
          when: "every 60s, at most 1000 times",
          wake: workspace.WakesIdle,
          fired: 2,
          body: "look",
        ),
      ])
    },
    schedule_cancel: fn(name, _target) {
      process.send(seen, ScheduleCancelAsked(name))
      Ok(Nil)
    },
    emit_ceiling: artifact.default_emit_ceiling,
  )
}

// A seam whose every closure refuses, with the refusal each arm is meant
// to translate.
fn refusing(refusal: workspace.FsRefusal) -> workspace.Workspace {
  let seen = recorder()
  workspace.Workspace(
    ..answering(seen),
    fs_read: fn(_path) { Error(refusal) },
    fs_list: fn(_path) { Error(refusal) },
  )
}

// The router under test, over an inner arm that records nothing and
// answers a distinctive refusal, so "handed down untouched" is provable
// rather than indistinguishable from "refused here".
const passed_through = "reached_the_inner_router"

fn routed(seam: workspace.Workspace) -> satellite.CapRouter {
  workspace.routing(seam, over: fn(request: satellite.CapRequest) {
    Error(satellite.CapDenial(code: passed_through, message: request.cap))
  })
}

// Routes one call and runs the plan it produced, which is what the host's
// worker process does.
fn serviced(
  seam: workspace.Workspace,
  cap: String,
  args: MsgPackValue,
) -> framing.CapOutcome {
  let assert Ok(satellite.ServedHere(serve:)) = routed(seam)(request(cap, args))
    as { "the workspace router must service " <> cap }
  serve()
}

fn refused(
  seam: workspace.Workspace,
  cap: String,
  args: MsgPackValue,
) -> satellite.CapDenial {
  let assert Error(denial) = routed(seam)(request(cap, args))
    as { "the workspace router must refuse " <> cap }
  denial
}

fn request(cap: String, args: MsgPackValue) -> satellite.CapRequest {
  satellite.CapRequest(
    cap:,
    args:,
    identity: phase(),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    ordinal: 0,
  )
}

fn phase() -> PhaseIdentity {
  let generator = ids.generator(clock.fixed(at: t), seed: 23)
  let #(op, generator) = ids.mint_op(generator)
  let #(entry, _generator) = ids.mint_entry(generator)
  identity.run_phase(identity.for_execution(
    op_id: op,
    step_id: ids.entry_id_to_string(entry),
    budget: budget.Budget(max_outstanding: 8, deadline_ms: t + 60_000),
  ))
}

fn map(fields: List(#(String, MsgPackValue))) -> MsgPackValue {
  msgpack.MapValue(
    list.map(fields, fn(field) { #(msgpack.StringValue(field.0), field.1) }),
  )
}

fn text(value: String) -> MsgPackValue {
  msgpack.StringValue(value)
}

fn int(value: Int) -> MsgPackValue {
  msgpack.IntValue(value)
}

fn field(value: MsgPackValue, key: String) -> Result(MsgPackValue, Nil) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    _other -> Error(Nil)
  }
}

// --- what the arms answer ----------------------------------------------------

pub fn a_read_answers_the_contents_field_test() {
  // `cap/fs.read` reads exactly `contents` back out and refuses anything
  // else as `bad fs.read result`, so the field name is the contract.
  let seen = recorder()
  let assert framing.CapOk(value:) =
    serviced(answering(seen), "fs.read", map([#("path", text("src/a.gleam"))]))
    as "a well-formed read is serviced"
  assert field(value, "contents") == Ok(text(file_contents))
  assert drain(seen) == [ReadAsked("src/a.gleam")]
}

pub fn a_list_answers_entries_of_name_and_is_dir_test() {
  // `cap/fs.decode_entry` reads `name` and `is_dir` — not `is_directory`,
  // which is what the Gleam-side record calls the same field. The wire
  // name is the contract and the two differ on purpose.
  let seen = recorder()
  let assert framing.CapOk(value:) =
    serviced(answering(seen), "fs.list", map([#("path", text("src"))]))
    as "a well-formed list is serviced"
  let assert Ok(msgpack.ArrayValue(items:)) = field(value, "entries")
    as "a listing answers an array of entries"
  assert list.map(items, fn(entry) { field(entry, "name") })
    == [Ok(text("src")), Ok(text("gleam.toml"))]
  assert list.map(items, fn(entry) { field(entry, "is_dir") })
    == [Ok(msgpack.BoolValue(True)), Ok(msgpack.BoolValue(False))]
  assert drain(seen) == [ListAsked("src")]
}

pub fn a_present_key_answers_found_and_value_test() {
  let seen = recorder()
  let assert framing.CapOk(value:) =
    serviced(answering(seen), "kv.get", map([#("key", text("k"))]))
    as "a well-formed get is serviced"
  assert field(value, "found") == Ok(msgpack.BoolValue(True))
  assert field(value, "value") == Ok(msgpack.BinaryValue(<<"stored":utf8>>))
  assert drain(seen) == [GetAsked("k")]
}

pub fn an_absent_key_answers_found_false_and_no_value_test() {
  // Absence is `Ok(None)` to a program, never an error: `cap/kv.get`
  // reads `found` first and only then the bytes, so an absent key must
  // answer the flag and may answer nothing else.
  let seen = recorder()
  let assert framing.CapOk(value:) =
    serviced(answering(seen), "kv.get", map([#("key", text("absent"))]))
    as "an absent key is still a serviced call"
  assert field(value, "found") == Ok(msgpack.BoolValue(False))
  assert field(value, "value") == Error(Nil)
  assert drain(seen) == [GetAsked("absent")]
}

pub fn a_set_carries_the_bytes_and_answers_empty_test() {
  let seen = recorder()
  let assert framing.CapOk(value:) =
    serviced(
      answering(seen),
      "kv.set",
      map([
        #("key", text("k")),
        #("value", msgpack.BinaryValue(<<"twelve bytes":utf8>>)),
      ]),
    )
    as "a well-formed set is serviced"
  assert value == msgpack.MapValue([])
  assert drain(seen) == [SetAsked("k", 12)]
}

pub fn a_delete_is_serviced_and_answers_empty_test() {
  let seen = recorder()
  let assert framing.CapOk(value:) =
    serviced(answering(seen), "kv.delete", map([#("key", text("k"))]))
    as "a well-formed delete is serviced"
  assert value == msgpack.MapValue([])
  assert drain(seen) == [DeleteAsked("k")]
}

pub fn an_emit_answers_the_id_field_test() {
  let seen = recorder()
  let assert framing.CapOk(value:) =
    serviced(answering(seen), "report.emit", emit_args("out.txt", "hello"))
    as "a well-formed emit is serviced"
  assert field(value, "id") == Ok(text(emitted_id))
  assert drain(seen) == [EmitAsked("out.txt", 5)]
}

// `count` zero bytes, built by doubling rather than by a bit-array size
// expression: a segment size computed from a constant needs Gleam 1.12
// and this package's `gleam.toml` admits 1.18.
fn zeros(count: Int) -> BitArray {
  grow(<<0>>, count)
}

fn grow(so_far: BitArray, want: Int) -> BitArray {
  let have = bit_array.byte_size(so_far)
  case have >= want {
    True -> bit_array.slice(so_far, 0, want) |> result.unwrap(so_far)
    False -> grow(bit_array.append(so_far, so_far), want)
  }
}

fn emit_args(name: String, body: String) -> MsgPackValue {
  map([
    #("name", text(name)),
    #("content_type", text("text/plain")),
    #("bytes", msgpack.BinaryValue(<<body:utf8>>)),
  ])
}

// --- what the arms refuse ----------------------------------------------------

pub fn a_missing_argument_is_invalid_in_band_test() {
  // Refused at *plan* time, before any closure runs: a call that cannot
  // be decoded has nothing to ask anybody.
  let seen = recorder()
  let seam = answering(seen)
  list.each(
    [
      #("fs.read", map([])),
      #("fs.list", map([])),
      #("kv.get", map([])),
      #("kv.set", map([#("key", text("k"))])),
      #("kv.delete", map([])),
      #("report.emit", map([#("name", text("a"))])),
    ],
    fn(row) {
      let denial = refused(seam, row.0, row.1)
      assert denial.code == workspace.invalid_argument_code
      assert string.contains(denial.message, "is missing")
    },
  )
  assert drain(seen) == []
}

pub fn a_wrong_typed_argument_is_invalid_in_band_test() {
  let seen = recorder()
  let seam = answering(seen)
  let denial = refused(seam, "fs.read", map([#("path", msgpack.IntValue(7))]))
  assert denial.code == workspace.invalid_argument_code
  assert string.contains(denial.message, "must be text")
  let bad_value =
    refused(
      seam,
      "kv.set",
      map([#("key", text("k")), #("value", msgpack.IntValue(7))]),
    )
  assert bad_value.code == workspace.invalid_argument_code
  assert string.contains(bad_value.message, "must be bytes or text")
  assert drain(seen) == []
}

pub fn arguments_that_are_not_a_map_are_invalid_test() {
  let seen = recorder()
  let denial = refused(answering(seen), "fs.read", msgpack.IntValue(1))
  assert denial.code == workspace.invalid_argument_code
  assert string.contains(denial.message, "must be a map")
  assert drain(seen) == []
}

pub fn a_path_outside_the_workspace_keeps_the_tools_own_vocabulary_test() {
  // The router does not decide containment and does not word it: the
  // decision is `tools/fs.resolve_real`'s, the sentence is the harness's
  // own, and the code is the one `cap/fs.map_error` turns back into
  // `PermissionDenied` so a program can branch on it.
  let assert framing.CapErr(code:, message:) =
    serviced(
      refusing(workspace.PathRefused(fs.EscapesWorkspace(path: "../etc"))),
      "fs.read",
      map([#("path", text("../etc"))]),
    )
    as "a contained path is refused in band, not at plan time"
  assert code == workspace.permission_denied_code
  assert string.contains(message, "../etc")
  assert string.contains(message, "outside the workspace root")
}

pub fn each_read_refusal_keeps_its_own_code_test() {
  // The whole table at once, because what matters is the
  // *correspondence*: a code `cap/fs` does not decode arrives as the
  // catch-all, so a row wired to the wrong one is a named variant a
  // program silently stops seeing.
  let rows = [
    #(workspace.PathRefused(fs.EmptyPath), workspace.invalid_argument_code),
    #(
      workspace.PathRefused(fs.EscapesWorkspace(path: "x")),
      workspace.permission_denied_code,
    ),
    #(
      workspace.PathRefused(fs.ProtectedPath(path: "x", protected: ".git")),
      workspace.permission_denied_code,
    ),
    #(
      workspace.PathRefused(fs.Unresolvable(path: "x", reason: "loop")),
      workspace.unresolvable_code,
    ),
    #(
      workspace.ReadRefused(fs.ReadFailed(tool.FsNotFound(path: "x"))),
      workspace.not_found_code,
    ),
    #(
      workspace.ReadRefused(fs.ReadFailed(tool.FsPermissionDenied(path: "x"))),
      workspace.permission_denied_code,
    ),
    #(
      workspace.ReadRefused(
        fs.ReadFailed(tool.FsFailure(path: "x", reason: "eio")),
      ),
      workspace.fs_failure_code,
    ),
    #(
      workspace.ReadRefused(fs.TooLarge(size: 9, limit: 8)),
      workspace.too_large_code,
    ),
    #(workspace.ReadRefused(fs.NotText), workspace.wrong_kind_code),
    #(
      workspace.ListRefused(tool.FsNotFound(path: "x")),
      workspace.not_found_code,
    ),
    #(
      workspace.TooManyEntries(count: 5000, limit: 4096),
      workspace.too_large_code,
    ),
  ]
  list.each(rows, fn(row) {
    assert workspace.fs_denial(row.0).code == row.1
    // Every refusal says something: a code with an empty sentence is a
    // program told only that it failed.
    assert workspace.fs_denial(row.0).message != ""
  })
}

pub fn a_scratch_refusal_keeps_its_own_code_test() {
  let too_large = workspace.kv_denial(workspace.EntryTooLarge(9, 8))
  assert too_large.code == workspace.too_large_code
  assert string.contains(too_large.message, "9")
  assert string.contains(too_large.message, "8")
  let gone = workspace.kv_denial(workspace.StoreUnavailable("wedged"))
  assert gone.code == workspace.kv_unavailable_code
  assert gone.message == "wedged"
}

pub fn an_oversized_artifact_is_refused_before_the_store_test() {
  // Refused at plan time, so a megabyte-plus payload costs no process and
  // no store round trip — and the closure is never asked, which is what
  // the empty drain proves.
  let seen = recorder()
  let oversized = zeros(artifact.max_emit_bytes + 1)
  let denial =
    refused(
      answering(seen),
      "report.emit",
      map([
        #("name", text("big")),
        #("content_type", text("application/octet-stream")),
        #("bytes", msgpack.BinaryValue(oversized)),
      ]),
    )
  assert denial.code == artifact.too_large_code
  assert string.contains(denial.message, int.to_string(artifact.max_emit_bytes))
  assert drain(seen) == []
}

pub fn an_artifact_at_the_bound_is_serviced_test() {
  // The bound is inclusive: exactly `max_emit_bytes` is admitted, and one
  // byte more is not. An off-by-one here is a refusal a program cannot
  // see the edge of.
  let seen = recorder()
  let at_bound = zeros(artifact.max_emit_bytes)
  let assert framing.CapOk(..) =
    serviced(
      answering(seen),
      "report.emit",
      map([
        #("name", text("exact")),
        #("content_type", text("application/octet-stream")),
        #("bytes", msgpack.BinaryValue(at_bound)),
      ]),
    )
    as "an artifact of exactly the bound is serviced"
  assert drain(seen) == [EmitAsked("exact", artifact.max_emit_bytes)]
}

pub fn a_store_failure_is_in_band_and_named_test() {
  let seen = recorder()
  let seam =
    workspace.Workspace(..answering(seen), emit: fn(_art) {
      Error(artifact.StoreFailed(reason: "the disk is full"))
    })
  let assert framing.CapErr(code:, message:) =
    serviced(seam, "report.emit", emit_args("out.txt", "hello"))
    as "a store failure settles in band"
  assert code == artifact.store_failed_code
  assert message == "the disk is full"
}

// --- what this seam does not service ------------------------------------------

pub fn a_write_routes_to_the_closure_with_both_arguments_test() {
  let seen = recorder()
  let assert framing.CapOk(..) =
    serviced(
      answering(seen),
      "fs.write",
      map([#("path", text("out.txt")), #("contents", text("hello"))]),
    )
    as "a well-formed write is serviced"
  assert drain(seen) == [WriteAsked("out.txt", "hello")]
}

pub fn an_edit_routes_with_the_decoded_replacements_test() {
  let seen = recorder()
  let assert framing.CapOk(..) =
    serviced(answering(seen), "fs.edit", well_formed("fs.edit"))
    as "a well-formed edit is serviced"
  assert drain(seen) == [EditAsked("out.txt", 1)]
}

pub fn an_empty_edit_list_is_refused_at_plan_time_test() {
  // An edit that edits nothing is a mistake to repair, not a success to
  // fake — and it is refused before any closure runs.
  let seen = recorder()
  let denial =
    refused(
      answering(seen),
      "fs.edit",
      map([#("path", text("a")), #("edits", msgpack.ArrayValue([]))]),
    )
  assert denial.code == workspace.invalid_argument_code
  assert drain(seen) == []
}

// --- the edit semantics --------------------------------------------------------
//
// `apply_replacements` is the whole of the fs.edit ruling, pure, so the
// corpus lives here and every host inherits it.

pub fn a_single_replacement_applies_test() {
  let edits = [workspace.Replacement(find: "old", replace_with: "new")]
  assert workspace.apply_replacements("one old line", edits)
    == Ok("one new line")
}

pub fn replacements_apply_in_order_against_the_current_text_test() {
  // The second find only exists because the first replacement created
  // it: sequential application is the stated contract.
  let edits = [
    workspace.Replacement(find: "a", replace_with: "b"),
    workspace.Replacement(find: "bb", replace_with: "c"),
  ]
  assert workspace.apply_replacements("ab", edits) == Ok("c")
}

pub fn a_missed_find_is_stale_and_applies_nothing_test() {
  let edits = [
    workspace.Replacement(find: "present", replace_with: "changed"),
    workspace.Replacement(find: "absent", replace_with: "x"),
  ]
  assert workspace.apply_replacements("present", edits)
    == Error(workspace.StaleFind(find: "absent"))
}

pub fn an_ambiguous_find_is_refused_with_its_count_test() {
  let edits = [workspace.Replacement(find: "a", replace_with: "b")]
  assert workspace.apply_replacements("a a a", edits)
    == Error(workspace.AmbiguousFind(find: "a", count: 3))
}

pub fn an_overlapping_find_counts_non_overlapping_matches_test() {
  // The one place the count and the replacement could have disagreed.
  // "aa" occurs twice in "aaa" if occurrences may overlap and once if
  // they may not, and `string.replace` takes the non-overlapping
  // reading — so a counter that overlapped would refuse as ambiguous an
  // edit `string.replace` would then apply unambiguously, or worse,
  // admit one it would apply twice. Counting by `string.split` is the
  // same non-overlapping scan `string.replace` performs, which is why
  // the two agree by construction rather than by luck.
  //
  // "aaa": one non-overlapping match, so the edit applies and consumes
  // the first two characters.
  let edits = [workspace.Replacement(find: "aa", replace_with: "X")]
  assert workspace.apply_replacements("aaa", edits) == Ok("Xa")
}

pub fn an_overlapping_find_with_two_matches_is_ambiguous_test() {
  // "aaaa": two non-overlapping matches, refused rather than replaced,
  // and the count a program reads is the non-overlapping one — three,
  // the overlapping count, would name occurrences the replacement would
  // never have touched.
  let edits = [workspace.Replacement(find: "aa", replace_with: "X")]
  assert workspace.apply_replacements("aaaa", edits)
    == Error(workspace.AmbiguousFind(find: "aa", count: 2))
}

pub fn an_empty_find_is_refused_test() {
  let edits = [workspace.Replacement(find: "", replace_with: "b")]
  assert workspace.apply_replacements("text", edits)
    == Error(workspace.EmptyFind)
}

pub fn a_stale_find_travels_as_stale_content_test() {
  // The other half of the contract is `cap/fs.map_error`, which turns
  // this code back into `StaleContent` — the variant whose honest
  // meaning the module doc's ruling pinned.
  let denial =
    workspace.fs_denial(
      workspace.EditRefused(workspace.StaleFind(find: "gone")),
    )
  assert denial.code == workspace.stale_content_code
  assert string.contains(denial.message, "gone")
}

pub fn an_ambiguous_find_travels_as_invalid_argument_test() {
  let denial =
    workspace.fs_denial(
      workspace.EditRefused(workspace.AmbiguousFind(find: "x", count: 2)),
    )
  assert denial.code == workspace.invalid_argument_code
  assert string.contains(denial.message, "2")
}

pub fn a_long_find_is_excerpted_in_the_refusal_test() {
  // The find text is program-controlled and can be a whole file; the
  // sentence quoted back is bounded, the program has the full value.
  let long = string.repeat("y", 500)
  let denial =
    workspace.fs_denial(workspace.EditRefused(workspace.StaleFind(find: long)))
  assert string.length(denial.message) < 200
}

pub fn every_serviced_cap_routes_and_none_builds_a_clearance_test() {
  // Two properties in one walk. The list `serviced_caps` publishes — and
  // therefore the list the model reads in the tool description — is
  // exactly what the arms answer, which is what keeps the constants and
  // the string-literal patterns from drifting. And every plan is
  // `ServedHere`: a router that builds no `CallSpec` cannot state
  // coordinates at all, which is the `codemode/identity` boundary this
  // seam had to be shaped around.
  let seen = recorder()
  let served =
    list.map(workspace.serviced_caps, fn(cap) {
      case routed(answering(seen))(request(cap, well_formed(cap))) {
        Ok(satellite.ServedHere(..)) -> True
        Ok(satellite.ClearedCall(..)) -> False
        Error(_denial) -> False
      }
    })
  assert served == list.repeat(True, list.length(workspace.serviced_caps))
  assert list.length(workspace.serviced_caps) == 11
}

pub fn an_unrouted_cap_is_handed_to_the_inner_router_test() {
  // `proc.run` is `satellite.default_router`'s and `mcp.<server>` is
  // `client/mcp`'s; this arm must pass both down untouched rather than
  // refusing them, or wrapping the shipped table would take `proc.run`
  // away.
  let seen = recorder()
  list.each(["proc.run", "mcp.github", "strand.spawn", "net.request"], fn(cap) {
    let denial = refused(answering(seen), cap, map([]))
    assert denial.code == passed_through
    assert denial.message == cap
  })
  assert drain(seen) == []
}

fn well_formed(cap: String) -> MsgPackValue {
  case cap {
    "fs.read" | "fs.list" -> map([#("path", text("src"))])
    "fs.write" -> map([#("path", text("out.txt")), #("contents", text("x"))])
    "fs.edit" ->
      map([
        #("path", text("out.txt")),
        #(
          "edits",
          msgpack.ArrayValue([
            map([#("find", text("a")), #("replace_with", text("b"))]),
          ]),
        ),
      ])
    "kv.get" | "kv.delete" -> map([#("key", text("k"))])
    "schedule.create" ->
      map([
        #("name", text("poll")),
        #("body", text("look")),
        #("every_seconds", int(60)),
      ])
    "schedule.cancel" -> map([#("name", text("poll"))])
    "kv.set" ->
      map([#("key", text("k")), #("value", msgpack.BinaryValue(<<1, 2>>))])
    "report.emit" -> emit_args("out.txt", "hello")
    _other -> map([])
  }
}

// --- the ceilings -------------------------------------------------------------

pub fn the_only_workspace_ceiling_is_the_one_that_mints_test() {
  // `fs.read`, `fs.list` and `kv.*` carry none, and the absence is a
  // decision. Two are reads bounded by their own size guards; the scratch
  // store is bounded *store-side* by a byte cap with eviction, which is
  // the right instrument for something that must not grow rather than
  // something that must not be called often. `report.emit` is the one
  // call that writes something outliving the execution.
  let seen = recorder()
  let assert [only] = workspace.ceilings(answering(seen))
    as "the workspace seam declares exactly one ceiling"
  assert only.cap == artifact.emit_cap
  assert only.admissions == artifact.default_emit_ceiling
  assert only.code == artifact.emit_ceiling_code
}

pub fn the_emit_ceiling_is_the_seams_own_number_test() {
  // A seam may be configured with a different one, and the ceiling list
  // must read it off the seam rather than off the constant — a table that
  // ignored the field would silently serve the default to a host that
  // asked for something else.
  let seen = recorder()
  let assert [only] =
    workspace.ceilings(workspace.Workspace(..answering(seen), emit_ceiling: 3))
    as "the workspace seam declares exactly one ceiling"
  assert only.admissions == 3
}

// --- through the real host ----------------------------------------------------
//
// The ceiling is the host's, not the router's: one host is stood up per
// execution and holds the one identity a caller may mint, so a tally kept
// beside it is keyed to that execution by construction and a test of the
// router alone could not see it. A peer loops `report.emit` past a shrunk
// ceiling and reports what it was told.

const emit_ceiling = 3

pub fn a_loop_past_the_emit_ceiling_is_refused_at_the_ceiling_test() {
  let seen = recorder()
  let assert Ok(reported) =
    run_peer(
      fresh_dir("emit-ceiling"),
      answering(seen),
      [artifact.ceiling(emit_ceiling)],
      emitting_peer(emit_ceiling + 2),
    )
    as "the ceiling peer must report"
  // Admitted exactly `emit_ceiling` times, then refused — at the ceiling,
  // not before it and not one call late.
  assert list.length(reported) == emit_ceiling + 2
  assert list.take(reported, emit_ceiling) == list.repeat("ok", emit_ceiling)
  let refusals = list.drop(reported, emit_ceiling)
  list.each(refusals, fn(refusal) {
    assert string.starts_with(refusal, artifact.emit_ceiling_code <> "\n")
    // A program told only "refused" retries forever. It is told the
    // capability, the number, and that the bound is for the execution's
    // whole life.
    assert string.contains(refusal, artifact.emit_cap)
    assert string.contains(refusal, int.to_string(emit_ceiling))
    assert string.contains(refusal, "lifetime")
  })
  // And the closure saw exactly the admitted ones: a refused call never
  // reached the store at all, which is the whole point of a ceiling over
  // a capability that mints.
  assert list.length(drain(seen)) == emit_ceiling
}

// A peer that emits `attempts` times, reporting `"ok"` for each admission
// and `"{code}\n{message}"` for each refusal, in order.
fn emitting_peer(attempts: Int) -> fn(PeerCtx) -> Nil {
  fn(ctx: PeerCtx) {
    let reported =
      list.map(counting(attempts), fn(nth) {
        satellite_peer.send_cap_call(
          ctx,
          ctx.token,
          nth,
          "report.emit",
          emit_args("out-" <> int.to_string(nth) <> ".txt", "hello"),
        )
        case answer(ctx, nth) {
          Ok(framing.CapOk(..)) -> "ok"
          Ok(framing.CapErr(code:, message:)) -> code <> "\n" <> message
          Error(Nil) -> "no answer"
        }
      })
    satellite_peer.send_outcome(
      ctx,
      msgpack.ArrayValue(list.map(reported, msgpack.StringValue)),
    )
  }
}

// The one `cap_result` for call `id`. The peer sends one call and waits
// for its answer before sending the next, so each answer is a whole frame
// of its own and a fresh deframer per wait is enough.
fn answer(ctx: PeerCtx, id: Int) -> Result(framing.CapOutcome, Nil) {
  case satellite_peer.collect_results(ctx, 1, 3000) {
    [#(answered, outcome)] if answered == id -> Ok(outcome)
    _other -> Error(Nil)
  }
}

// Runs one peer against a real satellite host under the workspace router
// and the given ceilings, and reads the string list it reported.
fn run_peer(
  dir: String,
  seam: workspace.Workspace,
  ceilings: List(satellite.CapCeiling),
  script: fn(PeerCtx) -> Nil,
) -> Result(List(String), String) {
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: t),
        checkout: fn() { Ok(fake_helper.start_helper(fake_helper.EchoNow)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the broker must start"
  let run =
    satellite.run(
      compile.Artifact(
        build_root: dir,
        beam_dir: dir <> "/ebin",
        entry_module: "loom_satellite",
        manifest_hash: "test",
      ),
      phase(),
      broker_actor,
      satellite.SatelliteConfig(
        base_policy: policy.workspace_default("/work"),
        demand: exec.BestEffort,
        env: [#("PATH", "/usr/bin")],
        cwd: "/work",
        cap_socket_path: dir <> "/sock",
        entropy: token.production_entropy(),
        clock: clock.fixed(at: t),
        write_token_file: satellite.private_token_writer(dir),
        unlink_token_file: satellite.unlink_token_file,
        router: workspace.routing(seam, over: satellite.default_router),
        ceilings:,
        call_timeout_ms: 3000,
      ),
      satellite_peer.launcher(script),
    )
  broker.stop(broker_actor)
  case run.outcome {
    Error(_error) -> Error("the satellite did not report an outcome")
    Ok(satellite.Errored(message:, details: _)) -> Error(message)
    Ok(satellite.Completed(value: msgpack.ArrayValue(items:))) ->
      Ok(
        list.filter_map(items, fn(item) {
          case item {
            msgpack.StringValue(reported) -> Ok(reported)
            _other -> Error(Nil)
          }
        }),
      )
    Ok(satellite.Completed(value: _other)) ->
      Error("the peer reported something other than a list")
  }
}

// `[1, …, attempts]`. `int.range` counts towards `to` without reaching
// it, so counting down and prepending yields the ascending list.
fn counting(attempts: Int) -> List(Int) {
  int.range(from: attempts, to: 0, with: [], run: list.prepend)
}

fn fresh_dir(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  let dir = here <> "/build/cmtest/workspace-" <> name
  let _cleared = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
    as "the test directory must be creatable"
  dir
}

// --- schedule ---------------------------------------------------------------

pub fn schedule_create_carries_the_request_and_the_granted_wake_test() {
  let seen = recorder()
  let assert framing.CapOk(value:) =
    serviced(
      answering(seen),
      "schedule.create",
      map([
        #("name", text("poll")),
        #("body", text("look")),
        #("every_seconds", int(60)),
        #("wake", msgpack.BoolValue(True)),
      ]),
    )
    as "schedule.create must be serviced"

  assert drain(seen) == [ScheduleCreateAsked("poll")]
  assert field(value, "name") == Ok(text("poll"))
  assert field(value, "wake") == Ok(msgpack.BoolValue(True))
  assert field(value, "when") == Ok(text("every 60s, at most 1000 times"))
}

// `wake` is optional and defaults false, so a program that never mentions
// it gets a schedule that steers rather than one the host has to guess
// about.
pub fn schedule_create_defaults_wake_to_false_test() {
  let seen = recorder()
  let assert framing.CapOk(value:) =
    serviced(
      answering(seen),
      "schedule.create",
      map([
        #("name", text("poll")),
        #("body", text("look")),
        #("every_seconds", int(60)),
      ]),
    )
    as "schedule.create must be serviced"

  assert field(value, "wake") == Ok(msgpack.BoolValue(False))
}

// Exactly one timing, refused here rather than at the host: a
// contradictory request costs one denial instead of a round trip into a
// store that would have had to invent an answer.
pub fn schedule_create_refuses_both_or_neither_timing_test() {
  let seen = recorder()
  let both =
    refused(
      answering(seen),
      "schedule.create",
      map([
        #("name", text("poll")),
        #("body", text("look")),
        #("every_seconds", int(60)),
        #("at", text("2026-09-01T09:00:00Z")),
      ]),
    )
  let neither =
    refused(
      answering(seen),
      "schedule.create",
      map([#("name", text("poll")), #("body", text("look"))]),
    )

  assert both.code == args.invalid_argument_code
  assert neither.code == args.invalid_argument_code
  // Neither reached the host: a request the router can see is wrong is
  // never handed on.
  assert drain(seen) == []
}

// The refusal names the arguments the program actually sent, because a
// program told "give exactly one timing" with four spellings to choose
// from cannot tell which two of them it used.
pub fn a_two_timing_refusal_names_both_timings_test() {
  let seen = recorder()
  let denial =
    refused(
      answering(seen),
      "schedule.create",
      map([
        #("name", text("poll")),
        #("body", text("look")),
        #("cron", text("0 9 * * *")),
        #("in_seconds", int(600)),
      ]),
    )

  assert string.contains(denial.message, "in_seconds")
  assert string.contains(denial.message, "cron")
  assert drain(seen) == []
}

// Each of the four timings on its own is serviced and reaches the host.
// A table rather than four tests, because the property is that the
// router admits exactly these four and the difference between them is
// one argument.
pub fn each_single_timing_is_serviced_test() {
  let timings = [
    #("every_seconds", int(60)),
    #("cron", text("0 9 * * 1-5")),
    #("at", text("2026-09-01T09:00:00Z")),
    #("in_seconds", int(2700)),
  ]
  list.each(timings, fn(timing) {
    let seen = recorder()
    let assert framing.CapOk(value:) =
      serviced(
        answering(seen),
        "schedule.create",
        map([#("name", text("poll")), #("body", text("look")), timing]),
      )
      as "one timing on its own must be serviced"

    assert drain(seen) == [ScheduleCreateAsked("poll")]
    assert field(value, "name") == Ok(text("poll"))
  })
}

// The two expiry arguments cross the router untouched: the host holds
// them to its own ceilings, and this package has no ceiling of its own
// to state.
pub fn the_expiry_bounds_reach_the_host_test() {
  let seen = recorder()
  let assert framing.CapOk(value:) =
    serviced(
      answering(seen),
      "schedule.create",
      map([
        #("name", text("poll")),
        #("body", text("look")),
        #("every_seconds", int(60)),
        #("max_fires", int(4)),
        #("expires_after_s", int(3600)),
      ]),
    )
    as "a bounded request must be serviced"

  assert drain(seen) == [ScheduleCreateAsked("poll")]
  assert field(value, "name") == Ok(text("poll"))
}

pub fn a_mistyped_expiry_bound_is_refused_test() {
  let seen = recorder()
  let denial =
    refused(
      answering(seen),
      "schedule.create",
      map([
        #("name", text("poll")),
        #("body", text("look")),
        #("every_seconds", int(60)),
        #("max_fires", text("4")),
      ]),
    )

  assert denial.code == args.invalid_argument_code
  assert drain(seen) == []
}

pub fn schedule_create_refuses_a_mistyped_argument_test() {
  let seen = recorder()
  let denial =
    refused(
      answering(seen),
      "schedule.create",
      map([
        #("name", text("poll")),
        #("body", text("look")),
        #("every_seconds", text("60")),
      ]),
    )

  assert denial.code == args.invalid_argument_code
  assert drain(seen) == []
}

pub fn schedule_list_renders_every_row_test() {
  let seen = recorder()
  let assert framing.CapOk(value:) =
    serviced(answering(seen), "schedule.list", map([]))
    as "schedule.list must be serviced"

  assert drain(seen) == [ScheduleListAsked]
  let assert Ok(msgpack.ArrayValue(items: [row])) = field(value, "schedules")
    as "one row must come back"
  assert field(row, "name") == Ok(text("poll"))
  assert field(row, "fired") == Ok(int(2))
  assert field(row, "wake") == Ok(msgpack.BoolValue(True))
  assert field(row, "body") == Ok(text("look"))
}

pub fn schedule_cancel_names_the_schedule_test() {
  let seen = recorder()
  let assert framing.CapOk(value:) =
    serviced(answering(seen), "schedule.cancel", map([#("name", text("poll"))]))
    as "schedule.cancel must be serviced"

  assert drain(seen) == [ScheduleCancelAsked("poll")]
  assert field(value, "cancelled") == Ok(msgpack.BoolValue(True))
}

// Each refusal gets its own code, because a program can act on the
// difference: a name clash means pick another, a limit means cancel
// something, an invalid request means fix the arguments.
pub fn every_schedule_refusal_has_its_own_code_test() {
  let codes =
    [
      workspace.ScheduleInvalid("r"),
      workspace.ScheduleLimitReached("r"),
      workspace.ScheduleNameTaken("r"),
      workspace.ScheduleNotFound("r"),
      workspace.ScheduleUnavailable("r"),
    ]
    |> list.map(fn(refusal) { workspace.schedule_denial(refusal).code })

  assert codes
    == [
      "invalid_schedule", "schedule_limit_reached", "schedule_name_taken",
      "schedule_not_found", "schedules_unavailable",
    ]
  // Distinct, which is the whole point of giving each one a code.
  assert list.length(list.unique(codes)) == 5
}
