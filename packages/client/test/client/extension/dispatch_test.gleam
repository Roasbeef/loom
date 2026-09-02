//// The dispatch path's three decidable halves, without a satellite.
////
//// A tool call spends a jailed node, so almost nothing about one is a
//// value a test can hold still. Three things are:
////
//// - the **policy translation** (`client/extension/policy`), which is a
////   pure function from the manifest's `[net]` table to the
////   `egress.Policy` every request is judged under and the ceilings the
////   execution runs under;
//// - the **router arms** (`client/extension/seam`), which are msgpack in
////   and msgpack out over an injected `perform` function, so a fake one
////   exercises the whole of `net.request` with no socket anywhere;
//// - the **settle** (`client/extension/dispatch.settle`), which is a pure
////   function from a `satellite.Run` to a tool reply.
////
//// What is deliberately *not* asserted here is the round trip against
//// `cap/ext`'s and `cap/net`'s own decoders. Those live inside the jailed
//// prelude, their decoders are private, and `packages/client` does not
//// depend on `packages/cap` — so the honest proof that the two halves of
//// the wire agree is `extension_e2e_test`, which boots a real satellite
//// running real `cap/ext` and `cap/net` against these very arms. What is
//// asserted here is the shape those decoders are documented to read, one
//// field at a time, so a change to it fails in a place that names the
//// field rather than in a jail.

import broker/broker
import broker/budget
import broker/egress
import broker/exec
import broker/framing
import broker/policy
import client/extension/dispatch
import client/extension/manifest
import client/extension/policy as ext_policy
import client/extension/record
import client/extension/seam
import codemode/enforcement
import codemode/identity
import codemode/satellite
import core/clock
import core/ids
import core/message
import core/msgpack
import gleam/erlang/process
import gleam/list
import gleam/string
import tools/tool

// --- the policy translation -----------------------------------------------

pub fn a_net_table_translates_field_by_field_test() {
  let assert ext_policy.Reaches(policy: translated) =
    ext_policy.egress_for(brave_net(), trust: egress.SystemRoots)
    as "a manifest with hosts reaches something"

  // The manifest's four, verbatim.
  assert translated.hosts == ["api.search.brave.com"]
  assert translated.methods == [egress.Get]
  assert translated.max_response_bytes == 1_048_576
  assert translated.secrets
    == [
      egress.Secret(
        env: "BRAVE_API_KEY",
        host: "api.search.brave.com",
        header: "X-Subscription-Token",
      ),
    ]

  // And the three this module fixes, which no manifest key can reach.
  assert translated.redirects
    == egress.SameHost(at_most: ext_policy.redirect_hops)
  assert translated.timeout_ms == ext_policy.request_timeout_ms
  assert translated.trust == egress.SystemRoots
}

pub fn every_method_the_manifest_can_name_translates_test() {
  // A method that did not translate would be dropped, which narrows —
  // safe, but it would also mean an extension whose manifest an operator
  // approved could not make the request they approved.
  let assert ext_policy.Reaches(policy: translated) =
    ext_policy.egress_for(
      manifest.Net(
        ..brave_net(),
        methods: ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"],
      ),
      trust: egress.SystemRoots,
    )
    as "a manifest with hosts reaches something"
  assert translated.methods
    == [
      egress.Get,
      egress.Post,
      egress.Put,
      egress.Delete,
      egress.Patch,
      egress.Head,
    ]
}

pub fn a_manifest_with_no_net_reaches_nothing_test() {
  // Not a `Policy` with an empty allowlist: the refusal an author reads
  // has to say "this extension asked for no network" rather than "this
  // host is not on a list nobody wrote".
  assert ext_policy.egress_for(manifest.no_net(), trust: egress.SystemRoots)
    == ext_policy.ReachesNothing
  assert ext_policy.network_off("hello").code == ext_policy.network_off_code
  assert string.contains(ext_policy.network_off("hello").message, "hello")
}

pub fn a_test_trust_pins_only_what_it_was_given_test() {
  // The one knob production never turns. It is a parameter so an e2e can
  // reach a loopback origin whose chain it generated, and nothing else
  // in the tree passes anything but `SystemRoots`.
  let pinned = egress.PinnedRoots(ders: [<<1, 2, 3>>])
  let assert ext_policy.Reaches(policy: translated) =
    ext_policy.egress_for(brave_net(), trust: pinned)
    as "a manifest with hosts reaches something"
  assert translated.trust == pinned
}

pub fn the_ceilings_are_the_manifests_request_count_and_one_call_test() {
  let ceilings = ext_policy.ceilings(brave_net())
  assert list.contains(ceilings, satellite.CapCeiling(
    cap: ext_policy.net_cap,
    admissions: 4,
    code: ext_policy.ceiling_code,
  ))
  assert list.contains(ceilings, satellite.CapCeiling(
    cap: ext_policy.call_cap,
    admissions: 1,
    code: ext_policy.call_ceiling_code,
  ))
}

pub fn an_extension_with_no_net_has_a_zero_request_ceiling_test() {
  // Unreachable — the router's own arm refuses `network_off` first — and
  // stated anyway, so reading the ceilings answers the question without
  // also having to read the router.
  let assert Ok(ceiling) =
    list.find(ext_policy.ceilings(manifest.no_net()), fn(each) {
      each.cap == ext_policy.net_cap
    })
    as "the net ceiling is always stated"
  assert ceiling.admissions == 0
}

pub fn a_policy_refusal_reaches_the_jail_as_a_denial_test() {
  // `cap/net.map_error` sorts on the code alone, so every refusal the
  // policy would never have permitted has to carry one of its four
  // denial codes or an extension reads "try again" about a request that
  // will never be permitted.
  let refused = [
    egress.SchemeNotHttps(url: "http://x"),
    egress.HostNotAllowed(host: "evil.example", allowed: ["a"]),
    egress.MethodNotAllowed(method: egress.Post),
    egress.HeaderReserved(header: "host"),
    egress.HeaderMalformed(header: "x"),
    egress.SecretMissing(env: "BRAVE_API_KEY"),
    egress.RedirectRefused(to: "https://y", why: "left the origin"),
    egress.MalformedUrl(url: "::"),
  ]
  list.each(refused, fn(refusal) {
    assert ext_policy.denial(refusal).code == ext_policy.denied_code
  })

  // And a request the policy permitted which then failed on the wire is
  // the other side of the split, so a retry is the right reading.
  list.each(
    [
      egress.ResponseTooLarge(cap: 10),
      egress.Timeout(after_ms: 10),
      egress.TransportFailed(reason: "closed"),
    ],
    fn(refusal) {
      assert ext_policy.denial(refusal).code == ext_policy.failed_code
    },
  )
}

pub fn a_secret_value_is_in_no_refusal_message_test() {
  // Structural rather than a convention: no `egress.Refusal` variant has
  // a field a value could occupy, so `describe` has nothing to redact.
  // Asserted on the one variant that names a binding at all.
  let message = ext_policy.denial(egress.SecretMissing(env: "BRAVE_API_KEY")).message
  assert string.contains(message, "BRAVE_API_KEY")
  assert !string.contains(message, "secret-value")
}

pub fn the_boot_summary_counts_bindings_and_names_no_value_test() {
  let line = ext_policy.summary(brave_net())
  assert string.contains(line, "api.search.brave.com")
  assert string.contains(line, "4 requests per call")
  assert string.contains(line, "1 secret bindings")
  assert !string.contains(line, "BRAVE_API_KEY")
  assert ext_policy.summary(manifest.no_net()) == "no network"
}

// --- the ext.call arm ------------------------------------------------------

pub fn ext_call_answers_the_shape_cap_ext_decodes_test() {
  // The four fields `cap/ext`'s module doc pins, at the msgpack types it
  // reads them at. `args` is text and not a msgpack value, which is the
  // one that would silently break: `gleam_json`'s parser is the only
  // route to a `Dynamic` the extension seam admits.
  let value =
    seam.call_value(seam.Call(
      tool: "web_search",
      args: "{\"query\":\"gleam\"}",
      strand: "main",
      deadline_ms: 19_000,
    ))
  assert field(value, "tool") == Ok(msgpack.StringValue("web_search"))
  assert field(value, "args") == Ok(msgpack.StringValue("{\"query\":\"gleam\"}"))
  assert field(value, "strand") == Ok(msgpack.StringValue("main"))
  assert field(value, "deadline_ms") == Ok(msgpack.IntValue(19_000))
}

pub fn ext_call_is_read_when_the_satellite_asks_test() {
  // The deadline is what is *left*, so the thunk has to be evaluated at
  // serve time. A value computed when the router was built would hand
  // every extension the whole timeout however long the launch took.
  let counted = seam.routing(
    seam.Extension(
      call: fn() {
        seam.Call(tool: "t", args: "{}", strand: "main", deadline_ms: 5)
      },
      egress: seam.ReachesNothing(refusal: ext_policy.network_off("x")),
    ),
    over: refusing_router,
  )
  let assert Ok(satellite.ServedHere(serve:)) =
    counted(a_request("ext.call", msgpack.MapValue([])))
    as "ext.call routes"
  let assert framing.CapOk(value:) = serve()
    as "ext.call is always answered"
  assert field(value, "deadline_ms") == Ok(msgpack.IntValue(5))
}

// --- the net.request arm ---------------------------------------------------

pub fn a_request_reaches_the_injected_egress_verbatim_test() {
  // Every field the extension sent, unchanged: a header this arm dropped
  // would be a request the extension believes it made and did not.
  let #(router, seen) = recording(fn(_ask) {
    Ok(seam.Answer(status: 200, headers: [#("x", "y")], body: <<"hi":utf8>>))
  })
  let assert Ok(satellite.ServedHere(serve:)) =
    router(a_request("net.request", ask_args("GET", "https://h/p", [
      #("Accept", "application/json"),
    ], <<"b":utf8>>)))
    as "net.request routes"
  let answer = serve()

  let assert Ok(ask) = seen()
    as "the injected egress was called"
  assert ask
    == seam.Ask(
      method: "GET",
      url: "https://h/p",
      headers: [#("Accept", "application/json")],
      body: <<"b":utf8>>,
    )

  // And the answer is the shape `cap/net.decode_response` reads.
  let assert framing.CapOk(value:) = answer as "a served request answers"
  assert field(value, "status") == Ok(msgpack.IntValue(200))
  assert field(value, "body") == Ok(msgpack.BinaryValue(<<"hi":utf8>>))
  assert field(value, "headers")
    == Ok(
      msgpack.MapValue([#(msgpack.StringValue("x"), msgpack.StringValue("y"))]),
    )
}

pub fn a_refusal_travels_back_under_its_own_code_test() {
  let #(router, _seen) = recording(fn(_ask) {
    Error(ext_policy.denial(egress.HostNotAllowed(
      host: "evil.example",
      allowed: ["api.search.brave.com"],
    )))
  })
  let assert Ok(satellite.ServedHere(serve:)) =
    router(a_request("net.request", ask_args("GET", "https://evil.example/", [], <<>>)))
    as "net.request routes"
  let assert framing.CapErr(code:, message:) = serve()
    as "a refused request answers with a denial"
  assert code == ext_policy.denied_code
  assert string.contains(message, "evil.example")
  assert string.contains(message, "api.search.brave.com")
}

pub fn an_extension_with_no_net_is_refused_before_anything_is_decoded_test() {
  // The arm answers without touching the arguments, so a malformed
  // request from an extension that reaches nothing still reads
  // `network_off` rather than `invalid_argument` — which is the sentence
  // that tells the author what to fix.
  let router =
    seam.routing(
      seam.Extension(
        call: fn() {
          seam.Call(tool: "t", args: "{}", strand: "main", deadline_ms: 1)
        },
        egress: seam.ReachesNothing(refusal: ext_policy.network_off("hello")),
      ),
      over: refusing_router,
    )
  let assert Ok(satellite.ServedHere(serve:)) =
    router(a_request("net.request", msgpack.NilValue))
    as "net.request routes even with no policy"
  let assert framing.CapErr(code:, message:) = serve()
    as "an extension with no [net] is refused"
  assert code == ext_policy.network_off_code
  assert string.contains(message, "hello")
}

pub fn a_malformed_request_is_refused_before_it_is_admitted_test() {
  // Refused by the *plan* rather than inside the served closure, so the
  // call consumes no ordinal and no admission against the ceiling — the
  // rule `satellite.CapRequest.ordinal` states.
  let #(router, seen) = recording(fn(_ask) {
    Ok(seam.Answer(status: 200, headers: [], body: <<>>))
  })
  let assert Error(denial) =
    router(a_request(
      "net.request",
      msgpack.MapValue([
        #(msgpack.StringValue("method"), msgpack.StringValue("GET")),
      ]),
    ))
    as "a request missing its url is refused"
  assert denial.code == seam.invalid_argument_code
  assert string.contains(denial.message, "url")
  assert seen() == Error(Nil)
}

pub fn a_header_map_that_is_not_text_is_refused_test() {
  let #(router, _seen) = recording(fn(_ask) {
    Ok(seam.Answer(status: 200, headers: [], body: <<>>))
  })
  let assert Error(denial) =
    router(a_request(
      "net.request",
      msgpack.MapValue([
        #(msgpack.StringValue("method"), msgpack.StringValue("GET")),
        #(msgpack.StringValue("url"), msgpack.StringValue("https://h/")),
        #(
          msgpack.StringValue("headers"),
          msgpack.MapValue([
            #(msgpack.StringValue("x"), msgpack.IntValue(1)),
          ]),
        ),
        #(msgpack.StringValue("body"), msgpack.BinaryValue(<<>>)),
      ]),
    ))
    as "a header value that is not text is refused"
  assert denial.code == seam.invalid_argument_code
}

pub fn every_serviced_cap_routes_and_nothing_else_does_test() {
  // Gleam patterns cannot name a constant, so `serviced_caps` and the
  // `case` arms are two lists that could drift. This is what keeps them
  // one.
  let #(router, _seen) = recording(fn(_ask) {
    Ok(seam.Answer(status: 200, headers: [], body: <<>>))
  })
  list.each(seam.serviced_caps, fn(cap) {
    let routed = router(a_request(cap, ask_args("GET", "https://h/", [], <<>>)))
    assert case routed {
      Ok(satellite.ServedHere(..)) -> True
      Ok(satellite.ClearedCall(..)) | Error(_) -> False
    }
  })

  // And a name neither arm answers reaches the router beneath.
  let assert Error(denial) =
    router(a_request("fs.read", msgpack.MapValue([])))
    as "an unanswered name falls through"
  assert denial.code == "beneath"
}

// --- the settle ------------------------------------------------------------

pub fn a_completed_outcome_is_the_extensions_content_blocks_test() {
  let outcome =
    dispatch.settle(
      a_ctx(),
      a_record(),
      a_tool(),
      satellite.Run(
        outcome: Ok(satellite.Completed(value: reply_value(
          [#("text", "the answer"), #("json", "{\"n\":1}")],
          False,
        ))),
        node: enforcement.Unreported("a fixture run"),
      ),
    )
  assert outcome.is_error == False
  assert outcome.terminate == tool.ContinueRun
  let assert [message.ToolResultText(text:, text_signature: _)] = outcome.content
    as "one text block carries the reply"
  assert string.contains(text, "the answer")
  assert string.contains(text, "{\"n\":1}")
}

pub fn a_terminating_outcome_ends_the_run_test() {
  // `ext.Outcome`'s `terminate` is the field `core/entry.terminate`
  // reads, and it is the only way an extension can end a run.
  let outcome =
    dispatch.settle(
      a_ctx(),
      a_record(),
      a_tool(),
      satellite.Run(
        outcome: Ok(satellite.Completed(value: reply_value(
          [#("text", "done")],
          True,
        ))),
        node: enforcement.Unreported("a fixture run"),
      ),
    )
  assert outcome.terminate == tool.TerminateRun
  assert outcome.is_error == False
}

pub fn an_errored_outcome_is_in_band_and_never_terminates_test() {
  // A refusal is something the model repairs on its next turn, so a tool
  // that ended the run by failing would take that turn away.
  let outcome =
    dispatch.settle(
      a_ctx(),
      a_record(),
      a_tool(),
      satellite.Run(
        outcome: Ok(satellite.Errored(
          message: "no such city",
          details: msgpack.MapValue([
            #(msgpack.StringValue("tool"), msgpack.StringValue("hello")),
          ]),
        )),
        node: enforcement.Unreported("a fixture run"),
      ),
    )
  assert outcome.is_error == True
  assert outcome.terminate == tool.ContinueRun
  let assert [message.ToolResultText(text:, text_signature: _)] = outcome.content
    as "one text block carries the refusal"
  assert string.contains(text, "no such city")
  assert string.contains(text, "hello")
}

pub fn a_run_that_produced_no_outcome_says_what_confined_the_node_test() {
  // A failure that says nothing about what confined the node invites the
  // reader to assume the strongest thing.
  let outcome =
    dispatch.settle(
      a_ctx(),
      a_record(),
      a_tool(),
      satellite.Run(
        outcome: Error(satellite.DeadlineExceeded),
        node: enforcement.Unreported("the node was reaped"),
      ),
    )
  assert outcome.is_error == True
  assert outcome.terminate == tool.ContinueRun
  let assert [message.ToolResultText(text:, text_signature: _)] = outcome.content
    as "one text block carries the failure"
  assert string.contains(text, "timeout")
  assert string.contains(text, "no enforcement report")
}

pub fn a_malformed_outcome_renders_rather_than_vanishing_test() {
  // The only way this happens is an artifact built against a different
  // `ext` than this server serves, and the operator needs to see what it
  // actually sent.
  let outcome =
    dispatch.settle(
      a_ctx(),
      a_record(),
      a_tool(),
      satellite.Run(
        outcome: Ok(satellite.Completed(value: msgpack.StringValue("bare"))),
        node: enforcement.Unreported("a fixture run"),
      ),
    )
  assert outcome.is_error == False
  let assert [message.ToolResultText(text:, text_signature: _)] = outcome.content
    as "one text block carries the value"
  assert string.contains(text, "bare")
}

// --- fixtures --------------------------------------------------------------

fn brave_net() -> manifest.Net {
  manifest.Net(
    hosts: ["api.search.brave.com"],
    methods: ["GET"],
    max_response_bytes: 1_048_576,
    requests_per_call: 4,
    secrets: [
      manifest.Secret(
        env: "BRAVE_API_KEY",
        host: "api.search.brave.com",
        header: "X-Subscription-Token",
      ),
    ],
  )
}

// A router whose one arm refuses everything with a code no other arm
// uses, so a test can tell "fell through" from "was answered here".
fn refusing_router(
  _request: satellite.CapRequest,
) -> Result(satellite.CapPlan, satellite.CapDenial) {
  Error(satellite.CapDenial(code: "beneath", message: "the router beneath"))
}

// An extension router over a fake egress, plus a way to read back the one
// `Ask` it was handed. A process-free recorder: the served closure runs
// on this process in these tests, so a mutable cell would be the only
// thing a subject bought.
fn recording(
  answer: fn(seam.Ask) -> Result(seam.Answer, satellite.CapDenial),
) -> #(satellite.CapRouter, fn() -> Result(seam.Ask, Nil)) {
  let seen = process.new_subject()
  let router =
    seam.routing(
      seam.Extension(
        call: fn() {
          seam.Call(tool: "t", args: "{}", strand: "main", deadline_ms: 1)
        },
        egress: seam.Reaches(perform: fn(ask) {
          process.send(seen, ask)
          answer(ask)
        }),
      ),
      over: refusing_router,
    )
  #(router, fn() { process.receive(seen, within: 0) })
}

fn a_request(cap: String, args: msgpack.MsgPackValue) -> satellite.CapRequest {
  let workspace = "/nonexistent/loom-extension-dispatch-test"
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 5))
  satellite.CapRequest(
    cap:,
    args:,
    identity: identity_for(op_id),
    base_policy: policy.workspace_default(workspace),
    demand: exec.BestEffort,
    env: [],
    cwd: workspace,
    ordinal: 0,
  )
}

fn ask_args(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> msgpack.MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("method"), msgpack.StringValue(method)),
    #(msgpack.StringValue("url"), msgpack.StringValue(url)),
    #(
      msgpack.StringValue("headers"),
      msgpack.MapValue(
        list.map(headers, fn(pair) {
          #(msgpack.StringValue(pair.0), msgpack.StringValue(pair.1))
        }),
      ),
    ),
    #(msgpack.StringValue("body"), msgpack.BinaryValue(body)),
  ])
}

// The `{content: [block…], terminate: Bool}` body `ext/runtime` sends.
fn reply_value(
  blocks: List(#(String, String)),
  terminate: Bool,
) -> msgpack.MsgPackValue {
  msgpack.MapValue([
    #(
      msgpack.StringValue("content"),
      msgpack.ArrayValue(
        list.map(blocks, fn(block) {
          msgpack.MapValue([
            #(msgpack.StringValue("type"), msgpack.StringValue(block.0)),
            #(msgpack.StringValue(block.0), msgpack.StringValue(block.1)),
          ])
        }),
      ),
    ),
    #(msgpack.StringValue("terminate"), msgpack.BoolValue(terminate)),
  ])
}

fn field(
  value: msgpack.MsgPackValue,
  key: String,
) -> Result(msgpack.MsgPackValue, Nil) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })

    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..) -> Error(Nil)
  }
}

// A run phase's identity, which is what a `CapRequest` carries. Nothing
// under test reads it; a router is handed one because the type says so.
fn identity_for(op_id: ids.OpId) -> identity.PhaseIdentity {
  identity.run_phase(identity.for_execution(
    op_id:,
    step_id: "step-1",
    budget: budget.Budget(max_outstanding: 4, deadline_ms: 1),
  ))
}

// The record and the manifest tool a settle reports about. Neither is
// read for anything but its name, version and hash.
fn a_record() -> record.Record {
  record.Record(
    format: record.format_version,
    name: "hello",
    version: "0.1.0",
    source: "./hello",
    revision: record.local_revision,
    tree_digest: "tree",
    manifest_hash: "artifact",
    allowlist: [],
    net: record.NetTerms(
      hosts: [],
      methods: [],
      max_response_bytes: 0,
      requests_per_call: 0,
      secret_env: [],
    ),
    tools: ["hello"],
    approved_at: "1970-01-01T00:00:00Z",
    approved_by: "nobody",
    artifact: "/nowhere/artifact",
  )
}

fn a_tool() -> manifest.Tool {
  manifest.Tool(
    name: "hello",
    description: "Echo an argument back.",
    prompt_snippet: "hello: echo an argument back",
    parameters: "schema/hello.json",
    entry: "hello/tool",
    timeout_ms: 20_000,
  )
}

// A context whose blob store is dead, so `blob.bound` falls back to the
// inline body and the settle's own rendering is what the assertions read.
fn a_ctx() -> tool.Ctx {
  let workspace = "/nonexistent/loom-extension-dispatch-test"
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 7))
  tool.Ctx(
    workspace:,
    strand: "main",
    op_id:,
    step_id: "step-1",
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.BestEffort,
    env: [],
    clock: clock.fixed(at: 0),
    filesystem: dead_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
  )
}

fn dead_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(path) { Error(tool.FsNotFound(path:)) },
    write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
    create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
    is_file: fn(_path) { Ok(False) },
    read_link: fn(_path) { Ok(tool.LinkMissing) },
    rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
  )
}
