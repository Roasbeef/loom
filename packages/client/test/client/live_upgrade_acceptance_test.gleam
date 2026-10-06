//// Production selection upgrades authored callbacks while retaining their jail.
//// The counter crosses the forward and rollback boundaries through real tools.

import broker/token
import client/evolution_acceptance_test as acceptance
import client/gateway
import client/serve
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap as native
import session/session
import simplifile
import support/extensions
import support/live_upgrade
import support/provider_http as peer
import telemetry/log
import weft/actor
import weft/poll

/// Runs source compilation, publication and current-state rollback in one jail.
///
/// ## Examples
///
/// `LOOM_EVOLUTION_E2E=1` enables the native acceptance requirement.
pub fn live_upgrade_retains_populated_state_test_() -> EunitTest {
  Timeout(90, fn() {
    case native.getenv("LOOM_EVOLUTION_E2E") {
      Ok("1") -> exercise()
      Ok(_) | Error(Nil) -> io.println_error("SKIP live upgrade acceptance")
    }
  })
}

fn exercise() {
  let root =
    extensions.scratch(
      "live-" <> bit_array.base16_encode(token.production_entropy()(6)),
    )
  let assert Ok(Nil) = native.ensure_private_directory(root)
    as "private state exists"
  let assert Ok(root) = native.canonical_directory(root)
    as "state root is canonical"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/work")
    as "author workspace exists"
  let assert Ok(collector) =
    actor.new([])
    |> actor.on_message(fn(state: List(acceptance.Authored), message) {
      case message {
        acceptance.Published(receipt) ->
          actor.continue(list.append(state, [receipt]))
        acceptance.Take(reply) -> {
          process.send(
            reply,
            list.first(state) |> result.map(Some) |> result.unwrap(None),
          )
          actor.continue(list.drop(state, 1))
        }
        acceptance.Done -> actor.stop()
      }
    })
    |> actor.start
    as "receipts cross provider callbacks"
  let authored = collector.data
  let script =
    list.flatten([
      acceptance.author_script_with(1, authored, live_upgrade.extension(1)),
      acceptance.invoke_script("invoke version 1", "version-1:fresh:count=1"),
      acceptance.author_script_with(2, authored, live_upgrade.extension(2)),
      list.take(launch_script(root), 2),
      acceptance.invoke_script("invoke version 2", "version-2:fresh:count=2"),
      acceptance.author_script_with(3, authored, live_upgrade.refusing(3)),
      acceptance.invoke_script(
        "invoke after refusal",
        "version-2:fresh:count=3",
      ),
      acceptance.author_script_with(4, authored, live_upgrade.timing_out(4)),
      list.drop(launch_script(root), 2),
      acceptance.invoke_script(
        "invoke after timeout",
        "version-2:fresh:count=4",
      ),
      acceptance.author_script_with(5, authored, live_upgrade.legacy_only(5)),
      acceptance.invoke_script(
        "invoke after incompatible rollback",
        "version-2:fresh:count=5",
      ),
      acceptance.author_script_with(
        6,
        authored,
        live_upgrade.definition_timing_out(6),
      ),
      acceptance.invoke_script(
        "invoke after definition timeout",
        "version-2:fresh:count=6",
      ),
      acceptance.author_script_with(7, authored, live_upgrade.changed_hooks(7)),
      acceptance.invoke_script(
        "invoke after changed hooks",
        "version-2:fresh:count=7",
      ),
      acceptance.invoke_script("invoke rollback", "version-1:fresh:count=8"),
    ])
  let #(Nil, observations) =
    peer.with_upgrade_script(script, fn(url) {
      let assert Ok(instance) =
        serve.open_instance(acceptance.settings(root, url), log.discard())
        as "production session starts"
      let socket = acceptance.operator(instance)
      let core = acceptance.request(socket, 900, "core_status", json.Object([]))
      assert acceptance.required_text(core, "component") == "scratch"
        as "the supervised scratch route is available"
      assert acceptance.required_text(core, "pid") != ""
        as "the supervised component reports its actual PID"
      assert acceptance.required_text(core, "version") != ""
        as "the supervised component reports its reviewed identity"
      let before = acceptance.helpers()
      acceptance.run(instance.runtime, "author version 1")
      let first = acceptance.authored_result(authored)
      acceptance.verify_evidence(socket, 901, first)
      acceptance.approve(socket, 902, first)
      acceptance.select(socket, 903, first, 0, "live-v1", "select")
      acceptance.run(instance.runtime, "invoke version 1")
      let original_pid = target_pid(socket, 920, "live-v1")
      let original = acceptance.new_helpers(before)
      assert original != [] as "the initial callback occupies an actual jail"
      acceptance.run(instance.runtime, "author version 2")
      let second = acceptance.authored_result(authored)
      acceptance.verify_evidence(socket, 904, second)
      acceptance.approve(socket, 905, second)
      acceptance.run(instance.runtime, "launch overlap job")
      let assert poll.Answered(Nil) =
        poll.until(20_000, 20, fn() {
          case simplifile.read(root <> "/work/overlap-started") {
            Ok("ready") -> poll.Done(Nil)
            _ -> poll.Retry
          }
        })
        as "the real code-mode job entered its brokered process before migration"
      acceptance.select(socket, 906, second, 1, "live-v2", "select")
      assert target_pid(socket, 921, "live-v2") == original_pid
        as "upgrade preserves the target state actor PID"
      assert list.all(original, fn(helper) {
        list.contains(acceptance.new_helpers(before), helper)
      })
        as "forward upgrade retains the same native helper identities"
      acceptance.run(instance.runtime, "invoke version 2")
      acceptance.run(instance.runtime, "author version 3")
      let refused = acceptance.authored_result(authored)
      acceptance.verify_evidence(socket, 930, refused)
      acceptance.approve(socket, 931, refused)
      reject_selection(socket, refused, "live-refused", "select")
      assert target_pid(socket, 934, "live-v2") == original_pid
        as "failed migration preserves the actor PID"
      acceptance.run(instance.runtime, "invoke after refusal")
      acceptance.run(instance.runtime, "author version 4")
      let timeout = acceptance.authored_result(authored)
      acceptance.verify_evidence(socket, 940, timeout)
      acceptance.approve(socket, 941, timeout)
      reject_selection(socket, timeout, "live-timeout", "select")
      assert target_pid(socket, 944, "live-v2") == original_pid
        as "timed-out migration preserves the actor PID"
      let assert Ok(Nil) =
        simplifile.write(root <> "/work/overlap-release", "continue")
        as "the operator releases the independent job after migration"
      let assert poll.Answered(Nil) =
        poll.until(10_000, 10, fn() {
          case simplifile.read(root <> "/work/overlap-finished") {
            Ok("joined") -> poll.Done(Nil)
            _ -> poll.Retry
          }
        })
        as "the original real code-mode execution completes through its notice and join"
      let assert poll.Answered(Nil) =
        poll.until(10_000, 10, fn() {
          case session.strand_state(instance.runtime.session, "main") {
            Ok(Some(session.Cell(value: state, ..))) -> {
              case state.current_operation {
                None -> poll.Done(Nil)
                Some(_) -> poll.Retry
              }
            }
            _ -> poll.Retry
          }
        })
        as "the automatic completion notice finishes before the next user turn"
      acceptance.run(instance.runtime, "invoke after timeout")
      acceptance.run(instance.runtime, "author version 5")
      let incompatible = acceptance.authored_result(authored)
      acceptance.verify_evidence(socket, 960, incompatible)
      acceptance.approve(socket, 961, incompatible)
      reject_selection(socket, incompatible, "live-incompatible", "rollback")
      assert target_pid(socket, 964, "live-v2") == original_pid
        as "an incompatible downgrade preserves the populated current actor"
      acceptance.run(instance.runtime, "invoke after incompatible rollback")
      acceptance.run(instance.runtime, "author version 6")
      let definition_timeout = acceptance.authored_result(authored)
      acceptance.verify_evidence(socket, 970, definition_timeout)
      acceptance.approve(socket, 971, definition_timeout)
      reject_selection(
        socket,
        definition_timeout,
        "live-definition-timeout",
        "select",
      )
      assert target_pid(socket, 974, "live-v2") == original_pid
        as "nonterminating authored definition cannot destroy the predecessor"
      acceptance.run(instance.runtime, "invoke after definition timeout")
      acceptance.run(instance.runtime, "author version 7")
      let changed_hooks = acceptance.authored_result(authored)
      acceptance.verify_evidence(socket, 980, changed_hooks)
      acceptance.approve(socket, 981, changed_hooks)
      reject_selection(socket, changed_hooks, "live-changed-hooks", "select")
      assert target_pid(socket, 984, "live-v2") == original_pid
        as "changed hook subscriptions cannot silently keep an obsolete bus"
      acceptance.run(instance.runtime, "invoke after changed hooks")
      acceptance.select(socket, 907, first, 2, "live-rollback", "rollback")
      assert target_pid(socket, 922, "live-rollback") == original_pid
        as "rollback preserves the target state actor PID"
      assert list.all(original, fn(helper) {
        list.contains(acceptance.new_helpers(before), helper)
      })
        as "rollback retains the same native helper identities"
      acceptance.run(instance.runtime, "invoke rollback")
      let final_helpers = acceptance.new_helpers(before)
      serve.close_instance(instance)
      acceptance.assert_departed(final_helpers)
      Nil
    })
  let assert Ok(requests) = observations
    as "all real provider exchanges complete"
  assert list.length(requests) == list.length(script)
    as "every scripted turn executes"
  process.send(authored, acceptance.Done)
}

fn target_pid(
  socket: gateway.ConnectionHandle,
  id: Int,
  request_id: String,
) -> String {
  let status =
    acceptance.request(
      socket,
      id,
      "status",
      json.Object([
        #("request_id", json.String(request_id)),
      ]),
    )
  let live = status |> acceptance.field("inventory") |> acceptance.field("live")
  let pid = acceptance.required_text(live, "state_pid")
  assert pid != "" as "reserved native inventory observes the target actor"
  pid
}

fn reject_selection(
  socket: gateway.ConnectionHandle,
  authored: acceptance.Authored,
  request_id: String,
  action: String,
) {
  let receipt =
    acceptance.request(
      socket,
      932,
      action,
      json.Object([
        #("candidate_id", json.String(authored.candidate_id)),
        #("evidence_id", json.String(authored.evidence_id)),
        #("expected_generation", json.Int(2)),
        #("request_id", json.String(request_id)),
        #("deadline_ms", json.Int(120_000)),
        #("reason", json.String("exercise failed migration")),
      ]),
    )
  assert acceptance.field(receipt, "state") == json.String("queued")
    as "the valid approved candidate reaches native preparation"
  let assert poll.Answered(status) =
    poll.until(within: 125_000, every: 100, attempt: fn() {
      let core = acceptance.request(socket, 950, "core_status", json.Object([]))
      assert acceptance.required_text(core, "component") == "scratch"
        as "unrelated supervised component responds during preparation"
      let status =
        acceptance.request(
          socket,
          933,
          "status",
          json.Object([
            #("request_id", json.String(request_id)),
          ]),
        )
      case acceptance.field(status, "state") {
        json.String("queued") | json.String("running") -> poll.Retry
        _ -> poll.Done(status)
      }
    })
    as "failed migration returns a conclusive native receipt"
  assert acceptance.field(status, "state") == json.String("failed")
    as json.to_string(status)
}

fn launch_script(root: String) -> List(peer.Exchange) {
  [
    peer.ToolUseExchange(
      "launch overlap job",
      "launch-overlap",
      "code_mode",
      json.Object([
        #("mode", json.String("launch")),
        #("program", json.String(overlap_program)),
        #("within_ms", json.Int(60_000)),
      ]),
    ),
    peer.ComputedExchange(peer.AwaitToolResult("launch-overlap"), fn(requests) {
      assert overlap_handle(requests) != ""
        as "production code mode returns an owned execution"
      peer.ReplyText("overlap job launched")
    }),
    peer.ComputedExchange(
      peer.AwaitPromptPrefix("[loom] async code-mode execution "),
      fn(requests) {
        peer.ReplyToolUse(
          "join-overlap",
          "code_mode",
          json.Object([
            #("mode", json.String("join")),
            #("handle", json.String(overlap_handle(requests))),
            #("within_ms", json.Int(10_000)),
          ]),
        )
      },
    ),
    peer.ComputedExchange(peer.AwaitToolResult("join-overlap"), fn(requests) {
      assert list.any(requests, fn(request) {
        case request.latest {
          peer.SuccessfulToolResult("join-overlap", text) ->
            string.contains(text, "overlap-complete")
          _ -> False
        }
      })
        as "the original independent code-mode job returns its real result"
      let assert Ok(Nil) =
        simplifile.write(root <> "/work/overlap-finished", "joined")
        as "the provider records the checked original execution result"
      peer.ReplyText("real overlap job completed")
    }),
  ]
}

fn overlap_handle(requests: List(peer.ObservedRequest)) -> String {
  let results =
    list.filter_map(requests, fn(request) {
      case request.latest {
        peer.SuccessfulToolResult("launch-overlap", text) ->
          json.parse(text) |> result.replace_error(Nil)
        _ -> Error(Nil)
      }
    })
  let assert Ok(result) = list.first(results)
    as "the actual launch response is retained"
  acceptance.required_text(result, "id")
}

const overlap_program =
  "//// Independently scheduled real capability execution.\n"
  <> "import cap/proc\nimport cap/report\n\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> " case proc.run(proc.command([\"/bin/sh\", \"-c\", \"printf ready > overlap-started; i=0; while [ ! -f overlap-release ] && [ $i -lt 600 ]; do /bin/sleep 0.05; i=$((i+1)); done; test -f overlap-release\"])) {\n"
  <> "  Ok(output) if output.exit_code == 0 -> report.text(\"overlap-complete\")\n"
  <> "  Ok(_) -> report.failure(\"overlap barrier expired\")\n"
  <> "  Error(_) -> report.failure(\"capability refused\")\n }\n}\n"
