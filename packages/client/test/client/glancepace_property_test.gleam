//// The glance schedule under generated event sequences, driven by `statem`.
////
//// `glancepace_test` pins each decision with a hand-built sequence. This module
//// states the schedule's rules as a reference and runs generated sequences of
//// steps, settlements, wakes and waits against the real book, which is where an
//// interaction between rules would show: a successor operation that starts while
//// its predecessor's request is out, a strand forgotten while it waits for a
//// slot, a backoff that keeps doubling under repeated failure, or a settlement
//// that frees a slot for the strand next in line.
////
//// An event is a step of one strand, the end of a request, a tick, or a wait of
//// some span. Strands come from a small pool. A request that ends is chosen by
//// position among the requests the oracle holds out, resolved when the event
//// runs, so deleting an event while shrinking leaves every later one meaningful,
//// and the model is empty: every event is admissible in every state. Time is
//// part of the sequence. The book holds no clock, so the oracle's `now` starts at
//// zero and moves only on a generated wait, and every event is passed that
//// reading.
////
//// The oracle lives in the system under test, beside the book, because it must
//// see the launches the book returns. It restates the rules from
//// `client/CLAUDE.md` ("the glance loop's schedule as one pure function") and the
//// module doc of `glancepace`, and reads the book only through `track`, which is
//// what the loop itself reads:
////
//// - an `Asking` strand is never launched again, and a request in flight is held
////   by a strand's one slot even when a successor operation starts;
//// - the launch pass fills at most `concurrency` slots, most overdue first with
////   ties broken by strand name, and leaves a strand due only when every slot is
////   taken;
//// - only a `Fresh` strand, one that stepped since its last request began, is
////   launched, and only once its `due` instant has come;
//// - after `Summarized` the next request is due `every_ms` after the previous one
////   started;
//// - `Unusable` leaves the strand `Fresh` and backs it off from `retry_ms`,
////   doubling per consecutive failure up to `retry_cap_ms`;
//// - `Ended` forgets the strand, and a `Resting` strand quiet for
////   `retire_after_ms` is forgotten on the next step;
//// - `Plan.wake` is the soonest due instant of a resting, fresh strand that is not
////   already due.
////
//// The campaign runs twice, under the shipped pace and under a tight one whose
//// bounds a few events reach, and `the_events_reach_every_schedule_case_test`
//// replays the drawn sequences and fails if any case the rules talk about is
//// never reached.

import client/glancepace.{
  type Book, type Pace, Asking, Covered, Ended, Fresh, Launch, Pace, Settled,
  Stepped, Summarized, Tick, Unusable,
}
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option}
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import qcheck
import statem

// --- the campaigns ----------------------------------------------------------

// A pace small enough that a few events reach each bound: a request per ten
// milliseconds at most, a back-off of 2 and then the cap of 3, two slots,
// and a strand forgotten after forty quiet milliseconds.
const tight =
  Pace(
    every_ms: 10,
    retry_ms: 2,
    retry_cap_ms: 3,
    concurrency: 2,
    retire_after_ms: 40,
  )

const campaign_seed = 1974

const runs = 150

const longest = 60

fn config() -> statem.Config {
  statem.default_config(seed: campaign_seed)
  |> statem.with_test_count(runs)
  |> statem.with_max_commands(longest)
}

// --- events -----------------------------------------------------------------

// Whether a step continues the strand's operation or starts a successor.
type Continuation {
  SameOperation
  NewOperation
}

// How long a wait is, in the units of the pace under test.
type Span {
  // One millisecond.
  Moment

  // Half of `retry_ms`.
  HalfRetry

  // `retry_ms`.
  Retry

  // Half of `every_ms`.
  HalfEvery

  // `every_ms`.
  Every

  // `retire_after_ms`.
  Retire
}

type Event {
  // A step of the `strand`-th pool strand.
  Step(strand: Int, continuation: Continuation, context: Option(Int))

  // The `pick`-th request out, in strand order, ends. Nothing happens when none
  // is out.
  Settle(pick: Int, ending: glancepace.Ending)

  // The wake the last plan asked for.
  Wake

  // The clock moves on; no event reaches the book.
  Wait(span: Span)
}

fn event() -> qcheck.Generator(Event) {
  qcheck.from_weighted_generators(
    #(
      40,
      qcheck.map3(
        qcheck.bounded_int(0, 15),
        continuation(),
        qcheck.option_from(qcheck.bounded_int(0, 5000)),
        fn(strand, continuation, context) {
          Step(strand:, continuation:, context:)
        },
      ),
    ),
    [
      #(
        30,
        qcheck.map2(qcheck.bounded_int(0, 15), ending(), fn(pick, ending) {
          Settle(pick:, ending:)
        }),
      ),
      #(10, qcheck.constant(Wake)),
      #(25, qcheck.map(span(), Wait)),
    ],
  )
}

// The simplest continuation is the same operation, so a shrink drops successors.
fn continuation() -> qcheck.Generator(Continuation) {
  qcheck.bounded_int(0, 3)
  |> qcheck.map(fn(pick) {
    case pick {
      0 | 1 | 2 -> SameOperation
      _ -> NewOperation
    }
  })
}

// Mostly answers, some failures, a few operations that were gone.
fn ending() -> qcheck.Generator(glancepace.Ending) {
  qcheck.bounded_int(0, 9)
  |> qcheck.map(fn(pick) {
    case pick {
      0 | 1 | 2 | 3 | 4 -> Summarized
      5 | 6 | 7 | 8 -> Unusable
      _ -> Ended
    }
  })
}

fn span() -> qcheck.Generator(Span) {
  qcheck.bounded_int(0, 5)
  |> qcheck.map(fn(pick) {
    case pick {
      0 -> Moment
      1 -> HalfRetry
      2 -> Retry
      3 -> HalfEvery
      4 -> Every
      _ -> Retire
    }
  })
}

fn describe(event: Event) -> String {
  string.inspect(event)
}

// --- what the oracle remembers ----------------------------------------------

// A request the oracle holds out: the operation it asked about and when it
// began.
type Flight {
  Flight(operation: String, since: Int)
}

// The clock, how many operations each strand has had, when each booked strand
// last stepped, the requests out, the strands that stepped since their last
// request began, the earliest instant a strand may be asked about again, and its
// consecutive failures.
type Oracle {
  Oracle(
    now: Int,
    operations: Dict(String, Int),
    seen: Dict(String, Int),
    flights: Dict(String, Flight),
    fresh: set.Set(String),
    earliest: Dict(String, Int),
    failures: Dict(String, Int),
  )
}

type Sut {
  Sut(book: Book, oracle: Oracle)
}

fn new_sut() -> Sut {
  Sut(
    book: glancepace.new(),
    oracle: Oracle(
      now: 0,
      operations: dict.new(),
      seen: dict.new(),
      flights: dict.new(),
      fresh: set.new(),
      earliest: dict.new(),
      failures: dict.new(),
    ),
  )
}

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

// Compares what the book did with what the rules say, and names the rule.
fn agree(tag: String, got: a, wanted: a) -> Result(Nil, statem.Violation) {
  case got == wanted {
    True -> Ok(Nil)
    False ->
      Error(violation(
        tag,
        "expected "
          <> string.inspect(wanted)
          <> " but got "
          <> string.inspect(got),
      ))
  }
}

// --- units ------------------------------------------------------------------

const pool = ["a", "b", "c", "d", "e"]

fn strand_name(stream: Int) -> String {
  case list.drop(pool, stream % list.length(pool)) {
    [name, ..] -> name
    [] -> "a"
  }
}

fn operation_name(strand: String, number: Int) -> String {
  strand <> "-op-" <> int.to_string(number)
}

fn span_ms(pace: Pace, span: Span) -> Int {
  case span {
    Moment -> 1
    HalfRetry -> int.max(pace.retry_ms / 2, 1)
    Retry -> pace.retry_ms
    HalfEvery -> int.max(pace.every_ms / 2, 1)
    Every -> pace.every_ms
    Retire -> pace.retire_after_ms
  }
}

// The delay after the `failures`-th consecutive failure: `retry_ms`, doubled for
// each failure after the first, never past the cap.
fn backoff(pace: Pace, failures: Int) -> Int {
  int.range(from: 1, to: failures, with: pace.retry_ms, run: fn(delay, _) {
    int.min(delay * 2, pace.retry_cap_ms)
  })
  |> int.min(pace.retry_cap_ms)
}

fn numbers(start: Int, stop: Int) -> List(Int) {
  int.range(from: start, to: stop, with: [], run: fn(all, number) {
    [number, ..all]
  })
  |> list.reverse
}

fn tracks_of(book: Book) -> List(#(String, glancepace.Track)) {
  list.filter_map(pool, fn(strand) {
    glancepace.track(book, strand) |> result.map(fn(track) { #(strand, track) })
  })
}

fn is_resting(track: glancepace.Track) -> Bool {
  case track.phase {
    Asking(..) -> False
    glancepace.Resting -> True
  }
}

// --- stepping ---------------------------------------------------------------

// What an event came to for the strand it concerned, which the checks after the
// step read.
type Outcome {
  // An event that concerned no strand in particular, such as a wake.
  Plain

  // A step of `strand` into `operation`.
  Stepping(
    strand: String,
    operation: String,
    continuation: Continuation,
    before_due: Option(Int),
    outstanding: Bool,
  )

  // The end of a request that began at `since`. `failures` is the strand's
  // consecutive failures after it, `current` whether the request asked about the
  // strand's current operation.
  Answered(
    strand: String,
    ending: glancepace.Ending,
    current: Current,
    since: Int,
    failures: Int,
  )
}

// Whether a settlement is about the strand's current operation or an earlier one.
type Current {
  CurrentOperation
  Predecessor
}

// One event, with the labels of the cases it reached. `execute` drops the
// labels, and the coverage test collects them.
fn step(
  pace: Pace,
  sut: Sut,
  event: Event,
) -> Result(#(Sut, List(String)), statem.Violation) {
  case event {
    Wait(span:) -> {
      let now = sut.oracle.now + span_ms(pace, span)
      Ok(#(Sut(..sut, oracle: Oracle(..sut.oracle, now:)), []))
    }

    Step(strand:, continuation:, context:) -> {
      let name = strand_name(strand)
      let #(oracle, operation) = stepped(sut.oracle, name, continuation)
      let before_due =
        glancepace.track(sut.book, name)
        |> result.map(fn(track) { track.due })
        |> option.from_result
      let outstanding = dict.has_key(sut.oracle.flights, name)
      apply(
        pace,
        sut.book,
        oracle,
        Stepped(name, operation, context),
        Stepping(name, operation, continuation, before_due, outstanding),
      )
    }

    Settle(pick:, ending:) -> {
      let outstanding =
        dict.to_list(sut.oracle.flights)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      case list.length(outstanding) {
        0 -> Ok(#(sut, []))
        size ->
          case list.drop(outstanding, pick % size) {
            [#(name, flight), ..] -> settle(pace, sut, name, flight, ending)
            [] -> Ok(#(sut, []))
          }
      }
    }

    Wake -> apply(pace, sut.book, sut.oracle, Tick, Plain)
  }
}

// The oracle after a step of `name`: its operation, and the strand fresh. A
// successor starts its schedule afresh, due at once with no failures.
fn stepped(
  oracle: Oracle,
  name: String,
  continuation: Continuation,
) -> #(Oracle, String) {
  let held = result.unwrap(dict.get(oracle.operations, name), 0)
  let number = case continuation {
    SameOperation -> held
    NewOperation -> held + 1
  }
  let #(earliest, failures) = case continuation {
    SameOperation -> #(oracle.earliest, oracle.failures)
    NewOperation -> #(
      dict.delete(oracle.earliest, name),
      dict.delete(oracle.failures, name),
    )
  }
  #(
    Oracle(
      ..oracle,
      operations: dict.insert(oracle.operations, name, number),
      seen: dict.insert(oracle.seen, name, oracle.now),
      fresh: set.insert(oracle.fresh, name),
      earliest:,
      failures:,
    ),
    operation_name(name, number),
  )
}

fn settle(
  pace: Pace,
  sut: Sut,
  name: String,
  flight: Flight,
  ending: glancepace.Ending,
) -> Result(#(Sut, List(String)), statem.Violation) {
  let oracle = sut.oracle
  let held = result.unwrap(dict.get(oracle.operations, name), 0)
  let current = case flight.operation == operation_name(name, held) {
    True -> CurrentOperation
    False -> Predecessor
  }
  let failures = result.unwrap(dict.get(oracle.failures, name), 0)
  let freed = Oracle(..oracle, flights: dict.delete(oracle.flights, name))

  // An answer about the predecessor frees the slot and changes nothing else.
  // For the current operation, the ending decides what the strand owes next.
  let #(settled, failed) = case current, ending {
    Predecessor, _ -> #(freed, 0)
    CurrentOperation, Summarized -> #(
      Oracle(
        ..freed,
        earliest: dict.insert(
          freed.earliest,
          name,
          flight.since + pace.every_ms,
        ),
        failures: dict.delete(freed.failures, name),
      ),
      0,
    )
    CurrentOperation, Unusable -> #(
      Oracle(
        ..freed,
        fresh: set.insert(freed.fresh, name),
        earliest: dict.insert(
          freed.earliest,
          name,
          freed.now + backoff(pace, failures + 1),
        ),
        failures: dict.insert(freed.failures, name, failures + 1),
      ),
      failures + 1,
    )
    CurrentOperation, Ended -> #(
      Oracle(
        ..freed,
        seen: dict.delete(freed.seen, name),
        fresh: set.delete(freed.fresh, name),
        earliest: dict.delete(freed.earliest, name),
        failures: dict.delete(freed.failures, name),
      ),
      0,
    )
  }
  apply(
    pace,
    sut.book,
    settled,
    Settled(name, flight.operation, ending),
    Answered(name, ending, current, flight.since, failed),
  )
}

// Gives the event to the book and holds its plan to the rules.
fn apply(
  pace: Pace,
  book: Book,
  oracle: Oracle,
  event: glancepace.Event,
  outcome: Outcome,
) -> Result(#(Sut, List(String)), statem.Violation) {
  let now = oracle.now
  let before = tracked(book)
  let plan = glancepace.step(book, event, now, pace)
  let after = tracks_of(plan.book)

  // A slot the oracle holds is a request the book cannot launch again, and a
  // launch is for a fresh strand whose instant has come.
  use Nil <- result.try(
    list.try_each(plan.launch, fn(launch) {
      use Nil <- result.try(agree(
        "never-relaunched",
        dict.has_key(oracle.flights, launch.strand),
        False,
      ))
      checked_launch(oracle, plan.book, launch)
    }),
  )

  // The requests now out are the ones before and the ones just launched, and
  // the book says the same strands are `Asking`, since when.
  let flights =
    list.fold(plan.launch, oracle.flights, fn(held, launch) {
      dict.insert(held, launch.strand, Flight(launch.operation, now))
    })
  use Nil <- result.try(agree(
    "concurrency",
    dict.size(flights) <= pace.concurrency,
    True,
  ))
  use Nil <- result.try(agree(
    "asking",
    list.filter_map(after, fn(pair) {
      case { pair.1 }.phase {
        Asking(since:) -> Ok(#(pair.0, since))
        glancepace.Resting -> Error(Nil)
      }
    }),
    dict.to_list(flights)
      |> list.map(fn(pair) { #(pair.0, { pair.1 }.since) })
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
  ))
  use Nil <- result.try(checked_booked(pace, oracle, after))
  let waiting = due_and_waiting(now, after)
  use Nil <- result.try(checked_order(
    pace,
    after,
    plan.launch,
    waiting,
    dict.size(flights),
  ))
  use Nil <- result.try(checked_wake(now, after, plan.wake))
  use Nil <- result.try(checked_retirement(pace, now, after))
  use Nil <- result.try(checked_outcome(pace, now, outcome, after, oracle))

  // A launched strand has been asked, and is not fresh again until it steps.
  let launched = list.map(plan.launch, fn(launch) { launch.strand })
  let fresh =
    list.fold(launched, oracle.fresh, fn(held, strand) {
      set.delete(held, strand)
    })
  let next =
    forgotten(
      Oracle(..oracle, flights:, fresh:),
      list.map(after, fn(pair) { pair.0 }),
    )
  Ok(#(
    Sut(book: plan.book, oracle: next),
    labels(before, after, plan, outcome, waiting, oracle, pace),
  ))
}

fn tracked(book: Book) -> List(String) {
  list.map(tracks_of(book), fn(pair) { pair.0 })
}

// What the oracle keeps for a strand the book no longer holds is dropped, so a
// strand booked afresh later starts with nothing carried over.
fn forgotten(oracle: Oracle, surviving: List(String)) -> Oracle {
  Oracle(
    ..oracle,
    seen: dict.filter(oracle.seen, fn(strand, _) {
      list.contains(surviving, strand)
    }),
    fresh: set.filter(oracle.fresh, list.contains(surviving, _)),
    earliest: dict.filter(oracle.earliest, fn(strand, _) {
      list.contains(surviving, strand)
    }),
    failures: dict.filter(oracle.failures, fn(strand, _) {
      list.contains(surviving, strand)
    }),
  )
}

// A launch carries what the strand's schedule says, and only a strand that
// stepped since its last request began, whose due instant and cadence allow it.
fn checked_launch(
  oracle: Oracle,
  book: Book,
  launch: glancepace.Launch,
) -> Result(Nil, statem.Violation) {
  let Launch(strand:, operation:, context:) = launch
  use track <- result.try(
    glancepace.track(book, strand)
    |> result.replace_error(violation(
      "launch-track",
      "launched a strand the book does not hold",
    )),
  )
  use Nil <- result.try(agree(
    "fresh-only",
    set.contains(oracle.fresh, strand),
    True,
  ))
  use Nil <- result.try(
    agree("launch-carries", #(operation, context), #(
      track.operation,
      track.context,
    )),
  )
  use Nil <- result.try(agree("due-reached", track.due <= oracle.now, True))
  let earliest = result.unwrap(dict.get(oracle.earliest, strand), 0)
  agree("cadence", oracle.now >= earliest, True)
}

fn compare_keys(a: #(Int, String), b: #(Int, String)) -> order.Order {
  case int.compare(a.0, b.0) {
    order.Eq -> string.compare(a.1, b.1)
    ordered -> ordered
  }
}

// The strands a launch pass left due: resting, fresh and past their instant.
fn due_and_waiting(
  now: Int,
  after: List(#(String, glancepace.Track)),
) -> List(#(Int, String)) {
  list.filter_map(after, fn(pair) {
    let #(strand, track) = pair
    case track.phase, track.activity {
      glancepace.Resting, Fresh if track.due <= now -> Ok(#(track.due, strand))
      glancepace.Resting, Fresh
      | glancepace.Resting, Covered
      | Asking(..), Fresh
      | Asking(..), Covered
      -> Error(Nil)
    }
  })
}

// The launch pass is most overdue first with ties by name, fills every slot a
// due strand could take, and leaves a strand due only when none is free.
fn checked_order(
  pace: Pace,
  after: List(#(String, glancepace.Track)),
  launches: List(glancepace.Launch),
  waiting: List(#(Int, String)),
  out: Int,
) -> Result(Nil, statem.Violation) {
  let launched =
    list.map(launches, fn(launch) {
      case list.key_find(after, launch.strand) {
        Ok(track) -> #(track.due, launch.strand)
        Error(Nil) -> #(0, launch.strand)
      }
    })
  use Nil <- result.try(agree(
    "overdue-first",
    launched,
    list.sort(launched, compare_keys),
  ))
  use Nil <- result.try(case waiting {
    [] -> Ok(Nil)
    [_, ..] -> agree("slots-fill", out, pace.concurrency)
  })
  list.try_each(waiting, fn(left) {
    list.try_each(launched, fn(first) {
      agree("overdue-first", compare_keys(first, left) == order.Gt, False)
    })
  })
}

// The wake is the soonest instant a resting, fresh strand becomes due, among
// those that are not due already.
fn checked_wake(
  now: Int,
  after: List(#(String, glancepace.Track)),
  wake: Option(Int),
) -> Result(Nil, statem.Violation) {
  let instants =
    list.filter_map(after, fn(pair) {
      let track = pair.1
      case track.phase, track.activity {
        glancepace.Resting, Fresh if track.due > now -> Ok(track.due)
        glancepace.Resting, Fresh
        | glancepace.Resting, Covered
        | Asking(..), Fresh
        | Asking(..), Covered
        -> Error(Nil)
      }
    })
  agree("wake", wake, list.reduce(instants, int.min) |> option.from_result)
}

// Whether the oracle holds `strand` resting and quiet for the retirement
// interval, so the step forgets it before the launch pass.
fn quiet(pace: Pace, oracle: Oracle, strand: String) -> Bool {
  case dict.get(oracle.seen, strand), dict.has_key(oracle.flights, strand) {
    Ok(stepped), False -> oracle.now - stepped >= pace.retire_after_ms
    Ok(_), True | Error(Nil), _ -> False
  }
}

// The strands the book holds after a step are the strands the oracle booked,
// less those that were resting and quiet for the retirement interval.
fn checked_booked(
  pace: Pace,
  oracle: Oracle,
  after: List(#(String, glancepace.Track)),
) -> Result(Nil, statem.Violation) {
  agree(
    "booked",
    list.map(after, fn(pair) { pair.0 }),
    dict.keys(oracle.seen)
      |> list.filter(fn(strand) { !quiet(pace, oracle, strand) })
      |> list.sort(string.compare),
  )
}

// A resting strand quiet for the retirement interval is not held after a step.
fn checked_retirement(
  pace: Pace,
  now: Int,
  after: List(#(String, glancepace.Track)),
) -> Result(Nil, statem.Violation) {
  list.try_each(after, fn(pair) {
    case is_resting(pair.1) {
      True ->
        agree("retire", now - { pair.1 }.seen < pace.retire_after_ms, True)
      False -> Ok(Nil)
    }
  })
}

// What the event itself did to the strand it concerned.
fn checked_outcome(
  pace: Pace,
  now: Int,
  outcome: Outcome,
  after: List(#(String, glancepace.Track)),
  oracle: Oracle,
) -> Result(Nil, statem.Violation) {
  case outcome {
    Plain -> Ok(Nil)

    Stepping(strand:, operation:, continuation:, before_due:, ..) -> {
      use track <- result.try(
        list.key_find(after, strand)
        |> result.replace_error(violation(
          "stepped-booked",
          "a strand that stepped is not booked",
        )),
      )
      use Nil <- result.try(agree(
        "stepped-operation",
        track.operation,
        operation,
      ))

      // A successor is due at once with no failures; a step of the same
      // operation never moves its instant.
      case continuation, before_due {
        NewOperation, _ ->
          agree("successor", #(track.due, track.failures), #(now, 0))
        SameOperation, option.Some(due) ->
          agree("same-operation", track.due, due)
        SameOperation, option.None -> agree("first-step", track.due, now)
      }
    }

    Answered(strand:, ending:, current: CurrentOperation, since:, failures:) -> {
      let track = list.key_find(after, strand)
      case ending, track {
        // A settlement of a strand that has been quiet for the retirement
        // interval leaves it forgotten in the same step.
        Summarized, Error(Nil) | Unusable, Error(Nil) ->
          agree("settled-quiet", quiet(pace, oracle, strand), True)

        Summarized, Ok(track) ->
          agree("summarized", #(track.due, track.failures), #(
            since + pace.every_ms,
            0,
          ))
        Unusable, Ok(track) ->
          agree("backoff", #(track.due, track.failures, track.activity), #(
            now + backoff(pace, failures),
            failures,
            Fresh,
          ))
        Ended, Error(Nil) -> Ok(Nil)
        Ended, Ok(_) ->
          Error(violation("ended-forgets", "the strand is still booked"))
      }
    }

    Answered(current: Predecessor, ..) -> Ok(Nil)
  }
}

// The cases an event reached, for the coverage test.
fn labels(
  before: List(String),
  after: List(#(String, glancepace.Track)),
  plan: glancepace.Plan,
  outcome: Outcome,
  waiting: List(#(Int, String)),
  oracle: Oracle,
  pace: Pace,
) -> List(String) {
  let gone =
    list.filter(before, fn(strand) {
      list.key_find(after, strand) == Error(Nil)
    })
  let retired = case outcome {
    Answered(strand:, ending: Ended, current: CurrentOperation, ..) ->
      list.filter(gone, fn(each) { each != strand })
    Answered(..) | Stepping(..) | Plain -> gone
  }
  let covered_waits =
    list.any(after, fn(pair) {
      case { pair.1 }.phase, { pair.1 }.activity {
        glancepace.Resting, Covered -> { pair.1 }.due <= oracle.now
        glancepace.Resting, Fresh | Asking(..), Fresh | Asking(..), Covered ->
          False
      }
    })
  list.flatten([
    case plan.launch {
      [] -> []
      [_, ..] -> ["launch"]
    },
    case waiting {
      [] -> []
      [_, ..] -> ["slots-full"]
    },
    case retired {
      [] -> []
      [_, ..] -> ["retired"]
    },
    case plan.wake {
      option.None -> []
      option.Some(_) -> ["wake"]
    },
    case covered_waits {
      True -> ["covered-waits"]
      False -> []
    },
    case outcome {
      Plain -> []
      Stepping(continuation: NewOperation, outstanding: True, ..) -> [
        "successor-inherits",
      ]
      Stepping(..) -> []
      Answered(current: Predecessor, ..) -> ["stale-settle"]
      Answered(ending: Summarized, ..) -> ["summarized"]
      Answered(ending: Ended, ..) -> ["ended"]
      Answered(ending: Unusable, failures:, ..) ->
        case failures {
          1 -> ["backoff-first"]
          _ ->
            case backoff(pace, failures) == pace.retry_cap_ms {
              True -> ["backoff-doubled", "backoff-capped"]
              False -> ["backoff-doubled"]
            }
        }
    },
  ])
}

// --- the property -----------------------------------------------------------

fn spec(pace: Pace) -> statem.Spec(Nil, Event, Sut) {
  statem.Spec(
    initial: Nil,
    command: fn(_) { event() },
    precondition: fn(_, _) { statem.Admit },
    next_model: fn(_, _) { Nil },
    new_sut:,
    execute: fn(sut, _, event) {
      step(pace, sut, event) |> result.map(fn(stepped) { stepped.0 })
    },
    finish: fn(_, _) { Ok(Nil) },
    teardown: fn(_) { Nil },
  )
}

fn checked(pace: Pace) -> Nil {
  case statem.check(spec(pace), config()) {
    Ok(Nil) -> Nil

    // EUnit clips a long panic message, so the whole report also goes to
    // standard error, which EUnit does not capture.
    Error(failure) -> {
      let report = statem.report(failure, describe)
      io.println_error(report)
      panic as report
    }
  }
}

pub fn the_schedule_keeps_its_rules_under_the_shipped_pace_test() {
  checked(glancepace.default_pace)
}

pub fn the_schedule_keeps_its_rules_under_a_tight_pace_test() {
  checked(tight)
}

// --- the generator is worth testing with ------------------------------------

// Every case the rules above talk about.
const wanted = [
  "launch", "slots-full", "successor-inherits", "stale-settle", "backoff-first",
  "backoff-doubled", "backoff-capped", "summarized", "ended", "retired", "wake",
  "covered-waits",
]

fn reached(pace: Pace) -> set.Set(String) {
  list.fold(numbers(0, runs), set.new(), fn(found, run) {
    let events = statem.commands(spec(pace), config(), run)
    let #(_, labels) =
      list.fold(events, #(new_sut(), []), fn(state, event) {
        case step(pace, state.0, event) {
          Ok(#(next, labels)) -> #(next, list.append(labels, state.1))
          Error(_) -> state
        }
      })
    set.union(found, set.from_list(labels))
  })
}

pub fn the_events_reach_every_schedule_case_test() {
  let shipped = reached(glancepace.default_pace)
  let small = reached(tight)
  assert list.filter(wanted, fn(label) { !set.contains(small, label) }) == []
    as "the tight pace never reached every case"

  // The shipped back-off needs five consecutive failures of one operation to
  // reach its cap of 300 s, which a sequence of this length seldom draws; the
  // tight pace reaches the cap, and the shipped one every other case.
  assert list.filter(wanted, fn(label) {
      label != "backoff-capped" && !set.contains(shipped, label)
    })
    == []
    as "the shipped pace never reached every case"
}
