//// Prompt evidence and rollout admission are verified independently of quality.
//// All providers here are scripted; the verdict must retain that limitation.

import broker/token
import client/evolution/prompt
import client/evolution/record
import client/evolution/record_test
import client/evolution/retirement
import client/evolution/rollout
import client/evolution/rollout_host
import client/evolution/store
import client/evolution/trace
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/register
import core/tx
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import provider/model
import provider/pricing
import provider/profile
import session/session
import storage/storage

fn candidate(text: String) -> record.Candidate {
  let base = record_test.candidate()
  record.identified(
    record.Candidate(
      ..base,
      kind: record.Prompt,
      scope: record.ExactModel(record.ModelScope("p", "m", "anthropic-messages")),
      files: [
        #(
          "prompt.json",
          "{\"version\":1,\"provider\":\"p\",\"model\":\"m\",\"api\":\"anthropic-messages\",\"system\":\""
            <> text
            <> "\",\"task\":\"Check the fixture.\",\"descriptions\":{\"code_mode\":\"Verify the result.\"}}",
        ),
      ],
      test_entry: None,
    ),
  )
}

fn opened() -> store.Store {
  let assert Ok(catalogue) =
    store.open(
      "build/test_db/evolution-models-"
        <> bit_array.base16_encode(token.production_entropy()(12)),
      store.Owner,
      record_test.candidate().identity,
      clock.fixed(1),
    )
    as "native catalogue opens"
  catalogue
}

fn target() -> model.ResolvedModel {
  model.ResolvedModel("p", "m", model.ThinkingOff, 1000, 100)
}

fn task() -> rollout.Task {
  rollout.Task(
    "repair-v1",
    "Repair fixture source and run its tests.",
    "fixture-test-v1",
    "fixture-source-v1",
  )
}

fn limits() -> rollout.Limits {
  rollout.Limits(2, 8, 10_000, 1.0, 10_000, 10_000)
}

fn scripted(
  opened: process.Subject(rollout.TrialRequest),
  closed: process.Subject(String),
) -> rollout.Callbacks {
  rollout.Callbacks(
    clock: clock.fixed(1),
    mode: rollout.ScriptedLifecycle,
    open: fn(request) {
      process.send(opened, request)
      Ok(
        rollout.Trial(
          step: fn(allowance) {
            assert allowance.turns > 0 && allowance.tokens > 0
            Ok(rollout.Step(
              target: record.ModelScope("p", "m", "anthropic-messages"),
              profile_id: case request.profile {
                None -> None
                Some(p) -> Some(profile.fields(p).0)
              },
              usage: storage.empty_usage(),
              turns: 1,
              tool_executions: 1,
              output: "tests passed",
              progress: rollout.Finished,
              composition_digests: [
                "0000000000000000000000000000000000000000000000000000000000000000",
              ],
              unreported: rollout.Unreported(0, 0.0),
            ))
          },
          score: fn(criterion) {
            assert criterion == "fixture-test-v1"
            Ok(trace.Succeeded)
          },
          close: retirement.repeat(fn() {
            process.send(closed, request.task.id)
            Ok(Nil)
          }),
          cleanup: fn() { Ok(Nil) },
        ),
      )
    },
  )
}

pub fn immutable_profile_pin_and_changed_text_evidence_test() {
  let first = candidate("Use real tools.")
  let second = candidate("Use real tools and inspect failures.")
  assert first.id != second.id
  let assert Ok(profile) = prompt.candidate_profile(first)
    as "exact candidate decodes"
  assert prompt.decode_map(prompt.encode_map([profile])) == Ok([profile])
  let base =
    model.ProviderRequest(
      model.ForResolved(target()),
      Some("required policy"),
      [],
      [model.ToolSpec("code_mode", "generated signatures", json.Object([]))],
      None,
    )
  let #(_, composed) =
    profile.apply([profile], target(), "anthropic-messages", base)
  assert prompt.fingerprint(composed.system, composed.tools)
    != prompt.fingerprint(base.system, base.tools)
  assert composed.tools
    == [
      model.ToolSpec(
        "code_mode",
        "generated signatures\n\nVerify the result.",
        json.Object([]),
      ),
    ]
  let edited_scope =
    record.Candidate(
      ..first,
      scope: record.ExactModel(record.ModelScope(
        "other",
        "m",
        "anthropic-messages",
      )),
    )
  assert prompt.candidate_profile(edited_scope)
    == Error("prompt.json does not match its approved exact model scope")
}

pub fn scripted_rollouts_are_paired_and_never_quality_evidence_test() {
  let catalogue = opened()
  let proposed = candidate("Check results.")
  let assert Ok(_) = store.propose(catalogue, proposed)
    as "candidate is retained"
  let openings = process.new_subject()
  let closings = process.new_subject()
  let assert Ok(evidence) =
    rollout.evaluate(
      catalogue,
      proposed.id,
      target(),
      "anthropic-messages",
      [task()],
      limits(),
      scripted(openings, closings),
    )
    as "paired evidence is durable"
  assert evidence.purpose == record.IndependentRollout
  let assert record.Inconclusive(reason) = evidence.verdict
    as "scripted evidence cannot measure quality"
  assert string.contains(reason, "scripted")
  let assert Ok(base) = process.receive(openings, within: 1000)
    as "base runtime was fresh"
  let assert Ok(changed) = process.receive(openings, within: 1000)
    as "candidate runtime was fresh"
  assert base.target == model.ForResolved(target()) && base.profile == None
  assert changed.profile != None && changed.task == base.task
  assert process.receive(closings, within: 1000) == Ok(task().id)
  assert process.receive(closings, within: 1000) == Ok(task().id)
  let assert Error(store.TestFailed(_)) =
    store.approve(
      catalogue,
      proposed.id,
      evidence.id,
      proposed.scope,
      "operator",
    )
    as "scripted quality evidence cannot approve a profile"
}

pub fn budget_exhaustion_retains_partial_trials_and_teardown_test() {
  let catalogue = opened()
  let proposed = candidate("Check results.")
  let assert Ok(_) = store.propose(catalogue, proposed)
    as "candidate is retained"
  let openings = process.new_subject()
  let closings = process.new_subject()
  let native = scripted(openings, closings)
  let native = rollout.Callbacks(..native, mode: rollout.LiveProduction)
  let assert Ok(evidence) =
    rollout.evaluate(
      catalogue,
      proposed.id,
      target(),
      "anthropic-messages",
      [task()],
      rollout.Limits(..limits(), trials: 1),
      native,
    )
    as "partial evidence is durable"
  let assert record.Inconclusive(reason) = evidence.verdict
    as "incomplete pair cannot pass"
  assert string.contains(reason, "budget")
  assert string.contains(evidence.observation, "repair-v1")
    && string.contains(evidence.observation, "tests passed")
  assert process.receive(closings, within: 1000) == Ok(task().id)
  let assert Ok(_) = process.receive(openings, within: 1000)
    as "baseline opened"
  assert process.receive(openings, within: 0) == Error(Nil)
}

pub fn missing_tool_execution_and_outcome_never_pass_test() {
  let catalogue = opened()
  let proposed = candidate("Check results.")
  let assert Ok(_) = store.propose(catalogue, proposed)
    as "candidate is retained"
  let native =
    rollout.Callbacks(
      clock: clock.fixed(1),
      mode: rollout.LiveProduction,
      open: fn(_) {
        Ok(
          rollout.Trial(
            step: fn(_) {
              Ok(rollout.Step(
                record.ModelScope("p", "m", "anthropic-messages"),
                None,
                storage.empty_usage(),
                1,
                0,
                "I did the work.",
                rollout.Finished,
                [
                  "0000000000000000000000000000000000000000000000000000000000000000",
                ],
                rollout.Unreported(0, 0.0),
              ))
            },
            score: fn(_) {
              panic as "a direct answer must not reach independent scoring"
            },
            close: retirement.repeat(fn() { Ok(Nil) }),
            cleanup: fn() { Ok(Nil) },
          ),
        )
      },
    )
  let assert Ok(evidence) =
    rollout.evaluate(
      catalogue,
      proposed.id,
      target(),
      "anthropic-messages",
      [task()],
      limits(),
      native,
    )
    as "refusal evidence is durable"
  let assert record.Inconclusive(reason) = evidence.verdict
    as "no tools is inconclusive"
  assert string.contains(reason, "real coding tool")
}

pub fn secret_shaped_excerpt_is_scrubbed_before_clipping_test() {
  let secret = "sk-" <> string.repeat("abcdef", 30)
  let clipped = trace.scrub_excerpt("failed " <> secret <> " later", 25)
  assert clipped == "failed <redacted> later"
  assert !string.contains(clipped, "abcdef")
  assert trace.scrub_excerpt("ordinary private prose can remain", 10)
    == "ordinary p"
}

pub fn trace_joins_actual_identity_usage_and_missing_outcomes_test() {
  let assert Ok(source) = session.open_memory(clock.fixed(1000))
    as "source session opens"
  let assert Ok(#(session_id, generator)) =
    session.ensure_id(source, ids.generator(clock.fixed(1000), seed: 9))
    as "source identity is durable"
  let #(id, generator) = ids.mint_entry(generator)
  let #(usage_id, generator) = ids.mint_usage(generator)
  let #(foreign_id, _) = ids.mint_entry(generator)
  let usage =
    message.Usage(..storage.empty_usage(), input: 5, output: 2, total_tokens: 7)
  let answer =
    message.AssistantMessage(
      content: [
        message.AssistantThinking("private reasoning", None, False),
        message.AssistantText("answer sk-secret-value", None),
        message.AssistantToolCall(message.ToolCall(
          "call",
          "fs_read",
          json.Object([#("password", json.String("tiny"))]),
          None,
          None,
        )),
      ],
      api: "anthropic-messages",
      provider: "p",
      model: "m",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage:,
      stop_reason: message.Stop,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: Some(True),
      timestamp: 1000,
    )
  let row = entry.MessageEntry(id, None, 0, 0, answer, False)
  let ledger = entry.UsageRow(usage_id, 0, Some(id), False, usage, None)
  let assert Ok(_) =
    storage.commit(
      source.store,
      tx.Tx(
        [
          tx.InsertEntry(row),
          tx.InsertUsage(ledger),
          tx.InsertEntry(entry.MessageEntry(
            foreign_id,
            None,
            0,
            1,
            message.AssistantMessage(..answer, provider: "q", model: "foreign"),
            False,
          )),
          tx.SetRegister(
            register.StrandLeaf,
            "main",
            register.leaf_value(Some(id)),
          ),
        ],
        [],
      ),
    )
    as "source and ledger commit"
  trace.actual_model(
    source,
    "main",
    record.ModelScope("q", "requested", "openai-responses"),
  )
  |> should.equal(Ok(record.ModelScope("p", "m", "anthropic-messages")))
  let assert Ok(brief) =
    trace.select(
      source,
      record.ModelScope("p", "m", "anthropic-messages"),
      trace.Bounds(64, 256, 8, 1024, 16_384),
    )
    as "bounded real source scan succeeds"
  let assert [excerpt] = brief.excerpts as "only actual model identity matches"
  assert excerpt.session_id == ids.session_id_to_string(session_id)
  assert excerpt.entry_id == id
    && excerpt.usage == Some(usage)
    && excerpt.outcome == trace.Unmarked
  assert !string.contains(excerpt.text, "private reasoning")
    && !string.contains(excerpt.text, "tiny")
  assert string.contains(excerpt.text, "<redacted>")
  let assert Ok(foreign) =
    trace.select(
      source,
      record.ModelScope("p", "other", "anthropic-messages"),
      trace.Bounds(64, 256, 8, 1024, 16_384),
    )
    as "foreign model scan is valid"
  assert foreign.excerpts == []
  let assert Ok(Nil) = session.close(source) as "source actor retires"
}

pub fn independent_score_runs_only_after_witnessed_native_retirement_test() {
  let catalogue = opened()
  let proposed = candidate("Check results.")
  let assert Ok(_) = store.propose(catalogue, proposed) as "candidate retained"
  let retired = process.new_subject()
  let scored = process.new_subject()
  let native =
    rollout.Callbacks(
      clock: clock.fixed(1),
      mode: rollout.ScriptedLifecycle,
      open: fn(request) {
        Ok(
          rollout.Trial(
            step: fn(_) {
              Ok(rollout.Step(
                record.ModelScope("p", "m", "anthropic-messages"),
                case request.profile {
                  None -> None
                  Some(p) -> Some(profile.fields(p).0)
                },
                storage.empty_usage(),
                1,
                1,
                "finished",
                rollout.Finished,
                [
                  "0000000000000000000000000000000000000000000000000000000000000000",
                ],
                rollout.Unreported(0, 0.0),
              ))
            },
            close: retirement.repeat(fn() {
              process.send(retired, Nil)
              Ok(Nil)
            }),
            score: fn(_) {
              process.receive(retired, 0) |> should.equal(Ok(Nil))
              process.send(scored, Nil)
              Ok(trace.Succeeded)
            },
            cleanup: fn() {
              process.receive(scored, 0) |> should.equal(Ok(Nil))
              Ok(Nil)
            },
          ),
        )
      },
    )
  rollout.evaluate(
    catalogue,
    proposed.id,
    target(),
    "anthropic-messages",
    [task()],
    limits(),
    native,
  )
  |> result.is_ok
  |> should.be_true
  process.receive(retired, 0) |> should.equal(Error(Nil))
}

pub fn unconfirmed_close_retains_witness_and_durable_inconclusive_evidence_test() {
  let catalogue = opened()
  let proposed = candidate("Check results.")
  let assert Ok(_) = store.propose(catalogue, proposed) as "candidate retained"
  let openings = process.new_subject()
  let closings = process.new_subject()
  let first_close = process.new_subject()
  process.send(first_close, Nil)
  let base = scripted(openings, closings)
  let native =
    rollout.Callbacks(..base, open: fn(request) {
      let assert Ok(trial) = base.open(request) as "scripted trial opens"
      Ok(
        rollout.Trial(
          ..trial,
          close: retirement.repeat(fn() {
            case process.receive(first_close, 0) {
              Ok(Nil) -> Error("native retirement withheld")
              Error(Nil) -> Ok(Nil)
            }
          }),
          score: fn(_) {
            panic as "retirement refusal must prevent independent scoring"
          },
        ),
      )
    })
  let assert Error(store.CleanupUnconfirmed(reason, retire)) =
    rollout.evaluate(
      catalogue,
      proposed.id,
      target(),
      "anthropic-messages",
      [task()],
      limits(),
      native,
    )
    as "unconfirmed native witness returns to custody owner"
  let assert Ok(evidence_text) =
    string.split(reason, "evidence_id=") |> list.last
    as "partial evidence address is retained"
  let assert Ok(evidence_id) = record.evidence_id(evidence_text)
    as "native evidence address parses"
  let assert Ok(evidence) = store.read_evidence(catalogue, evidence_id)
    as "partial evidence committed before refusal"
  let assert record.Inconclusive(_) = evidence.verdict
    as "unconfirmed close is inconclusive"
  retirement.perform(retire) |> should.equal(Ok(Nil))
  process.receive(openings, 1000) |> result.is_ok |> should.be_true
  process.receive(openings, 0) |> should.equal(Error(Nil))
}

pub fn unknown_attempt_spend_is_not_refunded_before_the_next_trial_arm_test() {
  list.each(
    [rollout.Unreported(10_000, 0.0), rollout.Unreported(0, 1.0)],
    fn(debit) {
      let catalogue = opened()
      let proposed = candidate("Carry unknown spend.")
      let assert Ok(_) = store.propose(catalogue, proposed)
        as "candidate retained"
      let openings = process.new_subject()
      let closings = process.new_subject()
      let base = scripted(openings, closings)
      let native =
        rollout.Callbacks(..base, open: fn(request) {
          let assert Ok(trial) = base.open(request) as "baseline opens"
          Ok(
            rollout.Trial(..trial, step: fn(allowance) {
              trial.step(allowance)
              |> result.map(fn(step) { rollout.Step(..step, unreported: debit) })
            }),
          )
        })
      let assert Ok(evidence) =
        rollout.evaluate(
          catalogue,
          proposed.id,
          target(),
          "anthropic-messages",
          [task()],
          limits(),
          native,
        )
        as "uncertain baseline spend is durably retained"
      let assert record.Inconclusive(_) = evidence.verdict
        as "comparison cannot continue"
      let assert Ok(json.Object(fields)) = json.parse(evidence.observation)
        as "evidence parses"
      assert list.key_find(fields, "partial_reason")
        == Ok(json.String("aggregate rollout budget exhausted"))
      let assert Ok(json.Object(unknown)) = list.key_find(fields, "unreported")
        as "uncertain spend remains a separate native debit"
      assert list.key_find(unknown, "tokens") == Ok(json.Int(debit.tokens))
        && list.key_find(unknown, "dollars") == Ok(json.Float(debit.dollars))
      process.receive(openings, 0) |> result.is_ok |> should.be_true
      process.receive(openings, 0) |> should.equal(Error(Nil))
      process.receive(closings, 0) |> should.equal(Ok(task().id))
    },
  )
}

pub fn unknown_native_attempts_retain_reservation_despite_foreign_or_synthetic_usage_test() {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(1), seed: 123))
  let answer =
    message.AssistantMessage(
      content: [message.AssistantText("settled", None)],
      api: "anthropic-messages",
      provider: "p",
      model: "m",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: message.Usage(
        ..storage.empty_usage(),
        input: 5,
        output: 2,
        total_tokens: 7,
      ),
      stop_reason: message.Stop,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: Some(True),
      timestamp: 1,
    )
  let entries = [
    entry.MessageEntry(id, None, 0, 0, answer, False),
    entry.MessageEntry(
      id,
      None,
      0,
      0,
      message.AssistantMessage(
        ..answer,
        api: "unknown",
        usage: storage.empty_usage(),
        stop_reason: message.Errored,
      ),
      False,
    ),
    entry.MessageEntry(
      id,
      None,
      0,
      0,
      message.AssistantMessage(..answer, provider: "foreign"),
      False,
    ),
  ]
  let debit =
    rollout_host.unreported_debit(
      3,
      target(),
      "anthropic-messages",
      entries,
      pricing.Pricing(1.0, 1.0, 1.0, 1.0),
    )
  assert debit.tokens == 6200
    && debit.dollars >=. 0.006
    && debit.dollars <=. 0.0063
    as "only exact complete native usage releases an uncertain attempt reservation"
}
