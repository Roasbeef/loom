//// Figure: a crash in the middle of a tool call.
////
//// Sources: `docs/architecture/orchestration.md` ("The effect sandwich"),
//// `docs/architecture/durability.md`, `docs/architecture/sessions.md`
//// ("Reopening after an unclean exit") and `docs/loom-design.md` section 4.1.
////
//// The drawing has three parts: the supervision tree on the left, the
//// session file on the right, and a bar along the bottom for the two
//// commits and the window between them.

import gleam/option.{None, Some}
import lustre/attribute
import lustre/element.{type Element}
import site/figure.{type Spec, Spec, Step}
import site/msg.{type Msg}
import site/svgx.{cls, text}

/// The words of every step.
pub fn spec() -> Spec {
  Spec(id: msg.Crash, title: "A crash in the middle of a tool call", steps: [
    Step(
      label: "Running",
      tag: "",
      caption: "Processes on the left work against one SQLite file on the right.",
      heading: "A session is a supervision tree over one file",
      body: [
        "Opening a session starts a `SessionSupervisor`. Under it, the `StorageWriter` is the only process that writes the session's SQLite file, and the `StrandSupervisor` runs each strand, a named line of work such as the main conversation.",
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
        #("Replay policy", "`ReplaySafe` or `ReplayNever`, persisted with the intent"),
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
      state: [#("Window", "after the intent commit, before the settle commit")],
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
        "After a daemon restart every session stays closed until someone opens it. Opening boots the same tree, with the writer first. Once the old lease has expired the new writer takes it and bumps the fence, so the old owner cannot commit again.",
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
      failure: Some("A crash during recovery is another crash: the same register is read again."),
    ),
  ])
}

/// The drawing for a step.
pub fn drawing(step: Int) -> Element(Msg) {
  let tree_dead = step == 3
  let tree_new = step >= 4
  svgx.root(560, 420, "A supervision tree and a session file, before and after a crash", [
    svgx.defs(),
    // The supervision tree, drawn as an indented list.
    tree_node(0, 24, 220, "SessionSupervisor", tree_dead, tree_new),
    tree_node(18, 72, 202, "StorageWriter", tree_dead, tree_new),
    tree_node(18, 120, 202, "StrandSupervisor", tree_dead, tree_new),
    tree_node(36, 168, 184, "strand main", tree_dead, tree_new),
    effect_node(step),
    tree_lines(step >= 1 && step <= 3),
    // The session file.
    svgx.rect(290, 14, 260, 256, [cls("panel-box", [])]),
    text(306, 38, "session.db", [attribute.class("t t-strong")]),
    entry_row(54, "entry: user prompt", True, False),
    entry_row(88, "entry: assistant, call bash", True, False),
    result_row(step),
    register_row(step),
    lease_row(step),
    // The command.
    command_row(step),
    // The two commits and the window.
    sandwich(step),
  ])
}

fn tree_node(
  indent: Int,
  y: Int,
  width: Int,
  name: String,
  dead: Bool,
  fresh: Bool,
) -> Element(Msg) {
  svgx.group([cls("node", [#("is-dead", dead), #("is-fresh", fresh)])], [
    svgx.rect(14 + indent, y, width, 34, [attribute.class("node-box")]),
    text(26 + indent, y + 22, name, [attribute.class("t")]),
  ])
}

fn effect_node(step: Int) -> Element(Msg) {
  let shown = step >= 1 && step <= 3
  svgx.group(
    [
      cls("node effect", [
        #("is-hidden", !shown),
        #("is-dead", step == 3),
        #("is-live", step == 2),
      ]),
    ],
    [
      svgx.rect(68, 216, 152, 34, [attribute.class("node-box")]),
      text(80, 238, "effect: bash", [attribute.class("t")]),
    ],
  )
}

fn tree_lines(effect_shown: Bool) -> Element(Msg) {
  svgx.group([attribute.class("links")], [
    svgx.path("M 26 58 V 89 H 32", []),
    svgx.path("M 26 58 V 137 H 32", []),
    svgx.path("M 44 154 V 185 H 50", []),
    svgx.path("M 62 202 V 233 H 68", [cls("link-effect", [#("is-hidden", !effect_shown)])]),
  ])
}

fn entry_row(y: Int, label: String, solid: Bool, ghost: Bool) -> Element(Msg) {
  svgx.group([cls("row", [#("is-ghost", ghost), #("is-solid", solid)])], [
    svgx.rect(302, y, 236, 28, [attribute.class("row-box")]),
    text(314, y + 19, label, [attribute.class("t t-sm")]),
  ])
}

fn result_row(step: Int) -> Element(Msg) {
  let reserved = step >= 1 && step < 6
  let written = step >= 6
  svgx.group(
    [
      cls("row", [
        #("is-ghost", reserved),
        #("is-solid", written),
        #("is-hidden", step == 0),
      ]),
    ],
    [
      svgx.rect(302, 122, 236, 28, [attribute.class("row-box")]),
      text(314, 141, case written {
        True -> "entry: tool result  (id R)"
        False -> "reserved: tool result  (id R)"
      }, [attribute.class("t t-sm")]),
    ],
  )
}

fn register_row(step: Int) -> Element(Msg) {
  let value = case step {
    0 -> "run"
    6 -> "next state"
    _ -> "effect_pending"
  }
  svgx.group([cls("row register", [#("is-hot", step == 1 || step == 4 || step == 6)])], [
    svgx.rect(302, 168, 236, 28, [attribute.class("row-box")]),
    text(314, 187, "op.state = " <> value, [attribute.class("t t-sm t-mono")]),
  ])
}

fn lease_row(step: Int) -> Element(Msg) {
  let value = case step {
    3 -> "stale until expiry"
    4 | 5 | 6 -> "new owner, fence + 1"
    _ -> "held by the daemon"
  }
  svgx.group([cls("row", [#("is-warn", step == 3), #("is-hot", step == 4)])], [
    svgx.rect(302, 206, 236, 28, [attribute.class("row-box")]),
    text(314, 225, "writer_lease: " <> value, [attribute.class("t t-sm")]),
  ])
}

fn command_row(step: Int) -> Element(Msg) {
  let value = case step {
    0 -> "no command yet"
    1 -> "about to start"
    2 -> "running in the sandbox"
    3 | 4 -> "outcome unknown"
    5 -> "run again, or marked unknown"
    _ -> "settled"
  }
  svgx.group(
    [cls("row command", [#("is-live", step == 2), #("is-warn", step == 3 || step == 4)])],
    [
      svgx.rect(290, 284, 260, 34, [attribute.class("row-box")]),
      text(304, 306, "bash: " <> value, [attribute.class("t t-sm")]),
    ],
  )
}

fn sandwich(step: Int) -> Element(Msg) {
  svgx.group([attribute.class("sandwich")], [
    svgx.group([cls("seg", [#("is-hot", step == 1)])], [
      svgx.rect(14, 346, 130, 44, [attribute.class("seg-box")]),
      text(79, 366, "commit", [attribute.class("t t-sm mid")]),
      text(79, 382, "intent", [attribute.class("t t-sm mid")]),
    ]),
    svgx.group(
      [cls("seg window", [#("is-hot", step >= 2 && step <= 5), #("is-warn", step == 3)])],
      [
        svgx.rect(152, 346, 256, 44, [attribute.class("seg-box")]),
        text(280, 366, "do the work: not durable", [attribute.class("t t-sm mid")]),
        text(280, 382, window_note(step), [attribute.class("t t-sm mid t-dim")]),
      ],
    ),
    svgx.group([cls("seg", [#("is-hot", step == 6)])], [
      svgx.rect(416, 346, 130, 44, [attribute.class("seg-box")]),
      text(481, 366, "commit", [attribute.class("t t-sm mid")]),
      text(481, 382, "settle", [attribute.class("t t-sm mid")]),
    ]),
  ])
}

fn window_note(step: Int) -> String {
  case step {
    3 -> "killed here"
    4 -> "recovery reads op.state"
    5 -> "replay policy decides"
    _ -> "the uncertain window"
  }
}
