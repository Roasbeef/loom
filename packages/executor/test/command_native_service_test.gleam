//// Command admission uses real resource/native SQLite actors and the native service.
//// Protocol controls stop before launch; the launch witness runs the fixed real
//// compiler template. Neither retained Ready nor a constructed phase is a permit.

import broker/command as offer
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/executor as local
import broker/policy
import codemode/compile
import codemode/service_command
import codemode/service_input as input
import codemode/service_resources as resources
import core/command
import core/ids
import core/msgpack as mp
import core/remote_tool
import core/workspace
import envoy
import executor
import executor/remote/admission
import executor/remote/identity
import executor/remote/journal
import executor/remote/native
import executor/remote/payload
import executor/remote/resource_journal as j
import executor/remote/service
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/timestamp
import simplifile
import sqlight
import telemetry/log
import tools/fs
import weft/actor
import weft/poll

type Fixture {
  Fixture(
    path: String,
    enrolled: enrollment.SessionEnrollment,
    resources: j.Journal,
    journal: journal.Journal,
    native: local.Executor,
    service: service.Service,
    compile_deadline_ms: Int,
  )
}

pub fn original_claim_and_concrete_endpoint_are_checked_test() {
  fixture("identity", fn(f) {
    let a = original(f, 3, "first")
    let b = original(f, 5, "second")
    let claim = prepared(f, a)
    let _ = prepared(f, b)
    assert service.live_command_context(
        f.service,
        claim,
        ref(b),
        f.compile_deadline_ms,
      )
      == Error(service.Invalid)
    let assert Ok(_) =
      service.live_command_context(
        f.service,
        claim,
        ref(a),
        f.compile_deadline_ms,
      )
      as "The original Claim matches its complete service key."
    let assert Ok(capacity) = admission.capacity(16)
      as "Other endpoint capacity."
    let assert Ok(other) =
      journal.fresh(f.path <> "/other.sqlite", scope(), capacity)
      as "Same scope is insufficient to identify a native endpoint."
    let assert Ok(server) =
      service.start(
        service.Config(
          ..service.configuration(f.service),
          journal: other,
          native: native_executor(f.path, fn() { Nil }),
        ),
      )
      as "Separate same-scope native service."
    assert service.live_command_context(
        server,
        claim,
        ref(a),
        f.compile_deadline_ms,
      )
      == Error(service.Invalid)
    assert service.command_context(server, f.resources, ref(a))
      == Error(service.Invalid)
    let assert Ok(context) =
      service.live_command_context(
        f.service,
        claim,
        ref(a),
        f.compile_deadline_ms,
      )
      as "Correct native endpoint."
    assert exchange(
        server,
        context,
        ref(a),
        wire.ChallengeRequest(key(a, 8), digest(request(f, a))),
      )
      == Error(service.Invalid)
    assert journal.payloads(other, key(a, 8), digest(request(f, a))) == Ok([])
    assert service.shutdown(server) == Ok(Nil)
    assert journal.release(other) == Ok(Nil)
  })
}

pub fn historical_context_cannot_challenge_or_first_submit_test() {
  fixture("history", fn(f) {
    let a = original(f, 3, "first")
    let _ = prepared(f, a)
    let assert Ok(context) =
      service.command_context(f.service, f.resources, ref(a))
      as "Historical data only."
    let request = request(f, a)
    let hash = digest(request)
    assert exchange(
        f.service,
        context,
        ref(a),
        wire.ChallengeRequest(key(a, 8), hash),
      )
      == Error(service.Uncertain)
    assert exchange(
        f.service,
        context,
        ref(a),
        wire.Submit(key(a, 8), hash, request, <<0:size(256)>>, 5000),
      )
      == Error(service.Uncertain)
    assert journal.payloads(f.journal, key(a, 8), hash) == Ok([])
    assert journal.inspect(f.journal, key(a, 8), hash)
      == Error(journal.Rejected(admission.UnknownRequest))
  })
}

pub fn complete_wrapper_reference_refuses_foreign_parent_before_write_test() {
  fixture("wrapper", fn(f) {
    let a = original(f, 3, "first")
    let b = original(f, 5, "second")
    let context = live(f, a)
    let _ = prepared(f, b)
    assert command.coordinates(a.key) == command.coordinates(b.key)
    assert command.parent(a.key) != command.parent(b.key)
    let request = request(f, a)
    assert exchange(
        f.service,
        context,
        ref(b),
        wire.ChallengeRequest(key(a, 8), digest(request)),
      )
      == Error(service.Invalid)
    assert journal.payloads(f.journal, key(a, 8), digest(request)) == Ok([])
  })
}

pub fn command_session_cannot_bypass_finite_ticket_test() {
  fixture("session", fn(f) {
    let a = original(f, 3, "first")
    let context = live(f, a)
    let request = wire.Prepared(..request(f, a), lifetime: wire.Session)
    assert exchange(
        f.service,
        context,
        ref(a),
        wire.Submit(key(a, 8), digest(request), request, <<0:size(256)>>, 0),
      )
      == Error(service.Invalid)
    assert journal.payloads(f.journal, key(a, 8), digest(request)) == Ok([])
  })
}

pub fn tickets_are_disjoint_between_native_command_and_complete_refs_test() {
  fixture("nonce", fn(f) {
    let a = original(f, 3, "first")
    let b = original(f, 5, "second")
    let context = live(f, a)
    let other = live(f, b)
    let request = request(f, a)
    let hash = digest(request)
    let k = key(a, 8)
    let assert Ok(wire.Challenge(_, _, nonce, _)) =
      service.exchange(f.service, envelope(wire.ChallengeRequest(k, hash)))
      as "Native route ticket."
    assert exchange(
        f.service,
        context,
        ref(a),
        wire.Submit(k, hash, request, nonce, 5000),
      )
      == Error(service.Expired)
    let nonce = challenge(f.service, context, ref(a), k, hash)
    assert service.exchange(
        f.service,
        envelope(wire.Submit(k, hash, request, nonce, 5000)),
      )
      == Error(service.Expired)
    assert exchange(
        f.service,
        other,
        ref(b),
        wire.Submit(k, hash, request, nonce, 5000),
      )
      == Error(service.Expired)
    assert journal.payloads(f.journal, k, hash) == Ok([])
  })
}

pub fn resource_fence_blocks_launch_after_actual_native_admit_test() {
  fixture("fenced", fn(f) {
    let a = original(f, 3, "first")
    let context = live(f, a)
    let request = request(f, a)
    let hash = digest(request)
    let k = key(a, 8)
    let nonce = challenge(f.service, context, ref(a), k, hash)
    assert j.mark_unknown(f.resources, a) == Ok(j.Unknown(Some(ready(f, a))))
    let outcome =
      exchange(
        f.service,
        context,
        ref(a),
        wire.Submit(k, hash, request, nonce, 5000),
      )
    let assert Ok(evidence) = journal.inspect(f.journal, k, hash)
      as "Request and Authority were admitted before association refused."
    assert admission.phase(evidence) == admission.Admitted
    assert outcome == Error(service.Uncertain)
    let assert Ok(bytes) = wire.encode_prepared(request)
      as "Exact Prepared bytes."
    let assert Ok(items) = journal.payloads(f.journal, k, hash)
      as "Durable payloads."
    assert list.contains(items, payload.Request(bytes))
    assert list.any(items, fn(item) {
      case item {
        payload.Authority(_) -> True
        _ -> False
      }
    })
    assert j.inspect_native(f.resources, a) == Ok(j.Unassociated)
    assert exchange(
        f.service,
        context,
        ref(a),
        wire.Submit(k, hash, request, nonce, 5000),
      )
      == Error(service.Uncertain)
    assert phase(f.journal, k, hash) == admission.Admitted
  })
}

pub fn unassociated_controls_cannot_create_cancel_or_receipt_evidence_test() {
  fixture("controls-empty", fn(f) {
    let a = original(f, 3, "first")
    let context = live(f, a)
    let hash = digest(request(f, a))
    let k = key(a, 8)
    list.each(controls(k, hash), fn(body) {
      assert exchange(f.service, context, ref(a), body)
        == Error(service.Uncertain)
      assert journal.payloads(f.journal, k, hash) == Ok([])
      assert journal.inspect(f.journal, k, hash)
        == Error(journal.Rejected(admission.UnknownRequest))
    })
  })
}

pub fn duplicate_submit_bare_admission_requires_exact_association_test() {
  fixture("duplicate-bare", fn(f) {
    let a = original(f, 3, "first")
    let b = original(f, 5, "second")
    let context = live(f, a)
    let a_hash = retain(f.journal, key(a, 9), request(f, a))
    let assert Ok(_) =
      j.associate_native(f.resources, a, ref(a), key(a, 9), a_hash)
      as "A owns a distinct exact admitted tuple."
    let request = request(f, b)
    let hash = digest(request)
    let k = key(b, 8)
    let assert Ok(_) = journal.admit(f.journal, k, hash)
      as "Bare durable admission."
    assert exchange(
        f.service,
        context,
        ref(a),
        wire.Submit(k, hash, request, <<0:size(256)>>, 5000),
      )
      == Error(service.Invalid)
    assert journal.payloads(f.journal, k, hash) == Ok([])
    assert phase(f.journal, k, hash) == admission.Admitted
  })
}

pub fn duplicate_submit_payload_requires_exact_association_test() {
  fixture("duplicate-payload", fn(f) {
    let a = original(f, 3, "first")
    let b = original(f, 5, "second")
    let context = live(f, a)
    let a_hash = retain(f.journal, key(a, 9), request(f, a))
    let assert Ok(_) =
      j.associate_native(f.resources, a, ref(a), key(a, 9), a_hash)
      as "A owns a distinct exact admitted tuple."
    let _ = prepared(f, b)
    let request = request(f, b)
    let hash = retain(f.journal, key(b, 8), request)
    let assert Ok(_) =
      j.associate_native(f.resources, b, ref(b), key(b, 8), hash)
      as "B owns its admitted native history."
    assert exchange(
        f.service,
        context,
        ref(a),
        wire.Submit(key(b, 8), hash, request, <<0:size(256)>>, 5000),
      )
      == Error(service.Invalid)
    assert phase(f.journal, key(b, 8), hash) == admission.Admitted
  })
}

pub fn foreign_controls_leave_other_native_bytes_and_state_unchanged_test() {
  fixture("controls-exact", fn(f) {
    let a = original(f, 3, "first")
    let b = original(f, 5, "second")
    let _ = prepared(f, a)
    let _ = prepared(f, b)
    let a_request = request(f, a)
    let a_hash = retain(f.journal, key(a, 8), a_request)
    let b_hash = retain(f.journal, key(b, 9), request(f, b))
    let assert Ok(_) =
      j.associate_native(f.resources, a, ref(a), key(a, 8), a_hash)
      as "Actual A association."
    let assert Ok(_) =
      j.associate_native(f.resources, b, ref(b), key(b, 9), b_hash)
      as "Actual B association."
    assert journal.put_payload(
        f.journal,
        key(b, 9),
        b_hash,
        payload.Output(0, <<"B secret":utf8>>),
      )
      == Ok(Nil)
    let assert Ok(before) = journal.payloads(f.journal, key(b, 9), b_hash)
      as "B's exact original history."
    let assert Ok(context) =
      service.command_context(f.service, f.resources, ref(a))
      as "Historical A route."
    list.each(controls(key(b, 9), b_hash), fn(body) {
      assert exchange(f.service, context, ref(a), body)
        == Error(service.Invalid)
      assert journal.payloads(f.journal, key(b, 9), b_hash) == Ok(before)
      assert phase(f.journal, key(b, 9), b_hash) == admission.Admitted
    })
    assert exchange(
        f.service,
        context,
        ref(a),
        wire.Query(key(a, 8), b_hash, 0),
      )
      == Error(service.Invalid)
  })
}

pub fn exact_historical_query_cancel_and_receipt_survive_reopen_test() {
  fixture("recovery", fn(f) {
    let a = original(f, 3, "first")
    let _ = prepared(f, a)
    let hash = retain(f.journal, key(a, 8), request(f, a))
    let assert Ok(_) =
      j.associate_native(f.resources, a, ref(a), key(a, 8), hash)
      as "Association is retained before recovery."
    assert j.release_endpoint(f.resources) == Ok(Nil)
    let assert Ok(book) =
      j.recover(f.path <> "/resources.sqlite", f.enrolled, limits(), f.journal)
      as "Recovered resources carry data only."
    let assert Ok(context) = service.command_context(f.service, book, ref(a))
      as "Recovered exact context."
    assert exchange(f.service, context, ref(a), wire.Query(key(a, 8), hash, 0))
      == Ok(wire.Evidence(key(a, 8), hash, 1, 1_000_000))
    let assert Ok(wire.Terminal(_, _, bytes)) =
      exchange(f.service, context, ref(a), wire.Cancel(key(a, 8), hash))
      as "Exact historical cancellation settles pre-launch admission."
    let assert Ok(terminal_hash) = wire.digest(bytes)
      as "Exact terminal digest."
    let receipt = wire.DurableReceipt(key(a, 8), hash, terminal_hash)
    assert exchange(f.service, context, ref(a), receipt)
      == Ok(wire.Terminal(key(a, 8), hash, bytes))
    assert exchange(f.service, context, ref(a), receipt)
      == Ok(wire.Terminal(key(a, 8), hash, bytes))
    assert phase(f.journal, key(a, 8), hash)
      == admission.Refused(terminal_hash, admission.ReceiptDurable)
    assert exchange(
        f.service,
        context,
        ref(a),
        wire.Submit(key(a, 8), hash, request(f, a), <<0:size(256)>>, 5000),
      )
      == Error(service.Uncertain)
    assert j.release_endpoint(book) == Ok(Nil)
  })
}

pub fn real_compiler_checkout_follows_committed_association_and_duplicates_do_not_relaunch_test() {
  fixture("compiler", fn(f) {
    let a = original(f, 3, "first")
    let claim = prepared(f, a)
    let request = request(f, a)
    let hash = digest(request)
    let k = key(a, 8)
    let checked = process.new_subject()
    let native =
      native_executor(f.path, fn() {
        assert j.inspect_native(f.resources, a)
          == Ok(j.Associated(ref(a), k, hash, request))
        let assert Ok(items) = journal.payloads(f.journal, k, hash)
          as "Both original payloads precede helper checkout."
        let assert Ok(bytes) = wire.encode_prepared(request)
          as "Canonical compiler."
        assert list.contains(items, payload.Request(bytes))
        assert list.any(items, fn(item) {
          case item {
            payload.Authority(_) -> True
            _ -> False
          }
        })
        assert phase(f.journal, k, hash)
          == admission.LaunchIntent(admission.NativeUnconfirmed)
        process.send(checked, Nil)
      })
    let assert Ok(server) =
      service.start(service.Config(..service.configuration(f.service), native:))
      as "Same journal engine with an observed real helper pool."
    let assert Ok(context) =
      service.live_command_context(server, claim, ref(a), f.compile_deadline_ms)
      as "Original Claim is passed to this exact service."
    let root = request.request.cwd
    prepare_project(root)
    let nonce = challenge(server, context, ref(a), k, hash)
    let submit = wire.Submit(k, hash, request, nonce, 5000)
    let assert Ok(_) = exchange(server, context, ref(a), submit)
      as "Real fixed compiler was launched."
    assert process.receive(checked, 3000) == Ok(Nil)
    let terminal_bytes = terminal(server, context, ref(a), k, hash)
    let assert Ok(dispatch.Completed(exit)) =
      native.decode_terminal(terminal_bytes)
      as "Compiler actually exited."
    assert exit.code == 0
    assert exit.signal == 0
    assert exit.timed_out == False
    assert exit.cancelled == False
    assert simplifile.is_file(
        root
        <> "/build/dev/erlang/native_route_fixture/ebin/native_route_fixture.beam",
      )
      == Ok(True)
    let retained = exchange(server, context, ref(a), wire.Query(k, hash, 0))
    let _discarded_reply = exchange(server, context, ref(a), submit)
    assert exchange(server, context, ref(a), submit) == retained
    assert terminal(server, context, ref(a), k, hash) == terminal_bytes
    assert process.receive(checked, 10) == Error(Nil)
    assert service.shutdown(server) == Ok(Nil)

    // Recovered history enters the same service engine without live eligibility.
    assert j.release_endpoint(f.resources) == Ok(Nil)
    let assert Ok(book) =
      j.recover(f.path <> "/resources.sqlite", f.enrolled, limits(), f.journal)
      as "Canonical native association survives resource reopen."
    let recovery_native =
      native_executor(f.path, fn() { process.send(checked, Nil) })
    let assert Ok(recovered) =
      service.start(
        service.Config(
          ..service.configuration(f.service),
          native: recovery_native,
        ),
      )
      as "New service actor over the original retained native journal."
    let assert Ok(history) = service.command_context(recovered, book, ref(a))
      as "No original Claim is reconstructed."
    assert exchange(recovered, history, ref(a), wire.Query(k, hash, 64))
      == Ok(wire.Terminal(k, hash, terminal_bytes))
    assert exchange(recovered, history, ref(a), submit)
      == Error(service.Uncertain)
    assert exchange(recovered, history, ref(a), wire.ChallengeRequest(k, hash))
      == Error(service.Uncertain)
    assert process.receive(checked, 10) == Error(Nil)
    assert service.shutdown(recovered) == Ok(Nil)
    assert j.release_endpoint(book) == Ok(Nil)
  })
}

pub fn foreign_controls_cannot_cancel_or_feed_a_live_compiler_test() {
  fixture("live-controls", fn(f) {
    let a = original(f, 3, "first")
    let b = original(f, 5, "second")
    let _ = prepared(f, a)
    let claim = prepared(f, b)
    let a_hash = retain(f.journal, key(a, 8), request(f, a))
    let assert Ok(_) =
      j.associate_native(f.resources, a, ref(a), key(a, 8), a_hash)
      as "A has an independent complete association."
    let request = request(f, b)
    let hash = digest(request)
    let k = key(b, 9)
    let checkouts = process.new_subject()
    let native =
      native_executor(f.path, fn() {
        let permit = process.new_subject()
        process.send(checkouts, permit)
        assert process.receive(permit, 3000) == Ok(Nil)
      })
    let assert Ok(server) =
      service.start(service.Config(..service.configuration(f.service), native:))
      as "A real compiler stays in live native custody during foreign controls."
    let assert Ok(context) =
      service.live_command_context(server, claim, ref(b), f.compile_deadline_ms)
      as "B's original Claim."
    let assert Ok(history) =
      service.command_context(server, f.resources, ref(a))
      as "A's historical route cannot borrow B's live key."
    prepare_project(request.request.cwd)
    let nonce = challenge(server, context, ref(b), k, hash)
    let assert Ok(wire.Evidence(_, _, 2, _)) =
      exchange(
        server,
        context,
        ref(b),
        wire.Submit(k, hash, request, nonce, 5000),
      )
      as "B entered real native custody."
    let assert Ok(permit) = process.receive(checkouts, 3000)
      as "Actual checkout reached its gate."
    let assert Ok(before) = journal.payloads(f.journal, k, hash)
      as "Original B payloads."
    list.each(controls(k, hash), fn(body) {
      assert exchange(server, history, ref(a), body) == Error(service.Invalid)
      assert journal.payloads(f.journal, k, hash) == Ok(before)
      assert phase(f.journal, k, hash)
        == admission.LaunchIntent(admission.NativeUnconfirmed)
    })

    // B completes after its own gate opens; a foreign Cancel or stdin never settled it.
    process.send(permit, Nil)
    let bytes = terminal(server, context, ref(b), k, hash)
    let assert Ok(dispatch.Completed(exit)) = native.decode_terminal(bytes)
      as "Actual compiler survived every foreign control."
    assert exit.code == 0
    assert exit.cancelled == False
    assert exit.timed_out == False
    assert service.shutdown(server) == Ok(Nil)
  })
}

fn prepare_project(root: String) -> Nil {
  assert simplifile.create_directory_all(root <> "/src") == Ok(Nil)
  assert simplifile.create_directory_all(root <> "/tmp") == Ok(Nil)
  assert simplifile.write(
      root <> "/gleam.toml",
      "name = \"native_route_fixture\"\nversion = \"1.0.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      root <> "/src/native_route_fixture.gleam",
      "pub fn main() { Nil }\n",
    )
    == Ok(Nil)
}

pub fn finite_compile_template_drift_never_reaches_launch_intent_test() {
  fixture("template", fn(f) {
    list.each(["argv", "env", "cwd", "stream", "policy"], fn(field) {
      let index = case field {
        "argv" -> 3
        "env" -> 5
        "cwd" -> 7
        "stream" -> 9
        _ -> 11
      }
      let a = original(f, index, field)
      let context = live(f, a)
      let good = request(f, a)
      let assert Some(base) = good.request.policy as "Full policy was retained."
      let assert Ok(compiler) = list.first(good.request.argv)
        as "The fixed compiler argv is nonempty."
      let changed = case field {
        "argv" ->
          wire.Prepared(
            ..good,
            request: exec.ExecRequest(..good.request, argv: [
              compiler,
              "--version",
            ]),
          )
        "env" ->
          wire.Prepared(
            ..good,
            request: exec.ExecRequest(
              ..good.request,
              env: list.reverse(good.request.env),
            ),
          )
        "cwd" ->
          wire.Prepared(
            ..good,
            request: exec.ExecRequest(..good.request, cwd: f.path <> "/work"),
          )
        "stream" -> wire.Prepared(..good, stream: wire.ProtocolStream)
        _ ->
          wire.Prepared(
            ..good,
            request: exec.ExecRequest(
              ..good.request,
              policy: Some(
                policy.SandboxPolicy(..base, network: policy.NetworkFull),
              ),
            ),
          )
      }
      let hash = digest(changed)
      let k = key(a, 20 + index)
      let nonce = challenge(f.service, context, ref(a), k, hash)
      assert exchange(
          f.service,
          context,
          ref(a),
          wire.Submit(k, hash, changed, nonce, 5000),
        )
        == Error(service.Uncertain)
      assert phase(f.journal, k, hash) == admission.Admitted
      assert j.inspect_native(f.resources, a) == Ok(j.Unassociated)
    })
  })
}

pub fn ambiguous_resource_commit_does_not_authorize_native_launch_test() {
  fixture("commit", fn(f) {
    let a = original(f, 3, "first")
    let context = live(f, a)
    let request = request(f, a)
    let hash = digest(request)
    let k = key(a, 8)
    let nonce = challenge(f.service, context, ref(a), k, hash)
    let assert Ok(connection) = sqlight.open(f.path <> "/resources.sqlite")
      as "Independent fault connection."
    assert sqlight.exec(
        "CREATE TRIGGER suppress_association BEFORE UPDATE OF native_id ON resource_call BEGIN SELECT RAISE(IGNORE); END",
        connection,
      )
      == Ok(Nil)
    assert sqlight.close(connection) == Ok(Nil)
    assert exchange(
        f.service,
        context,
        ref(a),
        wire.Submit(k, hash, request, nonce, 5000),
      )
      == Error(service.Uncertain)
    assert phase(f.journal, k, hash) == admission.Admitted
    assert exchange(
        f.service,
        context,
        ref(a),
        wire.Submit(k, hash, request, nonce, 5000),
      )
      == Error(service.Uncertain)
    assert phase(f.journal, k, hash) == admission.Admitted
  })
}

pub fn elapsed_time_after_association_cannot_renew_native_deadline_test() {
  fixture("elapsed", fn(f) {
    let a = original(f, 3, "first")
    let claim = prepared(f, a)
    let assert Ok(counter) =
      actor.new(0)
      |> actor.on_message(fn(count, reply) {
        let count = count + 1
        process.send(reply, count)
        case count {
          3 -> actor.stop()
          _ -> actor.continue(count)
        }
      })
      |> actor.start
      as "Serialized injected clock observations."
    let subject = counter.data
    let now = fn() {
      let reply = process.new_subject()
      process.send(subject, reply)
      let assert Ok(count) = process.receive(reply, 1000)
        as "Finite clock probe."
      case count {
        1 | 2 -> 100_000
        _ -> 106_000
      }
    }
    let assert Ok(server) =
      service.start(
        service.Config(
          ..service.configuration(f.service),
          now:,
          native: native_executor(f.path, fn() {
            panic as "An expired associated command cannot check out a helper."
          }),
        ),
      )
      as "Original elapsed authority, with no deadline refresh."
    let assert Ok(context) =
      service.live_command_context(server, claim, ref(a), 105_000)
      as "Original claim under the observed clock."
    let request = request(f, a)
    let hash = digest(request)
    let k = key(a, 8)
    let nonce = challenge(server, context, ref(a), k, hash)
    let assert Ok(wire.Terminal(_, _, bytes)) =
      exchange(
        server,
        context,
        ref(a),
        wire.Submit(k, hash, request, nonce, 5000),
      )
      as "Association consumes time but cannot renew the saved deadline."
    let assert Ok(terminal_hash) = wire.digest(bytes)
      as "Exact refusal evidence."
    assert phase(f.journal, k, hash)
      == admission.Refused(terminal_hash, admission.ReceiptPending)
    assert retained_authority(f.journal, k, hash) == #(1, 105_000, 5000)
    assert j.inspect_native(f.resources, a)
      == Ok(j.Associated(ref(a), k, hash, request))
    assert exchange(server, context, ref(a), wire.Query(k, hash, 0))
      == Ok(wire.Terminal(k, hash, bytes))
    assert service.shutdown(server) == Ok(Nil)
  })
}

pub fn original_compile_cap_clamps_retained_authority_without_rewriting_prepared_test() {
  fixture("cap-authority", fn(f) {
    let a = original(f, 3, "first")
    let claim = prepared(f, a)
    let server = clocked(f, fn() { 100_000 })
    let assert Ok(context) =
      service.live_command_context(server, claim, ref(a), 103_000)
      as "The original executor elapsed deadline accompanies the Claim."
    let request = request(f, a)
    let hash = digest(request)
    let k = key(a, 8)
    let nonce = challenge(server, context, ref(a), k, hash)
    assert j.mark_unknown(f.resources, a) == Ok(j.Unknown(Some(ready(f, a))))

    // Authority is real and durable even when the independent resource fence wins.
    assert exchange(
        server,
        context,
        ref(a),
        wire.Submit(k, hash, request, nonce, 8000),
      )
      == Error(service.Uncertain)
    assert retained_authority(f.journal, k, hash) == #(1, 103_000, 8000)
    let assert Ok(bytes) = wire.encode_prepared(request)
      as "Original Prepared bytes."
    let assert Ok(items) = journal.payloads(f.journal, k, hash)
      as "Actual retained native payloads."
    assert list.contains(items, payload.Request(bytes))
    assert phase(f.journal, k, hash) == admission.Admitted
    assert j.inspect_native(f.resources, a) == Ok(j.Unassociated)
    assert service.shutdown(server) == Ok(Nil)
  })
}

pub fn inflated_incoming_budget_cannot_launch_selected_wall_past_original_cap_test() {
  fixture("cap-wall", fn(f) {
    let a = original(f, 3, "first")
    let claim = prepared(f, a)
    let server = clocked(f, fn() { 100_000 })
    let assert Ok(context) =
      service.live_command_context(server, claim, ref(a), 101_500)
      as "Only 1500 original elapsed milliseconds remain."
    let request = request(f, a)
    let assert Some(policy) = request.request.policy
      as "Actual unchanged cleared policy."
    assert policy.limits.wall_s == 2
    let hash = digest(request)
    let k = key(a, 8)
    let nonce = challenge(server, context, ref(a), k, hash)

    // A later owner Unix rollback can inflate this budget; it cannot change the
    // native continuation's original cap or shrink the already selected two seconds.
    let assert Ok(wire.Terminal(_, _, terminal)) =
      exchange(
        server,
        context,
        ref(a),
        wire.Submit(k, hash, request, nonce, 8000),
      )
      as "Selected wall cannot fit original elapsed authority: no helper launch."
    assert retained_authority(f.journal, k, hash) == #(1, 101_500, 8000)
    let assert Ok(terminal_hash) = wire.digest(terminal)
      as "Exact native refusal."
    assert phase(f.journal, k, hash)
      == admission.Refused(terminal_hash, admission.ReceiptPending)
    assert j.inspect_native(f.resources, a)
      == Ok(j.Associated(ref(a), k, hash, request))
    assert exchange(
        server,
        context,
        ref(a),
        wire.Submit(k, hash, request, nonce, 9000),
      )
      == Ok(wire.Terminal(k, hash, terminal))
    assert retained_authority(f.journal, k, hash) == #(1, 101_500, 8000)
    let assert Ok(history) =
      service.command_context(server, f.resources, ref(a))
      as "Retained association is historical data."
    assert exchange(server, history, ref(a), wire.Query(k, hash, 0))
      == Ok(wire.Terminal(k, hash, terminal))
    assert service.shutdown(server) == Ok(Nil)
  })
}

pub fn zero_and_elapsed_compile_caps_refuse_without_native_payload_test() {
  fixture("cap-expired", fn(f) {
    let a = original(f, 3, "first")
    let claim = prepared(f, a)
    let server = clocked(f, fn() { 100_000 })
    assert service.live_command_context(server, claim, ref(a), 0)
      == Error(service.Invalid)
    let assert Ok(context) =
      service.live_command_context(server, claim, ref(a), 100_000)
      as "An expired original cap remains data until finite authorization checks it."
    let request = request(f, a)
    let hash = digest(request)
    let k = key(a, 8)
    let nonce = challenge(server, context, ref(a), k, hash)
    assert exchange(
        server,
        context,
        ref(a),
        wire.Submit(k, hash, request, nonce, 8000),
      )
      == Error(service.Expired)
    assert journal.payloads(f.journal, k, hash) == Ok([])
    assert journal.inspect(f.journal, k, hash)
      == Error(journal.Rejected(admission.UnknownRequest))
    assert j.inspect_native(f.resources, a) == Ok(j.Unassociated)
    assert service.shutdown(server) == Ok(Nil)
  })
}

pub fn negative_monotonic_era_is_valid_and_ordinary_native_deadline_is_unchanged_test() {
  fixture("cap-negative", fn(f) {
    let a = original(f, 3, "first")
    let claim = prepared(f, a)
    let server = clocked(f, fn() { -100_000 })
    let assert Ok(context) =
      service.live_command_context(server, claim, ref(a), -97_000)
      as "Negative nonzero deadlines can still be future elapsed authority."
    let request = request(f, a)
    let hash = digest(request)
    let k = key(a, 8)
    let nonce = challenge(server, context, ref(a), k, hash)
    assert j.mark_unknown(f.resources, a) == Ok(j.Unknown(Some(ready(f, a))))
    assert exchange(
        server,
        context,
        ref(a),
        wire.Submit(k, hash, request, nonce, 8000),
      )
      == Error(service.Uncertain)
    assert retained_authority(f.journal, k, hash) == #(1, -97_000, 8000)

    // Ordinary Native retains its challenge-derived deadline without a Compile cap.
    let assert Some(policy) = request.request.policy
      as "Complete native policy."
    let native_request =
      wire.Prepared(
        ..request,
        request: exec.ExecRequest(
          ..request.request,
          policy: Some(
            policy.SandboxPolicy(
              ..policy,
              limits: policy.Limits(..policy.limits, wall_s: 9),
            ),
          ),
        ),
      )
    let native_hash = digest(native_request)
    let native_key = key(a, 9)
    let assert Ok(wire.Challenge(_, _, native_nonce, _)) =
      service.exchange(
        server,
        envelope(wire.ChallengeRequest(native_key, native_hash)),
      )
      as "Original ordinary native ticket."
    let assert Ok(wire.Terminal(_, _, _)) =
      service.exchange(
        server,
        envelope(wire.Submit(
          native_key,
          native_hash,
          native_request,
          native_nonce,
          8000,
        )),
      )
      as "Nine seconds cannot fit eight; ordinary refusal stays unchanged."
    assert retained_authority(f.journal, native_key, native_hash)
      == #(1, -92_000, 8000)
    assert service.shutdown(server) == Ok(Nil)
  })
}

fn clocked(f: Fixture, now: fn() -> Int) -> service.Service {
  let assert Ok(server) =
    service.start(
      service.Config(
        ..service.configuration(f.service),
        now:,
        native: native_executor(f.path, fn() {
          panic as "These deadline controls must refuse before checking out a real helper."
        }),
      ),
    )
    as "Existing real native service with an injected elapsed clock."
  server
}

fn retained_authority(
  book: journal.Journal,
  key: identity.RequestKey,
  hash: identity.Digest,
) -> #(Int, Int, Int) {
  let assert Ok(items) = journal.payloads(book, key, hash)
    as "Actual native journal readback."
  let assert Ok(payload.Authority(bytes)) =
    list.find(items, fn(item) {
      case item {
        payload.Authority(_) -> True
        _ -> False
      }
    })
    as "Finite authorization was durably retained."
  let assert Ok(mp.ArrayValue([
    mp.IntValue(generation),
    mp.IntValue(deadline),
    mp.IntValue(budget),
  ])) = wire.decode_value(bytes)
    as "Exact canonical finite Authority tuple."
  #(generation, deadline, budget)
}

fn controls(k: identity.RequestKey, hash: identity.Digest) -> List(wire.Body) {
  [
    wire.Query(k, hash, 0),
    wire.Cancel(k, hash),
    wire.Stdin(k, hash, 0, <<"input":utf8>>, dispatch.EndOfInput),
    wire.DurableReceipt(k, hash, hash),
  ]
}

fn fixture(name: String, run: fn(Fixture) -> Nil) -> Nil {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let assert Ok(here) = simplifile.current_directory()
    as "Private fixture workspace."
  let path =
    here
    <> "/build/cns-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory_all(path <> "/seed") == Ok(Nil)
  let enrolled = enrolled(path)
  let assert Ok(capacity) = admission.capacity(16) as "Native lifetime slots."
  let assert Ok(book) =
    journal.fresh(path <> "/native.sqlite", scope(), capacity)
    as "Real native SQLite actor."
  let assert Ok(resources) =
    j.fresh(path <> "/resources.sqlite", enrolled, limits(), book)
    as "Real resource SQLite actor."
  let native = native_executor(path, fn() { Nil })
  let assert Ok(server) =
    service.start(service.Config(
      "owner",
      "linux",
      scope(),
      1,
      book,
      native,
      fn(_, prepared) {
        case prepared.registration == registration() {
          True -> Ok(Nil)
          False -> Error(Nil)
        }
      },
      poll.monotonic().now,
    ))
    as "Scoped service admission engine."
  run(Fixture(
    path,
    enrolled,
    resources,
    book,
    native,
    server,
    poll.monotonic().now() + 10_000,
  ))

  // Native drain is witnessed independently of resource metadata or receipt.
  assert service.shutdown(server) == Ok(Nil)
  assert j.release_endpoint(resources) == Ok(Nil)
  assert journal.release(book) == Ok(Nil)
  assert simplifile.delete(path) == Ok(Nil)
  let _name = name
  Nil
}

fn native_executor(
  path: String,
  before_checkout: fn() -> Nil,
) -> local.Executor {
  let assert Ok(here) = simplifile.current_directory() as "Helper fixture root."
  let helper = here <> "/../sandbox/loom-exec"
  assert simplifile.is_file(helper) == Ok(True)
  assert simplifile.create_directory_all(path <> "/pool/tmp") == Ok(Nil)
  let spawn =
    exec.SpawnConfig(
      helper,
      "/bin/sh",
      executor.base_policy(path),
      [],
      path <> "/pool/tmp",
      3000,
      3000,
      0,
    )
  let assert Ok(pool) = exec.start_pool(1, fn() { exec.prepare_helper(spawn) })
    as "Real helper pool."
  let assert Ok(native) =
    local.start(local.ExecutorConfig(
      fn() {
        before_checkout()
        exec.checkout(pool, waiting: 3000)
      },
      fn(helper) { exec.checkin(pool, helper) },
      fn() { exec.pool_custody(pool, waiting: 1000) },
      fn(ms) { exec.close_pool(pool, waiting: ms) },
      23,
      log.discard(),
    ))
    as "Existing scoped native executor."
  native
}

fn enrolled(path: String) -> enrollment.SessionEnrollment {
  let base = base(path)
  let #(gleam_dir, gleam) = executable("gleam")
  let #(erl_dir, erl) = executable("erl")
  let system =
    list.filter(["/usr", "/bin", "/System"], fn(root) {
      simplifile.is_directory(root) == Ok(True)
    })
  let roots =
    list.unique([toolchain_root(gleam_dir), toolchain_root(erl_dir), ..system])
  let path_env =
    string.join(list.unique([gleam_dir, erl_dir, "/usr/bin", "/bin"]), ":")
  let assert Ok(enrolled) =
    enrollment.new(
      enrollment.NativeFacts(
        core_scope(),
        [path, channel(path)],
        base,
        exec.PlatformEnforcement,
      ),
      enrollment.CodeModeFacts(
        path <> "/work",
        path <> "/build",
        channel(path),
        gleam,
        erl,
        path <> "/seed",
        roots,
        [],
        path_env,
      ),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Exact fixture roots disjoint from immutable toolchains."
  enrolled
}

// The fixture pins actual executables from its trusted test process environment.
// It never accepts a peer-selected compiler or substitutes another executable.
fn executable(name: String) -> #(String, String) {
  let assert Ok(path) = envoy.get("PATH") as "Test toolchain PATH is available."
  let assert Ok(directory) =
    list.find(string.split(path, ":"), fn(directory) {
      string.starts_with(directory, "/")
      && simplifile.is_file(directory <> "/" <> name) == Ok(True)
    })
    as "The real required toolchain is installed."
  let assert Ok(executable) =
    fs.resolve_real(fs.real_filesystem(), "/", directory <> "/" <> name)
    as "Trusted toolchain symlinks are resolved before enrollment."
  let canonical_directory =
    string.join(
      list.reverse(list.drop(list.reverse(string.split(executable, "/")), 1)),
      "/",
    )
  #(canonical_directory, executable)
}

// Channel names stay within the socket-path ceiling; Compile never opens them.
// Its actual build allocation stays in the workspace, outside the jail's /tmp.
fn channel(path: String) -> String {
  let assert Ok(name) = list.last(string.split(path, "/"))
    as "Unique fixture name."
  let tmp = case simplifile.is_directory("/private/tmp") {
    Ok(True) -> "/private/tmp"
    _ -> "/tmp"
  }
  tmp <> "/" <> name <> "/ch"
}

fn toolchain_root(directory: String) -> String {
  case directory != "/bin" && string.ends_with(directory, "/bin") {
    True -> string.drop_end(directory, 4)
    False -> directory
  }
}

fn base(path: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..executor.base_policy(path),
    writable_roots: [path <> "/work", path <> "/build", channel(path)],
    protected: [],
    limits: policy.Limits(10, 10, 536_870_912, 64, 16_777_216, 262_144),
    env_allow: ["PATH", "TMPDIR"],
  )
}

fn core_scope() -> workspace.Scope {
  let assert Ok(scope) =
    workspace.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "linux",
      2,
      7,
    )
    as "Full authority epochs."
  scope
}

fn scope() -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Session UUID."
  let assert Ok(name) = identity.workspace_id("checkout") as "Workspace label."
  let assert Ok(executor) = identity.executor_id("linux") as "Executor label."
  let assert Ok(session_epoch) = identity.epoch(2) as "Session authority epoch."
  let assert Ok(workspace_epoch) = identity.epoch(7)
    as "Workspace authority epoch."
  identity.scope(session, name, executor, session_epoch, workspace_epoch)
}

fn id(number: Int) -> ids.EntryId {
  let assert Ok(id) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "Stable original UUID."
  id
}

fn original(f: Fixture, number: Int, parent_step: String) -> j.Input {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Managed session."
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Managed operation."
  let assert Ok(parent) =
    remote_tool.key(session, op, parent_step, 3, string.repeat("a", 64), id(4))
    as "Complete parent."
  let assert Ok(decoded) =
    input.compile_input(
      f.enrolled,
      input.WorkspaceProgram,
      "pub fn main() { Nil }",
      [],
      compile.default_dependencies(),
      base(f.path),
      10_000,
    )
    as "Bounded original Compile data."
  let bytes = input.encode_compile(decoded)
  let hash = string.lowercase(bit_array.base16_encode(j.digest(bytes)))
  let assert Ok(step) = workspace.step("physical:build")
    as "Same physical coordinate across parents."
  let assert Ok(key) =
    command.service_key(
      parent,
      command.CompileService,
      core_scope(),
      op,
      step,
      id(number),
      hash,
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Complete original key."
  j.Input(key, bytes)
}

fn ref(original: j.Input) -> command.CommandRef {
  let assert Ok(ref) = command.command_ref(original.key, command.CompileCommand)
    as "Closed compile role."
  ref
}

fn key(original: j.Input, number: Int) -> identity.RequestKey {
  let assert Ok(request) =
    identity.request_id(ids.entry_id_to_string(id(number)))
    as "Native UUID is separate."
  identity.request_key(
    scope(),
    remote_tool.operation(command.parent(original.key)),
    request,
  )
}

fn ready(f: Fixture, original: j.Input) -> resources.Ready {
  let assert Ok(root) = enrollment.compile_path(f.enrolled, original.key)
    as "Original UUID build allocation."
  let assert Ok(locations) =
    resources.admit_compile_locations(f.enrolled, original.key, root)
    as "Full original locations."
  resources.CompileReady(locations)
}

fn prepared(f: Fixture, original: j.Input) -> j.Claim {
  assert j.reserve(f.resources, original) == Ok(j.Reserved)
  let assert Ok(j.Claimed(claim)) = j.claim_preparation(f.resources, original)
    as "Single committed original Claim."
  assert j.commit_ready(claim, ready(f, original))
    == Ok(j.Prepared(ready(f, original)))
  claim
}

fn live(f: Fixture, original: j.Input) -> service.CommandContext {
  let claim = prepared(f, original)
  let assert Ok(context) =
    service.live_command_context(
      f.service,
      claim,
      ref(original),
      f.compile_deadline_ms,
    )
    as "Original Claim identity retained."
  context
}

fn request(f: Fixture, original: j.Input) -> wire.Prepared {
  let assert Ok(decoded) = input.decode_compile(original.body)
    as "Bounded exact source input."
  let assert resources.CompileReady(locations) = ready(f, original)
    as "Compile locations."
  let assert Ok(expected) =
    service_command.compile_from_input(
      f.enrolled,
      original.key,
      decoded,
      locations,
      2,
    )
    as "Fixed real compiler expectation."
  let data = offer.data(service_command.offer(expected))
  wire.Prepared(
    "physical:build",
    registration(),
    wire.Finite(10_000),
    exec.ExecRequest(
      data.argv,
      data.env,
      data.cwd,
      Some(data.requirements),
      <<0:size(256)>>,
      exec.PlatformEnforcement,
    ),
    wire.Logs,
  )
}

fn registration() -> identity.Digest {
  let assert Ok(bytes) = bit_array.base16_decode(string.repeat("b", 64))
    as "Exact digest spelling."
  let assert Ok(hash) = identity.digest(bytes) as "Administrative digest."
  hash
}

fn digest(request: wire.Prepared) -> identity.Digest {
  let assert Ok(hash) = wire.prepared_digest(request)
    as "Exact full Prepared digest."
  hash
}

fn envelope(body: wire.Body) -> wire.Envelope {
  wire.Envelope(wire.Owner, "owner", "linux", 1, scope(), body)
}

fn exchange(
  server: service.Service,
  context: service.CommandContext,
  ref: command.CommandRef,
  body: wire.Body,
) -> Result(wire.Body, service.Error) {
  let assert Ok(envelope) = wire.command_envelope(ref, envelope(body))
    as "Closed full-reference framing."
  service.exchange_command(server, context, envelope)
}

fn challenge(
  server: service.Service,
  context: service.CommandContext,
  ref: command.CommandRef,
  k: identity.RequestKey,
  hash: identity.Digest,
) -> BitArray {
  let assert Ok(wire.Challenge(_, _, nonce, _)) =
    exchange(server, context, ref, wire.ChallengeRequest(k, hash))
    as "Finite original challenge."
  nonce
}

fn retain(
  book: journal.Journal,
  k: identity.RequestKey,
  prepared: wire.Prepared,
) -> identity.Digest {
  let assert Ok(bytes) = wire.encode_prepared(prepared)
    as "Canonical native Prepared."
  let hash = digest(prepared)
  assert journal.put_payload(book, k, hash, payload.Request(bytes)) == Ok(Nil)
  let assert Ok(authority) =
    wire.encode_value(
      mp.ArrayValue([mp.IntValue(1), mp.IntValue(1_000_000), mp.IntValue(5000)]),
    )
    as "Canonical finite historical authority."
  assert journal.put_payload(book, k, hash, payload.Authority(authority))
    == Ok(Nil)
  let assert Ok(_) = journal.admit(book, k, hash)
    as "Actual admission after retained Request and Authority."
  hash
}

fn phase(
  book: journal.Journal,
  k: identity.RequestKey,
  hash: identity.Digest,
) -> admission.Phase {
  let assert Ok(evidence) = journal.inspect(book, k, hash)
    as "Actual committed reducer evidence."
  admission.phase(evidence)
}

fn limits() -> j.Limits {
  let assert Ok(limits) = j.limits(16, 30_000_000)
    as "Explicit fixture capacity."
  limits
}

fn terminal(
  server: service.Service,
  context: service.CommandContext,
  ref: command.CommandRef,
  k: identity.RequestKey,
  hash: identity.Digest,
) -> BitArray {
  let assert poll.Answered(bytes) =
    poll.until(4000, 10, fn() {
      case exchange(server, context, ref, wire.Query(k, hash, 64)) {
        Ok(wire.Terminal(_, _, bytes)) -> poll.Done(bytes)
        _ -> poll.Retry
      }
    })
    as "Bounded observation of the actual compiler terminal."
  bytes
}

pub fn launch_command_context_accepts_satellite_and_refuses_compile_provenance_test() {
  fixture("launch-role", fn(f) {
    let producer = original(f, 3, "first")
    let #(scope, operation, step) = command.coordinates(producer.key)
    let #(input_digest, _, contract) = command.digests(producer.key)
    let artifact =
      compile.ExecutorArtifact(
        scope,
        operation,
        step,
        ids.entry_id_to_string(command.request_id(producer.key)),
        input_digest,
        "issued-artifact",
        contract,
        compile.entry_module,
        "sha256-" <> string.repeat("e", 64),
      )
    let assert Ok(decoded) =
      input.launch_input(
        f.enrolled,
        producer.key,
        artifact,
        [],
        workspace.root(),
        base(f.path),
        string.repeat("d", 64),
      )
      as "Canonical Launch input, independent of artifact proof."
    let body = input.encode_launch(decoded)
    let assert Ok(run_step) = workspace.step("physical:run") as "Launch step."
    let #(registration, contract) = enrollment.digests(f.enrolled)
    let assert Ok(key) =
      command.service_key(
        command.parent(producer.key),
        command.LaunchService,
        scope,
        operation,
        run_step,
        id(5),
        string.lowercase(bit_array.base16_encode(j.digest(body))),
        registration,
        contract,
      )
      as "Full original Launch service key."
    let launch = j.Input(key, body)
    let assert Ok(j.FreshClaim(claim)) =
      j.admit_preparation(f.resources, launch)
      as "Original live Launch claim."
    let assert Ok(satellite) =
      command.command_ref(key, command.SatelliteCommand)
      as "Exact SatelliteCommand purpose."
    let assert Ok(_) =
      service.live_command_context(
        f.service,
        claim,
        satellite,
        f.compile_deadline_ms,
      )
      as "Launch routes through the same native permit gate."
    let assert Ok(_) =
      service.command_context(f.service, f.resources, satellite)
      as "Historical context retains no first-Submit authority."
    assert service.live_command_context(
        f.service,
        claim,
        ref(producer),
        f.compile_deadline_ms,
      )
      == Error(service.Invalid)
    assert command.command_ref(key, command.CompileCommand)
      == Error("command role differs from original service purpose")
    Nil
  })
}
