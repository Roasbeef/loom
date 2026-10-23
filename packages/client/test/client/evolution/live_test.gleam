//// Generation tests observe ordering and withheld custody rather than reports.

import client/evolution/live
import client/evolution/record
import client/evolution/record_test
import client/evolution/retirement
import client/evolution/store
import client/internal/ffi_os
import core/clock
import core/json as core_json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should
import runtime/effects
import weft/poll

fn selection(generation: Int) -> record.Selection {
  let candidate = record_test.candidate()
  record.Selection(
    candidate.id,
    record.evidence_placeholder(),
    candidate.scope,
    candidate.name,
    generation,
  )
}

fn generation(
  selection: record.Selection,
  retire: fn() -> Result(Nil, String),
) -> live.Generation {
  live.Generation(
    mode: live.ReplacementOnly,
    selection:,
    tools: [],
    hooks: None,
    retire: retirement.repeat(retire),
    inventory: fn() { Ok(core_json.Null) },
    validate: fn() { Ok(Nil) },
  )
}

fn owner(
  stage: fn(record.Selection) -> Result(live.Generation, store.Refusal),
  adopt: fn(record.Selection) -> Result(Nil, store.Refusal),
) -> live.Live {
  let assert Ok(owner) =
    live.start(
      live.Config(clock: clock.fixed(0), stage:, adopt:, recover: fn() {
        Ok(None)
      }),
    )
    as "generation owner starts without native resources"
  owner
}

fn transition(
  selected: record.Selection,
  commit: fn() -> Result(record.Selection, store.Refusal),
) -> live.Transition {
  live.Transition(
    "request-" <> int.to_string(selected.generation),
    10_000,
    selected,
    commit,
    fn() { Ok(None) },
  )
}

pub fn predecessor_native_retirement_precedes_selection_and_audit_test() {
  let events = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        Ok(
          generation(selected, fn() {
            process.send(events, "retire")
            Ok(Nil)
          }),
        )
      },
      fn(_) {
        process.send(events, "audit")
        Ok(Nil)
      },
    )
  let first = selection(1)
  live.activate(owner, transition(first, fn() { Ok(first) }), 1000)
  |> should.equal(Ok(first))
  process.receive(events, 1000) |> should.equal(Ok("audit"))
  let next = selection(2)
  live.activate(
    owner,
    transition(next, fn() {
      process.send(events, "commit")
      Ok(next)
    }),
    1000,
  )
  |> should.equal(Ok(next))
  process.receive(events, 1000) |> should.equal(Ok("retire"))
  process.receive(events, 1000) |> should.equal(Ok("commit"))
  process.receive(events, 1000) |> should.equal(Ok("audit"))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}

pub fn unconfirmed_retirement_pins_custody_and_refuses_additional_staging_test() {
  let staged = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        process.send(staged, selected.generation)
        let retire = case selected.generation {
          1 -> fn() { Error("withheld native exit") }
          _ -> fn() { Ok(Nil) }
        }
        Ok(generation(selected, retire))
      },
      fn(_) { Ok(Nil) },
    )
  let first = selection(1)
  live.activate(owner, transition(first, fn() { Ok(first) }), 1000)
  |> should.equal(Ok(first))
  let next = selection(2)
  let refused = live.activate(owner, transition(next, fn() { Ok(next) }), 1000)
  case refused {
    Error(store.CleanupUnconfirmed(..)) -> Nil
    _ -> panic as "cleanup must refuse promotion"
  }
  live.activate(
    owner,
    transition(selection(3), fn() { Ok(selection(3)) }),
    1000,
  )
  |> result.is_error
  |> should.be_true
  process.receive(staged, 1000) |> should.equal(Ok(1))
  process.receive(staged, 1000) |> should.equal(Ok(2))
  process.receive(staged, 0) |> should.equal(Error(Nil))
}

pub fn failed_predecessor_has_one_owned_retirement_obligation_test() {
  let retired = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        Ok(
          generation(selected, fn() {
            process.send(retired, selected.generation)
            case selected.generation {
              1 -> Error("withheld predecessor exit")
              _ -> Ok(Nil)
            }
          }),
        )
      },
      fn(_) { Ok(Nil) },
    )
  let first = selection(1)
  live.activate(owner, transition(first, fn() { Ok(first) }), 1000)
  |> should.equal(Ok(first))
  let next = selection(2)
  live.activate(owner, transition(next, fn() { Ok(next) }), 1000)
  |> result.is_error
  |> should.be_true
  process.receive(retired, 1000) |> should.equal(Ok(1))
  process.receive(retired, 1000) |> should.equal(Ok(2))

  // Closing retries the held predecessor once. The prepared successor already
  // retired, and the predecessor's transported refusal is not another owner.
  live.close(owner, 1000) |> result.is_error |> should.be_true
  process.receive(retired, 1000) |> should.equal(Ok(1))
  process.receive(retired, 0) |> should.equal(Error(Nil))
}

pub fn expired_request_never_stages_or_commits_test() {
  let events = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        process.send(events, Nil)
        Ok(generation(selected, fn() { Ok(Nil) }))
      },
      fn(_) { Ok(Nil) },
    )
  let selected = selection(1)
  let expired =
    live.Transition(
      "expired",
      0,
      selected,
      fn() {
        process.send(events, Nil)
        Ok(selected)
      },
      fn() { Ok(None) },
    )
  live.activate(owner, expired, 1000) |> should.equal(Error(store.Busy))
  process.receive(events, 0) |> should.equal(Error(Nil))
}

pub fn failed_adoption_never_publishes_and_retires_staged_generation_test() {
  let retired = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        Ok(
          generation(selected, fn() {
            process.send(retired, Nil)
            Ok(Nil)
          }),
        )
      },
      fn(_) { Error(store.Unavailable("audit write failed")) },
    )
  let selected = selection(1)
  live.activate(owner, transition(selected, fn() { Ok(selected) }), 1000)
  |> result.is_error
  |> should.be_true
  process.receive(retired, 1000) |> should.equal(Ok(Nil))
  live.catalogue(owner)
  |> result.map(fn(active) {
    case active {
      None -> True
      Some(_) -> False
    }
  })
  |> should.equal(Ok(True))
}

pub fn uncertain_author_test_retirement_blocks_every_later_allocation_test() {
  let staged = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        process.send(staged, Nil)
        Ok(generation(selected, fn() { Ok(Nil) }))
      },
      fn(_) { Ok(Nil) },
    )
  live.evaluate(owner, fn() {
    Error(store.CleanupUnconfirmed(
      "held helper",
      retirement.repeat(fn() { Error("held") }),
    ))
  })
  |> result.is_error
  |> should.be_true
  let next = selection(1)
  live.activate(owner, transition(next, fn() { Ok(next) }), 1000)
  |> result.is_error
  |> should.be_true
  process.receive(staged, 0) |> should.equal(Error(Nil))
}

pub fn failed_selection_cas_rebuilds_committed_predecessor_before_return_test() {
  let events = process.new_subject()
  let first = selection(1)
  let assert Ok(owner) =
    live.start(
      live.Config(
        clock: clock.fixed(0),
        stage: fn(selected) {
          Ok(
            generation(selected, fn() {
              process.send(events, "retire")
              Ok(Nil)
            }),
          )
        },
        adopt: fn(_) { Ok(Nil) },
        recover: fn() {
          process.send(events, "recover")
          Ok(Some(generation(first, fn() { Ok(Nil) })))
        },
      ),
    )
    as "native generation owner starts"
  live.activate(owner, transition(first, fn() { Ok(first) }), 1000)
  |> should.equal(Ok(first))
  live.activate(
    owner,
    transition(selection(2), fn() { Error(store.Stale) }),
    1000,
  )
  |> should.equal(Error(store.Stale))
  process.receive(events, 1000) |> should.equal(Ok("retire"))
  process.receive(events, 1000) |> should.equal(Ok("retire"))
  process.receive(events, 1000) |> should.equal(Ok("recover"))
  live.catalogue(owner)
  |> result.map(fn(active) {
    option.map(active, fn(current) { current.selection.generation })
  })
  |> should.equal(Ok(Some(1)))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}

pub fn uncertain_prepare_retains_cleanup_witness_until_close_test() {
  let events = process.new_subject()
  let witness =
    retirement.repeat(fn() {
      process.send(events, "cleanup")
      Ok(Nil)
    })
  let owner =
    owner(
      fn(selected) {
        let base = generation(selected, fn() { Ok(Nil) })
        Ok(
          live.Generation(
            ..base,
            mode: live.Stateful(fn(_) {
              Error(store.CleanupUnconfirmed("pending prepare", witness))
            }),
          ),
        )
      },
      fn(_) { Ok(Nil) },
    )
  let first = selection(1)
  live.activate(owner, transition(first, fn() { Ok(first) }), 1000)
  |> should.equal(Ok(first))
  let next = selection(2)
  live.activate(owner, transition(next, fn() { Ok(next) }), 1000)
  |> result.is_error
  |> should.be_true
  live.close(owner, 1000) |> should.equal(Ok(Nil))
  process.receive(events, 1000) |> should.equal(Ok("cleanup"))
}

pub fn durable_receipt_after_commit_error_publishes_without_compensation_test() {
  let events = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        let base = generation(selected, fn() { Ok(Nil) })
        Ok(
          live.Generation(
            ..base,
            mode: live.Stateful(fn(next) {
              Ok(
                live.PreparedUpgrade(
                  generation(next, fn() { Ok(Nil) }),
                  fn() {
                    process.send(events, "publish")
                    Ok(Nil)
                  },
                  fn() {
                    process.send(events, "abort")
                    Ok(Nil)
                  },
                ),
              )
            }),
          ),
        )
      },
      fn(_) { Ok(Nil) },
    )
  let first = selection(1)
  live.activate(owner, transition(first, fn() { Ok(first) }), 1000)
  |> should.equal(Ok(first))
  let next = selection(2)
  let request =
    transition(next, fn() {
      Error(store.Unavailable("acknowledgement lost after CAS"))
    })
  live.activate(
    owner,
    live.Transition(..request, reconcile: fn() { Ok(Some(next)) }),
    1000,
  )
  |> should.equal(Ok(next))
  process.receive(events, 1000) |> should.equal(Ok("publish"))
  process.receive(events, 0) |> should.equal(Error(Nil))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}

pub fn unavailable_receipt_holds_prepared_generation_without_compensation_test() {
  let events = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        let base = generation(selected, fn() { Ok(Nil) })
        Ok(
          live.Generation(
            ..base,
            mode: live.Stateful(fn(next) {
              Ok(
                live.PreparedUpgrade(
                  generation(next, fn() {
                    process.send(events, "retire")
                    Ok(Nil)
                  }),
                  fn() {
                    process.send(events, "publish")
                    Ok(Nil)
                  },
                  fn() {
                    process.send(events, "abort")
                    Ok(Nil)
                  },
                ),
              )
            }),
          ),
        )
      },
      fn(_) { Ok(Nil) },
    )
  let first = selection(1)
  live.activate(owner, transition(first, fn() { Ok(first) }), 1000)
  |> should.equal(Ok(first))
  let request =
    transition(selection(2), fn() { Error(store.Unavailable("CAS reply lost")) })
  live.activate(
    owner,
    live.Transition(..request, reconcile: fn() {
      Error(store.Unavailable("receipt read lost"))
    }),
    1000,
  )
  |> result.is_error
  |> should.be_true
  process.receive(events, 0) |> should.equal(Error(Nil))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
  process.receive(events, 1000) |> should.equal(Ok("retire"))
  process.receive(events, 0) |> should.equal(Error(Nil))
}

// ---------------------------------------------------------------- leases
//
// A tool call holds a lease on the generation it runs against. These tests
// observe the three promises that follow: calls overlap, a call is bounded
// by admission and not by its own length, and a replacement waits for every
// lease and no longer. They run on the wall clock, because a frozen clock
// never expires a queued request and would let a request that outlived its
// caller take a lease nobody returns.

// A published first generation whose retirements are reported as events.
fn serving(events: process.Subject(String)) -> live.Live {
  let assert Ok(owner) =
    live.start(
      live.Config(
        clock: clock.from_function(ffi_os.system_time_ms),
        stage: fn(selected) {
          Ok(
            generation(selected, fn() {
              process.send(
                events,
                "retire:" <> int.to_string(selected.generation),
              )
              Ok(Nil)
            }),
          )
        },
        adopt: fn(_) { Ok(Nil) },
        recover: fn() { Ok(None) },
      ),
    )
    as "generation owner starts without native resources"
  let first = selection(1)
  live.activate(owner, soon(first), 1000) |> should.equal(Ok(first))
  owner
}

// A transition whose deadline is a minute away on the wall clock.
fn soon(selected: record.Selection) -> live.Transition {
  live.Transition(
    "request-" <> int.to_string(selected.generation),
    ffi_os.system_time_ms() + 60_000,
    selected,
    fn() { Ok(selected) },
    fn() { Ok(None) },
  )
}

// Runs one call that parks until released, from its own process. The call
// reports the gate it parks on and then the result it settles with.
fn parked_call(
  owner: live.Live,
  parked: process.Subject(process.Subject(Nil)),
  settled: process.Subject(effects.ToolOutcome),
  name: String,
) -> process.Pid {
  process.spawn_unlinked(fn() {
    let outcome =
      live.run(
        owner,
        fn(_generation) {
          let gate = process.new_subject()
          process.send(parked, gate)
          let _ = process.receive(gate, 10_000)
          effects.ToolFailed(name)
        },
        1000,
      )
    process.send(settled, outcome)
  })
}

// Asks for a replacement from its own process, so the test can watch it wait.
fn replace_in_background(
  owner: live.Live,
  next: record.Selection,
) -> process.Subject(Result(record.Selection, store.Refusal)) {
  let replaced = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(replaced, live.activate(owner, soon(next), 5000))
    })
  replaced
}

// A deterministic barrier: a probe call that cannot be admitted proves that
// the owner holds a request for replacement, because only a draining owner
// leaves a lease request unanswered. An open owner admits the probe at once.
fn await_draining(owner: live.Live) -> Nil {
  poll.until(within: 2000, every: 10, attempt: fn() {
    case live.run(owner, fn(_) { effects.ToolFailed("probe ran") }, 20) {
      effects.ToolFailed("probe ran") -> poll.Retry
      effects.ToolFailed(_) | effects.ToolCompleted(..) -> poll.Done(Nil)
    }
  })
  |> should.equal(poll.Answered(Nil))
}

pub fn two_calls_overlap_on_their_own_processes_test() {
  let events = process.new_subject()
  let owner = serving(events)
  let parked = process.new_subject()
  let settled = process.new_subject()
  let _ = parked_call(owner, parked, settled, "first")
  let _ = parked_call(owner, parked, settled, "second")

  // Each call waits for a release that this test sends only after seeing both
  // of them running. A serialized owner would never start the second call.
  let assert Ok(first_gate) = process.receive(parked, 1000)
    as "the first call runs"
  let assert Ok(second_gate) = process.receive(parked, 1000)
    as "the second call runs beside the first"
  process.send(first_gate, Nil)
  process.send(second_gate, Nil)
  let assert Ok(one) = process.receive(settled, 1000)
  let assert Ok(two) = process.receive(settled, 1000)
  list.contains([one, two], effects.ToolFailed("first")) |> should.be_true
  list.contains([one, two], effects.ToolFailed("second")) |> should.be_true
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}

pub fn call_longer_than_its_admission_deadline_keeps_its_own_result_test() {
  let events = process.new_subject()
  let owner = serving(events)

  // Admission is bounded by fifty milliseconds and the call takes four times
  // as long. Before leases the owner ran the call, so the caller gave up on
  // an owner it had made busy and reported a call that was still running.
  live.run(
    owner,
    fn(_generation) {
      process.sleep(200)
      effects.ToolFailed("the tool's own result")
    },
    50,
  )
  |> should.equal(effects.ToolFailed("the tool's own result"))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}

pub fn slow_author_test_overlaps_an_ordinary_call_test() {
  let events = process.new_subject()
  let owner = serving(events)
  let parked = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let _ =
        live.evaluate(owner, fn() {
          let gate = process.new_subject()
          process.send(parked, gate)
          let _ = process.receive(gate, 10_000)
          Error(store.Unavailable("author test finished"))
        })
      Nil
    })
  let assert Ok(gate) = process.receive(parked, 1000)
    as "the author test is running"

  // Before this was a lease, the owner ran the author test and every other
  // call in the session waited behind it.
  live.run(owner, fn(_) { effects.ToolFailed("ordinary call") }, 1000)
  |> should.equal(effects.ToolFailed("ordinary call"))
  process.send(gate, Nil)
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}

pub fn replacement_waits_for_an_inflight_call_then_serves_later_calls_test() {
  let events = process.new_subject()
  let owner = serving(events)
  let parked = process.new_subject()
  let settled = process.new_subject()
  let _ = parked_call(owner, parked, settled, "inflight")
  let assert Ok(gate) = process.receive(parked, 1000) as "the call runs"
  let next = selection(2)
  let replaced = replace_in_background(owner, next)
  await_draining(owner)

  // The replacement has arrived and must not begin under the running call.
  process.receive(replaced, 0) |> should.equal(Error(Nil))
  process.receive(events, 0) |> should.equal(Error(Nil))

  // A call that arrives while the replacement waits queues behind it, so a
  // stream of calls cannot starve the replacement, and it then runs against
  // the successor.
  let seen = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let _ =
        live.run(
          owner,
          fn(current) {
            process.send(
              seen,
              option.map(current, fn(one) { one.selection.generation }),
            )
            effects.ToolFailed("later")
          },
          5000,
        )
      Nil
    })
  process.send(gate, Nil)
  process.receive(replaced, 2000) |> should.equal(Ok(Ok(next)))
  process.receive(events, 1000) |> should.equal(Ok("retire:1"))
  process.receive(seen, 2000) |> should.equal(Ok(Some(2)))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}

pub fn close_waits_for_an_inflight_call_test() {
  let events = process.new_subject()
  let owner = serving(events)
  let parked = process.new_subject()
  let settled = process.new_subject()
  let _ = parked_call(owner, parked, settled, "inflight")
  let assert Ok(gate) = process.receive(parked, 1000) as "the call runs"
  let closed = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(closed, live.close(owner, 5000))
    })
  await_draining(owner)

  // Retirement must not run under a call that still holds the generation.
  process.receive(closed, 0) |> should.equal(Error(Nil))
  process.receive(events, 0) |> should.equal(Error(Nil))
  process.send(gate, Nil)
  process.receive(closed, 2000) |> should.equal(Ok(Ok(Nil)))
  process.receive(events, 1000) |> should.equal(Ok("retire:1"))
}

pub fn request_queued_past_its_deadline_is_refused_and_never_runs_test() {
  let events = process.new_subject()
  let owner = serving(events)
  let parked = process.new_subject()
  let settled = process.new_subject()
  let _ = parked_call(owner, parked, settled, "inflight")
  let assert Ok(gate) = process.receive(parked, 1000) as "the call runs"
  let next = selection(2)
  let replaced = replace_in_background(owner, next)
  await_draining(owner)

  // The caller waits one hundred milliseconds for admission and is refused.
  let ran = process.new_subject()
  case
    live.run(
      owner,
      fn(_) {
        process.send(ran, Nil)
        effects.ToolFailed("must not run")
      },
      100,
    )
  {
    effects.ToolFailed("Busy: " <> _) -> Nil
    _ -> panic as "a request that cannot be admitted in time is refused Busy"
  }

  // When the replacement finishes, the stale request replays and is refused as
  // expired. The catalogue read queues behind that replay, so by the time it
  // answers the stale request has been decided.
  process.send(gate, Nil)
  process.receive(replaced, 2000) |> should.equal(Ok(Ok(next)))
  let assert Ok(_) = live.catalogue(owner)
  process.receive(ran, 0) |> should.equal(Error(Nil))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}

pub fn retained_custody_refuses_leases_test() {
  let owner =
    owner(
      fn(selected) {
        let retire = case selected.generation {
          1 -> fn() { Error("withheld native exit") }
          _ -> fn() { Ok(Nil) }
        }
        Ok(generation(selected, retire))
      },
      fn(_) { Ok(Nil) },
    )
  let first = selection(1)
  live.activate(owner, transition(first, fn() { Ok(first) }), 1000)
  |> should.equal(Ok(first))
  let next = selection(2)
  live.activate(owner, transition(next, fn() { Ok(next) }), 1000)
  |> result.is_error
  |> should.be_true

  // The predecessor's retirement is unconfirmed, so no generation is callable.
  live.run(owner, fn(_) { effects.ToolFailed("must not run") }, 1000)
  |> should.equal(effects.ToolFailed(
    "CleanupUnconfirmed: retained native custody",
  ))
}

pub fn caller_that_dies_midcall_releases_its_lease_test() {
  let events = process.new_subject()
  let owner = serving(events)
  let parked = process.new_subject()
  let settled = process.new_subject()
  let holder = parked_call(owner, parked, settled, "doomed")
  let assert Ok(_gate) = process.receive(parked, 1000) as "the call runs"
  let next = selection(2)
  let replaced = replace_in_background(owner, next)
  await_draining(owner)
  process.receive(replaced, 0) |> should.equal(Error(Nil))

  // The holder never returns the lease. Its death is the release.
  process.kill(holder)
  process.receive(replaced, 2000) |> should.equal(Ok(Ok(next)))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}

pub fn notices_run_in_order_and_a_replacement_waits_for_the_running_one_test() {
  let events = process.new_subject()
  let owner = serving(events)
  let order = process.new_subject()
  let parked = process.new_subject()
  live.notice(owner, fn(_generation) {
    let gate = process.new_subject()
    process.send(parked, gate)
    process.send(order, "first:start")
    let _ = process.receive(gate, 10_000)
    process.send(order, "first:end")
  })
  live.notice(owner, fn(_generation) { process.send(order, "second") })
  let assert Ok(gate) = process.receive(parked, 1000) as "the notice runs"
  let next = selection(2)
  let replaced = replace_in_background(owner, next)
  await_draining(owner)
  process.receive(replaced, 0) |> should.equal(Error(Nil))
  process.send(gate, Nil)
  process.receive(replaced, 2000) |> should.equal(Ok(Ok(next)))
  process.receive(order, 1000) |> should.equal(Ok("first:start"))
  process.receive(order, 1000) |> should.equal(Ok("first:end"))
  process.receive(order, 2000) |> should.equal(Ok("second"))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}
