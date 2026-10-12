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
import site/diagram.{
  type Diagram, type Frame, Diagram, Done, Group, Live, Process, Quiet, Sizes,
  Store,
}
import site/dkit.{frame, link, node, r, scoped, send, state, with_chip, zone}
import site/figure.{type Spec, Sample, Spec, Step}
import site/msg

/// The words of every step.
pub fn spec() -> Spec {
  Spec(
    id: msg.Migration,
    title: "Moving a session between orchestrators",
    diagram: diagram(),
    steps: [
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
        sample: Some(Sample(
          "The command",
          "loom sessions move <id> --to <orchestrator>",
        )),
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
        failure: Some(
          "The `moving` row survives a crash of A. The restarted daemon resumes the mover, which asks B how far the move got (`Absent`, `Received` or `Activated`) and takes the remaining steps. The shipped test halts A after each of the six steps.",
        ),
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
        failure: Some(
          "If the executor does not answer, the mover stalls and retries. An unproven cleanup abandons the move and A's row returns to `resident`.",
        ),
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
        failure: Some(
          "Every run of the mover starts from what is on disk, so a restart resumes from the step the source's row and the receiver's answer show.",
        ),
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
        failure: Some(
          "If B is unreachable the mover stalls and retries every five seconds. It never abandons on silence, because B may have activated the session and lost the reply, and abandoning could leave two owners.",
        ),
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
        failure: Some(
          "Once B has committed `imported`, every `Activate` for that operation is answered `Accepted`, whatever else is now true. A refusal after the commit would make A abandon and leave two owners.",
        ),
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
    ],
  )
}

/// The boxes, the links and the eight frames.
pub fn diagram() -> Diagram {
  Diagram(
    sizes: Sizes(wide_w: 480, wide_h: 286, narrow_w: 320, narrow_h: 600),
    nodes: [
      zone(
        "zone_a",
        "Orchestrator A",
        Group,
        r(0, 0, 168, 286),
        r(0, 0, 320, 232),
      ),
      node(
        "a_file",
        "session file",
        "",
        Store,
        r(8, 26, 152, 80),
        r(8, 86, 304, 70),
      )
        |> scoped("A"),
      node(
        "a_row",
        "catalogue row",
        "",
        Store,
        r(8, 112, 152, 66),
        r(8, 26, 304, 56),
      )
        |> scoped("A"),
      node(
        "a_run",
        "session runtime",
        "",
        Process,
        r(8, 184, 152, 94),
        r(8, 160, 304, 64),
      )
        |> scoped("A"),
      zone(
        "zone_b",
        "Orchestrator B",
        Group,
        r(312, 0, 168, 286),
        r(0, 244, 320, 232),
      ),
      node(
        "b_file",
        "session file",
        "",
        Store,
        r(320, 26, 152, 80),
        r(8, 330, 304, 70),
      )
        |> scoped("B"),
      node(
        "b_row",
        "catalogue row",
        "",
        Store,
        r(320, 112, 152, 66),
        r(8, 270, 304, 56),
      )
        |> scoped("B"),
      node(
        "b_run",
        "session runtime",
        "",
        Process,
        r(320, 184, 152, 94),
        r(8, 404, 304, 64),
      )
        |> scoped("B"),
      node(
        "exec",
        "Executor",
        "",
        Process,
        r(182, 126, 116, 152),
        r(0, 488, 320, 112),
      ),
    ],
    links: [
      link("send", "a_file", "b_file"),
      link("close", "a_run", "exec"),
      link("attach", "b_run", "exec"),
    ],
    frames: [
      step_0(),
      step_1(),
      step_2(),
      step_3(),
      step_4(),
      step_5(),
      step_6(),
      step_7(),
    ],
  )
}

fn step_0() -> Frame {
  frame(
    [
      state("a_row", "resident", Done),
      state("a_file", "<id>.db\nthe conversation", Quiet),
      state("a_run", "serving the session", Done),
      state("b_row", "none", Quiet),
      state("b_file", "none", Quiet),
      state("b_run", "none", Quiet),
      state("exec", "scope open, incarnation n\nattached with A's token", Quiet),
    ],
    [],
  )
  |> with_chip("Owner", "orchestrator A")
}

fn step_1() -> Frame {
  frame(
    [
      state("a_row", "moving(op, to)", Live),
      state("a_file", "<id>.db\nrefuses new opens", Quiet),
      state("a_run", "slot stopped", Live),
      state("b_row", "none", Quiet),
      state("b_file", "none", Quiet),
      state("b_run", "none", Quiet),
      state("exec", "scope open, incarnation n", Quiet),
    ],
    [],
  )
  |> with_chip("Owner", "orchestrator A")
}

fn step_2() -> Frame {
  frame(
    [
      state("a_row", "moving(op, to)", Quiet),
      state("a_file", "scope cell: clean close", Live),
      state("a_run", "closes its scope", Live),
      state("b_row", "none", Quiet),
      state("b_file", "none", Quiet),
      state("b_run", "none", Quiet),
      state("exec", "scope closed, all_retired", Done),
    ],
    [send("close", "a_run", "close the scope")],
  )
  |> with_chip("Owner", "orchestrator A")
}

fn step_3() -> Frame {
  frame(
    [
      state("a_row", "moving(op, to)", Quiet),
      state("a_file", "copy cut, digest\nlease move:op", Live),
      state("a_run", "stopped", Quiet),
      state("b_row", "none", Quiet),
      state("b_file", "none", Quiet),
      state("b_run", "none", Quiet),
      state("exec", "scope closed, all_retired", Done),
    ],
    [],
  )
  |> with_chip("Owner", "orchestrator A")
}

fn step_4() -> Frame {
  frame(
    [
      state("a_row", "moving(op, to)", Quiet),
      state("a_file", "sending the copy\noriginal kept", Live),
      state("a_run", "stopped", Quiet),
      state("b_row", "none", Quiet),
      state("b_file", ".part\nnot yet a copy", Live),
      state("b_run", "none", Quiet),
      state("exec", "scope closed, all_retired", Done),
    ],
    [send("send", "a_file", "256 KiB pieces, each acknowledged")],
  )
  |> with_chip("Owner", "orchestrator A")
}

fn step_5() -> Frame {
  frame(
    [
      state("a_row", "moving(op, to)", Quiet),
      state("a_file", "original kept", Quiet),
      state("a_run", "waits for the answer", Quiet),
      state("b_row", "imported(op, from)", Live),
      state("b_file", "<id>.db\nin place", Live),
      state("b_run", "none", Quiet),
      state("exec", "scope closed, all_retired", Done),
    ],
    [
      send("send", "a_file", "Activate"),
      send("send", "b_file", "Accepted"),
    ],
  )
  |> with_chip("Owner", "orchestrator B")
}

fn step_6() -> Frame {
  frame(
    [
      state("a_row", "moved(to)", Done),
      state("a_file", "<id>.db.moved\nset aside", Quiet),
      state("a_run", "none", Quiet),
      state("b_row", "imported(op, from)", Quiet),
      state("b_file", "<id>.db\nthe conversation", Quiet),
      state("b_run", "none", Quiet),
      state("exec", "scope closed, all_retired", Done),
    ],
    [send("send", "b_file", "Activated")],
  )
  |> with_chip("Owner", "orchestrator B")
}

fn step_7() -> Frame {
  frame(
    [
      state("a_row", "moved(to)", Quiet),
      state("a_file", "<id>.db.moved", Quiet),
      state("a_run", "none", Quiet),
      state("b_row", "imported(op, from)", Quiet),
      state("b_file", "<id>.db", Quiet),
      state("b_run", "open", Live),
      state(
        "exec",
        "scope reopened at incarnation n + 1\nB's token; A's refused",
        Live,
      ),
    ],
    [send("attach", "b_run", "Attach at incarnation n + 1")],
  )
  |> with_chip("Owner", "orchestrator B")
}
