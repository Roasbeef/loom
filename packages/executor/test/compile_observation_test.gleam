//// Physical result adaptation uses real journals and compiler-produced products.
////
//// Each fixture owns both journal endpoints and an enrollment-derived allocation.
//// The compiler-produced satellite beam exercises the real shared flattening and
//// fingerprint path. Synthetic native verdicts test this component's observation
//// boundary; these fixtures do not claim a jailed compiler or whole Compile actor.

import broker/broker
import broker/command as offer
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/framing
import broker/policy
import codemode/build
import codemode/compile
import codemode/enforcement
import codemode/service_command
import codemode/service_input
import codemode/service_resources
import core/command
import core/ids
import core/remote_tool
import core/workspace
import executor/remote/admission
import executor/remote/compile_completion as completion
import executor/remote/compile_observation as observation
import executor/remote/identity
import executor/remote/journal
import executor/remote/native
import executor/remote/payload
import executor/remote/resource_journal as resources
import executor/remote/wire
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import simplifile

type Fixture {
  Fixture(
    directory: String,
    enrolled: enrollment.SessionEnrollment,
    original: resources.Input,
    locations: service_resources.CompileLocations,
    root: String,
    resources: resources.Journal,
    native: journal.Journal,
    key: identity.RequestKey,
    digest: identity.Digest,
  )
}

pub fn actual_products_finalize_with_exact_native_binding_and_fingerprint_test() {
  fixture("products", fn(f) {
    produce(f)
    let bytes = commit_terminal(f, dispatch.Completed(exit()))
    let observed = settled(f)
    let assert Ok(result) = observation.finalize(observed)
      as "Actual compiled products finalize through the shared local code."
    let assert compile.Compiled(Ok(compile.ExecutorArtifact(..)), report) =
      completion.compiled(result)
      as "Success is an executor artifact, never an owner-local Artifact."
    assert report == enforcement.Reported(exit().enforcement, True)
    let assert Ok(hash) = build.fingerprint_directory(f.root <> "/ebin")
      as "Fingerprint independently reads the actual flattened files."
    let assert compile.Compiled(
      Ok(compile.ExecutorArtifact(
        manifest_hash: found_hash,
        request_digest: found_digest,
        ..,
      )),
      _,
    ) = completion.compiled(result)
      as "The completed artifact is available."
    assert found_hash == hash
    assert found_digest == command.digests(f.original.key).0
    assert completion.native_association(result)
      == Some(completion.NativeAssociation(f.key, f.digest, bytes))
    let assert Ok(_) = resources.commit_compile(f.resources, f.original, result)
      as "The real custody commit accepts the same exact native terminal."
    let assert Ok(items) = journal.payloads(f.native, f.key, f.digest)
      as "Finalization leaves exact native receipt bytes retained."
    assert list.contains(items, payload.Terminal(bytes))
  })
}

pub fn output_order_sticky_truncation_and_exact_bytes_survive_test() {
  fixture("streams", fn(f) {
    let first = output(f, 0, framing.Stdout, <<0, 255, 65>>, 5, True)
    let second = output(f, 1, framing.Stderr, <<66>>, 1, False)
    let third = output(f, 2, framing.Stdout, <<67>>, 6, False)
    let terminal =
      dispatch.Completed(exec.ExecResult(..exit(), stderr_truncated: True))
    let bytes = commit_terminal(f, terminal)
    let collected = observation.collected(settled(f))
    assert collected.stdout == <<0, 255, 65, 67>>
    assert collected.stderr == <<66>>
    assert collected.stdout_truncated
    assert collected.stderr_truncated
    assert collected.outcome
      == broker.CallExited(exec.ExecResult(..exit(), stderr_truncated: True))
    let assert Ok(items) = journal.payloads(f.native, f.key, f.digest)
      as "Original encoded output remains the journal's receipt material."
    assert list.filter(items, fn(item) {
        case item {
          payload.Output(_, _) -> True
          _ -> False
        }
      })
      == [
        payload.Output(0, first),
        payload.Output(1, second),
        payload.Output(2, third),
      ]
    assert list.contains(items, payload.Terminal(bytes))
  })
}

pub fn terminal_payload_before_actual_commit_is_pending_test() {
  fixture("commit-gap", fn(f) {
    let bytes = retain_terminal(f, dispatch.Completed(exit()))
    assert observation.observe(f.resources, f.original) == Ok(None)
    let assert Ok(_) =
      journal.apply(
        f.native,
        f.key,
        f.digest,
        admission.ObserveTerminal(hash(bytes)),
      )
      as "Actual reducer terminal COMMIT closes the observation gap."
    let observed = settled(f)
    assert observation.collected(observed).outcome == broker.CallExited(exit())
  })
}

pub fn committed_terminal_missing_or_changed_payload_is_invalid_test() {
  list.each(["missing", "changed"], fn(name) {
    fixture(name, fn(f) {
      let assert Ok(_) =
        journal.apply(f.native, f.key, f.digest, admission.AuthorizeLaunch)
        as "Native intent precedes terminal evidence."
      let assert Ok(bytes) = native.encode_terminal(dispatch.Completed(exit()))
        as "Canonical result bytes."
      let _ = case name {
        "changed" -> {
          assert journal.put_payload(
              f.native,
              f.key,
              f.digest,
              payload.Terminal(bytes),
            )
            == Ok(Nil)
          let assert Ok(_) =
            journal.apply(
              f.native,
              f.key,
              f.digest,
              admission.ObserveTerminal(hash(<<1>>)),
            )
            as "A different actual committed digest cannot name these bytes."
        }
        _ -> {
          let assert Ok(_) =
            journal.apply(
              f.native,
              f.key,
              f.digest,
              admission.ObserveTerminal(hash(bytes)),
            )
            as "Committed evidence without its payload is not pending."
        }
      }
      assert observation.observe(f.resources, f.original)
        == Error(observation.InvalidEvidence)
    })
  })
}

pub fn gapped_output_and_wrong_original_refuse_test() {
  fixture("output-gap", fn(f) {
    let _ = output(f, 1, framing.Stdout, <<65>>, 1, False)
    let _ = commit_terminal(f, dispatch.Completed(exit()))
    assert observation.observe(f.resources, f.original)
      == Error(observation.InvalidEvidence)
    assert observation.observe(
        f.resources,
        resources.Input(f.original.key, <<1>>),
      )
      == Error(observation.ResourceError(resources.InvalidInput))
  })
}

pub fn cancellation_nonzero_signal_and_timeout_never_flatten_valid_products_test() {
  let verdicts = [
    #("cancelled", exec.ExecResult(..exit(), cancelled: True)),
    #("nonzero", exec.ExecResult(..exit(), code: 1)),
    #("signal", exec.ExecResult(..exit(), signal: 9)),
    #("timeout", exec.ExecResult(..exit(), timed_out: True)),
  ]
  list.each(verdicts, fn(verdict) {
    let #(name, result) = verdict
    fixture(name, fn(f) {
      produce(f)
      let bytes = commit_terminal(f, dispatch.Completed(result))
      let assert Ok(completed) = observation.finalize(settled(f))
        as "Native failure remains an encodable outer failure."
      let assert compile.Compiled(Error(_), report) =
        completion.compiled(completed)
        as "Existing valid products cannot override failed settlement."
      assert report == enforcement.of_call(broker.CallExited(result))
      assert simplifile.is_directory(f.root <> "/ebin") == Ok(False)
      assert completion.native_association(completed)
        == Some(completion.NativeAssociation(f.key, f.digest, bytes))
    })
  })
}

pub fn partial_products_and_native_channel_failure_preserve_variant_and_report_test() {
  fixture("partial", fn(f) {
    let directory =
      f.root <> "/build/dev/erlang/" <> compile.package_name <> "/ebin"
    assert simplifile.create_directory_all(directory) == Ok(Nil)
    assert simplifile.write(directory <> "/partial.beam", "partial") == Ok(Nil)
    let _ = commit_terminal(f, dispatch.Completed(exit()))
    let assert Ok(completed) = observation.finalize(settled(f))
      as "Partial product failure is still a closed exact-native completion."
    let assert compile.Compiled(Error(compile.ArtifactIncomplete(_)), _) =
      completion.compiled(completed)
      as "Missing real entry keeps the artifact error discriminator."
    Nil
  })
  fixture("channel", fn(f) {
    produce(f)
    let terminal = dispatch.Failed(exec.ChannelClosed(9))
    let bytes = commit_terminal(f, terminal)
    let assert Ok(completed) = observation.finalize(settled(f))
      as "Actual native failure produces a bounded outer error."
    let assert compile.Compiled(Error(compile.BuildUnavailable(_)), report) =
      completion.compiled(completed)
      as "Helper failure remains unavailable, not a source diagnostic."
    assert report
      == enforcement.of_call(broker.CallFailed(exec.ChannelClosed(9)))
    assert completion.native_association(completed)
      == Some(completion.NativeAssociation(f.key, f.digest, bytes))
  })
}

pub fn unicode_and_prefixed_seed_failure_fit_codec_without_changing_receipts_test() {
  list.each(
    [
      #("unicode", string.repeat("😀", 8001)),
      #("seed", "Resolving versions " <> string.repeat("a", 8000)),
    ],
    fn(example) {
      let #(name, diagnostics) = example
      fixture(name, fn(f) {
        let chunks = case name {
          "unicode" -> [
            string.repeat("😀", 2000),
            string.repeat("😀", 2000),
            string.repeat("😀", 2000),
            string.repeat("😀", 2001),
          ]
          _ -> [diagnostics]
        }
        let encoded =
          list.index_map(chunks, fn(chunk, index) {
            output(
              f,
              index,
              framing.Stderr,
              bit_array.from_string(chunk),
              string.byte_size(chunk),
              False,
            )
          })
        let bytes =
          commit_terminal(
            f,
            dispatch.Completed(exec.ExecResult(..exit(), code: 1)),
          )
        let observed = settled(f)
        assert observation.collected(observed).stderr
          == bit_array.from_string(diagnostics)
        let assert Ok(completed) = observation.finalize(observed)
          as "Completed Unicode or prefixed diagnostics must fit the closed codec."
        let assert compile.Compiled(Error(error), _) =
          completion.compiled(completed)
          as "The actual compiler failure remains an error."
        let text = case error {
          compile.BuildRejected(text) if name == "unicode" -> text
          compile.BuildUnavailable(text) if name == "seed" -> text
          _ ->
            panic as "Outer text adaptation must preserve the real failure variant."
        }
        assert string.byte_size(text) <= 8000
        assert string.ends_with(text, "\n[diagnostics truncated]")
        let assert Ok(frame) = completion.encode(completed)
          as "The full failure is encodable without widening the codec."
        assert completion.decode(f.enrolled, f.original.key, frame)
          == Ok(completed)
        let assert Ok(items) = journal.payloads(f.native, f.key, f.digest)
          as "Human-readable truncation does not change native output or terminal."
        assert list.contains(items, payload.Terminal(bytes))
        list.each(
          list.index_map(encoded, fn(bytes, ordinal) { #(ordinal, bytes) }),
          fn(item) {
            assert list.contains(items, payload.Output(item.0, item.1))
          },
        )
      })
    },
  )
}

pub fn all_error_variants_keep_exact_limit_and_valid_utf8_marker_test() {
  let constructors = [
    compile.WorkspaceSetupFailed,
    compile.BuildRejected,
    compile.BuildUnavailable,
    compile.ArtifactIncomplete,
  ]
  list.each(constructors, fn(make) {
    let exact = string.repeat("a", 8000)
    assert observation.bounded_error(make(exact)) == make(exact)
    let excess = string.repeat("a", 7975) <> "😀" <> string.repeat("b", 50)
    let bounded = observation.bounded_error(make(excess))
    let text = case bounded {
      compile.WorkspaceSetupFailed(text)
      | compile.BuildRejected(text)
      | compile.BuildUnavailable(text)
      | compile.ArtifactIncomplete(text) -> text
    }
    assert string.byte_size(text) <= 8000
    assert bit_array.to_string(bit_array.from_string(text)) == Ok(text)
    assert string.ends_with(text, "\n[diagnostics truncated]")
    assert bounded == make(text)
  })
}

pub fn missing_original_and_closed_endpoints_never_become_pending_test() {
  fixture("errors", fn(f) {
    let changed =
      resources.Input(
        service_key(f.enrolled, f.original.body, 5),
        f.original.body,
      )
    assert observation.observe(f.resources, changed)
      == Error(observation.ResourceError(resources.Missing))
    assert resources.reserve(f.resources, changed) == Ok(resources.Reserved)
    assert observation.observe(f.resources, changed) == Ok(None)
    assert observation.observe(f.resources, f.original) == Ok(None)
    assert journal.release(f.native) == Ok(Nil)
    assert observation.observe(f.resources, f.original)
      == Error(observation.NativeJournalError(journal.Closed))
    assert resources.release_endpoint(f.resources) == Ok(Nil)
    assert observation.observe(f.resources, f.original)
      == Error(observation.ResourceError(resources.Closed))
  })
}

pub fn refusal_and_compacted_phases_keep_exact_historical_observation_test() {
  fixture("refused", fn(f) {
    let terminal = dispatch.Failed(exec.ChannelClosed(9))
    let assert Ok(bytes) = native.encode_terminal(terminal)
      as "Exact refusal payload."
    assert journal.put_payload(
        f.native,
        f.key,
        f.digest,
        payload.Terminal(bytes),
      )
      == Ok(Nil)
    let assert Ok(_) =
      journal.apply(
        f.native,
        f.key,
        f.digest,
        admission.RefuseBeforeLaunch(hash(bytes)),
      )
      as "Actual committed refusal, without native launch intent."
    assert observation.collected(settled(f)).outcome
      == broker.CallFailed(exec.ChannelClosed(9))
    let assert Ok(_) =
      journal.apply(
        f.native,
        f.key,
        f.digest,
        admission.ConfirmOwnerReceipt(hash(bytes)),
      )
      as "Original owner receipt is separate from observation."
    let assert Ok(_) =
      journal.apply(f.native, f.key, f.digest, admission.Compact)
      as "Refusal compaction keeps its immutable payload and digest."
    assert observation.collected(settled(f)).outcome
      == broker.CallFailed(exec.ChannelClosed(9))
  })
  fixture("retired", fn(f) {
    let bytes = commit_terminal(f, dispatch.Completed(exit()))
    let assert Ok(_) =
      journal.apply(f.native, f.key, f.digest, admission.ConfirmRetirement)
      as "Actual retirement remains separate from terminal observation."
    let assert Ok(_) =
      journal.apply(
        f.native,
        f.key,
        f.digest,
        admission.ConfirmOwnerReceipt(hash(bytes)),
      )
      as "Only exact durable owner receipt permits compaction."
    let assert Ok(_) =
      journal.apply(f.native, f.key, f.digest, admission.Compact)
      as "Compacted terminal retains exact outcome bytes."
    assert observation.collected(settled(f)).outcome
      == broker.CallExited(exit())
  })
}

fn fixture(_name: String, run: fn(Fixture) -> Nil) {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let directory =
    "/private/tmp/o-" <> int.to_string(seconds) <> "-" <> int.to_string(nanos)
  assert simplifile.create_directory(directory) == Ok(Nil)
  let enrolled = enrolled(directory)
  let assert Ok(input) =
    service_input.compile_input(
      enrolled,
      service_input.WorkspaceProgram,
      "pub fn main() { Nil }",
      [],
      compile.default_dependencies(),
      base(directory),
      180_000,
    )
    as "Exact canonical retained source and seed policy."
  let body = service_input.encode_compile(input)
  let original = resources.Input(service_key(enrolled, body, 3), body)
  let assert Ok(root) = enrollment.compile_path(enrolled, original.key)
    as "Exact original allocation."
  let assert Ok(locations) =
    service_resources.admit_compile_locations(enrolled, original.key, root)
    as "Admitted Ready location."
  let assert Ok(capacity) = admission.capacity(20) as "Finite native capacity."
  let assert Ok(native) =
    journal.fresh(directory <> "/native.sqlite", native_scope(), capacity)
    as "Actual native journal."
  let assert Ok(limits) = resources.limits(20, 50_000_000)
    as "Finite resource capacity."
  let assert Ok(book) =
    resources.fresh(directory <> "/resources.sqlite", enrolled, limits, native)
    as "Original resource journal pins that native endpoint."
  assert resources.reserve(book, original) == Ok(resources.Reserved)
  let assert Ok(resources.Claimed(claim)) =
    resources.claim_preparation(book, original)
    as "Original live preparation claim."
  assert resources.commit_ready(
      claim,
      service_resources.CompileReady(locations),
    )
    == Ok(resources.Prepared(service_resources.CompileReady(locations)))
  let assert Ok(request_id) = identity.request_id(ids.entry_id_to_string(id(9)))
    as "Independent native UUID."
  let key =
    identity.request_key(
      native_scope(),
      remote_tool.operation(command.parent(original.key)),
      request_id,
    )
  let assert Ok(expected) =
    service_command.compile_from_input(
      enrolled,
      original.key,
      input,
      locations,
      5,
    )
    as "Actual native compiler template."
  let data = offer.data(service_command.offer(expected))
  let assert Ok(registration_bytes) =
    bit_array.base16_decode(string.repeat("b", 64))
    as "Exact registration spelling."
  let assert Ok(registration) = identity.digest(registration_bytes)
    as "Exact registration digest."
  let prepared =
    wire.Prepared(
      "physical:build",
      registration,
      wire.Finite(180_000),
      exec.ExecRequest(
        data.argv,
        data.env,
        data.cwd,
        Some(data.requirements),
        <<0:size(256)>>,
        exec.PlatformEnforcement,
      ),
      wire.Logs,
    )
  let assert Ok(bytes) = wire.encode_prepared(prepared)
    as "Canonical native Prepared."
  let digest = hash(bytes)
  assert journal.put_payload(native, key, digest, payload.Request(bytes))
    == Ok(Nil)
  let assert Ok(_) = journal.admit(native, key, digest)
    as "Actual native admission COMMIT."
  let assert Ok(ref) = command.command_ref(original.key, command.CompileCommand)
    as "Full original command reference."
  assert resources.associate_native(book, original, ref, key, digest)
    == Ok(resources.Associated(ref, key, digest, prepared))
  run(Fixture(
    directory,
    enrolled,
    original,
    locations,
    root,
    book,
    native,
    key,
    digest,
  ))
  let _ = resources.release_endpoint(book)
  let _ = journal.release(native)
  assert simplifile.delete(directory) == Ok(Nil)
}

fn enrolled(directory: String) -> enrollment.SessionEnrollment {
  let assert Ok(value) =
    enrollment.new(
      enrollment.NativeFacts(
        scope(),
        ["/"],
        base(directory),
        exec.PlatformEnforcement,
      ),
      enrollment.CodeModeFacts(
        directory <> "/work",
        directory <> "/alloc/build",
        directory <> "/alloc/channel",
        "/tc/bin/gleam",
        "/tc/bin/erl",
        "/seed",
        ["/tc"],
        base(directory).mounts,
        "/tc/bin",
      ),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Bounded disjoint literal enrollment."
  value
}

fn base(directory: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    [directory <> "/work", directory <> "/alloc"],
    ["/tc", "/seed", directory <> "/work"],
    [directory <> "/work/.git"],
    policy.NetworkOff,
    policy.Limits(11, 12, 13, 14, 15, 16),
    ["PATH", "HOME"],
    policy.ScratchTmpfs,
    [
      policy.Mount("/tc", policy.MountReadOnly, policy.MountRequired),
      policy.Mount("/seed", policy.MountReadOnly, policy.MountOptional),
    ],
  )
}

fn scope() -> workspace.Scope {
  let assert Ok(value) =
    workspace.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "linux",
      2,
      7,
    )
    as "Original scope."
  value
}

fn native_scope() -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Original session."
  let assert Ok(workspace) = identity.workspace_id("checkout")
    as "Workspace label."
  let assert Ok(executor) = identity.executor_id("linux") as "Executor label."
  let assert Ok(session_epoch) = identity.epoch(2) as "Session epoch."
  let assert Ok(workspace_epoch) = identity.epoch(7) as "Workspace epoch."
  identity.scope(session, workspace, executor, session_epoch, workspace_epoch)
}

fn id(number: Int) -> ids.EntryId {
  let assert Ok(value) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "Canonical UUID."
  value
}

fn service_key(
  enrolled: enrollment.SessionEnrollment,
  body: BitArray,
  number: Int,
) -> command.ServiceKey {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Original session."
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Original operation."
  let assert Ok(parent) =
    remote_tool.key(
      session,
      operation,
      "parent",
      number,
      string.repeat("a", 64),
      id(4),
    )
    as "Original parent."
  let physical_step = case number {
    3 -> "physical:build"
    _ -> "physical:build-" <> int.to_string(number)
  }
  let assert Ok(step) = workspace.step(physical_step) as "Physical step."
  let #(registration, contract) = enrollment.digests(enrolled)
  let assert Ok(key) =
    command.service_key(
      parent,
      command.CompileService,
      scope(),
      operation,
      step,
      id(number),
      string.lowercase(bit_array.base16_encode(resources.digest(body))),
      registration,
      contract,
    )
    as "Complete original identity."
  key
}

fn hash(bytes: BitArray) -> identity.Digest {
  let assert Ok(value) = identity.digest(resources.digest(bytes))
    as "SHA256 bytes."
  value
}

fn produce(f: Fixture) {
  let path = f.root <> "/build/dev/erlang/" <> compile.package_name <> "/ebin"
  assert simplifile.create_directory_all(path) == Ok(Nil)
  let assert Ok(here) = simplifile.current_directory()
    as "Actual compiled dependency location."
  assert simplifile.copy_file(
      here <> "/build/dev/erlang/executor/ebin/loom_satellite.beam",
      path <> "/loom_satellite.beam",
    )
    == Ok(Nil)
}

fn exit() -> exec.ExecResult {
  exec.ExecResult(
    0,
    0,
    0,
    0,
    False,
    False,
    ["seatbelt", "skip:rlimit_as: platform"],
    False,
    12,
    False,
    False,
  )
}

fn output(
  f: Fixture,
  ordinal: Int,
  stream: framing.OutputStream,
  bytes: BitArray,
  total: Int,
  truncated: Bool,
) -> BitArray {
  let assert Ok(encoded) =
    native.encode_output(dispatch.Chunk(stream, bytes, total, truncated))
    as "Canonical exact output item."
  assert journal.put_payload(
      f.native,
      f.key,
      f.digest,
      payload.Output(ordinal, encoded),
    )
    == Ok(Nil)
  encoded
}

fn retain_terminal(f: Fixture, terminal: dispatch.Terminal) -> BitArray {
  let assert Ok(_) =
    journal.apply(f.native, f.key, f.digest, admission.AuthorizeLaunch)
    as "Actual native intent."
  let assert Ok(bytes) = native.encode_terminal(terminal)
    as "Canonical native terminal."
  assert journal.put_payload(f.native, f.key, f.digest, payload.Terminal(bytes))
    == Ok(Nil)
  bytes
}

fn commit_terminal(f: Fixture, terminal: dispatch.Terminal) -> BitArray {
  let bytes = retain_terminal(f, terminal)
  let assert Ok(_) =
    journal.apply(
      f.native,
      f.key,
      f.digest,
      admission.ObserveTerminal(hash(bytes)),
    )
    as "Exact reducer settlement COMMIT."
  bytes
}

fn settled(f: Fixture) -> observation.Observation {
  let assert Ok(Some(value)) = observation.observe(f.resources, f.original)
    as "Exact original association plus committed native result."
  value
}
