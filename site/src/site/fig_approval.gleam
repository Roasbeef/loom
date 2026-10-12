//// Figure: a command that needs more access than the session grants.
////
//// Sources: `docs/architecture/approvals.md` (the vocabulary, "From refusal
//// to grant", "One record per question", "Deciding"),
//// `docs/architecture/effects.md` ("The one door", "The jail") and
//// `docs/loom-design.md` section 1.3 (Rule Zero).
////
//// The path `/srv/data` and the command are illustrative. Every name that
//// is not a path is the repository's own.

import gleam/option.{None, Some}
import site/diagram.{
  type Diagram, type Frame, Diagram, Done, JailZone, Jailed, Live, Outside,
  Process, Quiet, Sizes, Store,
}
import site/dkit.{frame, link, node, r, send, state, zone}
import site/figure.{type Spec, Sample, Spec, Step}
import site/msg

/// The words of every step.
pub fn spec() -> Spec {
  Spec(
    id: msg.Approval,
    title: "A command that needs more access",
    diagram: diagram(),
    steps: [
      Step(
        label: "The call",
        tag: "",
        caption: "The model calls bash and says it needs to write under /srv/data.",
        heading: "A call declares the access it needs",
        body: [
          "The model sends a `bash` call with a `permissions` argument. Before the command can start, the call's intent and effective arguments are committed, so everything after this point can be recovered.",
          "The session policy lets the command write inside the workspace. The path below is outside it.",
        ],
        state: [
          #(
            "Session policy",
            "writes stay in the workspace and explicit writable mounts",
          ),
          #("Requested", "a writable root, `/srv/data`"),
        ],
        sample: Some(Sample(
          "The call, as an illustration",
          "{\"command\": \"make export\",\n \"permissions\": {\n   \"writable_roots\": [\"/srv/data\"]}}",
        )),
        failure: None,
      ),
      Step(
        label: "Compose the policy",
        tag: "",
        caption: "The request is checked against the session policy before anything starts.",
        heading: "The most restrictive policy wins",
        body: [
          "The policy is composed from the session's base policy, the tool's requirements and any grants the call carries. Composition takes the most restrictive value of each field, and a grant is the only thing that widens one.",
          "`/srv/data` is not writable under the base policy, so the shortfall becomes a `Narrowing`, and `wanted_grants` turns it into the grant that would fix it. No budget is spent and no process starts. A refusal from the broker itself, `PolicyRefused`, takes the same path from here.",
        ],
        state: [
          #("Wanted grant", "writable root `/srv/data`"),
          #("Protected paths", "no grant can remove one"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Store the question",
        tag: "",
        caption: "The refusal becomes a durable record, and the call waits on its own process.",
        heading: "The question is stored, and the call waits",
        body: [
          "A record under `escalation/<id>` in the `fact.custom` register holds the question with the status `Pending`. Its id is a digest of the strand, the tool and the wanted grants, so a model that retries lands on the record that already exists. The record also keeps a digest of the call's arguments, the action, and a bounded preview of them.",
          "If an operator is attached, the call waits on its own effect process, not on the strand driver, so you can still abort the run being asked about.",
        ],
        state: [
          #("Record status", "`Pending`"),
          #(
            "Waits for",
            "the smaller of five minutes and the call's own deadline",
          ),
        ],
        sample: None,
        failure: Some(
          "With nobody attached, or when the window closes, the call settles with the refusal it arrived with. The model reads the same text either way.",
        ),
      ),
      Step(
        label: "Ask the operator",
        tag: "",
        caption: "The operator sees the exact action and the exact grants.",
        heading: "You see the command, not a category",
        body: [
          "The terminal opens a dialog with the captured action, the requesting strand and the exact grants. No choice is selected when it opens, so a queued Enter key cannot approve a request that arrived a moment earlier. The choices are allow once, allow for the session, and deny.",
          "The web page draws the same question as a card and ignores clicks for 600 ms after it appears.",
        ],
        state: [
          #("Shown", "action, requesting strand, exact grants"),
          #("Preselected", "nothing"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Decide",
        tag: "",
        caption: "The answer is checked against the record and committed at one sequence number.",
        heading: "An approval is bound to the action it was shown",
        body: [
          "The gateway checks that the echoed action digest equals the record's, that every echoed grant appears in the wanted list, and that the record is still at the sequence number the dialog was drawn at. An operator may approve a subset of the wanted grants but not more.",
          "The write is a compare-and-set. If two operators answer, the first to commit wins and the other receives `stale_approval`. An observer's answer is refused before any command runs.",
        ],
        state: [
          #("Record status", "`Approved`"),
          #("Lifetime", "once"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Spend and clear again",
        tag: "",
        caption: "The approval is spent once, then the call is cleared again with the grant.",
        heading: "One approval authorizes one execution",
        body: [
          "The waiting call reads `Approved`, checks that the record still names this call and this action, and moves the record to `Consumed` with a compare-and-set. Only a won commit returns the grants.",
          "Then `clear_call` runs once more with the grant appended. It reserves one slot against the pooled cap and deadline, mints a 32-byte token bound to the operation, step, policy and deadline, borrows a helper from the pool and dispatches. If the widened policy still falls short, that refusal stands. There is no loop.",
        ],
        state: [
          #("Record status", "`Consumed`"),
          #(
            "Token",
            "32 random bytes, bound to the operation, step, policy and deadline",
          ),
        ],
        sample: None,
        failure: Some(
          "A crash between the consume and the dispatch spends the approval without a run. That is the safe direction.",
        ),
      ),
      Step(
        label: "Enter the jail",
        tag: "",
        caption: "The helper restricts itself, then executes the command already inside the cage.",
        heading: "The command never runs in the harness VM",
        body: [
          "This is Rule Zero: model-influenced execution never runs in the harness VM. The helper, `loom-exec`, is a separate OS process. On Linux, `bwrap` builds the namespaces and the mount view with protected paths masked, and the execution gets its own cgroup with `memory.max` and `pids.max`.",
          "The helper then sets Landlock, `no_new_privs` and, when the network is off, a seccomp filter that stops the process from creating network sockets, and only then calls `execve`. On macOS the same stage runs under a generated Seatbelt profile, with enforcement gaps that are reported.",
        ],
        state: [
          #("Process", "`loom-exec`, one execution at a time"),
          #("Reported", "which layers actually enforced, on fd 4"),
        ],
        sample: None,
        failure: None,
      ),
      Step(
        label: "Settle",
        tag: "",
        caption: "Output returns, the token is revoked, and the result is committed.",
        heading: "One call, one settlement",
        body: [
          "The relay forwards output and enforces the wall deadline. Whatever happens downstream, the caller receives exactly one settlement, and settling revokes the token, so it is never valid twice. The result is then committed, which is the second half of the effect sandwich.",
          "The approval covered one execution. The next call that wants the same access asks again, unless you chose to allow it for the session.",
        ],
        state: [
          #("Token", "revoked"),
          #("Record status", "`Consumed`"),
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
    sizes: Sizes(wide_w: 480, wide_h: 320, narrow_w: 320, narrow_h: 560),
    nodes: [
      node("model", "Model", "", Outside, r(0, 0, 120, 84), r(0, 0, 154, 72)),
      node(
        "broker",
        "Broker",
        "",
        Process,
        r(136, 0, 192, 84),
        r(166, 0, 154, 72),
      ),
      node(
        "operator",
        "Operator",
        "",
        Outside,
        r(344, 0, 136, 84),
        r(0, 80, 320, 58),
      ),
      node(
        "record",
        "escalation record",
        "",
        Store,
        r(240, 104, 240, 86),
        r(0, 146, 320, 90),
      ),
      zone(
        "jail",
        "Kernel jail, outside the VM",
        JailZone,
        r(0, 214, 480, 106),
        r(0, 246, 320, 200),
      ),
      node(
        "helper",
        "loom-exec",
        "",
        Jailed,
        r(10, 240, 222, 72),
        r(8, 272, 304, 80),
      ),
      node(
        "command",
        "the command",
        "",
        Jailed,
        r(248, 240, 222, 72),
        r(8, 360, 304, 80),
      ),
    ],
    links: [
      link("call", "model", "broker"),
      link("store", "broker", "record"),
      link("ask", "record", "operator"),
      link("dispatch", "broker", "helper"),
      link("exec", "helper", "command"),
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
      state("model", "bash call with permissions", Live),
      state("broker", "has the call", Quiet),
      state("operator", "not asked yet", Quiet),
      state("record", "no record", Quiet),
      state("helper", "not started", Quiet),
      state("command", "make export: not started", Quiet),
    ],
    [send("call", "model", "bash + permissions")],
  )
}

fn step_1() -> Frame {
  frame(
    [
      state("model", "waits for the result", Quiet),
      state("broker", "refused: /srv/data is not writable", Live),
      state("operator", "not asked yet", Quiet),
      state("record", "no record", Quiet),
      state("helper", "not started", Quiet),
      state("command", "make export: not started", Quiet),
    ],
    [],
  )
}

fn step_2() -> Frame {
  frame(
    [
      state("model", "waits for the result", Quiet),
      state("broker", "waits on its own effect process", Live),
      state("operator", "not asked yet", Quiet),
      state("record", "status: Pending\nwants: writable root /srv/data", Live),
      state("helper", "not started", Quiet),
      state("command", "make export: not started", Quiet),
    ],
    [send("store", "broker", "write the record")],
  )
}

fn step_3() -> Frame {
  frame(
    [
      state("model", "waits for the result", Quiet),
      state("broker", "waits", Quiet),
      state("operator", "sees the action and grants", Live),
      state("record", "status: Pending\nwants: writable root /srv/data", Quiet),
      state("helper", "not started", Quiet),
      state("command", "make export: not started", Quiet),
    ],
    [send("ask", "record", "the question")],
  )
}

fn step_4() -> Frame {
  frame(
    [
      state("model", "waits for the result", Quiet),
      state("broker", "waits", Quiet),
      state("operator", "chose: allow once", Done),
      state(
        "record",
        "status: Approved\naction digest checked, one commit",
        Live,
      ),
      state("helper", "not started", Quiet),
      state("command", "make export: not started", Quiet),
    ],
    [send("ask", "operator", "allow once")],
  )
}

fn step_5() -> Frame {
  frame(
    [
      state("model", "waits for the result", Quiet),
      state("broker", "clears the call again, mints a token", Live),
      state("operator", "answered", Quiet),
      state("record", "status: Consumed", Live),
      state("helper", "borrowed from the pool", Live),
      state("command", "make export: not started", Quiet),
    ],
    [send("dispatch", "broker", "run, with a 32-byte token")],
  )
}

fn step_6() -> Frame {
  frame(
    [
      state("model", "waits for the result", Quiet),
      state("broker", "relays output; deadline", Quiet),
      state("operator", "answered", Quiet),
      state("record", "status: Consumed", Quiet),
      state("helper", "bwrap, cgroup, Landlock\nseccomp, no_new_privs", Live),
      state("command", "make export: running", Live),
    ],
    [send("exec", "helper", "execve")],
  )
}

fn step_7() -> Frame {
  frame(
    [
      state("model", "receives the result", Done),
      state("broker", "token revoked, result committed", Done),
      state("operator", "answered", Quiet),
      state("record", "status: Consumed", Quiet),
      state("helper", "exited", Quiet),
      state("command", "make export: exited", Done),
    ],
    [send("dispatch", "helper", "one settlement")],
  )
}
