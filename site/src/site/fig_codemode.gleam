//// Figure: code mode, from a program to a result.
////
//// Sources: `docs/code-mode.md` and `docs/architecture/code-mode.md`
//// ("The pipeline", "Layer one: vetting", "The prelude is the capability
//// system", "Program modes and capability admission"), and `docs/loom-design.md`
//// section 6. The program is the first example in `docs/code-mode.md`.

import gleam/option.{None, Some}
import site/diagram.{
  type Diagram, type Frame, type NodeState, Diagram, Done, JailZone, Jailed,
  Live, Outside, Process, Quiet, Sizes, TrustedZone,
}
import site/dkit.{frame, link, node, r, send, state, zone}
import site/figure.{type Spec, Sample, Spec, Step}
import site/msg

const program =
  "import cap/fs
import cap/report
import cap/task
import gleam/list
import gleam/result
import gleam/string

pub fn main() -> report.Outcome {
  let paths = [\"README.md\", \"docs/loom-design.md\", \"docs/code-mode.md\"]
  case task.parallel_map(paths, max_concurrency: 3, with: line_count) {
    Ok(counts) ->
      list.zip(paths, counts)
      |> list.map(fn(pair) { #(pair.0, report.int(pair.1)) })
      |> report.object
      |> report.value
    Error(failures) -> report.failure(string.inspect(failures))
  }
}

fn line_count(path: String) -> Result(Int, fs.FsError) {
  use text <- result.map(fs.read(path))
  list.length(string.split(text, \"\\n\"))
}"

/// The words of every step.
pub fn spec() -> Spec {
  Spec(
    id: msg.CodeMode,
    title: "Code mode: from a program to a result",
    diagram: diagram(),
    steps: [
      Step(
        label: "The task",
        tag: "",
        caption: "Three files, one question: how many lines does each have?",
        heading: "Three tool calls would be three round trips",
        body: [
          "A tool call is a round trip. The model emits a call, the harness runs it, and the result returns as context for the next turn. Counting the lines of three files that way takes three turns, and all three file texts land in the context although the model wanted only the counts.",
          "In code mode the model writes one program instead.",
        ],
        state: [
          #(
            "Without code mode",
            "three model turns, three file texts in the context",
          ),
          #("With code mode", "one execution, one result"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Write",
        tag: "",
        caption: "The model submits a Gleam program through the code_mode tool.",
        heading: "The model writes a Gleam program",
        body: [
          "The program imports capability modules: `cap/fs`, `cap/task` and `cap/report`. The import list is its permission set. It did not import `cap/proc` or `cap/net`, so it cannot run a command or open a connection, whatever its logic computes.",
          "The model submits it as `{\"program\": \"...\", \"seam\": \"workspace\"}`. A saved program can be run again by path with `program_path`.",
        ],
        state: [
          #("Can do", "read files, concurrently"),
          #("Cannot do", "run a command, use the network, start an agent"),
        ],
        sample: Some(Sample("The program", program)),
        failure: None,
      ),
      Step(
        label: "Vet",
        tag: "",
        caption: "A lint in the harness rejects anything outside the capability modules.",
        heading: "Vetting reads the source, not the behaviour",
        body: [
          "Vetting parses the source with `glance` and applies exact rules. It rejects any `@external` and, failing closed, any attribute at all, because `@external` is Gleam's only bridge to arbitrary Erlang. It rejects any import outside the allowlist: the capability prelude and a fixed pure part of the standard library. A token-level scan backs up the parser.",
          "This works because Gleam has no `eval`, no reflection, no macros and no dynamic module lookup. A program's maximal capabilities can be read off its imports without running it.",
        ],
        state: [
          #("Where", "the harness VM, a pure function"),
          #("Result", "pass, or `VetRejected` with a reason"),
        ],
        sample: None,
        failure: Some(
          "A rejection comes back to the model as an ordinary result that it can fix.",
        ),
      ),
      Step(
        label: "Compile",
        tag: "",
        caption: "The compiler builds the program inside the jail, offline.",
        heading: "A hermetic build, and the type checker checks every argument",
        body: [
          "`gleam build --warnings-as-errors` runs in the sandbox, offline, against a pinned and vendored prelude. The program is written to a path the compile service chooses, `loom_program.gleam`, so it cannot shadow `cap/fs` with a module of its own.",
          "The type checker also validates every tool argument. A wrong call fails here, before any node starts.",
        ],
        state: [
          #("Where", "the kernel jail"),
          #(
            "Result",
            "a build, or `CompileFailed` with the compiler's diagnostics",
          ),
        ],
        sample: None,
        failure: Some(
          "A build that fails only on unused imports, arguments or bindings is rewritten and retried once, automatically.",
        ),
      ),
      Step(
        label: "Run",
        tag: "",
        caption: "A fresh satellite node starts in the jail and runs the program.",
        heading: "The program runs in a disposable BEAM node",
        body: [
          "The satellite starts with Erlang distribution disabled, so it cannot reach or join another node. It has no network, enforced by seccomp and an empty network namespace. A cgroup, a CPU limit and a wall-clock deadline bound it, and it is destroyed when the program returns.",
          "Its only link to the outside is one Unix socket that carries framed `cap_call` and `cap_result` messages.",
        ],
        state: [
          #("Distribution", "disabled"),
          #("Network", "none"),
          #("Deadline", "five minutes by default, fifteen at most"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Call capabilities",
        tag: "",
        caption: "Each fs.read is a cap_call over the socket, checked by the broker.",
        heading: "Every effect is one checked call",
        body: [
          "`task.parallel_map` runs the three reads at once. Each `fs.read` becomes a `cap_call` frame carrying the execution's token. The broker checks the token, the session policy and the strand's tools, performs the read, and answers with a `cap_result`.",
          "A capability that needs a tool the strand does not hold, such as `proc.run` without `bash`, is refused with `tool_not_held`. All calls share one budget: a cap on outstanding effects, six by default, and one deadline.",
        ],
        state: [
          #("Checked", "execution token, session policy, the strand's tools"),
          #(
            "Budget",
            "six outstanding effects by default, pooled across the program",
          ),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Return",
        tag: "",
        caption: "Only the structured result reaches the model.",
        heading: "The model receives one value",
        body: [
          "`main` returns a `report.Outcome`. The harness marshals it back and the satellite is destroyed. The three file texts never entered the conversation: the model sees a map from each path to its line count.",
        ],
        state: [
          #("Success", "`Ran`, carrying the program's outcome"),
          #("Failure", "`RunFailed`, as an ordinary result"),
        ],
        sample: None,
        failure: None,
      ),
    ],
  )
}

/// The boxes, the links and the seven frames.
pub fn diagram() -> Diagram {
  Diagram(
    sizes: Sizes(wide_w: 480, wide_h: 372, narrow_w: 320, narrow_h: 552),
    nodes: [
      node("model", "Model", "", Outside, r(296, 0, 184, 70), r(0, 0, 320, 70)),
      zone(
        "harness",
        "Harness VM, trusted",
        TrustedZone,
        r(0, 96, 480, 132),
        r(0, 84, 320, 214),
      ),
      node("vet", "Vet", "", Process, r(10, 122, 202, 98), r(8, 108, 304, 90)),
      node(
        "broker",
        "ToolBroker",
        "",
        Process,
        r(268, 122, 202, 98),
        r(8, 204, 304, 90),
      ),
      zone(
        "jail",
        "Kernel jail, untrusted",
        JailZone,
        r(0, 252, 480, 120),
        r(0, 312, 320, 240),
      ),
      node(
        "build",
        "gleam build",
        "",
        Jailed,
        r(10, 278, 190, 86),
        r(8, 336, 304, 90),
      ),
      node(
        "satellite",
        "Satellite, a BEAM node",
        "",
        Jailed,
        r(212, 278, 258, 86),
        r(8, 436, 304, 108),
      ),
    ],
    links: [
      link("submit", "model", "vet"),
      link("compile", "vet", "build"),
      link("launch", "build", "satellite"),
      link("caps", "satellite", "broker"),
      link("result", "broker", "model"),
    ],
    frames: [
      step_0(),
      step_1(),
      step_2(),
      step_3(),
      step_4(),
      step_5(),
      step_6(),
    ],
  )
}

fn idle_vet() -> NodeState {
  state("vet", "waiting for a program", Quiet)
}

fn step_0() -> Frame {
  frame(
    [
      state("model", "needs 3 line counts\nno output yet", Live),
      idle_vet(),
      state("broker", "idle", Quiet),
      state("build", "idle", Quiet),
      state("satellite", "not started", Quiet),
    ],
    [],
  )
}

fn step_1() -> Frame {
  frame(
    [
      state("model", "writes a Gleam program", Live),
      state("vet", "receives the source", Live),
      state("broker", "idle", Quiet),
      state("build", "idle", Quiet),
      state("satellite", "not started", Quiet),
    ],
    [send("submit", "model", "code_mode: program, seam")],
  )
}

fn step_2() -> Frame {
  frame(
    [
      state("model", "waits", Quiet),
      state(
        "vet",
        "no @external\nimports on the allowlist\ntoken-stream backstop",
        Live,
      ),
      state("broker", "idle", Quiet),
      state("build", "idle", Quiet),
      state("satellite", "not started", Quiet),
    ],
    [],
  )
}

fn step_3() -> Frame {
  frame(
    [
      state("model", "waits", Quiet),
      state("vet", "passed", Done),
      state("broker", "idle", Quiet),
      state(
        "build",
        "offline, strict build\nvendored cap prelude\nloom_program.gleam",
        Live,
      ),
      state("satellite", "not started", Quiet),
    ],
    [send("compile", "vet", "vetted source")],
  )
}

fn step_4() -> Frame {
  frame(
    [
      state("model", "waits", Quiet),
      state("vet", "passed", Done),
      state("broker", "idle", Quiet),
      state("build", "built", Done),
      state(
        "satellite",
        "no distribution or network\ncgroup, CPU, wall limits",
        Live,
      ),
    ],
    [send("launch", "build", "the compiled program")],
  )
}

fn step_5() -> Frame {
  frame(
    [
      state("model", "waits", Quiet),
      state("vet", "passed", Done),
      state(
        "broker",
        "execution token\nsession policy\nstrand holds the tool",
        Live,
      ),
      state("build", "built", Done),
      state("satellite", "three fs.read calls in flight", Live),
    ],
    [
      send("caps", "satellite", "cap_call fs.read"),
      send("caps", "broker", "cap_result"),
    ],
  )
}

fn step_6() -> Frame {
  frame(
    [
      state("model", "receives one value\n3 line counts", Done),
      state("vet", "passed", Done),
      state("broker", "marshals the outcome", Live),
      state("build", "built", Done),
      state("satellite", "destroyed: the program returned", Quiet),
    ],
    [send("result", "broker", "the structured outcome")],
  )
}
