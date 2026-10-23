//// This acceptance sequence invokes a retained executable skill with fresh data.
//// The scripted peer writes the source through ordinary filesystem tools, asks
//// the real code-mode pipeline for author evidence, then discovers the approved
//// workspace version. Native owner commands approve and select it. Two distinct
//// calls compile and execute that retained version under the current caller's
//// actual policy. A second production session discovers the same selected skill
//// and proves its own stricter policy governs the retained source's effects.

import broker/internal/call
import broker/policy
import broker/token
import client/evolution/record
import client/evolution_acceptance_test as acceptance
import client/serve
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import host/bootstrap as native
import runtime/api
import simplifile
import support/evolution_program as fixture
import support/extensions
import support/provider_http as peer
import telemetry/log
import weft
import weft/actor

type Authored {
  Authored(candidate: String, evidence_id: String, evidence: String)
}

type ReceiptMessage {
  Published(Authored)
  Take(Subject(Option(Authored)))
  Done
}

/// Exercises immutable skill authoring and fresh execution through production.
///
/// ## Examples
///
/// `make e2e-evolution` enables the real helper and offline toolchain prerequisite.
pub fn executable_skill_authored_approved_and_invoked_with_fresh_inputs_test_() -> EunitTest {
  Timeout(180, fn() {
    case native.getenv("LOOM_EVOLUTION_E2E") {
      Ok("1") -> exercise()
      Ok(_) | Error(Nil) ->
        io.println_error(
          "SKIP executable skill acceptance: run make e2e-evolution",
        )
    }
  })
}

fn exercise() {
  let root =
    extensions.scratch(
      "evo-skill-" <> bit_array.base16_encode(token.production_entropy()(6)),
    )
  let assert Ok(Nil) = native.ensure_private_directory(root)
    as "fixture owns its state root"
  let assert Ok(root) = native.canonical_directory(root)
    as "policy root is canonical"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/work")
    as "author workspace exists"
  let protected = root <> "/evolution/run/other-session/protected.gleam"
  let original_source =
    "//// Another native session owns this immutable source.\n"
  let assert Ok(Nil) =
    simplifile.create_directory_all(root <> "/evolution/run/other-session")
    as "another session's protected private root exists"
  let assert Ok(Nil) = simplifile.write(protected, original_source)
    as "native fixture establishes an existing protected source"
  assert simplifile.read(protected) == Ok(original_source)
    && original_source != ""
    as "the negative targets existing native source bytes"
  let public = root <> "/work/public-read.txt"
  let assert Ok(Nil) = simplifile.write(public, "public readable control\n")
    as "the same cat executable has a readable positive control"
  let caller_private = root <> "/work/caller-policy-private"
  let caller_target = caller_private <> "/existing.txt"
  let assert Ok(Nil) = simplifile.create_directory_all(caller_private)
    as "the second caller's additional mask targets an existing directory"
  let assert Ok(Nil) =
    simplifile.write(caller_target, "caller policy readable bytes\n")
    as "the current-policy target contains real nonempty bytes"
  let assert Ok(collector) =
    actor.new(None)
    |> actor.on_message(fn(state: Option(Authored), message) {
      case message {
        Published(receipt) -> actor.continue(Some(receipt))
        Take(reply) -> {
          process.send(reply, state)
          actor.continue(None)
        }
        Done -> actor.stop()
      }
    })
    |> actor.start
    as "receipt collector owns cross-process handoff"
  let authored = collector.data
  let script =
    list.flatten([
      author_script(
        authored,
        fixture.source_with_caller_policy(protected, public, caller_target),
      ),
      invoke_script("invoke skill first", "first fresh input"),
      invoke_script("invoke skill second", "second fresh input"),
      protected_script(),
      caller_policy_script(
        "first caller readable target",
        "first-policy",
        "caller policy readable bytes\n",
      ),
      [
        peer.Exchange(
          "continue skill conversation",
          "skill conversation retained",
        ),
      ],
      invoke_script(
        "second session fresh invocation",
        "second session fresh input",
      ),
      caller_policy_script(
        "second caller hidden target",
        "second-policy",
        "caller policy target hidden",
      ),
      [
        peer.Exchange(
          "continue second conversation",
          "second session conversation retained",
        ),
      ],
    ])
  let before = acceptance.helpers()
  let #(Nil, observations) =
    peer.with_extended_script(script, fn(url) {
      let base = acceptance.settings(root, url)
      let granted =
        policy.SandboxPolicy(
          ..base.base_policy,
          readable_roots: list.append(base.base_policy.readable_roots, [
            root,
            "/bin/cat",
          ]),
          writable_roots: list.append(base.base_policy.writable_roots, [root]),
        )
      let assert Ok(instance) =
        serve.open_instance(
          serve.Settings(..base, base_policy: granted),
          log.discard(),
        )
        as "ordinary production session opens"
      let consumer_settings =
        serve.Settings(
          ..base,
          session_id: "evolution-consumer",
          session_path: root <> "/consumer.db",
          token_path: root <> "/consumer.token",
          base_policy: policy.SandboxPolicy(..granted, protected: [
            caller_private,
            ..granted.protected
          ]),
        )
      assert consumer_settings.workspace == base.workspace
        && consumer_settings.codemode_sockets == base.codemode_sockets
        && consumer_settings.session_path != base.session_path
        as "distinct session databases share the exact canonical workspace and catalogue root"
      let consumer_opened =
        serve.open_instance(consumer_settings, log.discard())
      let consumer = case consumer_opened {
        Ok(consumer) -> consumer
        Error(reason) -> {
          let assert Ok(Nil) = serve.retire_instance(instance)
            as "a failed second boot still retires the first native owner"
          panic as reason
        }
      }
      let outcomes =
        weft.new([
          fn() {
            let original = api.session_id(instance.runtime)
            let operator = acceptance.operator(instance)
            acceptance.run(instance.runtime, "author executable skill")
            let assert Ok(Some(authored)) =
              call.try_call(authored, waiting: 1000, sending: Take)
              as "real test receipt reaches fixture"
            let assert Ok(evidence) = record.decode_evidence(authored.evidence)
              as "durable evidence totally decodes"
            case evidence.verdict == record.Passed {
              True -> Nil
              False -> {
                io.println_error(
                  "program failed author evidence: " <> evidence.observation,
                )
                Nil
              }
            }
            assert evidence.verdict == record.Passed
              && evidence.purpose == record.AuthorTests
              as {
                "the actual jailed author check passed: "
                <> evidence.observation
              }
            assert record.id_string(evidence.candidate_id) == authored.candidate
            let inspected =
              acceptance.request(
                operator,
                201,
                "evidence",
                json.Object([
                  #("evidence_id", json.String(authored.evidence_id)),
                ]),
              )
            let assert Ok(encoded) = json.parse(authored.evidence)
              as "evidence envelope parses"
            assert inspected == encoded
              as "owner reads committed evidence before approval"
            let _approved =
              acceptance.request(
                operator,
                202,
                "approve",
                json.Object([
                  #("candidate_id", json.String(authored.candidate)),
                  #("evidence_id", json.String(authored.evidence_id)),
                ]),
              )
            let selected =
              acceptance.request(
                operator,
                203,
                "select",
                json.Object([
                  #("candidate_id", json.String(authored.candidate)),
                  #("evidence_id", json.String(authored.evidence_id)),
                  #("expected_generation", json.Int(0)),
                  #("request_id", json.String("select-workspace-skill")),
                  #(
                    "reason",
                    json.String("executable skill acceptance fixture"),
                  ),
                ]),
              )
            assert field(selected, "candidate_id")
              == json.String(authored.candidate)
              && field(selected, "generation") == json.Int(1)
              as "workspace skill selection commits through native owner CAS"
            acceptance.run(instance.runtime, "invoke skill first")
            acceptance.run(instance.runtime, "invoke skill second")
            acceptance.run(instance.runtime, "probe protected source")
            acceptance.run(instance.runtime, "first caller readable target")
            assert simplifile.read(protected) == Ok(original_source)
              as "native protected source remains unchanged despite broad state grants"
            assert api.session_id(instance.runtime) == original
              as "fresh invocations preserve source session identity"
            acceptance.run(instance.runtime, "continue skill conversation")
            acceptance.run(consumer.runtime, "second session fresh invocation")
            acceptance.run(consumer.runtime, "second caller hidden target")
            assert simplifile.read(caller_target)
              == Ok("caller policy readable bytes\n")
              as "the stricter caller hid existing bytes rather than removing its target"
            assert api.session_id(consumer.runtime) != original
              as "discovery and execution belong to a distinct production session"
            acceptance.run(consumer.runtime, "continue second conversation")
            Ok(Nil)
          },
        ])
        |> weft.deadline(120_000)
        |> weft.start

      // Both original owners survive assertion-worker failure. Every close is
      // attempted before either verdict is asserted, preserving independent custody.
      let consumer_retired = serve.retire_instance(consumer)
      let author_retired = serve.retire_instance(instance)
      consumer_retired |> should.equal(Ok(Nil))
      author_retired |> should.equal(Ok(Nil))
      assert acceptance.helpers() == before
        as "both session pools and every saved-program plane have retired"
      let assert [weft.Completed(0, Nil)] = outcomes
        as "both real sessions finish their complete finite provider script"
      Nil
    })
  process.send(authored, Done)
  let assert Ok(requests) = observations
    as "finite scripted peer retains actual requests"
  assert list.length(requests) == list.length(script)
  let transcripts =
    string.join(
      list.map(requests, fn(request) { json.to_string(request.body) }),
      "\n",
    )
  assert string.contains(transcripts, "skill-v1:first fresh input")
    && string.contains(transcripts, "skill-v1:second fresh input")
    && string.contains(transcripts, "skill-v1:second session fresh input")
    && string.contains(transcripts, "caller policy target hidden")
    as "actual replay retains all fresh calls and the second caller's strict policy result"
  io.println_error(
    "evolution executable skill acceptance: author, jailed test, approve, select, discover, fresh inputs, second-session discovery/current policy, protected source masking and retire passed",
  )
}

fn author_script(
  authored: Subject(ReceiptMessage),
  source: String,
) -> List(peer.Exchange) {
  // Each provider reply remains below its fixed 4 KiB wire bound. The model
  // assembles these exact bytes through the ordinary jailed shell tool before
  // immutable capture; native fixture code never writes the authored Program.
  assert string.length(source) <= 4500
    as "three bounded writes cover the exact source"
  [
    peer.ToolUseExchange(
      "author executable skill",
      "skill-part-a",
      "fs_write",
      json.Object([
        #("path", json.String("skill-part-a.txt")),
        #("content", json.String(string.slice(source, 0, 1500))),
      ]),
    ),
    peer.ComputedExchange(peer.AwaitToolResult("skill-part-a"), fn(_) {
      peer.ReplyToolUse(
        "skill-part-b",
        "fs_write",
        json.Object([
          #("path", json.String("skill-part-b.txt")),
          #("content", json.String(string.slice(source, 1500, 1500))),
        ]),
      )
    }),
    peer.ComputedExchange(peer.AwaitToolResult("skill-part-b"), fn(_) {
      peer.ReplyToolUse(
        "skill-part-c",
        "fs_write",
        json.Object([
          #("path", json.String("skill-part-c.txt")),
          #("content", json.String(string.drop_start(source, 3000))),
        ]),
      )
    }),
    peer.ComputedExchange(peer.AwaitToolResult("skill-part-c"), fn(_) {
      peer.ReplyToolUse(
        "skill-write",
        "bash",
        json.Object([
          #(
            "command",
            json.String(
              "mkdir -p skill && /bin/cat skill-part-a.txt skill-part-b.txt skill-part-c.txt > skill/program.gleam",
            ),
          ),
          #("mode", json.String("foreground")),
          #("timeout_ms", json.Int(5000)),
        ]),
      )
    }),
    peer.ComputedExchange(peer.AwaitToolResult("skill-write"), fn(_) {
      peer.ReplyToolUse(
        "skill-propose",
        "evolution_propose",
        json.Object([
          #("directory", json.String("skill")),
          #("name", json.String("fresh_echo")),
          #("kind", json.String("program")),
          #("test_entry", json.String("author_checks")),
          #(
            "description",
            json.String("Run an immutable native echo skill with fresh input."),
          ),
          #("input_schema", json.String(json.to_string(fixture.schema()))),
        ]),
      )
    }),
    peer.ComputedExchange(peer.AwaitToolResult("skill-propose"), fn(requests) {
      peer.ReplyToolUse(
        "skill-test",
        "evolution_test",
        json.Object([
          #("candidate_id", field(latest(requests), "candidate_id")),
        ]),
      )
    }),
    peer.ComputedExchange(peer.AwaitToolResult("skill-test"), fn(requests) {
      let receipt = latest(requests)
      process.send(
        authored,
        Published(Authored(
          text(receipt, "candidate_id"),
          text(receipt, "evidence_id"),
          text(receipt, "evidence"),
        )),
      )
      peer.ReplyText("executable skill evidence retained")
    }),
  ]
}

fn invoke_script(prompt: String, fresh: String) -> List(peer.Exchange) {
  [
    peer.ToolUseExchange(
      prompt,
      "catalogue-" <> fresh,
      "evolution_catalogue",
      json.Object([]),
    ),
    peer.ComputedExchange(
      peer.AwaitToolResult("catalogue-" <> fresh),
      fn(requests) {
        let assert json.Array([active]) = field(latest(requests), "active")
          as "only selected workspace skill is discovered"
        assert field(active, "kind") == json.String("program")
          && field(active, "schema") == fixture.schema()
          && field(active, "generation") == json.Int(1)
          && field(active, "origin_session")
          == json.String("evolution-acceptance")
          as "discovery binds the original author, version, kind and immutable schema"
        peer.ReplyToolUse(
          "invoke-" <> fresh,
          "evolution_invoke",
          json.Object([
            #("candidate_id", field(active, "candidate_id")),
            #("generation", field(active, "generation")),
            #("tool", field(active, "name")),
            #("arguments", json.Object([#("say", json.String(fresh))])),
          ]),
        )
      },
    ),
    peer.ComputedExchange(
      peer.AwaitToolResult("invoke-" <> fresh),
      fn(requests) {
        let execution = latest(requests)
        assert field(execution, "status") == json.String("completed")
          && field(execution, "value") == json.String("skill-v1:" <> fresh)
          as "fresh JSON enters the real retained code-mode source and native process"
        peer.ReplyText("fresh executable invocation verified")
      },
    ),
  ]
}

fn latest(requests: List(peer.ObservedRequest)) -> json.JsonValue {
  let assert Ok(request) = list.last(requests)
    as "actual observed request exists"
  let assert peer.SuccessfulToolResult(_, text) = request.latest
    as "real tool succeeds before script advances"
  let assert Ok(value) = json.parse(text)
    as "evolution tool receipt totally parses"
  value
}

fn protected_script() -> List(peer.Exchange) {
  [
    peer.ToolUseExchange(
      "probe protected source",
      "protected-catalogue",
      "evolution_catalogue",
      json.Object([]),
    ),
    peer.ComputedExchange(
      peer.AwaitToolResult("protected-catalogue"),
      fn(requests) {
        let assert json.Array([active]) = field(latest(requests), "active")
          as "selected workspace skill is discovered"
        peer.ReplyToolUse(
          "protected-invoke",
          "evolution_invoke",
          json.Object([
            #("candidate_id", field(active, "candidate_id")),
            #("generation", field(active, "generation")),
            #("tool", field(active, "name")),
            #(
              "arguments",
              json.Object([#("say", json.String("probe-protected-source"))]),
            ),
          ]),
        )
      },
    ),
    peer.ComputedExchange(
      peer.AwaitToolResult("protected-invoke"),
      fn(requests) {
        let execution = latest(requests)
        assert field(execution, "status") == json.String("completed")
          && field(execution, "value") == json.String("protected source hidden")
          as "real protected-directory masking hides the existing nonempty source"
        peer.ReplyText("shared native protected source mask checked")
      },
    ),
  ]
}

fn caller_policy_script(
  prompt: String,
  call_id: String,
  expected: String,
) -> List(peer.Exchange) {
  [
    peer.ToolUseExchange(
      prompt,
      call_id <> "-catalogue",
      "evolution_catalogue",
      json.Object([]),
    ),
    peer.ComputedExchange(
      peer.AwaitToolResult(call_id <> "-catalogue"),
      fn(requests) {
        let assert json.Array([active]) = field(latest(requests), "active")
          as "the caller discovers the already-selected shared Workspace Program"
        assert field(active, "origin_session")
          == json.String("evolution-acceptance")
          && field(active, "generation") == json.Int(1)
          as "the same retained author version crosses the session boundary"
        peer.ReplyToolUse(
          call_id <> "-invoke",
          "evolution_invoke",
          json.Object([
            #("candidate_id", field(active, "candidate_id")),
            #("generation", field(active, "generation")),
            #("tool", field(active, "name")),
            #(
              "arguments",
              json.Object([#("say", json.String("probe-caller-policy"))]),
            ),
          ]),
        )
      },
    ),
    peer.ComputedExchange(
      peer.AwaitToolResult(call_id <> "-invoke"),
      fn(requests) {
        let execution = latest(requests)
        assert field(execution, "status") == json.String("completed")
          && field(execution, "value") == json.String(expected)
          as "the saved source performs the public control and the exact caller-specific OS read"
        peer.ReplyText("current caller policy checked by retained source")
      },
    ),
  ]
}

fn field(value: json.JsonValue, name: String) -> json.JsonValue {
  let assert json.Object(fields) = value as "receipt is an object"
  let assert Ok(found) = list.key_find(fields, name)
    as "receipt has expected field"
  found
}

fn text(value: json.JsonValue, name: String) -> String {
  let assert json.String(text) = field(value, name)
    as "native receipt field is text"
  text
}
