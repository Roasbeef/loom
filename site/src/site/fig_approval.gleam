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
import lustre/attribute
import lustre/element.{type Element}
import site/figure.{type Spec, Sample, Spec, Step}
import site/msg.{type Msg}
import site/svgx.{cls, text}

/// The words of every step.
pub fn spec() -> Spec {
  Spec(id: msg.Approval, title: "A command that needs more access", steps: [
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
        #("Session policy", "writes stay in the workspace and explicit writable mounts"),
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
        #("Waits for", "the smaller of five minutes and the call's own deadline"),
      ],
      sample: None,
      failure: Some("With nobody attached, or when the window closes, the call settles with the refusal it arrived with. The model reads the same text either way."),
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
        #("Token", "32 random bytes, bound to the operation, step, policy and deadline"),
      ],
      sample: None,
      failure: Some("A crash between the consume and the dispatch spends the approval without a run. That is the safe direction."),
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
  ])
}

/// The drawing for a step.
pub fn drawing(step: Int) -> Element(Msg) {
  svgx.root(560, 430, "A tool call, a policy check, an operator's approval and a sandbox", [
    svgx.defs(),
    // Top row: model, policy check, operator.
    svgx.group([cls("node", [#("is-hot", step == 0)])], [
      svgx.rect(14, 18, 150, 62, [attribute.class("node-box")]),
      text(26, 42, "Model", [attribute.class("t t-strong")]),
      text(26, 62, "bash + permissions", [attribute.class("t t-sm")]),
    ]),
    svgx.group([cls("node", [#("is-hot", step == 1 || step == 5)])], [
      svgx.rect(200, 18, 166, 62, [attribute.class("node-box")]),
      text(212, 42, "Policy and broker", [attribute.class("t t-strong")]),
      text(212, 62, policy_note(step), [attribute.class("t t-sm")]),
    ]),
    svgx.group([cls("node", [#("is-hot", step == 3 || step == 4)])], [
      svgx.rect(392, 18, 154, 62, [attribute.class("node-box")]),
      text(404, 42, "Operator", [attribute.class("t t-strong")]),
      text(404, 62, operator_note(step), [attribute.class("t t-sm")]),
    ]),
    svgx.line(164, 49, 198, 49, [cls("wire", [#("is-on", step == 0 || step == 1)])]),
    // The escalation record.
    svgx.group([cls("row record", [#("is-hidden", step < 2), #("is-hot", step == 2 || step == 4 || step == 5)])], [
      svgx.rect(232, 106, 314, 74, [attribute.class("row-box")]),
      text(246, 128, "escalation/policy-…", [attribute.class("t t-sm t-mono")]),
      text(246, 148, "status: " <> record_status(step), [attribute.class("t t-sm")]),
      text(246, 168, "wants: writable root /srv/data", [attribute.class("t t-sm")]),
    ]),
    svgx.line(283, 80, 283, 104, [cls("wire", [#("is-on", step == 2)])]),
    svgx.line(469, 80, 469, 104, [cls("wire", [#("is-on", step == 3 || step == 4)])]),
    // The token and the dispatch arrow.
    svgx.line(215, 80, 215, 222, [cls("wire", [#("is-on", step == 5 || step == 6)])]),
    svgx.group(
      [
        cls("token", [#("is-hidden", step < 5), #("is-spent", step == 7)]),
        svgx.at(0, case step {
          5 -> 16
          _ -> 80
        }),
      ],
      [
        svgx.rect(100, 100, 108, 24, [attribute.class("token-box")]),
        text(110, 117, case step {
          7 -> "token: revoked"
          _ -> "32-byte token"
        }, [attribute.class("t t-sm")]),
      ],
    ),
    // The jail, drawn as layers around the command.
    ring(0, step >= 5, step == 5, "loom-exec: its own OS process"),
    ring(1, step >= 6, step == 6, "bwrap: namespaces and mount view"),
    ring(2, step >= 6, step == 6, "cgroup v2: memory and pid limits"),
    ring(3, step >= 6, step == 6, "Landlock, no_new_privs, seccomp"),
    svgx.group([cls("target", [#("is-hidden", step < 6), #("is-live", step == 6), #("is-done", step == 7)])], [
      svgx.rect(196, 330, 168, 38, [attribute.class("node-box")]),
      text(280, 354, case step {
        7 -> "exited; one settlement"
        _ -> "make export"
      }, [attribute.class("t mid")]),
    ]),
  ])
}

fn policy_note(step: Int) -> String {
  case step {
    0 -> "waiting for the call"
    1 -> "base + needs + grants"
    5 -> "clear_call, again"
    _ -> "refused: /srv/data"
  }
}

fn operator_note(step: Int) -> String {
  case step {
    3 -> "allow once / session / deny"
    4 -> "chose: allow once"
    _ -> "terminal or web"
  }
}

fn record_status(step: Int) -> String {
  case step {
    2 | 3 -> "Pending"
    4 -> "Approved"
    _ -> "Consumed"
  }
}

fn ring(index: Int, shown: Bool, lit: Bool, label: String) -> Element(Msg) {
  let x = 14 + 16 * index
  let y = 214 + 22 * index
  let width = 532 - 32 * index
  let height = 200 - 30 * index
  svgx.group(
    [
      cls("ring", [#("is-dim", !shown), #("is-lit", lit)]),
      svgx.delay(index * 220),
    ],
    [
      svgx.rect(x, y, width, height, [attribute.class("ring-box")]),
      text(x + 12, y + 17, label, [attribute.class("t t-sm")]),
    ],
  )
}
