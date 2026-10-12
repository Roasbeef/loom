//// Figure: moving a session between orchestrators with `sessions.move`.
////
//// Source: the section "Moving a session between orchestrators" of
//// `docs/architecture/distributed.md`, which is on the distributed-runtime
//// branches (issue #697, PR #923) and not yet on `main`. The six steps, the
//// row names (`resident`, `moving(op, to)`, `moved(to)`, `imported(op, from)`)
//// and the three rules are that document's.
////
//// Step 0 shows the state before the move and step 7 the first open on the
//// receiver, which is described in the document's "The executor fence". The
//// six numbered steps of the protocol are steps 1 to 6.

import gleam/option.{None, Some}
import lustre/attribute
import lustre/element.{type Element}
import site/figure.{type Spec, Sample, Spec, Step}
import site/msg.{type Msg}
import site/svgx.{cls, text}

/// The words of every step.
pub fn spec() -> Spec {
  Spec(id: msg.Migration, title: "Moving a session between orchestrators", steps: [
    Step(
      label: "Before",
      tag: "State before the move",
      caption: "Orchestrator A owns the session. The executor holds the checkout.",
      heading: "A session on an executor can change owner",
      body: [
        "Only a session whose checkout is on an executor can move. A local session cannot, because its checkout is a directory on the source. `sessions.move` hands the conversation file to another orchestrator. The checkout and the executor stay where they are.",
        "An owner starts a move from the terminal:",
      ],
      state: [
        #("Owner", "orchestrator A"),
        #("A's row", "`resident`"),
        #("Executor scope", "open, attached with A's token"),
      ],
      sample: Some(Sample("The command", "loom sessions move <id> --to <orchestrator>")),
      failure: None,
    ),
    Step(
      label: "Intend and stop",
      tag: "Protocol step 1 of 6",
      caption: "A records its intent and stops the session.",
      heading: "A write-ahead intent decides who owns the session",
      body: [
        "A's catalogue row goes from `resident` to `moving(op, to)` in the same registry turn that stops the session's slot. Admission refuses a `moving` or `moved` session, so no runtime on A can open the file afterwards.",
        "Each transition is a compare-and-set in one immediate transaction, keyed by the move's `op`. Two catalogue rows are the whole authority. No third store takes part, and the executor records no owner.",
      ],
      state: [
        #("Owner", "A, because its `moving` row is the one authority"),
        #("A's row", "`moving(op, to)`"),
      ],
      sample: None,
      failure: Some("The `moving` row survives a crash of A. The restarted daemon resumes the mover, which asks B how far the move got (`Absent`, `Received` or `Activated`) and takes the remaining steps. The shipped test halts A after each of the six steps."),
    ),
    Step(
      label: "Close",
      tag: "Protocol step 2 of 6",
      caption: "The executor scope is closed cleanly, and the outcome is written into the file.",
      heading: "Cleanup is proven before the file is copied",
      body: [
        "The session's cleanup closes its scope on the executor and writes the outcome into the file's scope cell: the incarnation, the last close outcome and the executor. If the orchestrator died before recording it, the mover asks the executor to close again, and the executor answers with the stored outcome.",
        "A cleanup that cannot be proven refuses the move.",
      ],
      state: [
        #("Owner", "A"),
        #("Executor scope", "closed, `all_retired`"),
      ],
      sample: None,
      failure: Some("If the executor does not answer, the mover stalls and retries. An unproven cleanup abandons the move and A's row returns to `resident`."),
    ),
    Step(
      label: "Cut",
      tag: "Protocol step 3 of 6",
      caption: "A copies the closed file and takes its digest.",
      heading: "A consistent copy of a closed file",
      body: [
        "The mover copies the file with `VACUUM INTO` while it holds the writer lease `move:<op>`, drops the lease row from the copy and hashes it. The runtime is stopped and the scope is closed, so nothing else writes to the file.",
      ],
      state: [
        #("Owner", "A"),
        #("Copy", "made under the lease `move:<op>`, with a digest"),
      ],
      sample: None,
      failure: Some("Every run of the mover starts from what is on disk, so a restart resumes from the step the source's row and the receiver's answer show."),
    ),
    Step(
      label: "Send",
      tag: "Protocol step 4 of 6",
      caption: "The copy crosses to B in acknowledged pieces.",
      heading: "The file travels in acknowledged pieces",
      body: [
        "A sends the copy to B in 256 KiB pieces, each acknowledged, up to 256 MiB. Any failure sends the whole file again.",
        "B holds a `.part` file until the copy is complete. A `.part` file is never taken for a copy, even after B restarts.",
      ],
      state: [
        #("Owner", "A. B holds only a partial file."),
        #("Piece size", "256 KiB, each acknowledged"),
      ],
      sample: None,
      failure: Some("If B is unreachable the mover stalls and retries every five seconds. It never abandons on silence, because B may have activated the session and lost the reply, and abandoning could leave two owners."),
    ),
    Step(
      label: "Activate",
      tag: "Protocol step 5 of 6",
      caption: "B validates the copy and records imported. From here B owns the session.",
      heading: "One compare-and-set transfers ownership",
      body: [
        "B checks that the sender's node matches an `[orchestrators.<name>]` entry, that the digest matches, that the copy's scope cell records a clean close at the claimed incarnation, and that B configures the executor the cell names.",
        "Then one registry turn registers the session, records `imported(op, from)` and renames the copy into place. The compare-and-set from `absent` to `imported` is the moment B becomes the owner.",
      ],
      state: [
        #("Owner", "B"),
        #("B's row", "`imported(op, from)`"),
        #("A's row", "still `moving(op, to)`"),
      ],
      sample: None,
      failure: Some("Once B has committed `imported`, every `Activate` for that operation is answered `Accepted`, whatever else is now true. A refusal after the commit would make A abandon and leave two owners."),
    ),
    Step(
      label: "Retire",
      tag: "Protocol step 6 of 6",
      caption: "A records moved(to) and sets its file aside.",
      heading: "The source gives up the file",
      body: [
        "After B reports `Activated`, A's row becomes `moved(to)`, its lease is released and its file is set aside as `<id>.db.moved`.",
        "The same `op` cannot undo `moved(to)`, so a late message from this move cannot bring the session back to A.",
      ],
      state: [
        #("Owner", "B"),
        #("A's row", "`moved(to)`"),
        #("A's file", "`<id>.db.moved`"),
      ],
      sample: None,
      failure: None,
    ),
    Step(
      label: "After",
      tag: "State after the move",
      caption: "When B opens the session, the executor fences A's old token.",
      heading: "The executor refuses the old owner by token",
      body: [
        "When B opens the session it attaches to the executor at the incarnation the copied cell implies, one above the clean close. The executor reopens the scope with B's token and refuses A's old token by value.",
        "A move carries no running processes. A background job dies with the scope's clean close, as it does on a stop. Memberships, claims and the memory domain stay on A, and a client reconnects to B and catches up from there.",
      ],
      state: [
        #("Owner", "B"),
        #("Executor scope", "reopened at incarnation n + 1, with B's token"),
      ],
      sample: None,
      failure: None,
    ),
  ])
}

/// The drawing for a step.
pub fn drawing(step: Int) -> Element(Msg) {
  let owner_is_b = step >= 5
  svgx.root(560, 440, "Two orchestrators and an executor while a session moves", [
    svgx.defs(),
    // The owner marker slides from A to B at the activation.
    svgx.group(
      [
        cls("owner", []),
        svgx.at(case owner_is_b {
          True -> 302
          False -> 0
        }, 0),
      ],
      [
        svgx.rect(14, 10, 230, 28, [attribute.class("owner-box")]),
        text(129, 29, case owner_is_b {
          True -> "owns the session: B"
          False -> "owns the session: A"
        }, [attribute.class("t t-sm t-strong mid")]),
      ],
    ),
    orchestrator(14, "Orchestrator A", "source", a_row(step), a_runtime(step), a_file(step), a_file_note(step), step <= 4, step >= 6),
    orchestrator(316, "Orchestrator B", "receiver", b_row(step), b_runtime(step), b_file(step), b_file_note(step), step >= 5, False),
    // The wire between them.
    svgx.line(244, 160, 316, 160, [cls("wire", [#("is-on", step == 4 || step == 5)])]),
    svgx.line(316, 196, 244, 196, [cls("wire", [#("is-on", step == 6)])]),
    svgx.group([cls("flow chunks", [#("is-on", step == 4)])], [
      svgx.square(246, 154, 14, 12, [attribute.class("chunk chunk-a")]),
      svgx.square(246, 154, 14, 12, [attribute.class("chunk chunk-b")]),
      svgx.square(246, 154, 14, 12, [attribute.class("chunk chunk-c")]),
      svgx.square(246, 154, 14, 12, [attribute.class("chunk chunk-d")]),
    ]),
    text(280, 128, wire_label_top(step), [cls("t t-sm mid wire-label", [#("is-on", step >= 4 && step <= 5)])]),
    text(280, 144, wire_label_middle(step), [cls("t t-sm t-dim mid wire-label", [#("is-on", step == 4)])]),
    text(280, 182, "each acked", [cls("t t-sm t-dim mid wire-label", [#("is-on", step == 4)])]),
    text(280, 214, "Activated", [cls("t t-sm mid wire-label", [#("is-on", step == 6)])]),
    // The executor.
    svgx.group([cls("node", [#("is-hot", step == 2 || step == 7)])], [
      svgx.rect(130, 318, 300, 108, [attribute.class("node-box")]),
      text(144, 344, "Executor", [attribute.class("t t-strong")]),
      text(144, 366, "the checkout stays here", [attribute.class("t t-sm")]),
      text(144, 388, scope_line(step), [attribute.class("t t-sm t-mono")]),
      text(144, 408, token_line(step), [attribute.class("t t-sm t-dim")]),
    ]),
    svgx.line(160, 264, 214, 318, [cls("wire", [#("is-on", step <= 1)])]),
    svgx.line(400, 264, 346, 318, [cls("wire", [#("is-on", step == 7)])]),
  ])
}

fn orchestrator(
  x: Int,
  name: String,
  role: String,
  row: String,
  runtime: String,
  file: String,
  note: String,
  hot: Bool,
  quiet: Bool,
) -> Element(Msg) {
  svgx.group([cls("node", [#("is-hot", hot), #("is-quiet", quiet)])], [
    svgx.rect(x, 50, 230, 214, [attribute.class("node-box")]),
    text(x + 14, 76, name, [attribute.class("t t-strong")]),
    text(x + 14, 94, role, [attribute.class("t t-sm t-dim")]),
    svgx.group([attribute.class("row")], [
      svgx.rect(x + 12, 108, 206, 30, [attribute.class("row-box")]),
      text(x + 22, 128, "row: " <> row, [attribute.class("t t-sm t-mono")]),
    ]),
    svgx.group([attribute.class("row")], [
      svgx.rect(x + 12, 146, 206, 30, [attribute.class("row-box")]),
      text(x + 22, 166, "session: " <> runtime, [attribute.class("t t-sm")]),
    ]),
    svgx.group([cls("row file", [#("is-ghost", file == "none" || file == ".part")])], [
      svgx.rect(x + 12, 184, 206, 66, [attribute.class("row-box")]),
      text(x + 22, 205, file, [attribute.class("t t-sm t-mono")]),
      text(x + 22, 226, note, [attribute.class("t t-sm t-dim")]),
    ]),
  ])
}

fn a_row(step: Int) -> String {
  case step {
    0 -> "resident"
    6 | 7 -> "moved(to)"
    _ -> "moving(op, to)"
  }
}

fn a_runtime(step: Int) -> String {
  case step {
    0 -> "running"
    _ -> "stopped"
  }
}

fn a_file(step: Int) -> String {
  case step {
    6 | 7 -> "<id>.db.moved"
    _ -> "<id>.db"
  }
}

fn a_file_note(step: Int) -> String {
  case step {
    0 -> "the conversation"
    1 -> "no runtime may open it"
    2 -> "scope cell: clean close"
    3 -> "copy + digest, lease move:op"
    4 | 5 -> "copy sent; original kept"
    _ -> "set aside"
  }
}

fn b_row(step: Int) -> String {
  case step {
    5 | 6 | 7 -> "imported(op, from)"
    _ -> "none"
  }
}

fn b_runtime(step: Int) -> String {
  case step {
    7 -> "open"
    _ -> "none"
  }
}

fn b_file(step: Int) -> String {
  case step {
    0 | 1 | 2 | 3 -> "none"
    4 -> ".part"
    _ -> "<id>.db"
  }
}

fn b_file_note(step: Int) -> String {
  case step {
    0 | 1 | 2 | 3 -> "nothing received"
    4 -> "partial: never a copy"
    5 -> "renamed into place"
    _ -> "the conversation"
  }
}

fn wire_label_top(step: Int) -> String {
  case step {
    5 -> "Activate"
    _ -> "256 KiB"
  }
}

fn wire_label_middle(_step: Int) -> String {
  "pieces"
}

fn scope_line(step: Int) -> String {
  case step {
    0 | 1 -> "scope: open, incarnation n"
    7 -> "scope: open, incarnation n+1"
    _ -> "scope: closed, all_retired"
  }
}

fn token_line(step: Int) -> String {
  case step {
    0 | 1 -> "attach token: A's"
    7 -> "attach token: B's; A's refused"
    _ -> "no live attach"
  }
}
