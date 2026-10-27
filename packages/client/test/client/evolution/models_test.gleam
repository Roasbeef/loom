//// Prompt evidence and rollout admission are verified independently of quality.
//// All providers here are scripted; the verdict must retain that limitation.

import broker/token
import client/evolution/prompt
import client/evolution/record
import client/evolution/record_test
import client/evolution/retirement
import client/evolution/rollout
import client/evolution/store
import client/evolution/trace
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/register
import core/tx
import core/usage_evidence
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import provider/model
import provider/profile.{type Profile}
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
  rollout.Limits(2, 8, 10_000, 1.0, 10_000, 10_000, 1)
}

fn graded(reward: Float) -> rollout.Grade {
  rollout.Grade(reward, [], "", rollout.ExpectedFiles)
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
            Ok(graded(1.0))
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
      rollout.Limits(..limits(), turns: 1),
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
  // Nonzero counts need provider-reported evidence: the codec refuses a
  // no-provider usage that claims consumption, so the fixture must say where
  // its numbers came from.
  let usage =
    message.Usage(
      ..storage.empty_usage(),
      input: 5,
      output: 2,
      total_tokens: 7,
      evidence: usage_evidence.reported(usage_evidence.Other),
    )
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
              Ok(graded(1.0))
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

// The paired fold's one generalisation: K samples per task per arm through
// the same budget. Both arms of every sample must appear, in budget order, and
// every debit must scale with the sample count rather than with the task count.
pub fn samples_double_the_trial_reports_and_the_budget_debits_test() {
  let once = sampled(1)
  let twice = sampled(2)
  assert list.length(once.reports) == 2 && list.length(twice.reports) == 4
    as "each sample adds one base and one candidate report"
  assert twice.trials == 2 * once.trials
    && twice.turns == 2 * once.turns
    && twice.tokens == 2 * once.tokens
    as "the budget debits double with the samples"
  assert once.openings == [None, Some("a")]
    as "one sample pairs base then candidate"
  assert twice.openings == [None, Some("a"), None, Some("a")]
    as "each sample pairs base then candidate in budget order"
  assert list.map(once.reports, sample_of) == [1, 1]
    && list.map(twice.reports, sample_of) == [1, 1, 2, 2]
    as "every report names its sample index"
}

type Sampled {
  Sampled(
    reports: List(json.JsonValue),
    trials: Int,
    turns: Int,
    tokens: Int,
    openings: List(Option(String)),
  )
}

fn sampled(samples: Int) -> Sampled {
  let catalogue = opened()
  let proposed = candidate("Sample twice.")
  let assert Ok(_) = store.propose(catalogue, proposed) as "candidate retained"
  let openings = process.new_subject()
  let closings = process.new_subject()
  let base = scripted(openings, closings)
  let native =
    rollout.Callbacks(..base, open: fn(request) {
      let assert Ok(trial) = base.open(request) as "scripted trial opens"
      Ok(
        rollout.Trial(..trial, step: fn(allowance) {
          trial.step(allowance)
          |> result.map(fn(step) {
            rollout.Step(
              ..step,
              usage: message.Usage(..storage.empty_usage(), input: 10),
            )
          })
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
      rollout.Limits(..limits(), trials: 4, samples:),
      native,
    )
    as "sampled evidence is durable"
  let assert Ok(observation) = json.parse(evidence.observation)
    as "observation parses"
  let assert json.Array(reports) = member(observation, "trials")
    as "reports are an array"
  let used = member(observation, "used")
  let assert json.Int(trials) = member(used, "trials") as "trials counted"
  let assert json.Int(turns) = member(used, "turns") as "turns counted"
  let assert json.Int(tokens) = member(used, "tokens") as "tokens counted"
  assert member(member(observation, "limits"), "samples") == json.Int(samples)
    as "the observation records the sample count it ran under"
  let opened_arms =
    list.map(drain(openings, []), fn(request) {
      option.map(request.profile, fn(p) { profile.fields(p).0 })
    })
    |> list.map(option.map(_, fn(_) { "a" }))
  Sampled(reports:, trials:, turns:, tokens:, openings: opened_arms)
}

fn drain(subject: process.Subject(a), collected: List(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(item) -> drain(subject, [item, ..collected])
    Error(Nil) -> list.reverse(collected)
  }
}

fn sample_of(report: json.JsonValue) -> Int {
  let assert json.Int(sample) = member(report, "sample") as "sample is an int"
  sample
}

fn member(value: json.JsonValue, name: String) -> json.JsonValue {
  let assert json.Object(fields) = value as "observation member is an object"
  let assert Ok(found) = list.key_find(fields, name) as name
  found
}

// One task cannot decide under the paired rule whichever way its grade
// falls: the statistic needs at least two tasks to see any spread, so the
// verdict says it is underpowered. A grade the verifier could not have
// produced is a defect that stops the comparison before the rule is asked.
pub fn a_single_task_is_underpowered_and_an_out_of_range_grade_is_a_defect_test() {
  let assert record.Inconclusive(reason) = graded_verdict(0.0).verdict
    as "one failing candidate task cannot decide"
  assert string.starts_with(reason, "underpowered: fewer than two tasks")
    as reason
  let assert record.Inconclusive(reason) = graded_verdict(1.0).verdict
    as "one passing candidate task cannot decide"
  assert string.starts_with(reason, "underpowered: fewer than two tasks")
    as reason
  let assert record.Inconclusive(reason) = graded_verdict(1.5).verdict
    as "an out-of-range reward is a verifier defect"
  assert string.contains(reason, "out of range")
  let assert record.Inconclusive(reason) = graded_verdict(-0.5).verdict
    as "a negative reward is a verifier defect"
  assert string.contains(reason, "out of range")
}

// Every grade member is bounded before it is retained, and a defect ends the
// comparison Inconclusive with its own reason while the partial observation
// still commits: a duplicate score name would otherwise corrupt the canonical
// JSON after the whole budget was spent.
pub fn grade_members_outside_their_bounds_stop_the_comparison_with_a_named_reason_test() {
  let program = rollout.ProgramRun(["bash", "verify.sh"], 0, 10)
  let cases = [
    #(
      rollout.Grade(1.0, [#("tests", 1.0), #("tests", 0.5)], "", program),
      "names repeat",
    ),
    #(rollout.Grade(1.0, [#("", 1.0)], "", program), "empty or over 32 bytes"),
    #(
      rollout.Grade(1.0, [#(string.repeat("n", 33), 1.0)], "", program),
      "empty or over 32 bytes",
    ),
    #(
      rollout.Grade(
        1.0,
        list.index_map(list.repeat(1.0, 9), fn(value, index) {
          #("s" <> int.to_string(index), value)
        }),
        "",
        program,
      ),
      "more than 8 scores",
    ),
    #(
      rollout.Grade(1.0, [#("tests", 1.5)], "", program),
      "score is out of range",
    ),
    #(
      rollout.Grade(1.0, [], "", rollout.ProgramRun(list.repeat("x", 9), 0, 10)),
      "more than 8 entries",
    ),
    #(
      rollout.Grade(
        1.0,
        [],
        "",
        rollout.ProgramRun([string.repeat("x", 513)], 0, 10),
      ),
      "exceeds 512 bytes",
    ),
  ]
  list.each(cases, fn(case_) {
    let evidence = graded_with(case_.0)
    let assert record.Inconclusive(reason) = evidence.verdict
      as "a defective grade cannot decide"
    assert string.contains(reason, case_.1) as reason
    let assert Ok(observation) = json.parse(evidence.observation)
      as "the partial observation still commits"
    assert member(observation, "partial_reason") == json.String(reason)
  })

  // A grade at every bound is admitted and retained whole.
  let full =
    rollout.Grade(
      1.0,
      list.index_map(list.repeat(1.0, 8), fn(value, index) {
        #(string.repeat("n", 31) <> int.to_string(index), value)
      }),
      "",
      rollout.ProgramRun(list.repeat(string.repeat("x", 64), 8), 0, 10),
    )
  let evidence = graded_with(full)
  let assert Ok(observation) = json.parse(evidence.observation)
    as "observation parses"
  assert member(observation, "partial_reason") == json.Null
    as "a grade at its bounds is admitted and the fold runs to its end"
}

// Side information is kept in bytes, so a multibyte text cannot carry four
// kilobytes under a grapheme count, and it is cut between graphemes.
pub fn side_info_is_clipped_to_a_kibibyte_of_whole_graphemes_test() {
  let text = string.repeat("é", 2000)
  let evidence =
    graded_with(rollout.Grade(0.0, [], text, rollout.ExpectedFiles))
  let assert Ok(observation) = json.parse(evidence.observation)
    as "observation parses"
  let assert json.Array([_, changed]) = member(observation, "trials")
    as "one pair"
  let assert json.String(kept) = member(member(changed, "grade"), "side_info")
    as "side_info is text"
  let size = bit_array.byte_size(bit_array.from_string(kept))
  assert size <= 1024 && size >= 1023 as "clipped to the byte bound"
  assert kept == string.repeat("é", 512) as "cut between whole graphemes"
}

// Live mode with two samples: the plan is one task times two samples per
// arm, every report pairs by its sample, and one task is still one cluster.
// Neither two passing samples nor a candidate that fails one of them can
// decide, and in particular the failed sample is no longer a `Failed` on its
// own; a plan that paired incompletely would say so instead of underpowered.
pub fn live_samples_pair_per_sample_and_one_task_never_decides_test() {
  let assert record.Inconclusive(reason) = live_sampled([1.0, 1.0]).verdict
    as "two passing samples of one task cannot decide"
  assert string.starts_with(reason, "underpowered: fewer than two tasks")
    as reason
  let assert record.Inconclusive(reason) = live_sampled([1.0, 0.0]).verdict
    as "one failing candidate sample no longer fails the comparison"
  assert string.starts_with(reason, "underpowered: fewer than two tasks")
    as reason
}

// Identical arms: every task passes on both sides, so there is no spread
// between tasks and the rule cannot see any effect. The verdict is
// Inconclusive as underpowered, never Passed and never Failed.
pub fn aa_comparison_is_inconclusive_test() {
  let evidence = live_over(tasks(3), fn(_, _) { 1.0 }, 1)
  let assert record.Inconclusive(reason) = evidence.verdict
    as "identical arms cannot demonstrate an improvement"
  assert string.starts_with(reason, "underpowered: no spread between tasks")
    as reason
  let assert Ok(observation) = json.parse(evidence.observation)
    as "observation parses"
  assert member(observation, "partial_reason") == json.Null
    as "the fold ran to its end; the rule, not a stop, was inconclusive"
}

// The base passes every task and the candidate fails all but one: nine
// tasks move against it and one ties, which is the spread a clustered
// interval needs. At ten tasks the governed path is powered to call that
// a demonstrated harm, and a demonstrated harm is Failed.
pub fn planted_harm_is_failed_test() {
  let evidence =
    live_over(tasks(10), fn(task, arm) { harm_reward(task, arm) }, 1)
  assert evidence.verdict == record.Failed as "a demonstrated harm is refused"
}

// The mirror of the planted harm: the base fails nine tasks and ties one,
// and the candidate passes them all. A demonstrated improvement is the one
// verdict that reads Passed.
pub fn baseline_fails_candidate_passes_is_passed_test() {
  let evidence =
    live_over(tasks(10), fn(task, arm) { improvement_reward(task, arm) }, 1)
  assert evidence.verdict == record.Passed
    as "a demonstrated improvement passes"
}

// The old rule failed a candidate for any one failed trial and ignored the
// base. Four tasks where the base fails three and the candidate fails one
// favour the candidate three tasks to one, which four tasks cannot make
// significant: the single candidate failure decides nothing by itself.
pub fn single_candidate_failure_no_longer_decides_test() {
  let evidence =
    live_over(
      tasks(4),
      fn(task, arm) {
        case task, arm {
          "task-4", Some(_) -> 0.0
          "task-4", None -> 1.0
          _, Some(_) -> 1.0
          _, None -> 0.0
        }
      },
      1,
    )
  let assert record.Inconclusive(reason) = evidence.verdict
    as "one candidate failure against three base failures cannot decide"
  assert string.starts_with(reason, "underpowered:") as reason
  assert string.contains(reason, "tasks would have sufficed") as reason
}

// The plan, not the reports, is the denominator: rows for two of three
// planned tasks are an incomplete comparison naming the missing row, never a
// smaller comparison over the rows that exist.
pub fn expected_rows_come_from_the_plan_test() {
  let graded = fn(task, arm, reward) {
    rollout.Row(task, 1, arm, Some(graded(reward)))
  }
  let rows = [
    graded("a", rollout.Base, 0.0),
    graded("a", rollout.Candidate, 1.0),
    graded("b", rollout.Base, 0.0),
    graded("b", rollout.Candidate, 1.0),
  ]
  assert rollout.decide(rows, ["a", "b", "c"], 1)
    == record.Inconclusive(
      "paired task set is incomplete: plan row (c, 0) has no trial on arm base",
    )
  assert rollout.decide(rows, ["a", "b"], 2)
    == record.Inconclusive(
      "paired task set is incomplete: plan row (a, 1) has no trial on arm base",
    )

  // A row the fold never graded is not evidence either way: it is reported
  // missing rather than counted or excluded.
  let ungraded = [rollout.Row("b", 1, rollout.Candidate, None), ..rows]
  assert rollout.decide(list.take(ungraded, 4), ["a", "b"], 1)
    == record.Inconclusive(
      "paired task set is incomplete: plan row (b, 0) has no trial on arm candidate",
    )
}

// A tie the design could have broken is Failed, not Passed: a hundred tasks
// at three samples, the candidate dropping one sample on two of them, has a
// minimum detectable effect under the ten-point target and no significant
// direction. The governed door caps a comparison at ten tasks, so this
// shape cannot reach `evaluate`; the rows are built directly for `decide`.
pub fn powered_tie_is_failed_test() {
  let names =
    list.index_map(list.repeat(Nil, 100), fn(_, index) {
      "task-" <> string.pad_start(int.to_string(index + 1), 3, "0")
    })
  let rows =
    list.flat_map(names, fn(task) {
      list.flat_map([1, 2, 3], fn(sample) {
        let dropped =
          { task == "task-001" || task == "task-002" } && sample == 1
        [
          rollout.Row(task, sample, rollout.Base, Some(graded(1.0))),
          rollout.Row(
            task,
            sample,
            rollout.Candidate,
            Some(
              graded(case dropped {
                True -> 0.0
                False -> 1.0
              }),
            ),
          ),
        ]
      })
    })
  assert rollout.decide(rows, names, 3) == record.Failed
    as "a powered tie earns no selection"
}

// The smallest plan the prompt acceptance fixture could run to a Passed:
// seven tasks at one sample, the base failing six and tying one, the
// candidate passing all. Six tasks in one direction is the smallest sign
// test under alpha (p = 2 / 64), and the tie is the spread the interval
// needs. The rows here are exactly the reports such a run retains, so the
// fixture's arithmetic is proven without its jail.
pub fn prompt_acceptance_plan_of_seven_tasks_is_a_demonstrated_improvement_test() {
  assert rollout.decide(acceptance_rows(7, 1), acceptance_names(7), 1)
    == record.Passed
    as "six wins and one tie over seven tasks is Improved"
}

// Why the door's turn ceiling had to move (protocol-change/100): under its
// old twenty turns a two-turn trial admitted at most five tasks, and no
// five-task shape is powered. Five wins have no spread, and four wins with a
// tie reach only p = 0.125, so a Passed was unreachable through the door.
pub fn five_tasks_cannot_be_a_demonstrated_improvement_test() {
  let assert record.Inconclusive(reason) =
    rollout.decide(acceptance_rows(5, 0), acceptance_names(5), 1)
    as "five wins with no tie have no spread"
  assert string.starts_with(reason, "underpowered: no spread") as reason
  let assert record.Inconclusive(reason) =
    rollout.decide(acceptance_rows(5, 1), acceptance_names(5), 1)
    as "four wins and a tie are not significant"
  assert string.starts_with(reason, "underpowered: minimum detectable")
    as reason
}

fn acceptance_names(count: Int) -> List(String) {
  list.index_map(list.repeat(Nil, count), fn(_, index) {
    "independent-file-" <> int.to_string(index + 1)
  })
}

// The base fails every task but the last `ties`, which it passes as the
// candidate does; the candidate passes every task.
fn acceptance_rows(count: Int, ties: Int) -> List(rollout.Row) {
  list.index_map(acceptance_names(count), fn(task, index) {
    let base_reward = case index >= count - ties {
      True -> 1.0
      False -> 0.0
    }
    [
      rollout.Row(task, 1, rollout.Base, Some(graded(base_reward))),
      rollout.Row(task, 1, rollout.Candidate, Some(graded(1.0))),
    ]
  })
  |> list.flatten
}

fn tasks(count: Int) -> List(rollout.Task) {
  list.index_map(list.repeat(Nil, count), fn(_, index) {
    rollout.Task(
      ..task(),
      id: "task-" <> int.to_string(index + 1),
      fixture: "fixture-" <> int.to_string(index + 1),
    )
  })
}

// Nine tasks the candidate loses and one tie: the base passes everything.
fn harm_reward(task: String, arm: Option(Profile)) -> Float {
  case task, arm {
    _, None -> 1.0
    "task-10", Some(_) -> 1.0
    _, Some(_) -> 0.0
  }
}

// Nine tasks the candidate wins and one tie: the candidate passes everything.
fn improvement_reward(task: String, arm: Option(Profile)) -> Float {
  case task, arm {
    _, Some(_) -> 1.0
    "task-10", None -> 1.0
    _, None -> 0.0
  }
}

// Runs the governed fold in live mode over `tasks`, grading every
// (task, arm) with `reward`, under a budget wide enough for twenty trials.
fn live_over(
  tasks: List(rollout.Task),
  reward: fn(String, Option(Profile)) -> Float,
  samples: Int,
) -> record.Evidence {
  let catalogue = opened()
  let proposed = candidate("Compare over many tasks.")
  let assert Ok(_) = store.propose(catalogue, proposed) as "candidate retained"
  let openings = process.new_subject()
  let closings = process.new_subject()
  let base = scripted(openings, closings)
  let native =
    rollout.Callbacks(..base, mode: rollout.LiveProduction, open: fn(request) {
      let assert Ok(trial) = base.open(request) as "scripted trial opens"
      Ok(
        rollout.Trial(..trial, score: fn(_) {
          Ok(graded(reward(request.task.id, request.profile)))
        }),
      )
    })
  let assert Ok(evidence) =
    rollout.evaluate(
      catalogue,
      proposed.id,
      target(),
      "anthropic-messages",
      tasks,
      rollout.Limits(..limits(), trials: 20, turns: 100, samples:),
      native,
    )
    as "live evidence over many tasks is durable"
  evidence
}

// A sample count the trial budget cannot pair is refused before any trial
// opens, naming the product, instead of spending the budget on a comparison
// that can only end Inconclusive.
pub fn a_sample_count_the_trial_budget_cannot_pair_is_refused_before_any_trial_opens_test() {
  let catalogue = opened()
  let proposed = candidate("Pair me.")
  let assert Ok(_) = store.propose(catalogue, proposed) as "candidate retained"
  let openings = process.new_subject()
  let closings = process.new_subject()
  let assert Error(store.Bounds(reason)) =
    rollout.evaluate(
      catalogue,
      proposed.id,
      target(),
      "anthropic-messages",
      [task()],
      rollout.Limits(..limits(), trials: 3, samples: 2),
      scripted(openings, closings),
    )
    as "an unpairable sample count is refused"
  assert string.contains(reason, "needs 4 trials")
    && string.contains(reason, "admits 3")
    as reason
  assert process.receive(openings, 0) == Error(Nil) as "no trial opened"
}

fn live_sampled(candidate_rewards: List(Float)) -> record.Evidence {
  let catalogue = opened()
  let proposed = candidate("Sample live.")
  let assert Ok(_) = store.propose(catalogue, proposed) as "candidate retained"
  let openings = process.new_subject()
  let closings = process.new_subject()
  let rewards = process.new_subject()
  list.each(candidate_rewards, process.send(rewards, _))
  let base = scripted(openings, closings)
  let native =
    rollout.Callbacks(..base, mode: rollout.LiveProduction, open: fn(request) {
      let assert Ok(trial) = base.open(request) as "scripted trial opens"
      Ok(
        rollout.Trial(..trial, score: fn(_) {
          case request.profile {
            None -> Ok(graded(1.0))
            Some(_) -> {
              let assert Ok(reward) = process.receive(rewards, 0)
                as "one candidate reward per sample"
              Ok(graded(reward))
            }
          }
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
      rollout.Limits(..limits(), trials: 4, samples: 2),
      native,
    )
    as "sampled live evidence is durable"
  evidence
}

// Every retained report carries the grade and the sample beside the projected
// outcome word, and the projection agrees with the grade.
pub fn reports_carry_grade_and_sample_beside_the_outcome_projection_test() {
  let evidence = graded_verdict(0.0)
  let assert Ok(observation) = json.parse(evidence.observation)
    as "observation parses"
  let assert json.Array([base, changed]) = member(observation, "trials")
    as "one task yields one pair"
  assert member(base, "outcome") == json.String("succeeded")
    && member(changed, "outcome") == json.String("failed")
  assert member(member(changed, "grade"), "reward") == json.Float(0.0)
    && member(member(base, "grade"), "reward") == json.Float(1.0)
  assert member(member(changed, "grade"), "side_info")
    == json.String("expected file differs: out/result.txt")
  assert member(member(member(changed, "grade"), "verifier"), "kind")
    == json.String("expected-files")
  assert member(base, "sample") == json.Int(1)
    && member(changed, "sample") == json.Int(1)
}

fn graded_verdict(candidate_reward: Float) -> record.Evidence {
  graded_with(rollout.Grade(
    candidate_reward,
    [],
    "expected file differs: out/result.txt",
    rollout.ExpectedFiles,
  ))
}

fn graded_with(candidate_grade: rollout.Grade) -> record.Evidence {
  let catalogue = opened()
  let proposed = candidate("Grade me.")
  let assert Ok(_) = store.propose(catalogue, proposed) as "candidate retained"
  let openings = process.new_subject()
  let closings = process.new_subject()
  let base = scripted(openings, closings)
  let native =
    rollout.Callbacks(..base, mode: rollout.LiveProduction, open: fn(request) {
      let assert Ok(trial) = base.open(request) as "scripted trial opens"
      Ok(
        rollout.Trial(..trial, score: fn(_) {
          case request.profile {
            None -> Ok(graded(1.0))
            Some(_) -> Ok(candidate_grade)
          }
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
    as "graded evidence is durable"
  evidence
}
