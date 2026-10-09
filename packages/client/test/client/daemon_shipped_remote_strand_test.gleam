//// A remote session's code-mode program spawns a child strand, against the
//// shipped daemon: an orchestrator and an executor, two real `bin/loomd`
//// processes that trust each other over TLS distribution (issue #697,
//// protocol-change/078).
////
//// `daemon_shipped_remote_caps_test` proves two owner-bound capabilities that
//// answer at once, `strand.roster` and `notes.put`. A spawn is a different
//// kind of call. It makes the orchestrator's Agency create a strand, start a
//// model turn for it, and keep the turn running after the capability call
//// returns, and the program then joins the child with `strand.wait`, which
//// holds the owner port's reply until the child's run ends. This fixture shows
//// that whole chain across the two nodes.
////
//// ## What it proves
////
//// `daemon_shipped_remote_strand_test_`, one registered session and one scripted
//// model that also plays the child.
////
//// - The model submits one `code_mode` program. The program is compiled and run
////   on the executor. It calls `strand.spawn` with a brief and then
////   `strand.wait` on the handle it got back. Both capabilities cross the
////   owner port and are answered by the orchestrator's Agency.
//// - The child's turn runs on the orchestrator, against the same scripted
////   provider. The provider sees the child's brief as the opening of a
////   request, in the order the script lists it, so the child ran exactly once.
//// - The child's own workspace tool goes to the executor. Its `bash` call
////   prints the executor's checkout as its working directory, which is the
////   session's registered workspace, and writes a file there. The file is in the
////   executor's checkout and nowhere on the orchestrator.
//// - The child's final text comes back through `strand.wait` into the program,
////   and the program's report carries it to the parent's model. That is the
////   child's result observed in the parent.
//// - Stopping the session closes the executor's scope `closed` with
////   `all_retired`, so the child's calls and the program's satellite were
////   retired with it.
////
//// ## What it needs
////
//// Code mode on the executor needs a toolchain and the build seed
//// `make codemode-seed` prepares, and the jail needs platform enforcement.
//// Without enforcement the fixture declines as the other shipped fixtures do.
//// Without `gleam`, `erl` or the seed it prints a skip line naming what is
//// missing, because it then proves nothing about this route.
////
//// ## Running it
////
//// ```sh
//// make codemode-seed
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// bash scripts/test.sh client --match 'client@daemon_shipped_remote_strand_test:'
//// ```
////
//// The fixture is the one `daemon_shipped_remote_test` documents, arranged for
//// a single pair by `support/remote_pair`.

import client/tui_e2e_test.{type EunitTest}
import core/json
import gleam/io
import gleam/string
import session_view/strand_framing
import simplifile
import support/provider_http as provider
import support/remote_daemons
import support/remote_pair.{type Pair}

const skip_label = "shipped remote strand"

const prompt = "delegate the note"

const answer = "delegation done"

// What the child writes in the checkout, and the text that ends its run.
const child_file = "child-note.txt"

const child_text = "child wrote the note"

// The child's one tool call. It prints its working directory before it writes,
// so the result the child's model reads says where the call ran.
const child_command = "pwd && echo from-the-child > child-note.txt"

/// Starts an orchestrator and an executor from the shipment and runs one
/// code-mode program on the executor that spawns a child strand and joins it.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_strand_test:'`.
pub fn daemon_shipped_remote_strand_test_() -> EunitTest {
  remote_pair.shipped(skip_label, [], gated)
}

// Code mode must have what it builds with. That is a property of the host and is
// measured here, before any daemon starts.
fn gated(prepared: Pair) -> Nil {
  case remote_pair.code_mode_seed() {
    Error(reason) ->
      io.println_error(
        "SKIP " <> skip_label <> ": code mode cannot build here: " <> reason,
      )
    Ok(seed) -> spawn_and_join(prepared, seed)
  }
}

// The program the model submits. The spawn and the join are both owner-bound:
// the Agency and the lineage ledger are in the orchestrator's session store.
fn program() -> String {
  string.join(
    [
      "import cap/report",
      "import cap/strand",
      "import gleam/list",
      "import gleam/string",
      "",
      "pub fn main() -> report.Outcome {",
      "  let child =",
      "    strand.assignment(purpose: \"write on the executor\", brief: \"write the note\")",
      "  case strand.spawn(child) {",
      "    Ok(handle) -> join(handle)",
      "    Error(error) -> report.failure(\"spawn refused: \" <> strand.error_text(error))",
      "  }",
      "}",
      "",
      "fn join(handle: strand.Handle) -> report.Outcome {",
      "  case strand.wait([handle], within_ms: 120_000) {",
      "    Ok([strand.Ready(outcome: strand.Completed, report: text, ..)]) ->",
      "      report.text(\"child completed: \" <> text)",
      "    Ok(other) ->",
      "      report.failure(string.join(list.map(other, strand.waited_text), \"; \"))",
      "    Error(error) -> report.failure(\"wait refused: \" <> strand.error_text(error))",
      "  }",
      "}",
      "",
    ],
    "\n",
  )
}

// The conversation in the order the provider is asked: the parent's prompt, the
// child's brief, the child's tool result, then the parent's program result. The
// provider matches each request against the next step, so a child that ran
// twice, or a reply that came in another order, is refused.
fn script() -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      prompt,
      "program-call",
      "code_mode",
      json.Object([
        #("program", json.String(program())),
        #("within_ms", json.Int(180_000)),
      ]),
    ),
    provider.ComputedExchange(
      provider.AwaitPromptPrefix(strand_framing.brief_head("main")),
      fn(_seen) {
        provider.ReplyToolUse(
          "child-call",
          "bash",
          json.Object([#("command", json.String(child_command))]),
        )
      },
    ),
    provider.ComputedExchange(provider.AwaitToolResult("child-call"), fn(_seen) {
      provider.ReplyText(child_text)
    }),
    provider.ComputedExchange(
      provider.AwaitToolResult("program-call"),
      fn(_seen) { provider.ReplyText(answer) },
    ),
  ]
}

fn spawn_and_join(prepared: Pair, seed: String) -> Nil {
  let keys = remote_pair.provision(prepared)
  let #(Nil, report) =
    provider.with_server_for(
      script(),
      provider.OnlySuccessful,
      remote_pair.callback_ms,
      fn(url) {
        remote_pair.configure(
          prepared,
          keys,
          remote_pair.Tables(
            models: remote_pair.models_without_glance(url),
            orchestrator: "",
            executor: "",
          ),
        )
        let opened =
          remote_pair.open_registered(
            prepared,
            ["--codemode-seed", seed],
            "e2e-remote-strand",
          )

        // Compiling a program in a jail takes tens of seconds before it runs.
        remote_pair.converse_for(opened, prompt, [answer])
        remote_pair.stop_and_close(prepared, opened, 1)
        remote_pair.close_daemons([opened.orchestrator])
      },
    )
  let assert Ok(requests) = report
    as "the provider saw the parent, the child and nothing else, in order"
  assert_results(prepared, requests)
}

// Where each part ran. The program's report holds the child's final text, so
// the spawn and the join both returned to the satellite on the executor. The
// child's `bash` result names the executor's checkout, and the file it wrote is
// there and nowhere on the orchestrator.
fn assert_results(
  prepared: Pair,
  requests: List(provider.ObservedRequest),
) -> Nil {
  let joined = remote_daemons.result_text(requests, "program-call")
  assert string.contains(joined, "child completed: " <> child_text)
  let directory = remote_daemons.result_text(requests, "child-call")
  assert string.trim(directory) == prepared.checkout
  let assert Ok(written) =
    simplifile.read(prepared.checkout <> "/" <> child_file)
    as "the child's file is under the executor checkout"
  assert written == "from-the-child\n"
  remote_daemons.assert_absent_from(
    [prepared.orchestrator.directory, prepared.orchestrator.home],
    child_file,
  )
}
