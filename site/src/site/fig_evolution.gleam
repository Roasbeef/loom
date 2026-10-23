//// Figure: an agent's candidate extension, from proposal to rollback.
////
//// Sources: `docs/architecture/evolution.md` ("Agent and operator workflow",
//// "Catalogue, commit and recovery", "Worker custody") and
//// `packages/tools/src/tools/evolution.gleam` (the five model doors and what
//// `evolution_propose` refuses). The figure follows an extension on a local
//// workspace, which is the only placement wired on `main`. The generation
//// numbers are illustrative.
////
//// The daemon box stands for the native evolution owner: it takes the
//// snapshot, drives compilation and tests, serializes the replacement and
//// owns the generation fence. The catalogue is `<state>/evolution/evolution.db`.

import gleam/option.{None, Some}
import site/diagram.{
  type Diagram, type Frame, Diagram, Done, JailZone, Jailed, Live, Outside,
  Process, Quiet, Sizes, Store,
}
import site/dkit.{frame, link, node, r, send, state, zone}
import site/figure.{type Spec, Spec, Step}
import site/msg

/// The words of every step.
pub fn spec() -> Spec {
  Spec(
    id: msg.Evolution,
    title: "A candidate extension, from proposal to rollback",
    diagram: diagram(),
    steps: [
      Step(
        label: "Propose",
        tag: "",
        caption: "The model names a directory, and the daemon snapshots it under a jail.",
        heading: "The daemon takes its own copy of the source",
        body: [
          "The model calls `evolution_propose` with a directory it can already read, a name and a kind. A bounded `tar` of that directory runs under the caller's own kernel jail, and the daemon decodes and hashes the bytes itself.",
          "The candidate ID covers the source, the test entry, the schemas, the kind, the publication scope, the session and strand that proposed it, and the build, seam and evaluator identities. A path or a digest from the model grants nothing, and a proposal creates no approval.",
        ],
        state: [
          #("Candidate", "stored, with no approval and no evidence"),
          #("Authority used", "the caller's own jail and read access"),
        ],
        sample: None,
        failure: Some(
          "A request that needs a new trusted capability is refused with `CoreChangeRequired`. That change goes through a pull request and a release.",
        ),
      ),
      Step(
        label: "Test",
        tag: "",
        caption: "The candidate is compiled offline and its author tests run in a jail.",
        heading: "Evidence is a separate record",
        body: [
          "`evolution_test` compiles the candidate offline and runs the tests that its author wrote. The result is stored as a content-addressed evidence record, apart from the candidate.",
          "A passing test shows that the author's own checks pass. It does not show model quality, and it does not replace Loom's isolation and lifecycle tests.",
        ],
        state: [
          #("Evidence", "stored, named by its own hash"),
          #("Where it ran", "a jailed worker, outside the harness VM"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Review",
        tag: "",
        caption: "The operator reads the exact source and the evidence.",
        heading: "The operator reads what will run",
        body: [
          "`loom evolution inspect` and `loom evolution evidence` print the retained source and the evidence. The authority comes from the authenticated connection to the daemon, not from anything in the request.",
          "The model has no approve or select tool. Its six tools are propose, test, inspect, catalogue, invoke and trace.",
        ],
        state: [
          #("Read by", "the operator, over the daemon's owner credential"),
          #("Observers", "can read, cannot change"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Approve and select",
        tag: "",
        caption: "The operator approves one candidate and one evidence record, then selects it.",
        heading: "Approval and selection name exact IDs",
        body: [
          "`approve` takes a candidate ID and an evidence ID. `select` takes them again, with the generation it expects to replace, a reason and a request ID.",
          "The daemon answers with a queued receipt at once and does the work in the background. The operator polls `status` with the same request ID.",
        ],
        state: [
          #("Approval", "recorded for this candidate and this evidence"),
          #("Receipt", "queued, keyed by the request ID"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Stage and publish",
        tag: "",
        caption: "The successor is compiled, the old generation retired, and the selection committed.",
        heading: "Selection commits only after the old generation is gone",
        body: [
          "The daemon checks the candidate and approval again, compiles the successor in a jail, retires the previous generation and confirms that its processes are gone. Then it commits the selection in one compare-and-swap against the whole preceding selection.",
          "The compare-and-swap is the commit point. The session's adoption record is a second transaction that recovery completes if the daemon stops between the two. Only then is the successor published.",
        ],
        state: [
          #("Selection", "generation 1, committed"),
          #("Generation fence", "a stale expected generation is refused"),
        ],
        sample: None,
        failure: Some(
          "If the previous generation cannot be confirmed gone, nothing is published and the daemon keeps the cleanup task until it is.",
        ),
      ),
      Step(
        label: "Serve",
        tag: "",
        caption: "The session calls the new version without restarting.",
        heading: "The call carries the exact version it was written for",
        body: [
          "`evolution_catalogue` returns the callable name, description, schema, candidate ID and generation. `evolution_invoke` requires that exact pair and runs the call under the caller's current policy.",
          "The session, its history and its other tools were never restarted.",
        ],
        state: [
          #("Callable", "the selected generation only"),
          #("Session", "the same process tree, the same history"),
        ],
        sample: None,
        failure: Some(
          "A call that carries an old generation is refused, so old arguments are never read under a new schema.",
        ),
      ),
      Step(
        label: "Roll back",
        tag: "",
        caption: "An earlier approved version is selected under a new generation.",
        heading: "A rollback is a new selection of older source",
        body: [
          "`rollback` names an earlier approved version, the current generation and a new request ID. The daemon retires the current version the same way it retires any replaced one, and selects the earlier source as generation 2.",
          "A rollback restores source. It does not reverse effects: files written and network calls made by earlier invocations stay as they are.",
        ],
        state: [
          #("Selection", "generation 2, the earlier source"),
          #("Effects of earlier calls", "not reversed"),
        ],
        sample: None,
        failure: None,
      ),
    ],
  )
}

/// The five boxes, the four links and the seven frames.
pub fn diagram() -> Diagram {
  Diagram(
    sizes: Sizes(wide_w: 480, wide_h: 340, narrow_w: 320, narrow_h: 348),
    nodes: [
      node("model", "Model", "", Outside, r(0, 0, 220, 72), r(0, 0, 154, 84)),
      node(
        "operator",
        "Operator",
        "",
        Outside,
        r(260, 0, 220, 72),
        r(166, 0, 154, 84),
      ),
      node(
        "daemon",
        "Daemon",
        "",
        Process,
        r(130, 108, 220, 96),
        r(0, 100, 320, 92),
      ),
      node(
        "catalogue",
        "Catalogue",
        "",
        Store,
        r(0, 240, 220, 100),
        r(0, 216, 154, 132),
      ),
      zone(
        "jail",
        "Kernel jail",
        JailZone,
        r(260, 224, 220, 116),
        r(166, 208, 154, 140),
      ),
      node(
        "worker",
        "Jailed worker",
        "",
        Jailed,
        r(268, 248, 204, 84),
        r(170, 232, 146, 108),
      ),
    ],
    links: [
      link("ask", "model", "daemon"),
      link("operate", "operator", "daemon"),
      link("record", "daemon", "catalogue"),
      link("run", "daemon", "worker"),
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

fn step_0() -> Frame {
  frame(
    [
      state("model", "calls evolution_propose", Live),
      state("operator", "not involved yet", Quiet),
      state("daemon", "hashes the snapshot, computes the candidate ID", Live),
      state("catalogue", "candidate stored, no approval", Live),
      state("worker", "tar of the directory, in the caller's jail", Live),
    ],
    [send("ask", "model", "propose"), send("run", "daemon", "snapshot")],
  )
}

fn step_1() -> Frame {
  frame(
    [
      state("model", "calls evolution_test", Live),
      state("operator", "not involved yet", Quiet),
      state("daemon", "compiles offline, runs the author tests", Live),
      state("catalogue", "candidate and evidence", Live),
      state("worker", "compiles and tests", Live),
    ],
    [
      send("ask", "model", "test"),
      send("run", "daemon", "compile, test"),
      send("record", "daemon", "evidence"),
    ],
  )
}

fn step_2() -> Frame {
  frame(
    [
      state("model", "has no approve tool", Quiet),
      state("operator", "reads source and evidence", Live),
      state("daemon", "serves the read-only views", Quiet),
      state("catalogue", "candidate and evidence, unchanged", Quiet),
      state("worker", "idle", Quiet),
    ],
    [send("operate", "operator", "inspect, evidence")],
  )
}

fn step_3() -> Frame {
  frame(
    [
      state("model", "not involved", Quiet),
      state("operator", "approves, then selects, expecting generation 0", Live),
      state("daemon", "returns a queued receipt", Live),
      state("catalogue", "approval recorded", Live),
      state("worker", "idle", Quiet),
    ],
    [
      send("operate", "operator", "approve, select"),
      send("record", "daemon", "approval"),
    ],
  )
}

fn step_4() -> Frame {
  frame(
    [
      state("model", "not involved", Quiet),
      state("operator", "polls status by request ID", Quiet),
      state("daemon", "stages, retires the old generation, then commits", Live),
      state("catalogue", "generation 1 selected by compare-and-swap", Done),
      state("worker", "successor compiled and running", Live),
    ],
    [send("run", "daemon", "stage"), send("record", "daemon", "swap")],
  )
}

fn step_5() -> Frame {
  frame(
    [
      state("model", "invokes by candidate ID and generation", Live),
      state("operator", "not involved", Quiet),
      state(
        "daemon",
        "checks the token, runs the call under the caller's policy",
        Live,
      ),
      state("catalogue", "generation 1 selected", Quiet),
      state("worker", "runs the extension", Live),
    ],
    [send("ask", "model", "invoke"), send("run", "daemon", "call")],
  )
}

fn step_6() -> Frame {
  frame(
    [
      state("model", "keeps working in the same session", Done),
      state("operator", "rolls back, expecting generation 1", Live),
      state("daemon", "retires generation 1, selects the earlier source", Live),
      state("catalogue", "generation 2, the earlier source", Done),
      state("worker", "earlier version running", Live),
    ],
    [
      send("operate", "operator", "rollback"),
      send("run", "daemon", "retire, stage"),
    ],
  )
}
