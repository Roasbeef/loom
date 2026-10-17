//// The sender's peer outbox under generated command sequences, driven by
//// `statem`.
////
//// `peer_outbox` is a pure module, and `peer_outbox_test` pins each rule with
//// one row. The rules compose in the store: `claim` decides what a message id
//// means against what is stored, `room` makes space before a new row is
//// written, `settle` moves a pending row, and `expire` refuses one that waited
//// too long. This test composes them the way `internal/peer_outbox_store` does,
//// over a dictionary of encoded rows in place of the session's store, and runs
//// generated sequences of claims, answers, sweeps, waits and unlinks against a
//// reference that states the rules of the module's `## Flow` and of
//// `client/CLAUDE.md` ("Sender outbox") without calling any of them.
////
//// Each command names its strand, message and content by position in a small
//// fixed pool, and an answer names the row it settles by position among the
//// stored rows in key order, so deleting a command while shrinking leaves every
//// later one meaningful. The model is the reference store with its clock; the
//// system under test is the encoded dictionary the real functions work on.
//// Time moves only on a wait, so many rows share one millisecond and the
//// eviction tie-break by key is exercised.
////
//// The rules checked after every command, by tag:
////
//// - `outcome`: a claim comes to what the reference says: a new row, a resume
////   of the same pending content, the stored receipt for the same admitted
////   content, a conflict for the same id with other content, an eviction of the
////   oldest finished row when the strand is at its bound, or `outbox_full`
////   when every row is pending;
//// - `rows`: the stored rows equal the reference's, state by state;
//// - `bound`: no strand holds more than 64 rows;
//// - `admitted-immutable` and `refused-replaced-only`: an admitted row never
////   moves, and a refused one is only ever replaced by a repeat of its id;
//// - `pending-text`: a pending row changes only what it says it waits for;
//// - `codec`: every stored row decodes and encodes to itself.
////
//// Three campaigns run: two strands and a few ids, where the same message is
//// claimed again and again; one strand with a hundred ids and answers, where the
//// bound is reached and finished rows are evicted; and one strand that is only
//// claimed from, where every row stays pending and the bound refuses. The
//// coverage test replays the drawn sequences against the reference and fails if
//// any outcome the rules name is never reached.

import client/peer_outbox.{
  type Row, Admitted, Conflict, Evict, Free, Full, Insert, NotOpen, OnOpen,
  OnOwner, Pending, Receipt, Refused, Rejected, Resume, Row, Settled, Unanswered,
}
import core/json.{type JsonValue}
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import qcheck
import statem

// --- the campaigns ----------------------------------------------------------

// The shape of one campaign: how many strands and message ids the pool holds,
// the weight of each kind of command, how long a sequence may run, and how many
// run. The crowded campaigns run fewer, longer sequences, since each command
// there reads and decodes up to sixty-four stored rows, and they shrink within a
// smaller budget, so that a failure is reported inside EUnit's time limit and is
// not cut off by it.
type Mix {
  Mix(
    strands: Int,
    messages: Int,
    claim: Int,
    answer: Int,
    sweep: Int,
    wait: Int,
    unlink: Int,
    longest: Int,
    runs: Int,
    shrinks: Int,
  )
}

const tangled =
  Mix(
    strands: 2,
    messages: 8,
    claim: 40,
    answer: 25,
    sweep: 8,
    wait: 15,
    unlink: 5,
    longest: 60,
    runs: 80,
    shrinks: 1000,
  )

const crowded =
  Mix(
    strands: 1,
    messages: 100,
    claim: 60,
    answer: 25,
    sweep: 3,
    wait: 8,
    unlink: 2,
    longest: 260,
    runs: 40,
    shrinks: 1200,
  )

const jammed =
  Mix(
    strands: 1,
    messages: 100,
    claim: 90,
    answer: 0,
    sweep: 0,
    wait: 5,
    unlink: 0,
    longest: 200,
    runs: 40,
    shrinks: 1200,
  )

const campaign_seed = 5667

fn config(mix: Mix) -> statem.Config {
  statem.default_config(seed: campaign_seed)
  |> statem.with_test_count(mix.runs)
  |> statem.with_max_shrinks(mix.shrinks)
  |> statem.with_max_commands(mix.longest)
}

// --- commands ---------------------------------------------------------------

// How an attempt to deliver a message ended, as the drainer reports it.
type Attempt {
  // The recipient admitted it and answered with a receipt.
  Landed

  // The recipient's owner did not answer.
  Silent

  // The recipient refused it.
  Declined

  // The recipient's session is saved and not open.
  Saved
}

// How far the clock moves.
type Span {
  // One millisecond.
  Moment

  // Half the pending limit, so two of them pass it.
  Half

  // Just past the pending limit.
  Beyond
}

type Command {
  // Sends message `message` of `strand` with the `content`-th text.
  Claim(strand: Int, message: Int, content: Int)

  // The `pick`-th stored row, in key order, has an attempt end.
  Answer(pick: Int, attempt: Attempt)

  // The drainer's pass: every pending row past the limit is refused.
  Sweep

  // The clock moves.
  Wait(span: Span)

  // The strand's pending rows to one target are deleted, as `Unlink` does.
  Unlink(strand: Int, target: Int)
}

fn command(mix: Mix) -> fn(Model) -> qcheck.Generator(Command) {
  fn(model: Model) {
    let sends =
      qcheck.map3(
        qcheck.bounded_int(0, 7),
        qcheck.bounded_int(0, 127),
        qcheck.bounded_int(0, 2),
        fn(strand, message, content) { Claim(strand:, message:, content:) },
      )
    let answers = case dict.size(model.rows) {
      0 -> []
      _ -> [
        #(
          mix.answer,
          qcheck.map2(qcheck.bounded_int(0, 255), attempt(), fn(pick, attempt) {
            Answer(pick:, attempt:)
          }),
        ),
      ]
    }
    qcheck.from_weighted_generators(
      #(int.max(mix.claim, 1), sends),
      list.flatten([
        answers,
        [
          #(mix.sweep, qcheck.constant(Sweep)),
          #(mix.wait, qcheck.map(span(), Wait)),
          #(
            mix.unlink,
            qcheck.map2(
              qcheck.bounded_int(0, 7),
              qcheck.bounded_int(0, 1),
              fn(strand, target) { Unlink(strand:, target:) },
            ),
          ),
        ],
      ])
        |> list.filter(fn(entry) { entry.0 > 0 }),
    )
  }
}

fn attempt() -> qcheck.Generator(Attempt) {
  qcheck.bounded_int(0, 5)
  |> qcheck.map(fn(pick) {
    case pick {
      0 | 1 -> Landed
      2 | 3 -> Silent
      4 -> Declined
      _ -> Saved
    }
  })
}

// The simplest span is a millisecond, so a shrink drops waits.
fn span() -> qcheck.Generator(Span) {
  qcheck.bounded_int(0, 3)
  |> qcheck.map(fn(pick) {
    case pick {
      0 | 1 -> Moment
      2 -> Half
      _ -> Beyond
    }
  })
}

fn describe(command: Command) -> String {
  string.inspect(command)
}

// --- the reference ----------------------------------------------------------

// The session every row belongs to, and the session the messages come from.
const session = "peer"

const source = "src"

const targets = ["main", "side"]

// What a message can say and whom it is for: the same text to two targets, and
// two texts to one, so a repeated id meets every kind of difference.
const contents = [#("main", "hello"), #("main", "changed"), #("side", "hello")]

fn strand_name(mix: Mix, strand: Int) -> String {
  "strand-" <> int.to_string(strand % mix.strands)
}

fn message_name(mix: Mix, message: Int) -> String {
  "m" <> int.to_string(message % mix.messages)
}

// What a message says, as a position in the pool, and what it is sent to.
fn target_of(content: Int) -> String {
  said(content).0
}

fn text_of(content: Int) -> String {
  said(content).1
}

fn said(content: Int) -> #(String, String) {
  case list.drop(contents, content % list.length(contents)) {
    [one, ..] -> one
    [] -> #("", "")
  }
}

fn at(items: List(String), index: Int) -> String {
  case list.drop(items, index % list.length(items)) {
    [item, ..] -> item
    [] -> ""
  }
}

// What a row waits for, or how it finished.
type Standing {
  OwnerWait
  OpenWait
  Receipted
  Turned(reason: String)
}

// One row as the rules describe it: its key, whose, which message, what it
// says, when it was queued and where it stands. The key is a digest, so it is
// made once, when a claim builds the row.
type Ref {
  Ref(
    key: String,
    strand: String,
    message: String,
    content: Int,
    queued_at: Int,
    standing: Standing,
  )
}

type Model {
  Model(rows: Dict(#(String, String), Ref), now: Int)
}

fn fresh() -> Model {
  Model(rows: dict.new(), now: 0)
}

fn is_finished(ref: Ref) -> Bool {
  case ref.standing {
    OwnerWait | OpenWait -> False
    Receipted | Turned(_) -> True
  }
}

fn key_of(ref: Ref) -> String {
  ref.key
}

// The row a claim of `message` on `strand` would store, queued now.
fn claimed_ref(
  mix: Mix,
  model: Model,
  strand: Int,
  message: Int,
  content: Int,
) -> Ref {
  let strand = strand_name(mix, strand)
  let message = message_name(mix, message)
  Ref(
    key: peer_outbox.key(strand, session, message),
    strand:,
    message:,
    content: content % list.length(contents),
    queued_at: model.now,
    standing: OwnerWait,
  )
}

// The row the module would store for a reference row.
fn row_of(ref: Ref) -> Row {
  let sent =
    peer_outbox.pending(
      ref.strand,
      session,
      target_of(ref.content),
      ref.message,
      text_of(ref.content),
      ref.queued_at,
    )
  Row(..sent, state: case ref.standing {
    OwnerWait -> Pending(text_of(ref.content), OnOwner)
    OpenWait -> Pending(text_of(ref.content), OnOpen)
    Receipted -> Admitted(receipt_for(sent))
    Turned(reason) -> Refused(reason)
  })
}

// The receipt a recipient answers with: the request it admitted, which is what
// a later claim of the same message is compared against.
fn receipt_for(sent: Row) -> JsonValue {
  json.Object([
    #("request", option.unwrap(peer_outbox.request(source, sent), json.Null)),
    #("admitted", json.Bool(True)),
  ])
}

// What one claim should come to.
type Claimed {
  Wrote
  WroteAfterEvicting(key: String)
  Resumed
  AlreadyAdmitted
  Conflicted
  Jammed
}

fn rows_of_strand(model: Model, strand: String) -> List(Ref) {
  dict.values(model.rows) |> list.filter(fn(ref) { ref.strand == strand })
}

// The oldest finished row of a strand: by when it was queued, and by key
// between rows of one millisecond.
fn oldest_finished(model: Model, strand: String) -> Result(Ref, Nil) {
  rows_of_strand(model, strand)
  |> list.filter(is_finished)
  |> list.sort(fn(a, b) {
    case int.compare(a.queued_at, b.queued_at) {
      order.Eq -> string.compare(key_of(a), key_of(b))
      other -> other
    }
  })
  |> list.first
}

// The stored rows in key order, so a position names the same row in the model
// and in the system.
fn ordered(model: Model) -> List(Ref) {
  dict.values(model.rows)
  |> list.sort(fn(a, b) { string.compare(key_of(a), key_of(b)) })
}

// What a command does to the reference, and what a claim should come to.
fn reference(mix: Mix, model: Model, command: Command) -> #(Claimed, Model) {
  case command {
    Claim(strand:, message:, content:) ->
      claimed(model, claimed_ref(mix, model, strand, message, content))

    Answer(pick:, attempt:) -> #(Wrote, answered(model, pick, attempt))
    Sweep -> #(Wrote, swept(model))
    Wait(span:) -> #(Wrote, Model(..model, now: model.now + span_ms(span)))
    Unlink(strand:, target:) -> #(Wrote, unlinked(mix, model, strand, target))
  }
}

// A claim against what is stored. A repeat of the same content resumes a
// pending row and is answered from an admitted one; other content under the
// same id is a conflict; a refused row is replaced by a repeat of its id and
// takes no new slot; a new id needs room, made by evicting the oldest finished
// row when the strand is at its bound.
fn claimed(model: Model, wanted: Ref) -> #(Claimed, Model) {
  let key = #(wanted.strand, wanted.message)
  let put = fn(rows) { Model(..model, rows: dict.insert(rows, key, wanted)) }
  case dict.get(model.rows, key) {
    Ok(Ref(standing: Turned(_), ..)) -> #(Wrote, put(model.rows))
    Ok(stored) ->
      case stored.content == wanted.content, is_finished(stored) {
        True, False -> #(Resumed, model)
        True, True -> #(AlreadyAdmitted, model)
        False, _ -> #(Conflicted, model)
      }
    Error(Nil) ->
      case
        list.length(rows_of_strand(model, wanted.strand))
        < peer_outbox.row_limit
      {
        True -> #(Wrote, put(model.rows))
        False ->
          case oldest_finished(model, wanted.strand) {
            Ok(oldest) -> #(
              WroteAfterEvicting(key_of(oldest)),
              put(dict.delete(model.rows, #(oldest.strand, oldest.message))),
            )
            Error(Nil) -> #(Jammed, model)
          }
      }
  }
}

// An attempt's end moves a pending row and nothing else: delivered admits it,
// a refusal refuses it, and silence or a saved recipient changes only what it
// waits for.
fn answered(model: Model, pick: Int, attempt: Attempt) -> Model {
  case list.drop(ordered(model), pick % int.max(dict.size(model.rows), 1)) {
    [] -> model
    [ref, ..] ->
      case is_finished(ref) {
        True -> model
        False ->
          Model(
            ..model,
            rows: dict.insert(
              model.rows,
              #(ref.strand, ref.message),
              Ref(..ref, standing: case attempt {
                Landed -> Receipted
                Declined -> Turned("declined")
                Silent -> OwnerWait
                Saved -> OpenWait
              }),
            ),
          )
      }
  }
}

// Every pending row past the limit is refused, in words naming what it waited
// for.
fn swept(model: Model) -> Model {
  Model(
    ..model,
    rows: dict.map_values(model.rows, fn(_, ref) {
      case
        is_finished(ref),
        model.now - ref.queued_at > peer_outbox.pending_ttl_ms
      {
        False, True ->
          Ref(..ref, standing: case ref.standing {
            OpenWait -> Turned(open_reason)
            OwnerWait | Receipted | Turned(_) -> Turned(owner_reason)
          })
        True, _ | False, False -> ref
      }
    }),
  )
}

const owner_reason = "the owner never answered"

const open_reason = "the session was never opened"

// The strand's pending rows to one target go.
fn unlinked(mix: Mix, model: Model, strand: Int, target: Int) -> Model {
  let name = strand_name(mix, strand)
  let aim = at(targets, target)
  Model(
    ..model,
    rows: dict.filter(model.rows, fn(_, ref) {
      is_finished(ref) || ref.strand != name || target_of(ref.content) != aim
    }),
  )
}

fn span_ms(span: Span) -> Int {
  case span {
    Moment -> 1
    Half -> peer_outbox.pending_ttl_ms / 2
    Beyond -> peer_outbox.pending_ttl_ms + 1
  }
}

// --- the system under test --------------------------------------------------

// The store's rows as the session store holds them, encoded, by key.
type Sut {
  Sut(cells: Dict(String, JsonValue))
}

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

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

// The rows of the store, decoded, as `peer_outbox_store.rows` lists them.
fn stored(sut: Sut) -> Result(List(#(String, Row)), statem.Violation) {
  list.try_map(dict.to_list(sut.cells), fn(pair) {
    peer_outbox.decode(pair.1)
    |> result.map(fn(row) { #(pair.0, row) })
    |> result.map_error(fn(why) { violation("codec", why) })
  })
}

fn put(sut: Sut, key: String, row: Row) -> Sut {
  Sut(cells: dict.insert(sut.cells, key, peer_outbox.encode(row)))
}

// A claim, composed as `peer_outbox_store.claim` composes it.
fn claim_row(
  sut: Sut,
  wanted: Row,
) -> Result(#(Sut, Claimed), statem.Violation) {
  let key = peer_outbox.key(wanted.strand, wanted.session, wanted.message_id)
  use existing <- result.try(case dict.get(sut.cells, key) {
    Ok(cell) ->
      peer_outbox.decode(cell)
      |> result.map(Some)
      |> result.map_error(fn(why) { violation("codec", why) })
    Error(Nil) -> Ok(None)
  })
  case peer_outbox.claim(existing, wanted, source) {
    Conflict -> Ok(#(sut, Conflicted))
    Resume -> Ok(#(sut, Resumed))
    Settled(_) -> Ok(#(sut, AlreadyAdmitted))
    Insert ->
      case existing {
        Some(_) -> Ok(#(put(sut, key, wanted), Wrote))
        None -> {
          use rows <- result.try(stored(sut))
          case peer_outbox.room(rows, wanted.strand) {
            Free -> Ok(#(put(sut, key, wanted), Wrote))
            Full -> Ok(#(sut, Jammed))
            Evict(key: oldest) ->
              Ok(#(
                put(Sut(cells: dict.delete(sut.cells, oldest)), key, wanted),
                WroteAfterEvicting(oldest),
              ))
          }
        }
      }
  }
}

fn answer_row(
  sut: Sut,
  key: String,
  attempt: Attempt,
) -> Result(Sut, statem.Violation) {
  case dict.get(sut.cells, key) {
    Error(Nil) -> Error(violation("answer", "the row to answer is not stored"))
    Ok(cell) -> {
      use row <- result.try(
        peer_outbox.decode(cell)
        |> result.map_error(fn(why) { violation("codec", why) }),
      )
      let outcome = case attempt {
        Landed -> Receipt(receipt_for(row))
        Silent -> Unanswered
        Declined -> Rejected("declined")
        Saved -> NotOpen
      }
      case peer_outbox.settle(row, outcome) {
        Some(next) -> Ok(put(sut, key, next))
        None -> Ok(sut)
      }
    }
  }
}

// The drainer's pass: each pending row is offered to `expire`, which refuses it
// past the limit, with the words for what it waited for.
fn sweep_rows(sut: Sut, now: Int) -> Result(Sut, statem.Violation) {
  use rows <- result.try(stored(sut))
  Ok(
    list.fold(rows, sut, fn(held, pair) {
      case peer_outbox.is_pending(pair.1) {
        False -> held
        True ->
          case
            peer_outbox.expire(
              pair.1,
              now,
              peer_outbox.expiry_reason(pair.1, owner_reason, open_reason),
            )
          {
            Some(next) -> put(held, pair.0, next)
            None -> held
          }
      }
    }),
  )
}

fn unlink_rows(
  sut: Sut,
  strand: String,
  target: String,
) -> Result(Sut, statem.Violation) {
  use rows <- result.try(stored(sut))
  Ok(
    Sut(
      cells: list.fold(rows, sut.cells, fn(held, pair) {
        let row = pair.1
        case
          peer_outbox.is_pending(row)
          && row.strand == strand
          && row.session == session
          && row.target_strand == target
        {
          True -> dict.delete(held, pair.0)
          False -> held
        }
      }),
    ),
  )
}

fn execute(
  mix: Mix,
  sut: Sut,
  model: Model,
  command: Command,
) -> Result(Sut, statem.Violation) {
  let #(expected, after) = reference(mix, model, command)
  use #(moved, claimed) <- result.try(case command {
    Claim(..) -> {
      let wanted = case reference_ref(mix, model, command) {
        Some(ref) -> row_of(ref)
        None -> row_of(claimed_ref(mix, model, 0, 0, 0))
      }
      claim_row(sut, wanted)
    }
    Answer(pick:, attempt:) ->
      case list.drop(ordered(model), pick % int.max(dict.size(model.rows), 1)) {
        [ref, ..] ->
          answer_row(sut, key_of(ref), attempt)
          |> result.map(fn(moved) { #(moved, Wrote) })
        [] -> Ok(#(sut, Wrote))
      }
    Sweep ->
      sweep_rows(sut, model.now) |> result.map(fn(moved) { #(moved, Wrote) })
    Wait(..) -> Ok(#(sut, Wrote))
    Unlink(strand:, target:) ->
      unlink_rows(sut, strand_name(mix, strand), at(targets, target))
      |> result.map(fn(moved) { #(moved, Wrote) })
  })
  use Nil <- result.try(agree("outcome", claimed, expected))
  use before <- result.try(stored(sut))
  use now <- result.try(stored(moved))
  use Nil <- result.try(agree(
    "rows",
    list.sort(now, fn(a, b) { string.compare(a.0, b.0) }),
    list.sort(
      list.map(dict.values(after.rows), fn(ref) { #(key_of(ref), row_of(ref)) }),
      fn(a, b) { string.compare(a.0, b.0) },
    ),
  ))
  use Nil <- result.try(bound(now))
  use Nil <- result.try(kept(before, now))
  Ok(moved)
}

// The claim's row, built the way the reference builds it.
fn reference_ref(mix: Mix, model: Model, command: Command) -> Option(Ref) {
  case command {
    Claim(strand:, message:, content:) ->
      Some(claimed_ref(mix, model, strand, message, content))
    Answer(..) | Sweep | Wait(..) | Unlink(..) -> None
  }
}

// No strand holds more rows than the bound.
fn bound(rows: List(#(String, Row))) -> Result(Nil, statem.Violation) {
  let counts =
    list.fold(rows, dict.new(), fn(held, pair) {
      dict.insert(
        held,
        { pair.1 }.strand,
        1 + result.unwrap(dict.get(held, { pair.1 }.strand), 0),
      )
    })
  agree(
    "bound",
    list.all(dict.values(counts), fn(count) { count <= peer_outbox.row_limit }),
    True,
  )
}

// An admitted row never moves, a refused row is only replaced by a repeat of
// its id, and a pending row changes only what it waits for. A row that is gone
// was evicted or unlinked, which the rows check accounts for.
fn kept(
  before: List(#(String, Row)),
  now: List(#(String, Row)),
) -> Result(Nil, statem.Violation) {
  list.try_each(before, fn(pair) {
    let #(key, row) = pair
    case list.key_find(now, key), row.state {
      Ok(later), Admitted(_) -> agree("admitted-immutable", later, row)
      Ok(later), Refused(_) ->
        agree("refused-replaced-only", #(later.strand, later.message_id), #(
          row.strand,
          row.message_id,
        ))
      Ok(later), Pending(text:, ..) ->
        agree(
          "pending-text",
          #(later.target_strand, later.queued_at, case later.state {
            Pending(text: now_text, ..) -> now_text
            Admitted(_) | Refused(_) -> text
          }),
          #(row.target_strand, row.queued_at, text),
        )
      Error(Nil), _ -> Ok(Nil)
    }
  })
}

// --- the property -----------------------------------------------------------

fn spec(mix: Mix) -> statem.Spec(Model, Command, Sut) {
  statem.Spec(
    initial: fresh(),
    command: command(mix),
    precondition: fn(model, command) {
      case command, dict.size(model.rows) {
        Answer(..), 0 -> statem.Reject
        Answer(..), _ | Claim(..), _ | Sweep, _ | Wait(..), _ | Unlink(..), _ ->
          statem.Admit
      }
    },
    next_model: fn(model, command) { reference(mix, model, command).1 },
    new_sut: fn() { Sut(cells: dict.new()) },
    execute: fn(sut, model, command) { execute(mix, sut, model, command) },
    finish: fn(_, _) { Ok(Nil) },
    teardown: fn(_) { Nil },
  )
}

fn checked(mix: Mix) -> Nil {
  case statem.check(spec(mix), config(mix)) {
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

pub fn the_outbox_keeps_its_rules_when_one_message_is_sent_again_test() {
  checked(tangled)
}

pub fn the_outbox_keeps_its_bound_when_finished_rows_are_evicted_test() {
  checked(crowded)
}

pub fn the_outbox_refuses_when_every_row_is_pending_test() {
  checked(jammed)
}

// --- the generator is worth testing with ------------------------------------

fn numbers(start: Int, stop: Int) -> List(Int) {
  int.range(from: start, to: stop, with: [], run: fn(all, number) {
    [number, ..all]
  })
  |> list.reverse
}

fn outcomes(mix: Mix) -> set.Set(String) {
  list.fold(numbers(0, mix.runs), set.new(), fn(found, run) {
    let #(_, labels) =
      list.fold(
        statem.commands(spec(mix), config(mix), run),
        #(fresh(), []),
        fn(state, command) {
          let #(model, labels) = state
          let #(claimed, next) = reference(mix, model, command)
          #(next, [label(command, claimed), ..labels])
        },
      )
    set.union(found, set.from_list(labels))
  })
}

fn label(command: Command, claimed: Claimed) -> String {
  case command, claimed {
    Claim(..), Wrote -> "wrote"
    Claim(..), WroteAfterEvicting(_) -> "evicted"
    Claim(..), Resumed -> "resumed"
    Claim(..), AlreadyAdmitted -> "already-admitted"
    Claim(..), Conflicted -> "conflicted"
    Claim(..), Jammed -> "jammed"
    Answer(..), _ -> "answered"
    Sweep, _ -> "swept"
    Wait(..), _ -> "waited"
    Unlink(..), _ -> "unlinked"
  }
}

pub fn the_sequences_reach_every_outcome_the_rules_name_test() {
  let tangled_cases = outcomes(tangled)
  let crowded_cases = outcomes(crowded)
  let jammed_cases = outcomes(jammed)
  assert list.filter(
      [
        "wrote",
        "resumed",
        "already-admitted",
        "conflicted",
        "answered",
        "swept",
        "unlinked",
      ],
      fn(label) { !set.contains(tangled_cases, label) },
    )
    == []
    as "the tangled campaign never reached every outcome"
  assert set.contains(crowded_cases, "evicted")
  assert set.contains(jammed_cases, "jammed")
}
