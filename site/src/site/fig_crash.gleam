//// Figure: a crash in the middle of a tool call.
////
//// Sources: `docs/architecture/orchestration.md` ("The supervision tree" and
//// "The effect sandwich"), `docs/architecture/durability.md`,
//// `docs/architecture/sessions.md` ("Reopening after an unclean exit") and
//// `docs/loom-design.md` section 4.1.
////
//// The drawing has three parts: the session's processes on the left, the
//// session file on the right, and a row of three stages under the file for
//// the two commits and the window between them. The tree shows three of the
//// supervisor's six children, the ones this story needs. The names are the
//// code's: the design document calls the strand factory `StrandSupervisor`,
//// and `docs/architecture/orchestration.md` is the later and exact account.

import gleam/option.{None, Some}
import site/diagram.{
  type Diagram, type Frame, Diagram, Done, Fault, Group, Jailed, Live, Process,
  Quiet, Sizes, Stage, Store,
}
import site/dkit.{frame, link, node, r, send, state, zone}
import site/figure.{type Spec, Spec, Step}
import site/msg

/// The words of every step, and the drawing.
pub fn spec() -> Spec {
  Spec(
    id: msg.Crash,
    title: "A crash in the middle of a tool call",
    diagram: diagram(),
    steps: [
      Step(
        label: "Running",
        tag: "",
        caption: "Processes on the left work against one SQLite file on the right.",
        heading: "A session is a supervision tree over one file",
        body: [
          "Opening a session starts a `SessionSupervisor`. It is a rest-for-one supervisor, so the order of its children is the recovery policy: a crash in one strand restarts only that strand, and a crash of the `StorageWriter` restarts the writer and every child started after it. The `StorageWriter` is the only process that writes the session's SQLite file.",
          "The conversation is a tree of rows that are written once and never modified. A separate set of registers holds current state, and the one that matters here is `op.state`.",
        ],
        state: [
          #("Entries", "write-once rows in `session.db`"),
          #("`op.state`", "the complete current state of the running operation"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Commit the intent",
        tag: "",
        caption: "One transaction records the intent and reserves the ids the result will use.",
        heading: "The intent is committed before the command starts",
        body: [
          "The strand is about to run a `bash` call. First it commits a transaction that sets `op.state` to `effect_pending` and holds two reserved ids: `R` for the result entry and `U` for the usage row. The tool's replay policy is declared and stored in the same place.",
          "`op.state` is the durable program counter. It never depends on an earlier value, so recovery reads this one register and knows where the operation was.",
        ],
        state: [
          #("`op.state`", "`effect_pending`, with reserved ids `R` and `U`"),
          #(
            "Replay policy",
            "`ReplaySafe` or `ReplayNever`, persisted with the intent",
          ),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Run the command",
        tag: "",
        caption: "The command runs. Nothing durable changes until it finishes.",
        heading: "Between two commits is the only uncertain window",
        body: [
          "The command runs in its sandbox. Nothing durable happens while it runs. A crash lands on one side of this window or the other: before the intent commit the effect never started, and after the settle commit it is fully recorded.",
          "Only a crash inside the window needs recovery.",
        ],
        state: [
          #("Window", "after the intent commit, before the settle commit"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Kill the daemon",
        tag: "",
        caption: "The tree is gone. The file still holds the intent.",
        heading: "A SIGKILL loses the processes and nothing durable",
        body: [
          "A kill runs no cleanup. The tree of processes is gone, but the file still holds the prompt, the call and the `effect_pending` state. Whether the command finished is now unknown.",
          "The writer's lease row also survives, with the expiry its dead owner last renewed, so a replacement is refused until that expiry passes. That takes up to 60 seconds.",
        ],
        state: [
          #("Lease", "stays until its expiry, up to 60 seconds after the kill"),
          #("The command", "outcome unknown"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Reopen",
        tag: "",
        caption: "The same tree boots again and the strand reads its registers.",
        heading: "Recovery and a cold start are the same code",
        body: [
          "After a daemon restart every session stays closed until someone opens it. Opening boots the same tree, with the writer before the strand factories. Once the old lease has expired the new writer takes it and bumps the fence, so the old owner cannot commit again.",
          "The strand reads `op.state` and validates the rows it names. A row that does not decode is reported as corruption instead of being trusted.",
        ],
        state: [
          #("Lease", "taken by the new writer, fence incremented"),
          #("`op.state`", "`effect_pending`, read by the strand"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Pick by replay policy",
        tag: "",
        caption: "A call that is safe to repeat runs again. Any other call gets an explicit failure.",
        heading: "The runtime finds an orphan and applies the replay policy",
        body: [
          "The runtime reloads `effect_pending`, finds no live effect to match it, and gives the state machine an orphan observation. For a tool call the machine reads the replay policy stored at intent.",
          "`ReplaySafe` runs the call again with the stored arguments under the same reserved result id. `ReplayNever` does not run it again. The machine writes an interrupted result under the reserved id, with a warning that the outcome is unknown.",
        ],
        state: [
          #("`ReplaySafe`", "run again with the persisted arguments"),
          #("`ReplayNever`", "write an interrupted result; never run twice"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Settle",
        tag: "",
        caption: "One transaction writes the result, the usage row and the next state.",
        heading: "Every call ends with a result",
        body: [
          "The settle commit is atomic: the result entry under `R`, the usage row `U`, the move of the strand's leaf, and the next `op.state`. Nothing ran twice, every tool call has a result, and billing survives the crash.",
          "The one price is that a `ReplayNever` call interrupted mid-flight gets the interrupted result and not the real one. The test suite asserts that divergence instead of hiding it.",
        ],
        state: [
          #("Entries", "the result row is now written, under the reserved id"),
          #("`op.state`", "the next state of the operation"),
        ],
        sample: None,
        failure: Some(
          "A crash during recovery is another crash: the same register is read again.",
        ),
      ),
    ],
  )
}

/// The boxes, the links and the seven frames.
pub fn diagram() -> Diagram {
  Diagram(
    sizes: Sizes(wide_w: 480, wide_h: 308, narrow_w: 320, narrow_h: 512),
    nodes: [
      zone(
        "tree",
        "One session, as processes",
        Group,
        r(0, 0, 232, 308),
        r(0, 0, 320, 300),
      ),
      node(
        "sup",
        "SessionSupervisor",
        "",
        Process,
        r(8, 24, 216, 50),
        r(8, 24, 304, 50),
      ),
      node(
        "writer",
        "StorageWriter",
        "",
        Process,
        r(20, 78, 204, 50),
        r(24, 78, 288, 50),
      ),
      node(
        "factory",
        "strand factory",
        "",
        Process,
        r(20, 132, 204, 50),
        r(24, 132, 288, 50),
      ),
      node(
        "strand",
        "strand: main",
        "",
        Process,
        r(32, 186, 192, 50),
        r(40, 186, 272, 50),
      ),
      node(
        "effect",
        "effect: bash",
        "",
        Jailed,
        r(32, 240, 192, 66),
        r(56, 240, 256, 54),
      ),
      node(
        "db",
        "session.db",
        "",
        Store,
        r(252, 0, 228, 200),
        r(0, 308, 320, 130),
      ),
      node(
        "p_intent",
        "Intent",
        "",
        Stage,
        r(252, 230, 74, 72),
        r(0, 446, 100, 66),
      ),
      node(
        "p_work",
        "Work",
        "",
        Stage,
        r(330, 230, 74, 72),
        r(110, 446, 100, 66),
      ),
      node(
        "p_settle",
        "Settle",
        "",
        Stage,
        r(408, 230, 72, 72),
        r(220, 446, 100, 66),
      ),
    ],
    links: [
      link("writes", "writer", "db"),
      link("reads", "strand", "db"),
      link("spawn", "strand", "effect"),
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

fn file_lines(tail: String) -> String {
  "entry: user prompt\nentry: assistant, call bash\n" <> tail
}

fn step_0() -> Frame {
  frame(
    [
      state("sup", "running", Quiet),
      state("writer", "sole writer of the file", Quiet),
      state("factory", "starts each strand", Quiet),
      state("strand", "decided to call bash", Quiet),
      state("effect", "not started", Quiet),
      state(
        "db",
        file_lines("op.state = run\nlease: held by this daemon"),
        Quiet,
      ),
      state("p_intent", "next", Quiet),
      state("p_work", "later", Quiet),
      state("p_settle", "later", Quiet),
    ],
    [],
  )
}

fn step_1() -> Frame {
  frame(
    [
      state("sup", "running", Quiet),
      state("writer", "commits the intent", Live),
      state("factory", "starts each strand", Quiet),
      state("strand", "waits for the commit", Live),
      state("effect", "about to start", Quiet),
      state(
        "db",
        file_lines("reserved: result R, usage U\nop.state = effect_pending"),
        Live,
      ),
      state("p_intent", "written", Live),
      state("p_work", "next", Quiet),
      state("p_settle", "later", Quiet),
    ],
    [send("writes", "writer", "commit the intent")],
  )
}

fn step_2() -> Frame {
  frame(
    [
      state("sup", "running", Quiet),
      state("writer", "idle", Quiet),
      state("factory", "starts each strand", Quiet),
      state("strand", "waits on the effect", Quiet),
      state("effect", "running in the sandbox", Live),
      state(
        "db",
        file_lines("reserved: result R, usage U\nop.state = effect_pending"),
        Quiet,
      ),
      state("p_intent", "written", Done),
      state("p_work", "running", Live),
      state("p_settle", "later", Quiet),
    ],
    [send("spawn", "strand", "run bash")],
  )
}

fn step_3() -> Frame {
  frame(
    [
      state("sup", "killed", Fault),
      state("writer", "gone", Fault),
      state("factory", "gone", Fault),
      state("strand", "gone", Fault),
      state("effect", "killed; outcome unknown", Fault),
      state(
        "db",
        file_lines("op.state = effect_pending\nlease: stays until it expires"),
        Quiet,
      ),
      state("p_intent", "written", Done),
      state("p_work", "killed here", Fault),
      state("p_settle", "not reached", Quiet),
    ],
    [],
  )
}

fn step_4() -> Frame {
  frame(
    [
      state("sup", "booted again", Done),
      state("writer", "takes lease, fence + 1", Live),
      state("factory", "boots the strands", Live),
      state("strand", "reads op.state", Live),
      state("effect", "none running", Quiet),
      state(
        "db",
        file_lines("op.state = effect_pending\nlease: the new writer's"),
        Live,
      ),
      state("p_intent", "written", Done),
      state("p_work", "recovery", Live),
      state("p_settle", "next", Quiet),
    ],
    [send("reads", "db", "op.state")],
  )
}

fn step_5() -> Frame {
  frame(
    [
      state("sup", "running", Quiet),
      state("writer", "idle", Quiet),
      state("factory", "running", Quiet),
      state("strand", "applies replay policy", Live),
      state("effect", "replay policy decides", Live),
      state(
        "db",
        file_lines("op.state = effect_pending\nreserved: result R, usage U"),
        Quiet,
      ),
      state("p_intent", "written", Done),
      state("p_work", "policy", Live),
      state("p_settle", "next", Quiet),
    ],
    [send("spawn", "strand", "run again, or not")],
  )
}

fn step_6() -> Frame {
  frame(
    [
      state("sup", "running", Quiet),
      state("writer", "commits the settle", Live),
      state("factory", "running", Quiet),
      state("strand", "settled; leaf moved", Done),
      state("effect", "settled", Done),
      state(
        "db",
        "entry: tool result (R)\nusage row U\nop.state = the next state",
        Live,
      ),
      state("p_intent", "written", Done),
      state("p_work", "done", Done),
      state("p_settle", "written", Live),
    ],
    [send("writes", "writer", "commit the settle")],
  )
}
