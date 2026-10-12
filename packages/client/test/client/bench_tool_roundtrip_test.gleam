//// Opt-in model-to-model latency through the shipped local and TLS executor
//// surfaces. Provider callbacks bracket each bash call, including transcript
//// persistence, job completion and response encoding. Boot and session opening
//// are outside the samples; the first call is reported as a cold observation.

import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import host/bootstrap as native
import simplifile
import support/provider_http as provider
import support/remote_daemons
import support/remote_pair

type Placement {
  Local
  Distributed
}

type Stamp {
  Started(id: String, at: Int)
  Finished(id: String, at: Int)
}

const samples = 20

/// Runs both placements only when explicitly requested.
///
/// ## Examples
///
/// `LOOM_BENCH_TOOLS=1 bash scripts/test.sh client --match client@bench_tool_roundtrip_test:`.
pub fn shipped_tool_latency_test_() -> EunitTest {
  case native.getenv("LOOM_BENCH_TOOLS") {
    Ok("1") ->
      Timeout(120, fn() {
        let completed = process.new_subject()
        let Timeout(_, local) =
          remote_pair.shipped("tool latency", [], fn(pair) {
            drive(pair, Local)
            process.send(completed, Nil)
          })
        let Timeout(_, remote) =
          remote_pair.shipped("tool latency", [], fn(pair) {
            drive(pair, Distributed)
            process.send(completed, Nil)
          })
        local()
        let assert Ok(Nil) = process.receive(completed, 1000)
          as "an explicitly requested local benchmark cannot skip execution"
        remote()
        let assert Ok(Nil) = process.receive(completed, 1000)
          as "an explicitly requested distributed benchmark cannot skip execution"
        Nil
      })
    _unset -> Timeout(1, fn() { Nil })
  }
}

fn drive(pair: remote_pair.Pair, placement: Placement) -> Nil {
  let stamps = process.new_subject()
  let keys = remote_pair.provision(pair)
  let #(Nil, report) =
    provider.with_server_for(
      script(stamps),
      provider.OnlySuccessful,
      remote_pair.callback_ms,
      fn(url) {
        remote_pair.configure(pair, keys, remote_pair.plain(url))
        case placement {
          Local -> {
            let assert Ok(Nil) =
              simplifile.write(
                pair.orchestrator.config,
                remote_daemons.model_table(url),
              )
              as "local placement has no distribution transport"
            Nil
          }
          Distributed -> Nil
        }
        let opened = case placement {
          Distributed -> remote_pair.open_registered(pair, [], "latency")
          Local -> {
            case native.getenv("LOOM_BENCH_PROFILE") {
              Ok("1") -> {
                let assert Ok(launcher) =
                  simplifile.read(pair.orchestrator.launcher)
                  as "the isolated launcher exists"
                let flags =
                  "ERL_FLAGS='-name "
                  <> keys.orchestrator.node
                  <> " -kernel inet_dist_use_interface {127,0,0,1}'\nexport ERL_FLAGS\nunset LOOM_DISTRIBUTION_OPTFILE\n"
                let assert Ok(Nil) =
                  simplifile.write(
                    pair.orchestrator.launcher,
                    string.replace(
                      launcher,
                      "#!/bin/sh\n",
                      "#!/bin/sh\n" <> flags,
                    ),
                  )
                  as "only the disposable local daemon is profiled"
                io.println_error("PROFILE_NODE=" <> keys.orchestrator.node)
                io.println_error(
                  "PROFILE_COOKIE="
                  <> pair.orchestrator.home
                  <> "/.erlang.cookie",
                )
                Nil
              }
              _unset -> Nil
            }
            let running = remote_daemons.start(pair.orchestrator)
            let control = remote_daemons.open_control(running)
            let #(session, settled) =
              remote_daemons.create_local_and_settle(
                control,
                1,
                "latency",
                pair.checkout,
              )
            assert remote_daemons.settled_state(settled) == "resident"
            remote_pair.Opened(orchestrator: running, control:, session:)
          }
        }
        case native.getenv("LOOM_BENCH_PROFILE"), placement {
          Ok("1"), Local -> {
            io.println_error(
              "PROFILE_STATE_DIR=" <> pair.orchestrator.paths.root,
            )
            process.sleep(5000)
          }
          _env, _placement -> Nil
        }
        remote_pair.converse_for(opened, "measure calls", ["measured"])
        case native.getenv("LOOM_BENCH_PROFILE"), placement {
          Ok("1"), Local -> process.sleep(20_000)
          _env, _placement -> Nil
        }
        remote_daemons.stop_session(
          opened.orchestrator,
          opened.control,
          100,
          opened.session,
        )
        remote_pair.close_daemons([opened.orchestrator])
      },
    )
  let assert Ok(requests) = report
    as "every scripted tool call returned successfully"
  assert list.length(requests) == samples + 2
  let elapsed =
    list.repeat(Nil, samples + 1)
    |> list.index_map(fn(_, i) { i })
    |> list.map(fn(index) {
      let id = int.to_string(index)
      let assert Ok(Started(start_id, started)) = process.receive(stamps, 1000)
        as "each call has its starting observation"
      let assert Ok(Finished(end_id, finished)) = process.receive(stamps, 1000)
        as "each call has its result observation"
      assert start_id == id && end_id == id
      finished - started
    })
  emit(placement, elapsed)
}

fn script(stamps: process.Subject(Stamp)) -> List(provider.Exchange) {
  let first =
    provider.ComputedExchange(provider.AwaitPrompt("measure calls"), fn(_seen) {
      invoke(stamps, 0)
    })
  let rest =
    list.repeat(Nil, samples + 1)
    |> list.index_map(fn(_, i) { i })
    |> list.map(fn(index) {
      let id = int.to_string(index)
      provider.ComputedExchange(provider.AwaitToolResult(id), fn(seen) {
        let finished = native.monotonic_time_ms()
        assert remote_daemons.result_text(seen, id) == "ready\n"
        process.send(stamps, Finished(id, finished))
        case index == samples {
          True -> provider.ReplyText("measured")
          False -> invoke(stamps, index + 1)
        }
      })
    })
  [first, ..rest]
}

fn invoke(stamps: process.Subject(Stamp), index: Int) -> provider.Reply {
  let id = int.to_string(index)
  process.send(stamps, Started(id, native.monotonic_time_ms()))
  provider.ReplyToolUse(
    id,
    "bash",
    json.Object([#("command", json.String(command()))]),
  )
}

fn emit(placement: Placement, elapsed: List(Int)) -> Nil {
  let label = case placement {
    Local -> "local"
    Distributed -> "distributed"
  }
  let warm = list.drop(elapsed, 1)
  let sorted = list.sort(warm, int.compare)
  let assert Ok(cold) = list.first(elapsed) as "the cold sample exists"
  let assert Ok(p50) = list.first(list.drop(sorted, 9))
    as "twenty warm samples exist"
  let assert Ok(p95) = list.first(list.drop(sorted, 18))
    as "twenty warm samples exist"
  let text =
    json.Object([
      #("placement", json.String(label)),
      #("command", json.String(command())),
      #("cold_ms", json.Int(cold)),
      #("p50_ms", json.Int(p50)),
      #("p95_ms", json.Int(p95)),
      #("warm_samples_ms", json.Array(list.map(warm, json.Int))),
    ])
    |> json.to_string
  io.println_error(text)
  let path = native.getenv("LOOM_BENCH_TOOLS_OUT") |> result_path
  let assert Ok(Nil) = simplifile.append(path, text <> "\n")
    as "the benchmark observations are saved"
  Nil
}

fn result_path(path: Result(String, Nil)) -> String {
  case path {
    Ok(path) -> path
    Error(Nil) -> "build/bench-tool-roundtrip.jsonl"
  }
}

// A bounded slow command exposes completion quantization after backoff has
// grown, while keeping output and successful exit identical to the short case.
fn command() -> String {
  case native.getenv("LOOM_BENCH_TOOLS_WORKLOAD") {
    Ok("delayed") -> "sleep 0.2; printf 'ready\\n'"
    _short -> "printf 'ready\\n'"
  }
}
