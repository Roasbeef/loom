//// This fixture drives prompt evolution through real production runtimes.
//// The provider is scripted: it establishes lifecycle and isolation mechanics,
//// not measured model quality. Each independent trial still uses loopback HTTP,
//// ordinary filesystem tools, a private native sandbox, witnessed retirement,
//// and operator-admitted exact-file scoring. Approved versions affect only new
//// session maps; resumed conversations retain their original immutable map.

import broker/internal/call
import broker/policy
import broker/token
import client/catalog
import client/evolution/record
import client/evolution_acceptance_test as acceptance
import client/gateway
import client/serve
import client/system_prompt
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap as native
import provider/http
import provider/pricing
import provider/profile
import provider/secret
import runtime/api
import simplifile
import support/extensions
import support/provider_http as peer
import telemetry/log
import weft/actor

// File masks may read as empty; directory masks hide each existing child.
// These native outcomes are distinct from a process that never ran.
type TargetMask {
  ProtectedFile
  ProtectedDirectoryChild
}

type CapturedBytes {
  EmptyBytes
  PresentBytes
}

type Authored {
  Authored(candidate: String, evidence_id: String, evidence: String)
}

type ReceiptMessage {
  Published(Authored)
  Take(Subject(Option(Authored)))
  Done
}

type TraceMessage {
  TraceSeen(json.JsonValue)
  ReadTrace(Subject(Option(json.JsonValue)))
  StopTrace
}

/// Exercises independent rollout evidence, pinning, replacement and rollback.
///
/// ## Examples
///
/// `make e2e-evolution` enables the offline toolchain and real native helper.
pub fn prompt_versions_real_trials_session_pins_and_rollback_test_() -> EunitTest {
  Timeout(150, fn() {
    case native.getenv("LOOM_EVOLUTION_E2E") {
      Ok("1") -> exercise()
      Ok(_) | Error(Nil) ->
        io.println_error("SKIP prompt acceptance: run make e2e-evolution")
    }
  })
}

fn exercise() {
  let root =
    extensions.scratch(
      "evo-prompt-" <> bit_array.base16_encode(token.production_entropy()(6)),
    )
  let assert Ok(Nil) = native.ensure_private_directory(root)
    as "fixture owns its private state root"
  let assert Ok(root) = native.canonical_directory(root)
    as "native policy root is canonical"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/work")
    as "source workspace exists"
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/owner-secret.token",
      "native owner fixture secret\n",
    )
    as "native owner establishes an existing protected secret"
  let assert Ok(collector) =
    actor.new([])
    |> actor.on_message(fn(state: List(Authored), message) {
      case message {
        Published(receipt) -> actor.continue(list.append(state, [receipt]))
        Take(reply) -> {
          process.send(
            reply,
            list.first(state) |> result.map(Some) |> result.unwrap(None),
          )
          actor.continue(list.drop(state, 1))
        }
        Done -> actor.stop()
      }
    })
    |> actor.start
    as "collector owns callback receipt delivery"
  let assert Ok(traces) =
    actor.new(None)
    |> actor.on_message(fn(state: Option(json.JsonValue), message) {
      case message {
        TraceSeen(brief) -> actor.continue(Some(brief))
        ReadTrace(reply) -> {
          process.send(reply, state)
          actor.continue(None)
        }
        StopTrace -> actor.stop()
      }
    })
    |> actor.start
    as "native trace collector owns result handoff"
  let script =
    list.flatten([
      [
        peer.Exchange(
          "trace source warmup",
          "independent source trace observation",
        ),
      ],
      author_script(root, 1, collector.data, traces.data),
      marked_trace_script(),
      probe("original after version one", None),
      probe("new version one", Some(1)),
      author_script(root, 2, collector.data, traces.data),
      probe("original after version two", None),
      probe("resumed version one", Some(1)),
      probe("new version two", Some(2)),
      probe("new after rollback", Some(1)),
      probe("original after rollback", None),
    ])
  let before = acceptance.helpers()
  let #(Nil, observations) =
    peer.with_extended_script(script, fn(url) {
      let original_settings = settings(root, url, "source")
      let assert Ok(source) =
        serve.open_instance(original_settings, log.discard())
        as "original production source opens"
      let original = api.session_id(source.runtime)
      let owner = acceptance.operator(source)
      acceptance.run(source.runtime, "trace source warmup")
      let admitted = acceptance.request(owner, 401, "admit_tasks", taskset())
      let taskset_id = text(admitted, "taskset_id")

      // The author supplies only the admitted task-set identity. The native
      // evaluator owns independent criteria, exact target and fresh workspaces.
      acceptance.run(source.runtime, "author prompt version 1 " <> taskset_id)
      let first = take(collector.data)
      let assert Ok(Some(brief)) =
        call.try_call(traces.data, waiting: 1000, sending: ReadTrace)
        as "model-visible trace retains actual native source identity"
      let assert json.Array(excerpts) = field(brief, "excerpts")
        as "trace excerpts are bounded"
      let assert Ok(warmup) =
        list.find(excerpts, fn(excerpt) {
          field(excerpt, "text")
          == json.String("independent source trace observation")
        })
        as "trace joins the actual warmup assistant message"
      assert field(warmup, "session_id")
        == json.String(ids.session_id_to_string(original))
        && field(warmup, "model") == json.String("fixture")
        && field(warmup, "provider") == json.String("fixture")
        && field(warmup, "api") == json.String("anthropic-messages")
        && field(warmup, "outcome") == json.String("unmarked")
        && field(warmup, "usage") != json.Null
        as "actual trace identity and usage preserve missing outcome as unmarked"
      let marked =
        acceptance.request(
          owner,
          420,
          "mark_outcome",
          json.Object([
            #("entry_id", field(warmup, "entry_id")),
            #("outcome", json.String("succeeded")),
          ]),
        )
      assert field(marked, "outcome") == json.String("succeeded")
      acceptance.run(source.runtime, "inspect marked source trace")
      inspect_and_approve(owner, 402, first)
      select(owner, 404, first, 0, "select-prompt-one", "select")
      pinned(source, None)
      acceptance.run(source.runtime, "original after version one")
      let v1_settings = settings(root, url, "pinned-one")
      let assert Ok(v1) = serve.open_instance(v1_settings, log.discard())
        as "new session adopts first approved prompt"
      pinned(v1, Some(first.candidate))
      acceptance.run(v1.runtime, "new version one")
      let assert Ok(Nil) = serve.retire_instance(v1)
        as "first pinned session retires before resume"

      // A differently named proposal still supersedes the same exact model
      // slot. Existing conversation pins do not follow this central selection.
      acceptance.run(source.runtime, "author prompt version 2 " <> taskset_id)
      let second = take(collector.data)
      assert second.candidate != first.candidate
        && second.evidence_id != first.evidence_id
        as "changed prompt text and observation have new immutable identities"
      inspect_and_approve(owner, 406, second)
      select(owner, 408, second, 1, "select-prompt-two", "select")
      pinned(source, None)
      acceptance.run(source.runtime, "original after version two")
      let assert Ok(resumed) = serve.open_instance(v1_settings, log.discard())
        as "existing production session resumes"
      pinned(resumed, Some(first.candidate))
      acceptance.run(resumed.runtime, "resumed version one")
      let assert Ok(Nil) = serve.retire_instance(resumed)
        as "resumed session proves native retirement"
      let assert Ok(v2) =
        serve.open_instance(settings(root, url, "pinned-two"), log.discard())
        as "new session adopts the second approved prompt"
      pinned(v2, Some(second.candidate))
      acceptance.run(v2.runtime, "new version two")
      let assert Ok(Nil) = serve.retire_instance(v2)
        as "second pinned session retires"
      select(owner, 409, first, 2, "rollback-prompt-one", "rollback")
      let assert Ok(rolled_back) =
        serve.open_instance(settings(root, url, "rollback"), log.discard())
        as "new session sees authenticated rollback"
      pinned(rolled_back, Some(first.candidate))
      acceptance.run(rolled_back.runtime, "new after rollback")
      let assert Ok(Nil) = serve.retire_instance(rolled_back)
        as "rollback session proves native retirement"
      acceptance.run(source.runtime, "original after rollback")
      assert simplifile.read(root <> "/owner-secret.token")
        == Ok("native owner fixture secret\n")
        as "original owner bytes remain unchanged after all trial arms"
      assert api.session_id(source.runtime) == original
        as "source conversation survives both evaluations and selections"
      let assert Ok(Nil) = serve.retire_instance(source)
        as "source runtime proves native retirement"
      assert acceptance.helpers() == before
        as "trials and pinned sessions leave no native helper behind"
      Nil
    })
  process.send(collector.data, Done)
  process.send(traces.data, StopTrace)
  let assert Ok(requests) = observations
    as "scripted peer retains real HTTP requests"
  assert list.length(requests) == list.length(script)
  io.println_error(
    "evolution prompt acceptance: real tools, protected source masking, independent file scoring, two approvals, session pins, resume, rollback and retirement passed; provider behavior was scripted",
  )
}

fn author_script(
  root: String,
  version: Int,
  collector: Subject(ReceiptMessage),
  traces: Subject(TraceMessage),
) -> List(peer.Exchange) {
  let v = int.to_string(version)
  [
    peer.ComputedExchange(
      peer.AwaitPromptPrefix("author prompt version " <> v <> " "),
      fn(requests) {
        assert_profile(requests, None)
        peer.ReplyToolUse(
          "prompt-write-" <> v,
          "fs_write",
          json.Object([
            #("path", json.String("prompt-" <> v <> "/prompt.json")),
            #("content", json.String(json.to_string(prompt(version)))),
          ]),
        )
      },
    ),
    peer.ComputedExchange(peer.AwaitToolResult("prompt-write-" <> v), fn(_) {
      peer.ReplyToolUse(
        "prompt-propose-" <> v,
        "evolution_propose",
        json.Object([
          #("directory", json.String("prompt-" <> v)),
          #("name", json.String("profile_" <> v)),
          #("kind", json.String("prompt")),
          #("description", json.String("Independent fixture prompt " <> v)),
        ]),
      )
    }),
    peer.ComputedExchange(
      peer.AwaitToolResult("prompt-propose-" <> v),
      fn(requests) {
        assert_evaluation_schema(requests)
        let assert Ok(<<"SQLite format 3":utf8, _:bits>>) =
          simplifile.read_bits(root <> "/run/evolution/evolution.db")
          as "negative trial targets an existing nonempty native catalogue"
        assert simplifile.read(root <> "/owner-secret.token")
          == Ok("native owner fixture secret\n")
          as "negative trial targets the existing nonempty owner secret"
        let receipt = latest(requests)
        let assert Ok(authored) =
          list.find(list.reverse(requests), fn(request) {
            case request.latest {
              peer.UserPrompt(text) ->
                string.starts_with(text, "author prompt version " <> v <> " ")
              peer.SuccessfulToolResult(..) -> False
            }
          })
          as "actual author prompt carries admitted identity"
        let assert peer.UserPrompt(author_text) = authored.latest
          as "author request is native text"
        let prefix = "author prompt version " <> v <> " "
        let taskset_id = string.drop_start(author_text, string.length(prefix))
        peer.ReplyToolUse(
          "prompt-test-" <> v,
          "evolution_test",
          json.Object([
            #("candidate_id", field(receipt, "candidate_id")),
            #("taskset_id", json.String(taskset_id)),
            #(
              "limits",
              json.Object([
                #("trials", json.Int(2)),
                #("turns", json.Int(6)),
                #("tokens", json.Int(1_000_000)),
                #("dollars", json.Float(2.0)),
                #("output_bytes", json.Int(65_536)),
                #("wall_ms", json.Int(120_000)),
              ]),
            ),
          ]),
        )
      },
    ),
    trial(root, version, None),
    trial_write(root, version, None),
    peer.ComputedExchange(peer.AwaitToolResult("trial-baseline-" <> v), fn(_) {
      peer.ReplyText("baseline work complete")
    }),
    trial(root, version, Some(version)),
    trial_write(root, version, Some(version)),
    peer.ComputedExchange(peer.AwaitToolResult("trial-candidate-" <> v), fn(_) {
      peer.ReplyText("candidate work complete")
    }),
    peer.ComputedExchange(
      peer.AwaitToolResult("prompt-test-" <> v),
      fn(requests) {
        let receipt = latest(requests)
        process.send(
          collector,
          Published(Authored(
            text(receipt, "candidate_id"),
            text(receipt, "evidence_id"),
            text(receipt, "evidence"),
          )),
        )
        peer.ReplyToolUse(
          "prompt-trace-" <> v,
          "evolution_trace",
          json.Object([
            #(
              "limit",
              json.Int(case version {
                1 -> 12
                _ -> 3
              }),
            ),
          ]),
        )
      },
    ),
    peer.ComputedExchange(
      peer.AwaitToolResult("prompt-trace-" <> v),
      fn(requests) {
        process.send(traces, TraceSeen(latest(requests)))
        peer.ReplyText("prompt evidence and source trace retained")
      },
    ),
  ]
}

fn trial(root: String, version: Int, applied: Option(Int)) -> peer.Exchange {
  let tag = trial_tag(applied)
  peer.ComputedExchange(
    peer.AwaitPrompt("Write the independently specified result file."),
    fn(requests) {
      assert_profile(requests, applied)
      peer.ReplyToolUse(
        "trial-read-" <> tag <> "-" <> int.to_string(version),
        "bash",
        json.Object([
          #("mode", json.String("foreground")),
          #("timeout_ms", json.Int(10_000)),
          #(
            "command",
            json.String(
              "/bin/cat public-control.txt; "
              <> read_command("owner", root <> "/owner-secret.token")
              <> "; "
              <> read_command(
                "catalogue",
                root <> "/run/evolution/evolution.db",
              ),
            ),
          ),
        ]),
      )
    },
  )
}

fn trial_write(
  root: String,
  version: Int,
  applied: Option(Int),
) -> peer.Exchange {
  let tag = trial_tag(applied)
  peer.ComputedExchange(
    peer.AwaitToolResult("trial-read-" <> tag <> "-" <> int.to_string(version)),
    fn(requests) {
      let assert Ok(request) = list.last(requests)
        as "actual trial tool settles"
      let assert peer.SuccessfulToolResult(_, output) = request.latest
        as "ordinary foreground shell executes in the isolated trial"
      assert string.contains(output, "trial public readable control")
        as "the same native shell can read its admitted public fixture"
      let #(owner_status, owner_bytes, owner_error) =
        read_result(output, "owner")
      let #(catalogue_status, catalogue_bytes, catalogue_error) =
        read_result(output, "catalogue")
      assert masked_read(
          ProtectedFile,
          root <> "/owner-secret.token",
          owner_status,
          owner_bytes,
          owner_error,
        )
        && masked_read(
          ProtectedDirectoryChild,
          root <> "/run/evolution/evolution.db",
          catalogue_status,
          catalogue_bytes,
          catalogue_error,
        )
        as "each existing nonempty target yields its exact native mask outcome and no bytes"
      peer.ReplyToolUse(
        "trial-" <> tag <> "-" <> int.to_string(version),
        "fs_write",
        json.Object([
          #("path", json.String("result.txt")),
          #(
            "content",
            json.String(case applied {
              None -> "wrong baseline\n"
              Some(_) -> "checked output\n"
            }),
          ),
        ]),
      )
    },
  )
}

// Probe output reports byte presence rather than discarding stdout. Otherwise
// a successful file read could hide leaked owner bytes behind /dev/null.
fn read_command(label: String, path: String) -> String {
  let quoted = "'" <> string.replace(path, "'", "'\"'\"'") <> "'"
  "/bin/cat "
  <> quoted
  <> " >"
  <> label
  <> "-output.txt 2>"
  <> label
  <> "-denial.txt; "
  <> "echo "
  <> label
  <> "-status:$?; "
  <> "if [ -s "
  <> label
  <> "-output.txt ]; then echo "
  <> label
  <> "-bytes:present; "
  <> "else echo "
  <> label
  <> "-bytes:empty; fi; "
  <> "echo "
  <> label
  <> "-error-begin; /bin/cat "
  <> label
  <> "-denial.txt; "
  <> "echo "
  <> label
  <> "-error-end"
}

fn read_result(output: String, label: String) -> #(Int, CapturedBytes, String) {
  let lines = string.split(output, "\n")
  let prefix = label <> "-status:"
  let assert Ok(status_line) =
    list.find(lines, fn(line) { string.starts_with(line, prefix) })
    as "the native shell reports the actual target read exit"
  let assert Ok(status) =
    int.parse(string.drop_start(status_line, string.length(prefix)))
    as "target read exit totally parses"
  let bytes = case
    list.contains(lines, label <> "-bytes:empty"),
    list.contains(lines, label <> "-bytes:present")
  {
    True, False -> EmptyBytes
    False, True -> PresentBytes
    _, _ -> panic as "native probe reports exactly one byte-presence marker"
  }
  let assert [_, after] = string.split(output, label <> "-error-begin\n")
    as "each native stderr has its own start marker"
  let assert [error, _] = string.split(after, label <> "-error-end")
    as "each native stderr has its own end marker"
  #(status, bytes, string.trim(error))
}

// This follows the native bwrap mask plan and Seatbelt denial. It never
// treats an arbitrary failure or unavailable process as evidence of isolation.
fn masked_read(
  mask: TargetMask,
  path: String,
  status: Int,
  bytes: CapturedBytes,
  error: String,
) -> Bool {
  let permission =
    string.contains(error, path <> ": Operation not permitted")
    || string.contains(error, path <> ": Permission denied")
  let absent = string.contains(error, path <> ": No such file or directory")
  case mask, status, bytes, error {
    ProtectedFile, 0, EmptyBytes, "" -> True
    ProtectedFile, 1, EmptyBytes, _ -> permission
    ProtectedDirectoryChild, 1, EmptyBytes, _ -> permission || absent
    _, _, _, _ -> False
  }
}

/// Checks the native mask outcomes without accepting generic process failures.
///
/// ## Examples
///
/// The real fixture uses the same predicate for captured kernel read results.
pub fn native_mask_outcomes_require_empty_bytes_and_exact_target_diagnostics_test() {
  let path = "/native/existing-secret"
  assert masked_read(ProtectedFile, path, 0, EmptyBytes, "")
    as "Linux empty file mask hides nonempty native bytes"
  assert masked_read(
    ProtectedDirectoryChild,
    path,
    1,
    EmptyBytes,
    "cat: " <> path <> ": No such file or directory",
  )
    as "Linux directory mask removes an existing native child"
  assert masked_read(
    ProtectedFile,
    path,
    1,
    EmptyBytes,
    "cat: " <> path <> ": Operation not permitted",
  )
    as "Darwin named denial hides native file bytes"
  assert !masked_read(ProtectedFile, path, 0, PresentBytes, "")
    && !masked_read(ProtectedDirectoryChild, path, 0, EmptyBytes, "")
    && !masked_read(ProtectedFile, path, 1, EmptyBytes, "unavailable")
    && !masked_read(
      ProtectedDirectoryChild,
      path,
      1,
      EmptyBytes,
      "cat: /other: No such file or directory",
    )
    && !masked_read(
      ProtectedFile,
      path,
      1,
      EmptyBytes,
      "cat: " <> path <> ": No such file or directory",
    )
    as "leaked bytes, generic errors and wrong mask shapes never pass"
}

fn trial_tag(applied: Option(Int)) -> String {
  case applied {
    None -> "baseline"
    Some(_) -> "candidate"
  }
}

fn probe(text: String, applied: Option(Int)) -> List(peer.Exchange) {
  [
    peer.ComputedExchange(peer.AwaitPrompt(text), fn(requests) {
      assert_profile(requests, applied)
      peer.ReplyText("immutable session profile checked")
    }),
  ]
}

fn marked_trace_script() -> List(peer.Exchange) {
  [
    peer.ToolUseExchange(
      "inspect marked source trace",
      "marked-trace",
      "evolution_trace",
      json.Object([#("limit", json.Int(12))]),
    ),
    peer.ComputedExchange(peer.AwaitToolResult("marked-trace"), fn(requests) {
      let assert json.Array(excerpts) = field(latest(requests), "excerpts")
        as "trace stays bounded"
      let assert Ok(warmup) =
        list.find(excerpts, fn(excerpt) {
          field(excerpt, "text")
          == json.String("independent source trace observation")
        })
        as "actual source survives operator marking"
      assert field(warmup, "outcome") == json.String("succeeded")
        as "model-visible evidence joins native operator-owned outcome"
      peer.ReplyText("operator-owned source outcome checked")
    }),
  ]
}

fn assert_profile(requests: List(peer.ObservedRequest), applied: Option(Int)) {
  let assert Ok(request) = list.last(requests) as "real provider request exists"
  let system = json.to_string(field(request.body, "system"))
  case applied {
    None -> {
      assert !string.contains(system, "PROMPT_ACCEPTANCE_VERSION_")
        as "baseline and original source use unchanged base prompt"
    }
    Some(version) -> {
      assert string.contains(system, suffix(version))
        as "actual wire request carries its exact approved overlay"
      assert !string.contains(system, suffix(3 - version))
        as "wire composition never accumulates other version text"
    }
  }
}

fn assert_evaluation_schema(requests: List(peer.ObservedRequest)) {
  let assert Ok(request) = list.last(requests)
    as "actual provider request exists"
  let assert json.Array(tools) = field(request.body, "tools")
    as "actual callable tools are advertised"
  let assert Ok(declared) =
    list.find(tools, fn(tool) {
      field(tool, "name") == json.String("evolution_test")
    })
    as "prompt evaluator is model-visible"
  let schema = field(declared, "input_schema")
  let properties = field(schema, "properties")
  assert field(field(properties, "taskset_id"), "type") == json.String("string")
    as "model schema permits the native admitted task-set identity"
  let assert json.Object(limits) =
    field(field(properties, "limits"), "properties")
    as "bounded comparison limits are model-visible"
  assert list.sort(list.map(limits, fn(field) { field.0 }), string.compare)
    == ["dollars", "output_bytes", "tokens", "trials", "turns", "wall_ms"]
    as "schema advertises exactly the native six budget fields"
  assert field(schema, "additionalProperties") == json.Bool(False)
    as "ordinary unknown evaluator arguments remain forbidden"
}

fn pinned(instance: serve.Instance, expected: Option(String)) {
  let assert Ok(Some(profiles)) =
    system_prompt.pinned_profiles_in(instance.runtime.session)
    as "native session owns its immutable profile pin"
  case expected {
    None -> {
      assert profiles == [] as "original map remains empty"
    }
    Some(id) -> {
      let assert [actual] = profiles
        as "one exact target has one selected profile"
      assert profile.fields(actual).0 == id
        as "pin binds immutable candidate identity"
    }
  }
}

fn take(collector: Subject(ReceiptMessage)) -> Authored {
  let assert Ok(Some(receipt)) =
    call.try_call(collector, waiting: 1000, sending: Take)
    as "real independent evaluation receipt reaches native fixture"
  receipt
}

fn inspect_and_approve(
  owner: gateway.ConnectionHandle,
  id: Int,
  authored: Authored,
) {
  let assert Ok(evidence) = record.decode_evidence(authored.evidence)
    as "committed independent evidence totally decodes"
  assert evidence.verdict == record.Passed as evidence.observation
  assert evidence.purpose == record.IndependentRollout
    && record.id_string(evidence.candidate_id) == authored.candidate
  let assert Ok(observation) = json.parse(evidence.observation)
    as "rollout observation is bounded canonical JSON"
  assert field(observation, "mode") == json.String("live-production")
  let inspected =
    acceptance.request(
      owner,
      id,
      "evidence",
      json.Object([
        #("evidence_id", json.String(authored.evidence_id)),
      ]),
    )
  let assert Ok(expected) = json.parse(authored.evidence)
    as "evidence envelope parses"
  assert inspected == expected as "operator reads exact committed evidence"
  let _ =
    acceptance.request(
      owner,
      id + 1,
      "approve",
      json.Object([
        #("candidate_id", json.String(authored.candidate)),
        #("evidence_id", json.String(authored.evidence_id)),
      ]),
    )
  Nil
}

fn select(
  owner: gateway.ConnectionHandle,
  id: Int,
  authored: Authored,
  generation: Int,
  request_id: String,
  action: String,
) {
  let selected =
    acceptance.request(
      owner,
      id,
      action,
      json.Object([
        #("candidate_id", json.String(authored.candidate)),
        #("evidence_id", json.String(authored.evidence_id)),
        #("expected_generation", json.Int(generation)),
        #("request_id", json.String(request_id)),
        #("reason", json.String("scripted production prompt acceptance")),
      ]),
    )
  assert field(selected, "candidate_id") == json.String(authored.candidate)
    && field(selected, "generation") == json.Int(generation + 1)
    as "authenticated owner changes one exact model slot by native CAS"
}

fn taskset() -> json.JsonValue {
  json.Object([
    #("version", json.Int(1)),
    #(
      "tasks",
      json.Array([
        json.Object([
          #("id", json.String("independent-file-v1")),
          #(
            "prompt",
            json.String("Write the independently specified result file."),
          ),
          #(
            "files",
            json.Object([
              #("result.txt", json.String("initial\n")),
              #(
                "public-control.txt",
                json.String("trial public readable control\n"),
              ),
            ]),
          ),
          #(
            "expected",
            json.Object([#("result.txt", json.String("checked output\n"))]),
          ),
        ]),
      ]),
    ),
  ])
}

fn prompt(version: Int) -> json.JsonValue {
  json.Object([
    #("version", json.Int(1)),
    #("provider", json.String("fixture")),
    #("model", json.String("fixture")),
    #("api", json.String("anthropic-messages")),
    #("system", json.String(suffix(version))),
    #("task", json.String("")),
    #("descriptions", json.Object([])),
  ])
}

fn suffix(version: Int) -> String {
  "PROMPT_ACCEPTANCE_VERSION_" <> int.to_string(version)
}

fn settings(root: String, url: String, tag: String) -> serve.Settings {
  let base = acceptance.settings(root, url)
  let catalogue =
    catalog.Catalog(
      ..base.catalog,
      models: list.map(base.catalog.models, fn(model) {
        catalog.CatalogModel(
          ..model,
          context_window: 65_536,
          max_output_tokens: 1024,
          pricing: Some(pricing.Pricing(1.0, 1.0, 1.0, 1.0)),
        )
      }),
    )
  serve.Settings(
    ..base,
    base_policy: policy.SandboxPolicy(
      ..base.base_policy,
      readable_roots: list.append(base.base_policy.readable_roots, [
        root,
        "/bin/cat",
      ]),
      protected: list.append(base.base_policy.protected, [
        root <> "/owner-secret.token",
      ]),
    ),
    session_id: "prompt-" <> tag,
    session_path: root <> "/" <> tag <> ".db",
    token_path: root <> "/" <> tag <> ".token",
    codemode_sockets: Some(root <> "/run/" <> tag),
    catalog: catalogue,
    gateway: catalog.gateway(
      catalogue,
      http.httpc_transport(),
      secret.from_list([#("FIXTURE_KEY", peer.dummy_key)]),
      clock.from_function(native.system_time_ms),
    ),
    context_window: 65_536,
    max_output_tokens: 1024,
  )
}

fn latest(requests: List(peer.ObservedRequest)) -> json.JsonValue {
  let assert Ok(request) = list.last(requests) as "actual request exists"
  let assert peer.SuccessfulToolResult(_, text) = request.latest
    as "ordinary production tool succeeds before script advances"
  let assert Ok(value) = json.parse(text) as "native receipt totally parses"
  value
}

fn field(value: json.JsonValue, name: String) -> json.JsonValue {
  let assert json.Object(fields) = value as "receipt is an object"
  let assert Ok(value) = list.key_find(fields, name)
    as "expected receipt field exists"
  value
}

fn text(value: json.JsonValue, name: String) -> String {
  let assert json.String(value) = field(value, name)
    as "native receipt field is text"
  value
}
