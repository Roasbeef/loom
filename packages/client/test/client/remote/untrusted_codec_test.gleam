//// The untrusted wire's codec: every frame, request, reply, callback and
//// answer comes back as it went in, and a hostile frame is a report, never a
//// crash and never a different value.
////
//// ## Flow
////
//// `the_handshake_frames_round_trip_test` → `every_request_round_trips_test` →
//// `every_refusal_round_trips_test` → `every_callback_round_trips_test` →
//// `every_answer_round_trips_test` → `bytes_that_are_not_text_are_refused_test`
//// → `a_response_decodes_only_against_its_own_kind_test` →
//// `drawn_keys_refusals_and_lookups_round_trip_test`
////
//// 1. The round-trip tests send every constructor of every frame through
////    `encode_frame` and `decode_frame` and require the same value back.
//// 2. The hostile-frame tests feed the envelope and the typed decoders bytes
////    and JSON that no honest executor writes, and require an `Error`.
//// 3. The kind tests decode each reply against every kind but its own.
//// 4. The property test draws keys, refusals and lookups from a fixed seed.
//// 5. The tunnel tests (protocol-change/117) send every `clear_call`, every
////    `broker.Refusal` and every `ExecFailure` through the codec, refuse a
////    spec that carries grants, a demand or an oversized field, and hold
////    frames and fetched outcomes to the value bound.

import broker/broker
import broker/budget
import broker/escalation
import broker/exec
import broker/framing
import broker/policy
import broker/token
import client/codemode as codemode_wiring
import client/escalate
import client/extension/installed
import client/hookserve
import client/lsp/profile
import client/notice
import client/owner_services
import client/remote/blob_transfer
import client/remote/protocol
import client/remote/remote_census
import client/remote/untrusted_codec
import client/remote/untrusted_wire
import client/state_object
import client/state_transfer
import client/system_prompt
import client/wiring
import client/workspace_plane
import client/workspace_policy
import codemode/satellite
import codemode/vet/policy as vet_policy
import core/clock
import core/corruption.{type CorruptionReport}
import core/ids
import core/json.{type JsonValue}
import core/message
import core/msgpack
import gleam/bit_array
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import machine/operation
import qcheck
import runtime/api
import runtime/effects
import tools/agent
import tools/codemode as codemode_tool
import tools/directory_access
import tools/tool

// --- values to carry -----------------------------------------------------------

const tip = "0123456789abcdef0123456789abcdef01234567"

const base = "89abcdef0123456789abcdef0123456789abcdef"

/// A deterministic operation id.
fn op() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 7)
  let #(id, _next) = ids.mint_op(generator)
  id
}

/// A binding as the link mints one: sixteen bytes.
fn binding() -> BitArray {
  <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>
}

/// An attach token.
fn token() -> BitArray {
  <<"attach-token":utf8>>
}

/// A call's key.
fn key() -> protocol.Key {
  protocol.Key(session: "s1", op: "op-1", step: "step-1", source_index: 2)
}

/// A repository state that passes `state_object.validate`.
fn state() -> state_object.State {
  state_object.State(
    hash: state_object.hash_of(<<"a bundle":utf8>>),
    size: 8,
    tip:,
    base: Some(base),
    dirty: state_object.Dirty,
  )
}

/// One piece of that state.
fn piece() -> state_transfer.Piece {
  state_transfer.Piece(state: state(), offset: 4, bytes: <<0, 1, 2, 255>>)
}

/// A tool result with text, an image and details.
fn result_message() -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: "call_1",
    tool_name: "bash",
    content: [
      message.ToolResultText(
        text: "hello \"quoted\" \u{00e9}",
        text_signature: None,
      ),
      message.ToolResultImage(data: "AAAA", mime_type: "image/png"),
    ],
    details: Some(json.Object([#("exit", json.Int(0))])),
    usage: None,
    added_tool_names: Some(["fs_read"]),
    is_error: False,
    timestamp: 1_700_000_000_000,
  )
}

/// A tool call to run, with every optional field set.
fn tool_run() -> effects.ToolRun {
  effects.ToolRun(
    operation: op(),
    step_id: "step-1",
    source_index: 2,
    strand: "main",
    call: message.ToolCall(
      id: "call_1",
      name: "bash",
      arguments: json.Object([#("command", json.String("ls"))]),
      thought_signature: Some("sig"),
      namespace: Some("ns"),
    ),
    arguments: json.Object([#("command", json.String("ls"))]),
    replay: operation.ReplaySafe,
    grants: [
      json.Object([
        #("grant", json.String("env")),
        #("name", json.String("HOME")),
      ]),
    ],
  )
}

/// The authority stored for a call: a directory access and standing grants.
fn authority() -> wiring.Authority {
  wiring.Authority(
    access: directory_access.approved(directory_access.none(), [
      policy.GrantWritableRoot("/work"),
    ]),
    standing: [
      policy.GrantEnv(name: "HOME"),
      policy.GrantScratch(scratch: policy.ScratchTmpfs),
      policy.GrantNetwork(network: policy.NetworkProxy(
        allow: ["example.com"],
        proxy: "p:1",
      )),
    ],
  )
}

/// What a background launch captured, with grants and a directory access.
fn terms() -> owner_services.ExecutionTerms {
  owner_services.ExecutionTerms(
    strand: "main",
    op_id: op(),
    launch_step: "step-1",
    source_index: 2,
    source: "import cap/fs\npub fn main() { fs.read(\"a\") }",
    seam: "orchestration",
    within_ms: 60_000,
    access: authority().access,
    grants: [
      policy.GrantEnv(name: "HOME"),
      policy.GrantWritableRoot("/work"),
    ],
  )
}

/// An execution's key, as `protocol.execution_key` makes one.
fn execution_key() -> protocol.Key {
  protocol.execution_key("s1", op(), "a1b2")
}

/// A language server profile.
fn lsp_server() -> profile.LspServer {
  profile.LspServer(
    preparation: profile.AlreadyPrepared,
    name: "go",
    command: ["gopls"],
    extensions: [".go"],
    root_markers: ["go.mod"],
    project: profile.ProjectReadOnly,
    readable: [profile.AbsolutePath("/opt/go")],
    writable: [],
    env: ["GOFLAGS"],
    cache_env: [#("GOCACHE", "go")],
    language_id: "go",
    qualifier_separators: ["."],
    module_case: profile.AsWritten,
    hint: Some("Qualify as pkg.Name"),
  )
}

/// The plane census an executor reports, with every list populated.
fn plane_census() -> workspace_plane.Census {
  workspace_plane.Census(
    workspace: "/executor/checkout",
    blob_root: "/executor/checkout/blobs",
    toolchain: Ok(codemode_wiring.Toolchain(
      gleam_path: "/opt/gleam/bin/gleam",
      erl_path: "/opt/erlang/bin/erl",
      seed_root: "/opt/seed",
      gleam_prefix: "/opt/gleam",
      erl_prefix: "/opt/erlang",
      gleam_binary: codemode_wiring.GleamSymlink,
    )),
    lsp_servers: [lsp_server()],
    extensions: [],
    platform: #("linux", "x86_64-pc-linux-gnu"),
    shell: "/bin/sh",
    base_policy: workspace_policy.base_policy("/executor/checkout"),
    env: [#("HOME", "/home/x"), #("PATH", "/usr/bin")],
    unset_env: ["TOKEN"],
    git: "/usr/bin/git",
    hook_files: [
      #("/w/.claude/settings.json", hookserve.Bytes(<<"{}":utf8>>)),
      #("/w/.claude/settings.local.json", hookserve.Missing),
      #("/w/.claude/other.json", hookserve.Unreadable(reason: "denied")),
    ],
    warnings: [
      workspace_plane.Warning(event: "boot", fields: [#("a", "b"), #("a", "c")]),
    ],
  )
}

/// A tool as a plane describes it.
fn described(name: String) -> tool.Described {
  tool.Described(
    name:,
    description: "The " <> name <> " tool.",
    prompt_snippet: Some("Use " <> name),
    schema: json.Object([#("type", json.String("object"))]),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
  )
}

/// The wire census with every nested type exercised.
fn census() -> untrusted_wire.Census {
  untrusted_wire.Census(
    census: plane_census(),
    tools: [
      described("bash"),
      tool.Described(
        ..described("edit"),
        replay: tool.Never,
        prompt_snippet: None,
        execution_mode: tool.Exclusive,
      ),
    ],
    prompt: workspace_plane.PromptFacts(
      guidance: [
        system_prompt.GuidanceFile(
          path: "/w/AGENTS.md",
          origin: system_prompt.WorkspaceFile,
          text: "Be careful.\n\"quoted\"",
        ),
        system_prompt.GuidanceFile(
          path: "~/AGENTS.md",
          origin: system_prompt.UserDefaultFile,
          text: "",
        ),
        system_prompt.GuidanceFile(
          path: "rule",
          origin: system_prompt.ApprovedRule,
          text: "x",
        ),
      ],
      guidance_notes: ["a note"],
      helper: workspace_plane.Degraded,
    ),
    mcp: [
      remote_census.McpReady(server: "fs", tools: 3),
      remote_census.McpRefused(server: "db", reason: "no binary"),
    ],
    branch: Some("loom/session"),
    states: remote_census.Moves,
  )
}

/// An escalation the plane could not settle.
fn refused() -> escalate.Refused {
  escalate.Refused(
    operation: op(),
    strand: "main",
    step_id: "step-1",
    source_index: 0,
    call_id: "call_1",
    tool: "bash",
    denial: escalation.Denial(
      reason: "needs a write",
      source: escalation.PolicyDenial,
      wanted: [policy.GrantWritableRoot("/work"), policy.GrantEnv("TOKEN")],
    ),
    arguments: json.Object([#("command", json.String("make"))]),
    deadline_ms: -5,
  )
}

/// A caller of the holds check.
fn caller(minter: agent.Minter) -> agent.Caller {
  agent.Caller(
    strand: "main",
    operation: op(),
    step_id: "step-1",
    source_index: 1,
    minter:,
  )
}

/// A capability call owned by the session.
fn cap_call(seam: vet_policy.Seam) -> owner_services.OwnerCapCall {
  owner_services.OwnerCapCall(
    strand: "main",
    op_id: op(),
    step_id: "step-1",
    source_index: 1,
    seam:,
    cap: "notes.read",
    args: msgpack.MapValue([
      #(msgpack.StringValue("path"), msgpack.StringValue("a.md")),
      #(msgpack.StringValue("limit"), msgpack.IntValue(-3)),
      #(msgpack.StringValue("raw"), msgpack.BinaryValue(<<0, 255>>)),
      #(
        msgpack.StringValue("xs"),
        msgpack.ArrayValue([
          msgpack.NilValue,
          msgpack.BoolValue(True),
          msgpack.FloatValue(1.5),
        ]),
      ),
    ]),
    ordinal: 3,
  )
}

// --- which reply a frame awaits -------------------------------------------------

/// The reply kind a receiver would have remembered for a response.
fn response_kind_of(
  response: untrusted_wire.Response,
) -> untrusted_wire.ResponseKind {
  case response {
    untrusted_wire.AttachAnswered(..) -> untrusted_wire.AttachKind
    untrusted_wire.RunAnswered(..) -> untrusted_wire.RunKind
    untrusted_wire.LookupAnswered(..) -> untrusted_wire.LookupKind
    untrusted_wire.UnackedAnswered(..) -> untrusted_wire.UnackedKind
    untrusted_wire.CloseAnswered(..) -> untrusted_wire.CloseKind
    untrusted_wire.CaptureAnswered(..) -> untrusted_wire.CaptureKind
    untrusted_wire.ApplyAnswered(..) -> untrusted_wire.ApplyKind
    untrusted_wire.ChunkAnswered(..) -> untrusted_wire.ChunkKind
    untrusted_wire.StatusAnswered(..) -> untrusted_wire.StatusKind
    untrusted_wire.FetchAnswered(..) -> untrusted_wire.FetchKind
    untrusted_wire.BlobStatusAnswered(..) -> untrusted_wire.BlobStatusKind
    untrusted_wire.BlobPutAnswered(..) -> untrusted_wire.BlobPutKind
    untrusted_wire.OutcomePieceAnswered(..) -> untrusted_wire.OutcomePieceKind
    untrusted_wire.ExecutionAnswered(..) -> untrusted_wire.ExecutionKind
    untrusted_wire.ClearedAnswered(..) -> untrusted_wire.ClearedKind
  }
}

/// The answer kind a receiver would have remembered for an answer.
fn answer_kind_of(answer: untrusted_wire.Answer) -> untrusted_wire.AnswerKind {
  case answer {
    untrusted_wire.Decided(..) -> untrusted_wire.DecidedKind
    untrusted_wire.FactCellAnswered(..) -> untrusted_wire.FactCellKind
    untrusted_wire.FactSeqAnswered(..) -> untrusted_wire.FactSeqKind
    untrusted_wire.FactDoneAnswered(..) -> untrusted_wire.FactDoneKind
    untrusted_wire.FactListAnswered(..) -> untrusted_wire.FactListKind
    untrusted_wire.NotifyAnswered(..) -> untrusted_wire.NotifyKind
    untrusted_wire.ActivityAnswered(..) -> untrusted_wire.ActivityKind
    untrusted_wire.WakeAnswered(..) -> untrusted_wire.WakeKind
    untrusted_wire.HoldsAnswered(..) -> untrusted_wire.HoldsKind
    untrusted_wire.CapabilityAnswered(..) -> untrusted_wire.CapabilityKind
    untrusted_wire.McpPlanAnswered(..) -> untrusted_wire.McpPlanKind
    untrusted_wire.GitIdentityAnswered(..) -> untrusted_wire.GitIdentityKind
    untrusted_wire.LaunchAnswered(..) -> untrusted_wire.LaunchKind
    untrusted_wire.InteractAnswered(..) -> untrusted_wire.InteractKind
  }
}

/// Sends a frame through `encode_frame` and `decode_frame`, as a receiver that
/// was waiting for exactly this reply would: the kind it remembers is read off
/// the frame's own constructor.
fn through(
  frame: untrusted_wire.Frame,
) -> Result(untrusted_wire.Frame, CorruptionReport) {
  untrusted_codec.decode_frame(
    untrusted_codec.encode_frame(frame),
    fn(_id) {
      case frame {
        untrusted_wire.Response(response:, ..) ->
          Some(response_kind_of(response))
        _ -> None
      }
    },
    fn(_binding, _id) {
      case frame {
        untrusted_wire.Answer(answer:, ..) -> Some(answer_kind_of(answer))
        _ -> None
      }
    },
  )
}

/// Asserts that a request, sent in a frame, comes back equal.
fn assert_request(request: untrusted_wire.Request) -> Nil {
  let frame = untrusted_wire.Request(id: 11, request:)
  assert through(frame) == Ok(frame)
}

/// Asserts that a response, sent in a frame, comes back equal.
fn assert_response(response: untrusted_wire.Response) -> Nil {
  let frame = untrusted_wire.Response(id: 12, response:)
  assert through(frame) == Ok(frame)
}

/// Asserts that a callback, sent in a frame, comes back equal.
fn assert_callback(callback: untrusted_wire.Callback) -> Nil {
  let frame = untrusted_wire.Callback(binding: binding(), id: 13, callback:)
  assert through(frame) == Ok(frame)
}

/// Asserts that an answer, sent in a frame, comes back equal.
fn assert_answer(answer: untrusted_wire.Answer) -> Nil {
  let frame = untrusted_wire.Answer(binding: binding(), id: 14, answer:)
  assert through(frame) == Ok(frame)
}

/// The body of a frame, as the envelope hands it to a typed decoder.
fn body_of(frame: untrusted_wire.Frame) -> JsonValue {
  let assert Ok(envelope) =
    untrusted_codec.decode_envelope(untrusted_codec.encode_frame(frame))
    as "A frame this module wrote must have a readable header."
  case envelope {
    untrusted_codec.RequestEnvelope(body:, ..) -> body
    untrusted_codec.ResponseEnvelope(body:, ..) -> body
    untrusted_codec.CallbackEnvelope(body:, ..) -> body
    untrusted_codec.AnswerEnvelope(body:, ..) -> body
    untrusted_codec.CallEventEnvelope(body:, ..) -> body
    untrusted_codec.HelloEnvelope(..)
    | untrusted_codec.WelcomeEnvelope(..)
    | untrusted_codec.CancelEnvelope(..)
    | untrusted_codec.OversizedEnvelope(..) -> json.Null
  }
}

/// Parses JSON text a test wrote by hand.
fn parsed(text: String) -> JsonValue {
  let assert Ok(value) = json.parse(text) as "The test's own JSON must parse."
  value
}

/// Asserts that bytes are refused at the envelope.
fn assert_refused(text: String) -> Nil {
  let assert Error(_report) =
    untrusted_codec.decode_envelope(bit_array.from_string(text))
    as "A hostile frame must be refused."
  Nil
}

// --- frames ----------------------------------------------------------------------

pub fn the_handshake_frames_round_trip_test() {
  let hello = untrusted_wire.Hello(wire: untrusted_wire.version, protocol: 6)
  let welcome = untrusted_wire.Welcome(wire: 1, protocol: 6)
  let cancel = untrusted_wire.Cancel(id: 9)

  assert through(hello) == Ok(hello)
  assert through(welcome) == Ok(welcome)
  assert through(cancel) == Ok(cancel)
}

pub fn the_envelope_reads_a_header_and_keeps_the_body_test() {
  let request = untrusted_wire.QueryRequest(key: key())
  let frame = untrusted_wire.Request(id: 5, request:)
  let bytes = untrusted_codec.encode_frame(frame)

  let assert Ok(untrusted_codec.RequestEnvelope(id: 5, body:)) =
    untrusted_codec.decode_envelope(bytes)
    as "A request's header must be read."
  assert untrusted_codec.decode_request(body) == Ok(request)

  let callback = untrusted_wire.McpPlanCall
  let frame = untrusted_wire.Callback(binding: binding(), id: 6, callback:)
  let assert Ok(untrusted_codec.CallbackEnvelope(binding: found, id: 6, body:)) =
    untrusted_codec.decode_envelope(untrusted_codec.encode_frame(frame))
    as "A callback's header must be read."
  assert found == binding()
  assert untrusted_codec.decode_callback(body) == Ok(callback)

  let answer = untrusted_wire.GitIdentityAnswered(identity: None)
  let frame = untrusted_wire.Answer(binding: binding(), id: 7, answer:)
  assert untrusted_codec.decode_answer(
      untrusted_wire.GitIdentityKind,
      body_of(frame),
    )
    == Ok(answer)
}

// --- requests --------------------------------------------------------------------

pub fn every_request_round_trips_test() {
  assert_request(untrusted_wire.AttachRequest(
    version: 6,
    session: "s1",
    workspace: "/executor/checkout",
    incarnation: 3,
    token: token(),
    binding: binding(),
  ))

  assert_request(untrusted_wire.RunRequest(
    key: key(),
    incarnation: 3,
    token: token(),
    run: tool_run(),
    authority: authority(),
  ))

  assert_request(untrusted_wire.QueryRequest(key: key()))
  assert_request(untrusted_wire.QueryOrFenceRequest(key: key(), incarnation: 4))
  assert_request(untrusted_wire.ListUnackedRequest(session: "s1"))
  assert_request(untrusted_wire.AckRequest(key: key()))
  assert_request(untrusted_wire.CloseRequest(
    session: "s1",
    workspace: "/w",
    incarnation: 3,
  ))
}

pub fn every_state_request_round_trips_test() {
  assert_request(untrusted_wire.StateCaptureRequest(
    session: "s1",
    incarnation: 3,
    token: token(),
    basis: state_object.Full,
    content: state_object.WithWorkingTree,
  ))

  assert_request(untrusted_wire.StateCaptureRequest(
    session: "s1",
    incarnation: 3,
    token: token(),
    basis: state_object.Thin(base:),
    content: state_object.CommittedOnly,
  ))

  assert_request(untrusted_wire.StateApplyRequest(
    session: "s1",
    incarnation: 3,
    token: token(),
    state: state(),
  ))

  assert_request(untrusted_wire.StateChunkRequest(piece: piece()))
  assert_request(untrusted_wire.StateStatusRequest(hash: state().hash))
  assert_request(untrusted_wire.StateFetchRequest(hash: state().hash, offset: 0))
}

pub fn the_background_execution_requests_round_trip_test() {
  assert_request(untrusted_wire.StartExecutionRequest(
    key: execution_key(),
    incarnation: 3,
    token: token(),
    terms: terms(),
    remaining_ms: 45_000,
  ))

  // The host clamps a negative time left itself, so the wire carries it.
  assert_request(untrusted_wire.StartExecutionRequest(
    key: execution_key(),
    incarnation: 3,
    token: token(),
    terms: owner_services.ExecutionTerms(..terms(), seam: "workspace"),
    remaining_ms: -1,
  ))

  assert_request(untrusted_wire.StopExecutionRequest(
    key: execution_key(),
    incarnation: 3,
  ))
  assert untrusted_wire.response_kind(untrusted_wire.StopExecutionRequest(
      key: execution_key(),
      incarnation: 3,
    ))
    == None
}

pub fn every_execution_answer_round_trips_test() {
  list.each(
    [
      protocol.ExecutionFinished(
        value: json.Object([
          #("status", json.String("ok")),
          #("value", json.Array([json.Int(1), json.Null])),
        ]),
      ),
      protocol.ExecutionLost,
      protocol.ExecutionRefused(protocol.StaleToken),
      protocol.ExecutionRefused(protocol.Unreachable("gone")),
    ],
    fn(answer) { assert_response(untrusted_wire.ExecutionAnswered(answer:)) },
  )
}

pub fn the_background_execution_callbacks_round_trip_test() {
  assert_callback(untrusted_wire.LaunchExecutionCall(terms: terms()))

  list.each(
    [
      codemode_tool.Check,
      codemode_tool.Join,
      codemode_tool.Cancel,
      codemode_tool.Send(value: json.Object([#("n", json.Int(1))])),
      codemode_tool.SendTo(endpoint: "progress", value: json.String("x")),
    ],
    fn(interaction) {
      assert_callback(untrusted_wire.InteractExecutionCall(
        strand: "main",
        handle: "exec-1",
        interaction:,
        within_ms: 5000,
      ))
    },
  )

  list.each([Ok(json.String("exec-1")), Error("not yours")], fn(answer) {
    assert_answer(untrusted_wire.LaunchAnswered(answer:))
    assert_answer(untrusted_wire.InteractAnswered(answer:))
  })
}

pub fn a_launch_under_a_mode_no_program_has_is_refused_test() {
  let launch =
    bit_array_text(
      untrusted_codec.encode_frame(untrusted_wire.Callback(
        binding: binding(),
        id: 1,
        callback: untrusted_wire.LaunchExecutionCall(terms: terms()),
      )),
    )
  assert_refused_callback(string.replace(
    launch,
    "\"seam\":\"orchestration\"",
    "\"seam\":\"resident\"",
  ))
  assert_refused_callback(string.replace(
    launch,
    "\"within_ms\":60000",
    "\"within_ms\":-1",
  ))
  assert_refused_callback(string.replace(
    launch,
    "\"source_index\":2",
    "\"source_index\":\"2\"",
  ))
}

pub fn malformed_execution_bodies_are_refused_test() {
  let refused_body = fn(text: String) {
    let assert Error(_report) = untrusted_codec.decode_callback(parsed(text))
      as "A malformed execution callback must be refused."
    Nil
  }

  refused_body("{\"kind\":\"launch_execution\"}")
  refused_body("{\"kind\":\"launch_execution\",\"terms\":{}}")
  refused_body(
    "{\"kind\":\"interact_execution\",\"strand\":\"s\",\"handle\":\"h\",\"interaction\":{\"kind\":\"detonate\"},\"within_ms\":1}",
  )
  refused_body(
    "{\"kind\":\"interact_execution\",\"strand\":\"s\",\"handle\":\"h\",\"interaction\":{\"kind\":\"send\"},\"within_ms\":1}",
  )
  refused_body(
    "{\"kind\":\"interact_execution\",\"strand\":\"s\",\"handle\":\"h\",\"interaction\":{\"kind\":\"join\"},\"within_ms\":-1}",
  )

  assert_request_refused("{\"kind\":\"stop_execution\",\"incarnation\":1}")
  assert_request_refused("{\"kind\":\"start_execution\"}")

  let answer = "{\"kind\":\"execution\",\"answer\":{\"kind\":\"vanished\"}}"
  let assert Error(_report) =
    untrusted_codec.decode_response(
      untrusted_wire.ExecutionKind,
      parsed(answer),
    )
    as "An execution answer of no known kind must be refused."
  let launched = "{\"kind\":\"launch\",\"answer\":{\"error\":7}}"
  let assert Error(_report) =
    untrusted_codec.decode_answer(untrusted_wire.LaunchKind, parsed(launched))
    as "A launch refusal must be text."
}

pub fn a_run_request_keeps_its_authority_and_its_call_test() {
  let run = tool_run()
  let frame =
    untrusted_wire.Request(
      id: 1,
      request: untrusted_wire.RunRequest(
        key: key(),
        incarnation: 1,
        token: token(),
        run:,
        authority: authority(),
      ),
    )

  let assert Ok(untrusted_wire.Request(
    request: untrusted_wire.RunRequest(run: found, authority: stored, ..),
    ..,
  )) = through(frame)
    as "A run request must come back."
  assert found.call.thought_signature == Some("sig")
  assert found.call.namespace == Some("ns")
  assert found.replay == operation.ReplaySafe
  assert stored == authority()
}

// A directory access is a set, and `client/directories` reads its entries back
// in the opposite order, so a pair of roots is compared as a set.
pub fn a_directory_access_comes_back_as_the_same_set_test() {
  let access =
    directory_access.approved(directory_access.none(), [
      policy.GrantReadableRoot("/data"),
      policy.GrantWritableRoot("/work"),
    ])
  let stored = wiring.Authority(access:, standing: [])
  let frame =
    untrusted_wire.Request(
      id: 1,
      request: untrusted_wire.RunRequest(
        key: key(),
        incarnation: 1,
        token: token(),
        run: tool_run(),
        authority: stored,
      ),
    )

  let assert Ok(untrusted_wire.Request(
    request: untrusted_wire.RunRequest(authority: found, ..),
    ..,
  )) = through(frame)
    as "A run request must come back."
  assert list.sort(found.access.readable, string.compare) == ["/data", "/work"]
  assert found.access.writable == ["/work"]
}

// --- responses -------------------------------------------------------------------

/// Every refusal a host can answer with, each carrying a distinct payload.
fn every_refusal() -> List(protocol.Refusal) {
  [
    protocol.StaleToken,
    protocol.StaleIncarnation(stored: 4),
    protocol.ScopeNotOpen,
    protocol.ScopeClosing,
    protocol.UncleanClose(count: 2),
    protocol.CapacityExhausted(limit: 8),
    protocol.BudgetExhausted(limit: 9),
    protocol.VersionMismatch(supported: 6),
    protocol.WorkspaceMismatch(stored: "/other"),
    protocol.NoSuchScope,
    protocol.NoPlane(reason: "no plane"),
    protocol.PlaneBuilding,
    protocol.WorktreeFailed(reason: "git said no"),
    protocol.UnknownHandle,
    protocol.AlreadyPublished,
    protocol.StaleGeneration(serving: 5),
    protocol.NoEvolution(reason: "none"),
    protocol.NoStates(reason: "no git"),
    protocol.Invalid(reason: "bad"),
    protocol.ExecutorFault(reason: "boom"),
    protocol.Unreachable(reason: "gone"),
  ]
}

pub fn every_refusal_round_trips_test() {
  assert list.length(every_refusal()) == 21

  list.each(every_refusal(), fn(refusal) {
    assert_response(untrusted_wire.LookupAnswered(answer: Error(refusal)))
  })
}

pub fn every_run_and_lookup_answer_round_trips_test() {
  let completed =
    effects.ToolCompleted(result: result_message(), terminate: True)
  let failed = effects.ToolFailed(reason: "the helper died")

  assert_response(
    untrusted_wire.RunAnswered(answer: protocol.RunFinished(completed)),
  )
  assert_response(
    untrusted_wire.RunAnswered(answer: protocol.RunFinished(failed)),
  )
  assert_response(untrusted_wire.RunAnswered(answer: protocol.RunLost))
  assert_response(
    untrusted_wire.RunAnswered(answer: protocol.RunRefused(protocol.StaleToken)),
  )

  list.each(
    [
      protocol.Missing,
      protocol.Admitted,
      protocol.Terminal(outcome: completed),
      protocol.Terminal(outcome: failed),
      protocol.Unknown,
      protocol.Fenced,
      protocol.Executed(value: json.Object([#("n", json.Float(1.5))])),
    ],
    fn(lookup) {
      assert_response(untrusted_wire.LookupAnswered(answer: Ok(lookup)))
    },
  )
}

pub fn the_attach_reply_carries_the_whole_census_test() {
  let unacked =
    protocol.Unacked(terminal: [key()], unknown: [], executions: [key()])
  let attached =
    protocol.Attached(census: census(), executor_now_ms: -12, unacked:)

  assert_response(untrusted_wire.AttachAnswered(answer: Ok(attached)))
  assert_response(
    untrusted_wire.AttachAnswered(
      answer: Error(protocol.VersionMismatch(supported: 6)),
    ),
  )
}

pub fn the_census_round_trips_on_its_own_test() {
  let attached =
    protocol.Attached(
      census: census(),
      executor_now_ms: 1,
      unacked: protocol.Unacked(terminal: [], unknown: [], executions: []),
    )
  let frame =
    untrusted_wire.Response(
      id: 1,
      response: untrusted_wire.AttachAnswered(answer: Ok(attached)),
    )

  let assert Ok(untrusted_wire.Response(
    response: untrusted_wire.AttachAnswered(answer: Ok(found)),
    ..,
  )) = through(frame)
    as "An attach reply must come back."

  assert found.census.census.base_policy == plane_census().base_policy
  assert found.census.census.toolchain == plane_census().toolchain
  assert found.census.census.lsp_servers == [lsp_server()]
  assert found.census.census.hook_files == plane_census().hook_files
  assert found.census.census.warnings == plane_census().warnings
  assert found.census.tools == census().tools
  assert found.census.prompt == census().prompt
  assert found.census.mcp == census().mcp
}

pub fn a_toolchain_that_is_absent_round_trips_test() {
  let absent =
    untrusted_wire.Census(
      ..census(),
      census: workspace_plane.Census(
        ..plane_census(),
        toolchain: Error("no gleam on this machine"),
      ),
      states: remote_census.Stays(reason: "no git"),
      branch: None,
    )
  let attached =
    protocol.Attached(
      census: absent,
      executor_now_ms: 0,
      unacked: protocol.Unacked(terminal: [], unknown: [], executions: []),
    )

  assert_response(untrusted_wire.AttachAnswered(answer: Ok(attached)))
}

pub fn the_executors_extensions_are_not_carried_test() {
  let with_extension =
    untrusted_wire.Census(
      ..census(),
      census: workspace_plane.Census(..plane_census(), extensions: [
        installed.Refused(name: "lint", reason: "stale"),
      ]),
    )
  let attached =
    protocol.Attached(
      census: with_extension,
      executor_now_ms: 0,
      unacked: protocol.Unacked(terminal: [], unknown: [], executions: []),
    )
  let frame =
    untrusted_wire.Response(
      id: 1,
      response: untrusted_wire.AttachAnswered(answer: Ok(attached)),
    )

  let assert Ok(untrusted_wire.Response(
    response: untrusted_wire.AttachAnswered(answer: Ok(found)),
    ..,
  )) = through(frame)
    as "An attach reply must come back."
  assert found.census.census.extensions == []
}

pub fn the_remaining_replies_round_trip_test() {
  assert_response(
    untrusted_wire.UnackedAnswered(
      answer: Ok(
        protocol.Unacked(terminal: [key()], unknown: [key()], executions: []),
      ),
    ),
  )
  assert_response(
    untrusted_wire.UnackedAnswered(answer: Error(protocol.ScopeNotOpen)),
  )

  assert_response(untrusted_wire.CloseAnswered(answer: Ok(protocol.AllRetired)))
  assert_response(
    untrusted_wire.CloseAnswered(answer: Ok(protocol.UnknownCleanup(count: 3))),
  )
  assert_response(
    untrusted_wire.CloseAnswered(answer: Error(protocol.UncleanClose(count: 1))),
  )

  assert_response(untrusted_wire.CaptureAnswered(answer: Ok(Some(state()))))
  assert_response(untrusted_wire.CaptureAnswered(answer: Ok(None)))
  assert_response(
    untrusted_wire.CaptureAnswered(
      answer: Error(protocol.NoStates(reason: "no git")),
    ),
  )

  assert_response(untrusted_wire.ApplyAnswered(answer: Ok("refs/loom/s1")))
  assert_response(
    untrusted_wire.ApplyAnswered(answer: Error(protocol.Invalid(reason: "no"))),
  )
}

pub fn every_state_transfer_reply_round_trips_test() {
  list.each(
    [
      state_transfer.BadState(reason: "a"),
      state_transfer.BadPiece(reason: "b"),
      state_transfer.TooLarge(limit: 9),
      state_transfer.NoRoom(reason: "c"),
      state_transfer.OutOfOrder(expected: 4),
      state_transfer.Mismatch(reason: "d"),
      state_transfer.NotServing,
    ],
    fn(refusal) {
      assert_response(
        untrusted_wire.ChunkAnswered(verdict: state_transfer.Refused(refusal:)),
      )
    },
  )

  assert_response(
    untrusted_wire.ChunkAnswered(verdict: state_transfer.Accepted(held: 8)),
  )
  assert_response(
    untrusted_wire.ChunkAnswered(verdict: state_transfer.Failed(reason: "disk")),
  )

  assert_response(
    untrusted_wire.StatusAnswered(answer: Ok(state_transfer.Absent)),
  )
  assert_response(
    untrusted_wire.StatusAnswered(answer: Ok(state_transfer.Partial(held: 4))),
  )
  assert_response(
    untrusted_wire.StatusAnswered(answer: Ok(state_transfer.Complete)),
  )
  assert_response(untrusted_wire.StatusAnswered(answer: Error("unknown state")))

  assert_response(
    untrusted_wire.FetchAnswered(fetched: state_transfer.Served(piece: piece())),
  )
  assert_response(untrusted_wire.FetchAnswered(fetched: state_transfer.NotHeld))
  assert_response(
    untrusted_wire.FetchAnswered(fetched: state_transfer.FetchFailed(
      reason: "io",
    )),
  )
}

// --- placed blobs and outcomes in pieces (protocol-change/110) ------------------

/// A digest of the right form.
fn digest() -> String {
  blob_transfer.digest_of(<<"blob">>)
}

/// One piece of a blob, with bytes no text encoding would keep.
fn blob_piece() -> blob_transfer.Piece {
  blob_transfer.Piece(
    blob: blob_transfer.Blob(digest: digest(), size: 4096),
    offset: 1024,
    bytes: <<0, 255, 10, 13>>,
  )
}

pub fn every_blob_and_outcome_request_round_trips_test() {
  assert_request(untrusted_wire.BlobStatusRequest(
    binding: binding(),
    digest: digest(),
  ))
  assert_request(untrusted_wire.BlobPutRequest(
    binding: binding(),
    piece: blob_piece(),
  ))
  assert_request(untrusted_wire.OutcomePieceRequest(key: key(), offset: 0))
  assert_request(untrusted_wire.OutcomePieceRequest(
    key: key(),
    offset: 33_554_432,
  ))
}

pub fn every_blob_reply_round_trips_test() {
  list.each(
    [
      blob_transfer.Accepted(held: 8),
      blob_transfer.Stored,
      blob_transfer.OutOfOrder(expected: 4),
      blob_transfer.Refused(reason: "over the binding's bound"),
      blob_transfer.Failed(reason: "disk"),
    ],
    fn(verdict) { assert_response(untrusted_wire.BlobPutAnswered(verdict:)) },
  )
  list.each(
    [
      Ok(blob_transfer.Absent),
      Ok(blob_transfer.Partial(held: 4)),
      Ok(blob_transfer.Complete),
      Error("the binding is not one this orchestrator holds"),
    ],
    fn(answer) { assert_response(untrusted_wire.BlobStatusAnswered(answer:)) },
  )
}

pub fn every_outcome_piece_round_trips_test() {
  assert_response(
    untrusted_wire.OutcomePieceAnswered(
      piece: untrusted_wire.OutcomeServed(
        size: 40,
        digest: digest(),
        offset: 8,
        bytes: <<1, 2, 3>>,
      ),
    ),
  )
  assert_response(
    untrusted_wire.OutcomePieceAnswered(
      piece: untrusted_wire.OutcomeServed(
        size: 40,
        digest: digest(),
        offset: 40,
        bytes: <<>>,
      ),
    ),
  )
  assert_response(
    untrusted_wire.OutcomePieceAnswered(piece: untrusted_wire.OutcomeNotHeld(
      reason: "no row",
    )),
  )
}

pub fn the_oversized_frame_round_trips_and_has_no_body_test() {
  let frame =
    untrusted_wire.Oversized(id: 9, size: 50_331_648, digest: digest())
  assert through(frame) == Ok(frame)
  assert untrusted_codec.decode_envelope(untrusted_codec.encode_frame(frame))
    == Ok(untrusted_codec.OversizedEnvelope(
      id: 9,
      size: 50_331_648,
      digest: digest(),
    ))
}

pub fn a_malformed_oversized_frame_is_refused_test() {
  let good = digest()
  assert_refused(
    "{\"frame\":\"oversized\",\"id\":0,\"size\":1,\"digest\":\""
    <> good
    <> "\"}",
  )
  assert_refused(
    "{\"frame\":\"oversized\",\"id\":1,\"size\":-1,\"digest\":\""
    <> good
    <> "\"}",
  )
  assert_refused(
    "{\"frame\":\"oversized\",\"id\":1,\"size\":1,\"digest\":\""
    <> string.uppercase(good)
    <> "\"}",
  )
  assert_refused(
    "{\"frame\":\"oversized\",\"id\":1,\"size\":1,\"digest\":\"../x\"}",
  )
  assert_refused("{\"frame\":\"oversized\",\"id\":1,\"size\":1}")
}

pub fn malformed_blob_requests_are_refused_test() {
  let binding_text = bit_array.base64_encode(binding(), True)
  let piece = fn(digest: String, size: String, offset: String, bytes: String) {
    "{\"kind\":\"blob_put\",\"binding\":\""
    <> binding_text
    <> "\",\"piece\":{\"digest\":\""
    <> digest
    <> "\",\"size\":"
    <> size
    <> ",\"offset\":"
    <> offset
    <> ",\"bytes\":\""
    <> bytes
    <> "\"}}"
  }
  let good = digest()

  let assert Ok(_request) =
    untrusted_codec.decode_request(parsed(piece(good, "4", "0", "AAAA")))
    as "A well-formed piece is legal."
  list.each(
    [
      piece("abc", "4", "0", "AAAA"),
      piece("../../etc/passwd", "4", "0", "AAAA"),
      piece(string.uppercase(good), "4", "0", "AAAA"),
      piece(good, "-1", "0", "AAAA"),
      piece(good, "4", "-1", "AAAA"),
      piece(good, "4", "0", "not base64!"),
      piece(good, "\"4\"", "0", "AAAA"),
    ],
    assert_request_refused,
  )

  // A binding of the wrong length is refused before the blob is looked at.
  assert_request_refused(
    "{\"kind\":\"blob_status\",\"binding\":\"AAAA\",\"digest\":\""
    <> good
    <> "\"}",
  )
}

pub fn an_oversized_blob_piece_is_refused_test() {
  let text = fn(size: Int) {
    json.to_string(
      json.Object([
        #("kind", json.String("blob_put")),
        #("binding", json.String(bit_array.base64_encode(binding(), True))),
        #(
          "piece",
          json.Object([
            #("digest", json.String(digest())),
            #("size", json.Int(size)),
            #("offset", json.Int(0)),
            #(
              "bytes",
              json.String(bit_array.base64_encode(
                bit_array.from_string(string.repeat("p", size)),
                True,
              )),
            ),
          ]),
        ),
      ]),
    )
  }

  let assert Ok(_request) = untrusted_codec.decode_request(parsed(text(1024)))
    as "A small piece is legal."
  let assert Error(_report) =
    untrusted_codec.decode_request(
      parsed(text(untrusted_wire.max_piece_bytes + 1)),
    )
    as "A blob piece beyond max_piece_bytes must be refused."
  Nil
}

pub fn an_outcome_encodes_the_same_bytes_every_time_test() {
  let outcome =
    effects.ToolCompleted(result: result_message(), terminate: False)
  let bytes = untrusted_codec.encode_outcome_bytes(outcome)
  assert untrusted_codec.encode_outcome_bytes(outcome) == bytes
  assert untrusted_codec.decode_outcome_bytes(bytes) == Ok(outcome)
  let assert Error(_report) =
    untrusted_codec.decode_outcome_bytes(<<"{\"kind\":\"done\"}">>)
    as "An outcome of an unknown kind is refused."
  let assert Error(_report) = untrusted_codec.decode_outcome_bytes(<<255>>)
    as "Bytes that are not text are refused."
  Nil
}

// --- callbacks -------------------------------------------------------------------

pub fn every_callback_round_trips_test() {
  assert_callback(untrusted_wire.EscalateCall(
    refused: refused(),
    remaining_ms: 900,
  ))

  assert_callback(untrusted_wire.FactGetCall(key: "loom/a"))
  assert_callback(untrusted_wire.FactPutCall(
    key: "loom/a",
    value: json.Object([#("v", json.Array([json.Int(1), json.Null]))]),
    expected: Some(4),
  ))
  assert_callback(untrusted_wire.FactPutCall(
    key: "loom/a",
    value: json.Bool(True),
    expected: None,
  ))
  assert_callback(untrusted_wire.FactPutBlindCall(
    key: "loom/a",
    value: json.String("x"),
  ))
  assert_callback(untrusted_wire.FactDeleteCall(key: "loom/a"))
  assert_callback(untrusted_wire.FactListCall(prefix: "loom/"))

  assert_callback(untrusted_wire.StrandActivityCall(strand: "main"))
  assert_callback(untrusted_wire.WakeCall(strand: "main", text: "wake up"))
  assert_callback(untrusted_wire.McpPlanCall)
  assert_callback(untrusted_wire.GitIdentityCall)
}

pub fn notices_holds_tails_and_capabilities_round_trip_test() {
  list.each(
    [
      notice.Job(id: "j1"),
      notice.Execution(id: "e1"),
      notice.Escalation(id: "x1", seq: 7),
    ],
    fn(work) {
      assert_callback(untrusted_wire.NotifyCall(
        strand: "main",
        work:,
        text: "finished",
      ))
    },
  )

  assert_callback(untrusted_wire.HoldsCall(
    caller: caller(agent.ToolCall),
    tool: "bash",
  ))
  assert_callback(untrusted_wire.HoldsCall(
    caller: caller(agent.Program(ordinal: 5)),
    tool: "fs_read",
  ))

  list.each([framing.Stdout, framing.Stderr], fn(stream) {
    assert_callback(untrusted_wire.TailCast(
      run: tool_run(),
      tail: tool.OutputTail(stream:, tail: "last lines\n", total_bytes: 4096),
    ))
  })

  list.each(
    [
      vet_policy.WorkspaceSeam,
      vet_policy.OrchestrationSeam,
      vet_policy.ExtensionSeam,
      vet_policy.ResidentSeam,
    ],
    fn(seam) {
      assert_callback(untrusted_wire.CapabilityCall(call: cap_call(seam)))
    },
  )
}

// --- answers ---------------------------------------------------------------------

pub fn every_answer_round_trips_test() {
  assert_answer(untrusted_wire.Decided(decision: escalate.Settle))
  assert_answer(
    untrusted_wire.Decided(
      decision: escalate.Resume(grants: [
        policy.GrantWritableRoot("/work"),
        policy.GrantLimit(field: policy.MemBytes, value: 1024),
      ]),
    ),
  )

  assert_answer(
    untrusted_wire.McpPlanAnswered(plan: protocol.McpPlan(
      served: [
        protocol.Facade(
          server: "fs",
          module_name: "mcp_fs",
          source: "pub fn read() { Nil }",
          surface: "read",
        ),
      ],
      expected: ["fs", "db"],
      host: option.Some(protocol.HostPlan(
        imports: ["cap/search", "cap/lsp"],
        withheld: ["lsp.rename"],
        module: option.Some(protocol.Facade(
          server: "aegis",
          module_name: "cap/aegis",
          source: "pub fn post_note() { Nil }",
          surface: "post_note",
        )),
      )),
    )),
  )

  // A host seam that only narrows carries no module.
  assert_answer(
    untrusted_wire.McpPlanAnswered(plan: protocol.McpPlan(
      served: [],
      expected: [],
      host: option.Some(protocol.HostPlan(
        imports: ["cap/search"],
        withheld: [],
        module: option.None,
      )),
    )),
  )

  assert_answer(
    untrusted_wire.GitIdentityAnswered(
      identity: Some(protocol.GitIdentity(name: "Ada", email: "ada@example.com")),
    ),
  )
  assert_answer(untrusted_wire.GitIdentityAnswered(identity: None))
}

pub fn every_fact_answer_round_trips_test() {
  let faults = [
    owner_services.StoreAbsent,
    owner_services.Conflict,
    owner_services.LeaseStolen(held_by: Some("other")),
    owner_services.LeaseStolen(held_by: None),
    owner_services.Failed(detail: "disk"),
    owner_services.NotServed(key: "k"),
  ]

  assert_answer(
    untrusted_wire.FactCellAnswered(
      answer: Ok(Some(api.FactCell(value: json.Int(3), seq: 9))),
    ),
  )
  assert_answer(untrusted_wire.FactCellAnswered(answer: Ok(None)))
  assert_answer(untrusted_wire.FactSeqAnswered(answer: Ok(12)))
  assert_answer(untrusted_wire.FactDoneAnswered(answer: Ok(Nil)))
  assert_answer(
    untrusted_wire.FactListAnswered(
      answer: Ok([#("a", json.Int(1)), #("b", json.Null)]),
    ),
  )

  list.each(faults, fn(fault) {
    assert_answer(untrusted_wire.FactCellAnswered(answer: Error(fault)))
    assert_answer(untrusted_wire.FactSeqAnswered(answer: Error(fault)))
    assert_answer(untrusted_wire.FactDoneAnswered(answer: Error(fault)))
    assert_answer(untrusted_wire.FactListAnswered(answer: Error(fault)))
  })
}

pub fn notice_answers_round_trip_test() {
  list.each(
    [notice.Delivered, notice.AlreadyDelivered, notice.Withheld],
    fn(delivered) {
      assert_answer(untrusted_wire.NotifyAnswered(answer: Ok(delivered)))
    },
  )
  assert_answer(untrusted_wire.NotifyAnswered(answer: Error("no such strand")))

  assert_answer(untrusted_wire.ActivityAnswered(answer: Ok(notice.Busy)))
  assert_answer(untrusted_wire.ActivityAnswered(answer: Ok(notice.Idle)))
  assert_answer(untrusted_wire.ActivityAnswered(answer: Error("gone")))

  assert_answer(untrusted_wire.WakeAnswered(answer: Ok(Nil)))
  assert_answer(untrusted_wire.WakeAnswered(answer: Error("asleep")))
}

pub fn holds_and_capability_answers_round_trip_test() {
  let refusals = [
    agent.AgencyUnavailable,
    agent.MalformedHandle(text: "?"),
    agent.NotAddressable(strand: "a"),
    agent.NotADescendant(strand: "b"),
    agent.DepthCapReached(depth: 3),
    agent.FanOutCapReached(live: 4, cap: 4),
    agent.UnknownTool(name: "t"),
    agent.InvalidArgument(reason: "r"),
    agent.ParentRunEnded(strand: "c"),
    agent.NameAlreadyMinted(strand: "d"),
    agent.ToolNotHeld(tool: "bash"),
    agent.RemoteRefused(orchestrator: "o", reason: "r"),
    agent.RemoteSilent(orchestrator: "o"),
    agent.PlaneFailed(reason: "p"),
  ]

  assert_answer(untrusted_wire.HoldsAnswered(answer: Ok(Nil)))
  list.each(refusals, fn(refusal) {
    assert_answer(untrusted_wire.HoldsAnswered(answer: Error(refusal)))
  })

  assert_answer(
    untrusted_wire.CapabilityAnswered(
      answer: Ok(framing.CapOk(value: msgpack.StringValue("done"))),
    ),
  )
  assert_answer(
    untrusted_wire.CapabilityAnswered(
      answer: Ok(framing.CapErr(code: "bad_args", message: "no")),
    ),
  )
  assert_answer(
    untrusted_wire.CapabilityAnswered(
      answer: Error(satellite.CapDenial(code: "owner_unavailable", message: "m")),
    ),
  )
}

pub fn a_result_schema_refusal_is_carried_as_a_plane_failure_test() {
  let assert Ok(schema) =
    agent.parse_result_schema(
      json.Object([
        #("type", json.String("object")),
        #(
          "properties",
          json.Object([
            #("answer", json.Object([#("type", json.String("string"))])),
          ]),
        ),
      ]),
    )
    as "The test's schema must parse."
  let unmet =
    agent.ResultSchemaUnmet(
      schema:,
      received: json.Null,
      mismatch: agent.NotAnObject(received: "null"),
    )
  let frame =
    untrusted_wire.Answer(
      binding: binding(),
      id: 1,
      answer: untrusted_wire.HoldsAnswered(answer: Error(unmet)),
    )

  assert through(frame)
    == Ok(untrusted_wire.Answer(
      binding: binding(),
      id: 1,
      answer: untrusted_wire.HoldsAnswered(
        answer: Error(agent.PlaneFailed(reason: "result schema unmet")),
      ),
    ))
}

pub fn an_execution_denial_comes_back_without_its_enforcement_list_test() {
  let execution =
    escalate.Refused(
      ..refused(),
      denial: escalation.Denial(
        reason: "the helper refused",
        source: escalation.ExecutionDenial(enforcement: ["landlock"]),
        wanted: [policy.GrantEnv("TOKEN")],
      ),
    )
  let frame =
    untrusted_wire.Callback(
      binding: binding(),
      id: 1,
      callback: untrusted_wire.EscalateCall(refused: execution, remaining_ms: 5),
    )

  let assert Ok(untrusted_wire.Callback(
    callback: untrusted_wire.EscalateCall(refused: found, ..),
    ..,
  )) = through(frame)
    as "An escalation must come back."
  assert found.denial.source == escalation.ExecutionDenial(enforcement: [])
  assert found.denial.wanted == [policy.GrantEnv("TOKEN")]
}

// --- hostile frames --------------------------------------------------------------

pub fn bytes_that_are_not_text_are_refused_test() {
  let assert Error(_report) = untrusted_codec.decode_envelope(<<255, 254, 253>>)
    as "Bytes that are not UTF-8 must be refused."
  let assert Error(_report) = untrusted_codec.decode_envelope(<<>>)
    as "An empty frame must be refused."
  Nil
}

pub fn json_that_is_not_an_object_is_refused_test() {
  assert_refused("not json")
  assert_refused("[1]")
  assert_refused("7")
  assert_refused("\"hello\"")
  assert_refused("null")
  assert_refused("{\"frame\":")
  assert_refused("{\"frame\":\"hello\",\"wire\":1,\"protocol\":6} trailing")
}

pub fn an_unknown_or_malformed_frame_name_is_refused_test() {
  assert_refused("{}")
  assert_refused("{\"frame\":\"goodbye\"}")
  assert_refused("{\"frame\":7,\"wire\":1,\"protocol\":6}")
  assert_refused("{\"frame\":null}")
  assert_refused("{\"frame\":[\"hello\"]}")
}

pub fn a_missing_or_mistyped_header_field_is_refused_test() {
  assert_refused("{\"frame\":\"hello\",\"wire\":1}")
  assert_refused("{\"frame\":\"hello\",\"wire\":\"1\",\"protocol\":6}")
  assert_refused("{\"frame\":\"hello\",\"wire\":1.5,\"protocol\":6}")
  assert_refused("{\"frame\":\"welcome\",\"wire\":true,\"protocol\":6}")
  assert_refused("{\"frame\":\"request\",\"id\":1}")
  assert_refused("{\"frame\":\"request\",\"id\":\"1\",\"body\":{}}")
  assert_refused("{\"frame\":\"cancel\"}")
  assert_refused("{\"frame\":\"response\",\"body\":{}}")
}

pub fn an_integer_beyond_sixty_four_bits_is_refused_test() {
  assert_refused(
    "{\"frame\":\"hello\",\"wire\":99999999999999999999999,\"protocol\":6}",
  )
}

pub fn an_id_below_one_is_refused_test() {
  assert_refused("{\"frame\":\"cancel\",\"id\":0}")
  assert_refused("{\"frame\":\"cancel\",\"id\":-1}")
  assert_refused("{\"frame\":\"request\",\"id\":0,\"body\":{}}")
  assert_refused("{\"frame\":\"response\",\"id\":-4,\"body\":{}}")

  let zero = "AAECAwQFBgcICQoLDA0ODw=="
  assert_refused(
    "{\"frame\":\"callback\",\"binding\":\""
    <> zero
    <> "\",\"id\":0,\"body\":{}}",
  )
  assert_refused(
    "{\"frame\":\"answer\",\"binding\":\""
    <> zero
    <> "\",\"id\":-1,\"body\":{}}",
  )

  let assert Ok(_envelope) =
    untrusted_codec.decode_envelope(bit_array.from_string(
      "{\"frame\":\"cancel\",\"id\":1}",
    ))
    as "Id 1 is the smallest legal id."
  Nil
}

pub fn a_binding_must_be_exactly_sixteen_bytes_test() {
  let frame = fn(bytes: BitArray) {
    "{\"frame\":\"callback\",\"binding\":\""
    <> bit_array.base64_encode(bytes, True)
    <> "\",\"id\":1,\"body\":{\"kind\":\"mcp_plan\"}}"
  }

  assert_refused(frame(<<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>))
  assert_refused(
    frame(<<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17>>),
  )
  assert_refused(frame(<<>>))

  let assert Ok(_envelope) =
    untrusted_codec.decode_envelope(bit_array.from_string(frame(binding())))
    as "Sixteen bytes is a binding."
  Nil
}

pub fn base64_must_be_canonical_and_padded_test() {
  let callback = fn(binding: String) {
    "{\"frame\":\"callback\",\"binding\":"
    <> binding
    <> ",\"id\":1,\"body\":{\"kind\":\"mcp_plan\"}}"
  }

  assert_refused(callback("\"!!!!\""))
  assert_refused(callback("\"AAECAwQFBgcICQoLDA0ODw\""))
  assert_refused(callback("\"AAECAwQF BgcICQoLDA0ODw==\""))
  assert_refused(callback("\"AAECAwQFBgcICQoLDA0ODw=\""))
  assert_refused(callback("12"))
  assert_refused(callback("null"))
}

pub fn a_duplicated_key_is_refused_test() {
  assert_refused(
    "{\"frame\":\"hello\",\"frame\":\"welcome\",\"wire\":1,\"protocol\":6}",
  )
  assert_refused("{\"frame\":\"hello\",\"wire\":1,\"wire\":2,\"protocol\":6}")
}

pub fn json_nested_three_hundred_deep_is_refused_test() {
  let deep = string.repeat("[", 300) <> string.repeat("]", 300)
  assert_refused("{\"frame\":\"request\",\"id\":1,\"body\":" <> deep <> "}")

  let deep_objects =
    string.repeat("{\"a\":", 300) <> "1" <> string.repeat("}", 300)
  assert_refused(
    "{\"frame\":\"response\",\"id\":1,\"body\":" <> deep_objects <> "}",
  )
}

pub fn a_frame_beyond_the_limit_is_refused_before_it_is_parsed_test() {
  let assert Ok(_envelope) =
    untrusted_codec.decode_envelope(bit_array.from_string(
      "{\"frame\":\"cancel\",\"id\":1}",
    ))
    as "A small frame must be read."

  let oversized =
    bit_array.from_string(
      "{\"frame\":\"cancel\",\"id\":1,\"pad\":\""
      <> string.repeat("a", untrusted_wire.max_frame_bytes)
      <> "\"}",
    )
  let assert Error(_report) = untrusted_codec.decode_envelope(oversized)
    as "A frame beyond max_frame_bytes must be refused."
  Nil
}

/// Asserts that a request body is refused.
fn assert_request_refused(text: String) -> Nil {
  let assert Error(_report) = untrusted_codec.decode_request(parsed(text))
    as "A malformed request must be refused."
  Nil
}

pub fn malformed_request_bodies_are_refused_test() {
  assert_request_refused("[]")
  assert_request_refused("{}")
  assert_request_refused("{\"kind\":7}")
  assert_request_refused("{\"kind\":\"launch\"}")

  assert_request_refused("{\"kind\":\"query\"}")
  assert_request_refused("{\"kind\":\"query\",\"key\":3}")
  assert_request_refused(
    "{\"kind\":\"query\",\"key\":{\"session\":\"s\",\"op\":\"o\",\"step\":\"t\"}}",
  )
  assert_request_refused(
    "{\"kind\":\"query\",\"key\":{\"session\":\"s\",\"op\":\"o\",\"step\":\"t\",\"source_index\":\"0\"}}",
  )
  assert_request_refused("{\"kind\":\"list_unacked\",\"session\":false}")
}

pub fn a_negative_size_offset_or_duration_is_refused_test() {
  assert_request_refused(
    "{\"kind\":\"state_fetch\",\"hash\":\"h\",\"offset\":-1}",
  )
  assert_request_refused(
    "{\"kind\":\"query\",\"key\":{\"session\":\"s\",\"op\":\"o\",\"step\":\"t\",\"source_index\":-1}}",
  )

  let assert Ok(_request) =
    untrusted_codec.decode_request(parsed(
      "{\"kind\":\"state_fetch\",\"hash\":\"h\",\"offset\":0}",
    ))
    as "Offset zero is legal."

  let verdict =
    "{\"kind\":\"chunk\",\"verdict\":{\"kind\":\"accepted\",\"held\":-1}}"
  let assert Error(_report) =
    untrusted_codec.decode_response(untrusted_wire.ChunkKind, parsed(verdict))
    as "A negative held count must be refused."

  let escalate =
    untrusted_wire.EscalateCall(refused: refused(), remaining_ms: 5)
  let escalation_text =
    string.replace(
      bit_array_text(
        untrusted_codec.encode_frame(untrusted_wire.Callback(
          binding: binding(),
          id: 1,
          callback: escalate,
        )),
      ),
      "\"remaining_ms\":5",
      "\"remaining_ms\":-5",
    )
  assert_refused_callback(escalation_text)
}

/// The text of encoded bytes.
fn bit_array_text(bytes: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(bytes) as "The codec writes UTF-8."
  text
}

/// Asserts that a whole callback frame, given as text, does not decode.
fn assert_refused_callback(text: String) -> Nil {
  let assert Ok(untrusted_codec.CallbackEnvelope(body:, ..)) =
    untrusted_codec.decode_envelope(bit_array.from_string(text))
    as "The header of the edited callback is still well formed."
  let assert Error(_report) = untrusted_codec.decode_callback(body)
    as "The edited callback body must be refused."
  Nil
}

pub fn a_token_longer_than_sixty_four_bytes_is_refused_test() {
  let attach = fn(token: BitArray) {
    "{\"kind\":\"attach\",\"version\":6,\"session\":\"s\",\"workspace\":\"w\",\"incarnation\":1,\"token\":\""
    <> bit_array.base64_encode(token, True)
    <> "\",\"binding\":\"AAECAwQFBgcICQoLDA0ODw==\"}"
  }

  let sixty_four = bit_array.from_string(string.repeat("t", 64))
  let sixty_five = bit_array.from_string(string.repeat("t", 65))

  let assert Ok(_request) =
    untrusted_codec.decode_request(parsed(attach(sixty_four)))
    as "A token of 64 bytes is the longest legal one."
  let assert Error(_report) =
    untrusted_codec.decode_request(parsed(attach(sixty_five)))
    as "A token of 65 bytes must be refused."
  Nil
}

pub fn malformed_callback_bodies_are_refused_test() {
  let refused_body = fn(text: String) {
    let assert Error(_report) = untrusted_codec.decode_callback(parsed(text))
      as "A malformed callback must be refused."
    Nil
  }

  refused_body("{}")
  refused_body("{\"kind\":\"dial_out\"}")
  refused_body("{\"kind\":\"fact_get\"}")
  refused_body("{\"kind\":\"fact_get\",\"key\":3}")
  refused_body("{\"kind\":\"fact_put\",\"key\":\"k\",\"value\":1}")
  refused_body(
    "{\"kind\":\"fact_put\",\"key\":\"k\",\"value\":1,\"expected\":-2}",
  )
  refused_body(
    "{\"kind\":\"notify\",\"strand\":\"s\",\"work\":{\"kind\":\"job\"},\"text\":\"t\"}",
  )
  refused_body("{\"kind\":\"capability\",\"call\":{}}")
}

pub fn a_capability_whose_arguments_are_not_msgpack_is_refused_test() {
  let call = fn(args: String) {
    "{\"kind\":\"capability\",\"call\":{\"strand\":\"main\",\"op_id\":\""
    <> ids.op_id_to_string(op())
    <> "\",\"step_id\":\"s\",\"source_index\":0,\"seam\":\"workspace\",\"cap\":\"c\",\"args\":"
    <> args
    <> ",\"ordinal\":0}}"
  }

  // 0xc1 is the one byte msgpack never assigns.
  let never_assigned = bit_array.base64_encode(<<0xc1>>, True)
  let nil_value = bit_array.base64_encode(<<0xc0>>, True)

  let assert Error(_report) =
    untrusted_codec.decode_callback(
      parsed(call("\"" <> never_assigned <> "\"")),
    )
    as "Bytes that are not msgpack must be refused."
  let assert Error(_report) =
    untrusted_codec.decode_callback(parsed(call("null")))
    as "Null is not msgpack bytes."
  let assert Ok(_callback) =
    untrusted_codec.decode_callback(parsed(call("\"" <> nil_value <> "\"")))
    as "A well-formed msgpack nil is legal arguments."
  Nil
}

pub fn a_value_msgpack_cannot_encode_is_refused_by_the_receiver_test() {
  let call =
    owner_services.OwnerCapCall(
      ..cap_call(vet_policy.WorkspaceSeam),
      args: msgpack.IntValue(1_180_591_620_717_411_303_424),
    )
  let frame =
    untrusted_wire.Callback(
      binding: binding(),
      id: 1,
      callback: untrusted_wire.CapabilityCall(call:),
    )

  let assert Error(_report) = through(frame)
    as "A value that cannot be encoded must not arrive as another value."
  Nil
}

pub fn an_oversized_piece_is_refused_test() {
  let piece_text = fn(size: Int) {
    let state_text = state_object.encode(state())
    json.to_string(
      json.Object([
        #("kind", json.String("state_chunk")),
        #(
          "piece",
          json.Object([
            #("state", json.String(state_text)),
            #("offset", json.Int(0)),
            #(
              "bytes",
              json.String(bit_array.base64_encode(
                bit_array.from_string(string.repeat("p", size)),
                True,
              )),
            ),
          ]),
        ),
      ]),
    )
  }

  let assert Ok(_request) =
    untrusted_codec.decode_request(parsed(piece_text(1024)))
    as "A small piece is legal."
  let assert Error(_report) =
    untrusted_codec.decode_request(
      parsed(piece_text(untrusted_wire.max_piece_bytes + 1)),
    )
    as "A piece beyond max_piece_bytes must be refused."
  Nil
}

pub fn a_state_that_does_not_validate_is_refused_test() {
  let piece_with = fn(state_text: String) {
    json.to_string(
      json.Object([
        #("kind", json.String("state_chunk")),
        #(
          "piece",
          json.Object([
            #("state", json.String(state_text)),
            #("offset", json.Int(0)),
            #("bytes", json.String("")),
          ]),
        ),
      ]),
    )
  }

  let assert Error(_report) =
    untrusted_codec.decode_request(
      parsed(piece_with("{\"hash\":\"../../etc\"}")),
    )
    as "A state that is not a state object must be refused."
  let assert Error(_report) =
    untrusted_codec.decode_request(parsed(piece_with("not json")))
    as "Text that is not JSON is not a state."
  Nil
}

// --- the reply kind is checked ---------------------------------------------------

/// One response of every kind, in the order of `ResponseKind`.
fn one_response_of_each_kind() -> List(untrusted_wire.Response) {
  [
    untrusted_wire.AttachAnswered(answer: Error(protocol.NoSuchScope)),
    untrusted_wire.RunAnswered(answer: protocol.RunLost),
    untrusted_wire.LookupAnswered(answer: Ok(protocol.Admitted)),
    untrusted_wire.UnackedAnswered(
      answer: Ok(protocol.Unacked(terminal: [], unknown: [], executions: [])),
    ),
    untrusted_wire.CloseAnswered(answer: Ok(protocol.AllRetired)),
    untrusted_wire.CaptureAnswered(answer: Ok(None)),
    untrusted_wire.ApplyAnswered(answer: Ok("ref")),
    untrusted_wire.ChunkAnswered(verdict: state_transfer.Accepted(held: 1)),
    untrusted_wire.StatusAnswered(answer: Ok(state_transfer.Complete)),
    untrusted_wire.FetchAnswered(fetched: state_transfer.NotHeld),
    untrusted_wire.BlobStatusAnswered(answer: Ok(blob_transfer.Absent)),
    untrusted_wire.BlobPutAnswered(verdict: blob_transfer.Stored),
    untrusted_wire.OutcomePieceAnswered(piece: untrusted_wire.OutcomeNotHeld(
      reason: "gone",
    )),
    untrusted_wire.ExecutionAnswered(answer: protocol.ExecutionLost),
    untrusted_wire.ClearedAnswered(answer: Error(broker.BrokerUnavailable)),
  ]
}

/// Every response kind.
fn every_response_kind() -> List(untrusted_wire.ResponseKind) {
  [
    untrusted_wire.AttachKind,
    untrusted_wire.RunKind,
    untrusted_wire.LookupKind,
    untrusted_wire.UnackedKind,
    untrusted_wire.CloseKind,
    untrusted_wire.CaptureKind,
    untrusted_wire.ApplyKind,
    untrusted_wire.ChunkKind,
    untrusted_wire.StatusKind,
    untrusted_wire.FetchKind,
    untrusted_wire.BlobStatusKind,
    untrusted_wire.BlobPutKind,
    untrusted_wire.OutcomePieceKind,
    untrusted_wire.ExecutionKind,
    untrusted_wire.ClearedKind,
  ]
}

pub fn a_response_decodes_only_against_its_own_kind_test() {
  assert list.length(one_response_of_each_kind()) == 15

  list.each(one_response_of_each_kind(), fn(response) {
    let body = body_of(untrusted_wire.Response(id: 1, response:))

    list.each(every_response_kind(), fn(kind) {
      case kind == response_kind_of(response) {
        True -> {
          assert untrusted_codec.decode_response(kind, body) == Ok(response)
        }
        False -> {
          let assert Error(_report) =
            untrusted_codec.decode_response(kind, body)
            as "A response of another kind must be refused."
          Nil
        }
      }
    })
  })
}

pub fn a_well_formed_run_answer_is_not_a_lookup_test() {
  let run =
    body_of(untrusted_wire.Response(
      id: 1,
      response: untrusted_wire.RunAnswered(answer: protocol.RunLost),
    ))

  let assert Error(_report) =
    untrusted_codec.decode_response(untrusted_wire.LookupKind, run)
    as "A run answer is a protocol violation where a lookup is expected."
  assert untrusted_codec.decode_response(untrusted_wire.RunKind, run)
    == Ok(untrusted_wire.RunAnswered(answer: protocol.RunLost))
}

/// One answer of every kind, in the order of `AnswerKind`.
fn one_answer_of_each_kind() -> List(untrusted_wire.Answer) {
  [
    untrusted_wire.Decided(decision: escalate.Settle),
    untrusted_wire.FactCellAnswered(answer: Ok(None)),
    untrusted_wire.FactSeqAnswered(answer: Ok(1)),
    untrusted_wire.FactDoneAnswered(answer: Ok(Nil)),
    untrusted_wire.FactListAnswered(answer: Ok([])),
    untrusted_wire.NotifyAnswered(answer: Ok(notice.Delivered)),
    untrusted_wire.ActivityAnswered(answer: Ok(notice.Idle)),
    untrusted_wire.WakeAnswered(answer: Ok(Nil)),
    untrusted_wire.HoldsAnswered(answer: Ok(Nil)),
    untrusted_wire.CapabilityAnswered(
      answer: Ok(framing.CapOk(msgpack.NilValue)),
    ),
    untrusted_wire.McpPlanAnswered(plan: protocol.empty_mcp_plan()),
    untrusted_wire.GitIdentityAnswered(identity: None),
    untrusted_wire.LaunchAnswered(answer: Ok(json.String("exec-1"))),
    untrusted_wire.InteractAnswered(answer: Ok(json.String("exec-1"))),
  ]
}

/// Every answer kind.
fn every_answer_kind() -> List(untrusted_wire.AnswerKind) {
  [
    untrusted_wire.DecidedKind,
    untrusted_wire.FactCellKind,
    untrusted_wire.FactSeqKind,
    untrusted_wire.FactDoneKind,
    untrusted_wire.FactListKind,
    untrusted_wire.NotifyKind,
    untrusted_wire.ActivityKind,
    untrusted_wire.WakeKind,
    untrusted_wire.HoldsKind,
    untrusted_wire.CapabilityKind,
    untrusted_wire.McpPlanKind,
    untrusted_wire.GitIdentityKind,
    untrusted_wire.LaunchKind,
    untrusted_wire.InteractKind,
  ]
}

pub fn an_answer_decodes_only_against_its_own_kind_test() {
  assert list.length(one_answer_of_each_kind()) == 14

  list.each(one_answer_of_each_kind(), fn(answer) {
    let body =
      body_of(untrusted_wire.Answer(binding: binding(), id: 1, answer:))

    list.each(every_answer_kind(), fn(kind) {
      case kind == answer_kind_of(answer) {
        True -> {
          assert untrusted_codec.decode_answer(kind, body) == Ok(answer)
        }
        False -> {
          let assert Error(_report) = untrusted_codec.decode_answer(kind, body)
            as "An answer of another kind must be refused."
          Nil
        }
      }
    })
  })
}

pub fn a_reply_nobody_awaits_is_refused_test() {
  let response =
    untrusted_codec.encode_frame(untrusted_wire.Response(
      id: 3,
      response: untrusted_wire.RunAnswered(answer: protocol.RunLost),
    ))
  let answer =
    untrusted_codec.encode_frame(untrusted_wire.Answer(
      binding: binding(),
      id: 3,
      answer: untrusted_wire.WakeAnswered(answer: Ok(Nil)),
    ))

  let nobody_responds = fn(_id) { None }
  let nobody_answers = fn(_binding, _id) { None }

  let assert Error(_report) =
    untrusted_codec.decode_frame(response, nobody_responds, nobody_answers)
    as "A response for an id nothing was sent under must be refused."
  let assert Error(_report) =
    untrusted_codec.decode_frame(answer, nobody_responds, nobody_answers)
    as "An answer to a callback nothing sent must be refused."
  Nil
}

pub fn a_result_object_with_both_sides_or_neither_is_refused_test() {
  let lookup = fn(text: String) {
    untrusted_codec.decode_response(
      untrusted_wire.LookupKind,
      parsed("{\"kind\":\"lookup\",\"answer\":" <> text <> "}"),
    )
  }

  let assert Ok(_response) = lookup("{\"ok\":{\"kind\":\"missing\"}}")
    as "One side is a result."
  let assert Error(_report) = lookup("{}") as "Neither side is not a result."
  let assert Error(_report) =
    lookup(
      "{\"ok\":{\"kind\":\"missing\"},\"error\":{\"kind\":\"stale_token\"}}",
    )
    as "Both sides is not a result."
  let assert Error(_report) = lookup("[]") as "An array is not a result."
  let assert Error(_report) = lookup("{\"ok\":{\"kind\":\"vanished\"}}")
    as "An unknown lookup kind is refused."
  let assert Error(_report) = lookup("{\"error\":{\"kind\":\"vanished\"}}")
    as "An unknown refusal kind is refused."
  Nil
}

// --- a property over the values a host answers with -------------------------------

// The seed the round-trip property is drawn from, so that a red run is the
// same red run everywhere, and how many cases it checks.
const property_seed = 1109

const property_cases = 200

/// A refusal picked by number, carrying the drawn text and number.
fn refusal_of(pick: Int, text: String, number: Int) -> protocol.Refusal {
  case pick {
    0 -> protocol.StaleToken
    1 -> protocol.StaleIncarnation(stored: number)
    2 -> protocol.ScopeNotOpen
    3 -> protocol.ScopeClosing
    4 -> protocol.UncleanClose(count: number)
    5 -> protocol.CapacityExhausted(limit: number)
    6 -> protocol.BudgetExhausted(limit: number)
    7 -> protocol.VersionMismatch(supported: number)
    8 -> protocol.WorkspaceMismatch(stored: text)
    9 -> protocol.NoSuchScope
    10 -> protocol.NoPlane(reason: text)
    11 -> protocol.PlaneBuilding
    12 -> protocol.WorktreeFailed(reason: text)
    13 -> protocol.UnknownHandle
    14 -> protocol.AlreadyPublished
    15 -> protocol.StaleGeneration(serving: number)
    16 -> protocol.NoEvolution(reason: text)
    17 -> protocol.NoStates(reason: text)
    18 -> protocol.Invalid(reason: text)
    19 -> protocol.ExecutorFault(reason: text)
    _ -> protocol.Unreachable(reason: text)
  }
}

/// A lookup picked by number.
fn lookup_of(pick: Int, text: String) -> protocol.Lookup {
  case pick {
    0 -> protocol.Missing
    1 -> protocol.Admitted
    2 -> protocol.Terminal(outcome: effects.ToolFailed(reason: text))
    3 -> protocol.Unknown
    4 -> protocol.Fenced
    _ -> protocol.Executed(value: json.String(text))
  }
}

pub fn drawn_keys_refusals_and_lookups_round_trip_test() {
  let generator =
    qcheck.tuple4(
      qcheck.tuple3(qcheck.string(), qcheck.string(), qcheck.string()),
      qcheck.bounded_int(0, 1_000_000),
      qcheck.bounded_int(0, 20),
      qcheck.bounded_int(0, 5),
    )

  qcheck.default_config()
  |> qcheck.with_test_count(property_cases)
  |> qcheck.with_seed(qcheck.seed(property_seed))
  |> qcheck.run(generator, fn(drawn) {
    let #(#(session, step, text), number, refusal_pick, lookup_pick) = drawn
    let drawn_key =
      protocol.Key(session:, op: "op", step:, source_index: number)

    assert_request(untrusted_wire.QueryRequest(key: drawn_key))
    assert_response(
      untrusted_wire.LookupAnswered(
        answer: Error(refusal_of(refusal_pick, text, number)),
      ),
    )
    assert_response(
      untrusted_wire.LookupAnswered(answer: Ok(lookup_of(lookup_pick, text))),
    )
  })
}

// --- the broker tunnel (protocol-change/117) --------------------------------------

/// A tunnelled call's spec with every field set.
fn tunnel_spec() -> untrusted_wire.TunnelSpec {
  untrusted_wire.TunnelSpec(
    op_id: op(),
    step_id: "goal-check:1",
    base_policy: workspace_policy.base_policy("/executor/checkout"),
    requirements: workspace_policy.base_policy("/executor/checkout"),
    response: broker.ProceedNarrowed,
    argv: ["git", "status", "--porcelain=v2", "-z"],
    env: [#("PATH", "/usr/bin:/bin"), #("LC_ALL", "C"), #("PATH", "again")],
    cwd: "/executor/checkout",
    budget: budget.Budget(max_outstanding: 1, deadline_ms: 1_700_000_060_000),
  )
}

/// A completed execution with every field away from its default.
fn exec_result() -> exec.ExecResult {
  exec.ExecResult(
    code: 2,
    signal: 0,
    stdout_bytes: 1_048_576,
    stderr_bytes: 12,
    stdout_truncated: True,
    stderr_truncated: False,
    enforcement: ["landlock", "seccomp", "skip:rlimit_as"],
    degraded: False,
    wall_ms: 1500,
    timed_out: False,
    cancelled: True,
  )
}

/// Every `ExecFailure`, each once.
fn every_exec_failure() -> List(exec.ExecFailure) {
  [
    exec.NotReady,
    exec.HandshakeTimeout,
    exec.HelperBusy,
    exec.DegradedHelper(features: ["landlock", "skip:bwrap"]),
    exec.DegradedExecution(result: exec_result()),
    exec.RefusedByHelper(code: "bad_policy", message: "no such root"),
    exec.ChannelFault(
      fault: framing.CorruptFrame(report: corruption.report(
        at: "broker/framing",
        on: "frame 3",
        expected: "a msgpack map",
        context: "0xc1",
      )),
    ),
    exec.ChannelFault(fault: framing.VersionMismatch(version: 9)),
    exec.ChannelFault(fault: framing.OversizedFrame(declared_bytes: 99_999_999)),
    exec.ChannelClosed(status: 137),
    exec.ProtocolViolation(kind: "exec_start"),
    exec.ProtocolVersionMismatch(helper: 5, broker: 6),
    exec.SendFailed,
    exec.CancelEscalated,
    exec.HeartbeatMissed,
    exec.HelperUnresponsive,
    exec.ExecutionLost(cause: exec.HelperActorDown),
    exec.ExecutionLost(cause: exec.RelayDown),
    exec.ExecutionLost(cause: exec.ExecutorClosing),
  ]
}

/// Every `broker.Refusal`, with every variant of every value inside it, save
/// the one the codec carries lossily (see
/// `an_abnormal_actor_exit_is_carried_as_its_printed_form_test`).
fn every_broker_refusal() -> List(broker.Refusal) {
  let policy_errors = [
    policy.RelativePath(path: "work"),
    policy.NegativeLimit(field: policy.CpuSeconds, value: -1),
    policy.NegativeLimit(field: policy.WallSeconds, value: -2),
    policy.NegativeLimit(field: policy.MemBytes, value: -3),
    policy.NegativeLimit(field: policy.Pids, value: -4),
    policy.NegativeLimit(field: policy.FsizeBytes, value: -5),
    policy.NegativeLimit(field: policy.OutputBytes, value: -6),
    policy.ScratchIsRoot,
    policy.MountOverlapsProtected(mount: "/a", protected: "/a/b"),
    policy.DuplicateMount(path: "/a"),
    policy.MountPathTrailingSlash(path: "/a/"),
    policy.MountPathParentSegment(path: "/a/../b"),
    policy.MountShadowsWritableRoot(mount: "/", writable_root: "/work"),
  ]
  let spawn_errors = [
    exec.PolicyUnencodable(error: msgpack.IntegerOutOfRange(
      value: 99_999_999_999_999_999_999_999,
    )),
    exec.PolicyUnencodable(error: msgpack.UnencodableLength(
      length: 5_000_000_000,
    )),
    exec.PolicyFileFailed,
    exec.PortOpenFailed,
    exec.ActorFailed(error: actor.InitTimeout),
    exec.ActorFailed(error: actor.InitFailed("no slot")),
    exec.ActorFailed(error: actor.InitExited(process.Normal)),
    exec.ActorFailed(error: actor.InitExited(process.Killed)),
    exec.HandshakeFailed(failure: exec.ProtocolVersionMismatch(1, 2)),
  ]

  list.flatten([
    [
      broker.PolicyRefused(
        denial: escalation.Denial(
          reason: "network is off",
          source: escalation.PolicyDenial,
          wanted: [policy.GrantEnv("TOKEN"), policy.GrantWritableRoot("/work")],
        ),
      ),
    ],
    list.map(policy_errors, broker.InvalidPolicy),
    [
      broker.BudgetRefused(refusal: budget.OutstandingCapReached(cap: 8)),
      broker.BudgetRefused(refusal: budget.DeadlinePassed(deadline_ms: 77)),
      broker.MintRefused(error: token.EntropyFailure(got_bytes: 3)),
      broker.MintRefused(error: token.DuplicateToken),
      broker.NoHelper(error: exec.AllBusy(size: 4)),
      broker.NoHelper(error: exec.PoolUnavailable),
    ],
    list.map(spawn_errors, fn(error) {
      broker.NoHelper(exec.SpawnFailed(error))
    }),
    [broker.OperationAborted, broker.BrokerUnavailable],
  ])
}

pub fn a_clear_call_round_trips_test() {
  assert_request(untrusted_wire.ClearCallRequest(
    binding: binding(),
    spec: tunnel_spec(),
    waiting_ms: 29_000,
  ))
  assert_request(untrusted_wire.ClearCallRequest(
    binding: binding(),
    spec: untrusted_wire.TunnelSpec(
      ..tunnel_spec(),
      response: broker.RefuseNarrowed,
      argv: [],
      env: [],
    ),
    waiting_ms: 0,
  ))
}

pub fn every_cleared_answer_round_trips_test() {
  assert_response(untrusted_wire.ClearedAnswered(answer: Ok(Nil)))
  list.each(every_broker_refusal(), fn(refusal) {
    assert_response(untrusted_wire.ClearedAnswered(answer: Error(refusal)))
  })
}

pub fn every_call_event_round_trips_test() {
  let assert_event = fn(event) {
    let frame = untrusted_wire.CallEvent(call: 21, event:)
    assert through(frame) == Ok(frame)
  }

  assert_event(untrusted_wire.TunnelOutput(framing.Stdout, <<"diff --git">>))
  assert_event(untrusted_wire.TunnelOutput(framing.Stderr, <<0, 255, 10>>))
  assert_event(untrusted_wire.TunnelSettled(broker.CallExited(exec_result())))
  list.each(every_exec_failure(), fn(failure) {
    assert_event(untrusted_wire.TunnelSettled(broker.CallFailed(failure)))
  })
}

// An initialiser's abnormal exit carries a term, which no frame carries; the
// reason arrives as its printed form under `InitFailed`, and nothing else in
// the refusal changes.
pub fn an_abnormal_actor_exit_is_carried_as_its_printed_form_test() {
  let sent =
    broker.NoHelper(
      exec.SpawnFailed(
        exec.ActorFailed(
          actor.InitExited(process.Abnormal(reason: dynamic.string("boom"))),
        ),
      ),
    )
  let frame =
    untrusted_wire.Response(
      id: 12,
      response: untrusted_wire.ClearedAnswered(answer: Error(sent)),
    )
  let assert Ok(untrusted_wire.Response(
    response: untrusted_wire.ClearedAnswered(answer: Error(broker.NoHelper(exec.SpawnFailed(exec.ActorFailed(actor.InitFailed(
      reason,
    )))))),
    ..,
  )) = through(frame)
    as "the abnormal exit arrives as an initialiser failure"
  assert string.contains(reason, "boom")
}

/// A `clear_call` body whose spec has `member` set to `value`, every other
/// field as `tunnel_spec` has it.
fn clear_call_with(member: String, value: JsonValue) -> JsonValue {
  let assert json.Object(fields) =
    body_of(untrusted_wire.Request(
      id: 1,
      request: untrusted_wire.ClearCallRequest(
        binding: binding(),
        spec: tunnel_spec(),
        waiting_ms: 1000,
      ),
    ))
    as "a request body is an object"
  json.Object(
    list.map(fields, fn(field) {
      case field {
        #("spec", json.Object(spec)) -> #(
          "spec",
          json.Object(
            list.append(list.filter(spec, fn(entry) { entry.0 != member }), [
              #(member, value),
            ]),
          ),
        )
        other -> other
      }
    }),
  )
}

/// A `clear_call` body with `waiting_ms` set to `value`.
fn clear_call_waiting(value: Int) -> JsonValue {
  let assert json.Object(fields) = clear_call_with("cwd", json.String("/w"))
    as "a request body is an object"
  json.Object(
    list.map(fields, fn(field) {
      case field {
        #("waiting_ms", _) -> #("waiting_ms", json.Int(value))
        other -> other
      }
    }),
  )
}

pub fn a_spec_that_names_grants_or_a_demand_is_refused_test() {
  let assert Ok(_request) =
    untrusted_codec.decode_request(clear_call_with("cwd", json.String("/w")))
    as "the body the refusals are cut from decodes"
  let assert Error(_report) =
    untrusted_codec.decode_request(clear_call_with("grants", json.Array([])))
    as "even an empty grants member is refused"
  let assert Error(_report) =
    untrusted_codec.decode_request(clear_call_with(
      "grants",
      json.Array([grant_codec_env("TOKEN")]),
    ))
    as "a spec carrying a grant is refused"
  let assert Error(_report) =
    untrusted_codec.decode_request(clear_call_with(
      "demand",
      json.String("best_effort"),
    ))
    as "a spec carrying an enforcement demand is refused"
  Nil
}

/// The JSON of an environment grant, as `client/grants` writes one.
fn grant_codec_env(name: String) -> JsonValue {
  json.Object([#("kind", json.String("env")), #("name", json.String(name))])
}

pub fn an_argv_or_env_past_its_bound_is_refused_test() {
  let argv = fn(count) {
    clear_call_with("argv", json.Array(list.repeat(json.String("a"), count)))
  }
  let pair =
    json.Object([#("name", json.String("A")), #("value", json.String("b"))])
  let env = fn(count) {
    clear_call_with("env", json.Array(list.repeat(pair, count)))
  }

  let assert Ok(_request) = untrusted_codec.decode_request(argv(4096))
    as "4,096 arguments are carried"
  let assert Error(_report) = untrusted_codec.decode_request(argv(4097))
    as "4,097 arguments are refused"
  let assert Ok(_request) = untrusted_codec.decode_request(env(1024))
    as "1,024 environment pairs are carried"
  let assert Error(_report) = untrusted_codec.decode_request(env(1025))
    as "1,025 environment pairs are refused"
  Nil
}

pub fn a_wait_or_deadline_outside_its_range_is_refused_test() {
  let largest = untrusted_codec.max_call_ms
  assert largest == 4_398_046_511_104
  let deadline = fn(value) {
    clear_call_with(
      "budget",
      json.Object([
        #("max_outstanding", json.Int(1)),
        #("deadline_ms", json.Int(value)),
      ]),
    )
  }

  let longest = untrusted_codec.max_call_wait_ms
  assert longest == 4_294_967_295
  let assert Ok(_request) =
    untrusted_codec.decode_request(clear_call_waiting(longest))
    as "a wait of 2^32 - 1 milliseconds is carried"
  let assert Error(_report) =
    untrusted_codec.decode_request(clear_call_waiting(longest + 1))
    as "a wait past what a receive's timeout holds is refused"
  let assert Error(_report) =
    untrusted_codec.decode_request(clear_call_waiting(-1))
    as "a negative wait is refused"
  let assert Ok(_request) = untrusted_codec.decode_request(deadline(largest))
    as "a deadline of 2^42 is carried"
  let assert Error(_report) =
    untrusted_codec.decode_request(deadline(largest + 1))
    as "a deadline past 2^42 is refused"
  let assert Error(_report) = untrusted_codec.decode_request(deadline(-1))
    as "a negative deadline is refused"
  let assert Error(_report) =
    untrusted_codec.decode_request(clear_call_with(
      "budget",
      json.Object([
        #("max_outstanding", json.Int(0)),
        #("deadline_ms", json.Int(0)),
      ]),
    ))
    as "a budget with no room for the call is refused"
  Nil
}

pub fn a_malformed_call_event_is_refused_test() {
  let event = fn(text: String) {
    untrusted_codec.decode_envelope(bit_array.from_string(
      "{\"frame\":\"call_event\"," <> text <> "}",
    ))
  }

  let assert Error(_report) =
    event("\"call\":0,\"event\":{\"kind\":\"settled\"}")
    as "a call id below 1 is refused"
  let assert Ok(untrusted_codec.CallEventEnvelope(call: 3, body:)) =
    event("\"call\":3,\"event\":{\"kind\":\"finished\"}")
    as "the header is read before the event"
  let assert Error(_report) = untrusted_codec.decode_call_event(body)
    as "an event kind the tunnel does not define is refused"
  let assert Error(_report) =
    untrusted_codec.decode_call_event(parsed(
      "{\"kind\":\"output\",\"stream\":\"stdin\",\"data\":\"\"}",
    ))
    as "output on a stream that is not stdout or stderr is refused"
  let assert Error(_report) =
    untrusted_codec.decode_call_event(parsed(
      "{\"kind\":\"settled\",\"outcome\":{\"kind\":\"failed\",\"failure\":{\"kind\":\"execution_lost\",\"cause\":\"gone\"}}}",
    ))
    as "a loss cause the broker does not name is refused"
  Nil
}

// --- the bound on values -----------------------------------------------------------

/// A `cancel` frame padded with an array of `items` zeros under a member the
/// envelope does not read, so the frame holds `items + 4` values: the frame,
/// its name, its id and the array.
fn padded_cancel(items: Int) -> BitArray {
  bit_array.from_string(
    "{\"frame\":\"cancel\",\"id\":1,\"pad\":["
    <> string.join(list.repeat("0", items), ",")
    <> "]}",
  )
}

pub fn a_frame_of_more_values_than_the_bound_is_refused_test() {
  let at_bound = untrusted_wire.max_frame_values - 4

  assert untrusted_codec.decode_envelope(padded_cancel(at_bound))
    == Ok(untrusted_codec.CancelEnvelope(id: 1))
  let assert Error(report) =
    untrusted_codec.decode_envelope(padded_cancel(at_bound + 1))
    as "one value past the bound is refused"
  assert string.contains(report.expected, "bound")
}

/// A tool outcome whose details are an array of `items` zeros.
fn outcome_of_width(items: Int) -> effects.ToolOutcome {
  effects.ToolCompleted(
    result: message.ToolResultMessage(
      tool_call_id: "call_1",
      tool_name: "bash",
      content: [],
      details: Some(json.Array(list.repeat(json.Int(0), items))),
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 0,
    ),
    terminate: False,
  )
}

pub fn a_fetched_outcome_of_more_values_than_the_bound_is_refused_test() {
  let assert Ok(empty) =
    json.parse(
      bit_array_text(untrusted_codec.encode_outcome_bytes(outcome_of_width(0))),
    )
    as "an outcome's bytes are JSON"
  let at_bound = untrusted_wire.max_frame_values - json.count_values(empty)

  let fitting = outcome_of_width(at_bound)
  assert untrusted_codec.decode_outcome_bytes(
      untrusted_codec.encode_outcome_bytes(fitting),
    )
    == Ok(fitting)
  let assert Error(_report) =
    untrusted_codec.decode_outcome_bytes(
      untrusted_codec.encode_outcome_bytes(outcome_of_width(at_bound + 1)),
    )
    as "an outcome one value past the bound is refused"
  Nil
}

pub fn a_sender_checks_its_frame_against_both_bounds_test() {
  let small = untrusted_wire.Cancel(id: 7)
  assert untrusted_codec.encode_fitting(small)
    == Ok(untrusted_codec.encode_frame(small))

  // Two megabytes of zeros: far inside the byte bound, past the value bound.
  let wide =
    untrusted_wire.Response(
      id: 3,
      response: untrusted_wire.RunAnswered(
        protocol.RunFinished(outcome_of_width(untrusted_wire.max_frame_values)),
      ),
    )
  let assert Error(untrusted_codec.Unfit(bytes:, reason:)) =
    untrusted_codec.encode_fitting(wide)
    as "a frame of too many values does not fit"
  assert bytes == untrusted_codec.encode_frame(wide)
  assert bit_array.byte_size(bytes) < untrusted_wire.max_frame_bytes
  assert string.contains(reason, "values")

  let long =
    untrusted_wire.Response(
      id: 4,
      response: untrusted_wire.RunAnswered(
        protocol.RunFinished(
          effects.ToolFailed(reason: string.repeat(
            "x",
            untrusted_wire.max_frame_bytes,
          )),
        ),
      ),
    )
  let assert Error(untrusted_codec.Unfit(reason:, ..)) =
    untrusted_codec.encode_fitting(long)
    as "a frame of too many bytes does not fit"
  assert string.contains(reason, "bytes")
}

// A spec and a settlement drawn from a fixed seed: arguments, environment and
// every number of an execution's report come back as they went.
pub fn drawn_tunnel_items_round_trip_test() {
  let generator =
    qcheck.tuple4(
      qcheck.list_from(qcheck.string()),
      qcheck.list_from(qcheck.tuple2(qcheck.string(), qcheck.string())),
      qcheck.tuple3(
        qcheck.bounded_int(-1000, 1000),
        qcheck.bounded_int(0, 1_000_000_000),
        qcheck.bounded_int(1, 64),
      ),
      qcheck.tuple3(qcheck.bool(), qcheck.bool(), qcheck.bool()),
    )

  qcheck.default_config()
  |> qcheck.with_test_count(property_cases)
  |> qcheck.with_seed(qcheck.seed(property_seed))
  |> qcheck.run(generator, fn(drawn) {
    let #(argv, env, #(code, number, cap), #(truncated, degraded, cancelled)) =
      drawn
    let spec =
      untrusted_wire.TunnelSpec(
        ..tunnel_spec(),
        argv:,
        env:,
        budget: budget.Budget(max_outstanding: cap, deadline_ms: number),
      )
    assert_request(untrusted_wire.ClearCallRequest(
      binding: binding(),
      spec:,
      waiting_ms: number,
    ))

    let result =
      exec.ExecResult(
        ..exec_result(),
        code:,
        stdout_bytes: number,
        stdout_truncated: truncated,
        degraded:,
        cancelled:,
      )
    let frame =
      untrusted_wire.CallEvent(
        call: cap,
        event: untrusted_wire.TunnelSettled(broker.CallExited(result)),
      )
    assert through(frame) == Ok(frame)
  })
}
