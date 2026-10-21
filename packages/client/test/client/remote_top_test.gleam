//// The vocabulary of a spawner's page driving top-level sessions
//// (protocol-change/094): what each refusal says, how the offers and the pages
//// of sessions are bounded, and that their decoders are total.
////
//// A decoder is total when every input is an `Ok` or an `Error` and no input
//// crashes it. The property tests below feed each decoder values drawn from a
//// fixed seed: arbitrary JSON, and valid encodings with one member deleted,
//// retyped or replaced. Whatever decodes is checked to encode back to the same
//// value, so a decoder cannot accept something it would not itself produce.

import client/protocol
import client/remote_top.{
  Archived, CapReached, Degraded, Down, Folder, FolderOffer, Full, Idle,
  InvalidArgument, NeedsYou, NotOffered, NotRelayed, NotYetOpen, OfferedExecutor,
  Offers, PoolOffer, Pooled, Ready, Row, StoreFailure, TopLevelOff,
  UnknownSpawner, Working, Workspace,
}
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import qcheck
import session_view/remote_agent

const seed = 94

// The numbers one to `count`.
fn numbers(count: Int) -> List(Int) {
  list.index_map(list.repeat(0, count), fn(_, index) { index + 1 })
}

const draws = 200

fn config() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(draws)
  |> qcheck.with_seed(qcheck.seed(seed))
}

fn record(seq: Int, preview: String) -> protocol.EscalationRecord {
  protocol.EscalationRecord(
    escalation_id: "policy-" <> int.to_string(seq),
    op: "op",
    strand: "main",
    status: "pending",
    tool: "bash",
    action: "digest",
    preview:,
    asked: 1,
    denial: None,
    seq:,
    origin: None,
    placement: None,
    admitted: Some([]),
  )
}

fn row(n: Int, requests: List(protocol.EscalationRecord)) -> remote_top.Row {
  Row(
    session_id: "0198c0de-0000-7000-8000-" <> int.to_string(100 + n),
    request_id: "0198c0de-1111-7000-8000-" <> int.to_string(100 + n),
    name: "session " <> int.to_string(n),
    placement: Workspace(executor: "exec", name: "repo"),
    activity: Working,
    updated_at: 1000 + n,
    requests:,
    more: 0,
    children: [],
  )
}

// --- refusals ----------------------------------------------------------------

pub fn every_refusal_says_what_it_means_test() {
  assert remote_top.describe_refusal(UnknownSpawner("laptop@10.0.0.1"))
    == "this orchestrator has no [spawners.<name>] for the node laptop@10.0.0.1"
  assert string.contains(remote_top.describe_refusal(TopLevelOff), "top_level")
  assert remote_top.describe_refusal(NotOffered(OfferedExecutor, "exec"))
    == "this orchestrator does not offer the executor exec to your orchestrator"
  assert remote_top.describe_refusal(CapReached(remote_top.MaxSessions, 8))
    == "the orchestrator already holds 8 of your sessions (max_sessions)"
  assert remote_top.describe_refusal(CapReached(remote_top.MaxPerHour, 10))
    == "your orchestrator has started 10 sessions there in the last hour (max_per_hour)"
  assert remote_top.describe_refusal(NotRelayed)
    == "that session was not started by your orchestrator"
  assert remote_top.describe_refusal(InvalidArgument("bad")) == "bad"
}

pub fn only_a_receiver_that_could_not_try_is_worth_asking_again_test() {
  assert remote_top.retryable(NotYetOpen("opening"))
  assert remote_top.retryable(StoreFailure("busy"))
  assert !remote_top.retryable(NotRelayed)
  assert !remote_top.retryable(TopLevelOff)
  assert !remote_top.retryable(UnknownSpawner("n"))
  assert !remote_top.retryable(CapReached(remote_top.MaxPerHour, 1))
  assert !remote_top.retryable(NotOffered(OfferedExecutor, "x"))
  assert !remote_top.retryable(InvalidArgument("x"))
}

// --- offers --------------------------------------------------------------------

fn offers() -> remote_top.Offers {
  Offers(
    folders: [FolderOffer(path: "/srv/work", label: "work")],
    executors: [
      remote_top.ExecutorOffer(
        name: "exec",
        state: Degraded,
        free_scopes: Some(3),
        workspaces: ["repo", "docs"],
      ),
      remote_top.ExecutorOffer(
        name: "old",
        state: Down,
        free_scopes: None,
        workspaces: [],
      ),
    ],
    pools: [PoolOffer(name: "linux", ready: 2, workspaces: ["repo"])],
    profiles: ["default", "codex"],
    models: ["fast"],
  )
}

pub fn offers_round_trip_through_json_test() {
  assert remote_top.decode_offers(remote_top.encode_offers(offers()))
    == Ok(offers())
  assert remote_top.decode_offers(
      remote_top.encode_offers(remote_top.no_offers()),
    )
    == Ok(remote_top.no_offers())
  assert remote_top.entries(offers()) == 7
}

pub fn every_executor_state_survives_the_wire_test() {
  list.each([Ready, Degraded, Full, Down], fn(state) {
    let one =
      Offers(..remote_top.no_offers(), executors: [
        remote_top.ExecutorOffer(
          name: "e",
          state:,
          free_scopes: None,
          workspaces: [],
        ),
      ])
    assert remote_top.decode_offers(remote_top.encode_offers(one)) == Ok(one)
  })
}

pub fn the_offers_are_cut_to_the_entry_bound_in_order_test() {
  let many = list.map(numbers(300), fn(n) { "p" <> int.to_string(n) })
  let big = Offers(..offers(), profiles: many, models: many)
  let cut = remote_top.bounded(big)
  assert remote_top.entries(cut) == remote_top.max_offers

  // The earlier lists are whole, and the cut falls in the profiles.
  assert cut.folders == offers().folders
  assert cut.executors == offers().executors
  assert cut.pools == offers().pools
  assert list.length(cut.profiles) == remote_top.max_offers - 4
  assert cut.models == []
  assert result.is_ok(remote_top.decode_offers(remote_top.encode_offers(cut)))
}

pub fn a_workspace_list_is_cut_to_its_bound_test() {
  let names = list.map(numbers(100), fn(n) { "w" <> int.to_string(n) })
  let one =
    Offers(..remote_top.no_offers(), pools: [
      PoolOffer(name: "p", ready: 1, workspaces: names),
    ])
  let assert [pool] = remote_top.bounded(one).pools
  assert list.length(pool.workspaces) == remote_top.max_workspaces
}

pub fn offers_that_break_a_bound_are_refused_whole_test() {
  let too_many =
    Offers(
      ..remote_top.no_offers(),
      profiles: list.map(numbers(257), int.to_string),
    )
  assert remote_top.decode_offers(remote_top.encode_offers(too_many))
    == Error("profiles holds too many entries")

  let long = string.repeat("x", remote_top.max_text_bytes + 1)
  let assert Error(_) =
    remote_top.decode_offers(remote_top.encode_offers(
      Offers(..offers(), profiles: [long]),
    ))

  let bad_state =
    json.Object([
      #("folders", json.Array([])),
      #(
        "executors",
        json.Array([
          json.Object([
            #("name", json.String("e")),
            #("state", json.String("asleep")),
            #("free_scopes", json.Null),
            #("workspaces", json.Array([])),
          ]),
        ]),
      ),
      #("pools", json.Array([])),
      #("profiles", json.Array([])),
      #("models", json.Array([])),
    ])
  assert remote_top.decode_offers(bad_state)
    == Error("state is not a known executor state")

  // The entries are bounded in total, not only per list.
  let spread =
    Offers(
      ..remote_top.no_offers(),
      profiles: list.map(numbers(200), int.to_string),
      models: list.map(numbers(100), int.to_string),
    )
  assert remote_top.decode_offers(remote_top.encode_offers(spread))
    == Error("offers hold too many entries")
  assert remote_top.decode_offers(json.Null) == Error("offers is not an object")
  assert remote_top.decode_offers(json.Object([]))
    == Error("folders is not an array")
}

// --- rows and pages -------------------------------------------------------------

pub fn a_row_round_trips_with_its_requests_and_children_test() {
  let child =
    remote_agent.RemoteAgent(
      id: "sub:^main/x",
      parent: "main",
      orchestrator: "other",
      standing: remote_agent.Running,
      title: "t",
      summary: "s",
      tokens: 4,
      model: "fast",
      age_ms: Some(10),
    )
  let full =
    Row(
      ..row(1, [record(3, "a"), record(5, "b")]),
      placement: Pooled(pool: "linux", name: "repo"),
      activity: NeedsYou,
      more: 2,
      children: [child],
    )
  assert remote_top.decode_row(remote_top.encode_row(full)) == Ok(full)
  list.each(
    [
      Folder("/srv/work"),
      Workspace(executor: "e", name: "w"),
      Pooled(pool: "p", name: "w"),
    ],
    fn(placement) {
      assert remote_top.decode_placement(remote_top.encode_placement(placement))
        == Ok(placement)
    },
  )
  list.each([NeedsYou, Working, Idle, Archived], fn(activity) {
    let one = Row(..row(1, []), activity:)
    assert remote_top.decode_row(remote_top.encode_row(one)) == Ok(one)
  })
}

pub fn requests_are_the_oldest_eight_by_seq_with_the_rest_counted_test() {
  let pending =
    list.map([9, 3, 12, 1, 7, 5, 11, 2, 8, 4, 10, 6], fn(n) { record(n, "x") })
  let #(kept, more) = remote_top.fit_requests(pending, 200)
  assert list.map(kept, fn(r) { r.seq }) == [1, 2, 3, 4, 5, 6, 7, 8]
  assert more == 4
  assert remote_top.fit_requests([], 200) == #([], 0)
}

pub fn a_row_with_huge_requests_still_fits_the_row_bound_test() {
  let large = string.repeat("p", 10_000)
  let pending = list.map([1, 2, 3, 4, 5], fn(n) { record(n, large) })
  let #(kept, more) = remote_top.fit_requests(pending, 600)
  assert list.length(kept) + more == 5
  let encoded =
    json.to_string(remote_top.encode_row(Row(..row(1, kept), more:)))
  assert string.byte_size(encoded) <= remote_top.max_row_bytes
  assert list.map(kept, fn(r) { r.seq }) == [1, 2]
}

pub fn a_page_holds_at_most_sixty_four_rows_test() {
  let rows = list.map(numbers(100), fn(n) { row(n, []) })
  let page = remote_top.page_of(rows, remote_top.Last)
  assert list.length(page.rows) == remote_top.max_rows
  assert page.more == remote_top.Further
  assert page.rows == list.take(rows, remote_top.max_rows)
}

pub fn a_page_is_cut_at_the_byte_bound_and_never_splits_a_row_test() {
  let large = string.repeat("p", 4000)
  let rows =
    list.map(numbers(40), fn(n) {
      let #(kept, more) =
        remote_top.fit_requests(
          list.map([1, 2, 3, 4, 5, 6, 7, 8], fn(q) { record(q, large) }),
          600,
        )
      Row(..row(n, kept), more:)
    })
  let page = remote_top.page_of(rows, remote_top.Last)
  assert string.byte_size(json.to_string(remote_top.encode_page(page)))
    <= remote_top.max_page_bytes
  assert page.more == remote_top.Further
  assert page.rows != []
  assert page.rows == list.take(rows, list.length(page.rows))
  assert remote_top.decode_page(remote_top.encode_page(page)) == Ok(page)
}

pub fn a_page_that_fits_ends_with_the_callers_word_test() {
  let rows = [row(1, []), row(2, [])]
  assert remote_top.page_of(rows, remote_top.Last).more == remote_top.Last
  assert remote_top.page_of(rows, remote_top.Further).more == remote_top.Further
  assert remote_top.page_of([], remote_top.Last) == remote_top.empty_page()
}

pub fn a_page_over_its_bounds_is_refused_whole_test() {
  let rows = list.map(numbers(65), fn(n) { row(n, []) })
  let over = remote_top.SessionsPage(rows:, more: remote_top.Last)
  assert remote_top.decode_page(remote_top.encode_page(over))
    == Error("rows holds too many entries")

  let requests = list.map(numbers(9), fn(n) { record(n, "x") })
  let crowded = remote_top.SessionsPage([row(1, requests)], remote_top.Last)
  assert remote_top.decode_page(remote_top.encode_page(crowded))
    == Error("requests holds too many entries")

  let heavy =
    remote_top.SessionsPage(
      [row(1, [record(1, string.repeat("x", 70_000))])],
      remote_top.Last,
    )
  assert remote_top.decode_page(remote_top.encode_page(heavy))
    == Error("page is larger than a page may be")
}

// --- totality ----------------------------------------------------------------------

fn json_text() -> qcheck.Generator(String) {
  qcheck.bounded_int(0, 5)
  |> qcheck.map(fn(pick) {
    case pick {
      0 -> ""
      1 -> "main"
      2 -> "needs_you"
      3 -> "workspace"
      4 -> "last"
      _ -> "ready"
    }
  })
}

fn json_value(depth: Int) -> qcheck.Generator(JsonValue) {
  let leaf =
    qcheck.from_generators(qcheck.return(json.Null), [
      qcheck.return(json.Bool(True)),
      qcheck.map(qcheck.bounded_int(-3, 70), json.Int),
      qcheck.map(json_text(), json.String),
    ])
  case depth {
    0 -> leaf
    _ ->
      qcheck.from_generators(leaf, [
        qcheck.map(
          qcheck.generic_list(
            elements_from: json_value(depth - 1),
            length_from: qcheck.bounded_int(0, 3),
          ),
          json.Array,
        ),
        qcheck.map(
          qcheck.generic_list(
            elements_from: qcheck.tuple2(
              qcheck.from_generators(
                qcheck.return("rows"),
                list.map(
                  [
                    "more", "kind", "path", "name", "state", "ready", "activity",
                    "requests", "children", "folders", "executors", "pools",
                    "profiles", "models", "placement", "session_id",
                  ],
                  qcheck.return,
                ),
              ),
              json_value(depth - 1),
            ),
            length_from: qcheck.bounded_int(0, 6),
          ),
          json.Object,
        ),
      ])
  }
}

// A valid encoding with one member removed, retyped or replaced, found by
// walking to the nth object member in document order.
fn mutate(value: JsonValue, target: Int, how: Int) -> JsonValue {
  let #(mutated, _) = walk(value, target, how)
  mutated
}

fn walk(value: JsonValue, target: Int, how: Int) -> #(JsonValue, Int) {
  case value {
    json.Object(members) -> {
      let #(rebuilt, left) =
        list.fold(members, #([], target), fn(state, member) {
          let #(done, left) = state
          let #(key, inner) = member
          case left {
            0 -> #(list.append(done, replaced(key, inner, how)), -1)
            _ -> {
              let #(inner, left) = walk(inner, left - 1, how)
              #(list.append(done, [#(key, inner)]), left)
            }
          }
        })
      #(json.Object(rebuilt), left)
    }
    json.Array(items) -> {
      let #(rebuilt, left) =
        list.fold(items, #([], target), fn(state, item) {
          let #(done, left) = state
          let #(item, left) = walk(item, left, how)
          #(list.append(done, [item]), left)
        })
      #(json.Array(rebuilt), left)
    }
    other -> #(other, target)
  }
}

fn replaced(
  key: String,
  inner: JsonValue,
  how: Int,
) -> List(#(String, JsonValue)) {
  case how {
    0 -> []
    1 -> [#(key, json.Null)]
    2 -> [#(key, json.String("x"))]
    3 -> [#(key, json.Int(-1))]
    4 -> [#(key, json.Array([inner]))]
    _ -> [#(key, json.Object([]))]
  }
}

fn sample_page() -> remote_top.SessionsPage {
  remote_top.SessionsPage(
    rows: [row(1, [record(2, "a")]), row(2, [])],
    more: remote_top.Further,
  )
}

pub fn the_offers_decoder_is_total_test() {
  qcheck.run(config(), json_value(3), fn(value) {
    case remote_top.decode_offers(value) {
      Ok(found) -> {
        assert remote_top.decode_offers(remote_top.encode_offers(found))
          == Ok(found)
      }
      Error(_) -> Nil
    }
  })
  qcheck.run(
    config(),
    qcheck.tuple2(qcheck.bounded_int(0, 40), qcheck.bounded_int(0, 5)),
    fn(drawn) {
      let #(target, how) = drawn
      case
        remote_top.decode_offers(mutate(
          remote_top.encode_offers(offers()),
          target,
          how,
        ))
      {
        Ok(found) -> {
          assert remote_top.decode_offers(remote_top.encode_offers(found))
            == Ok(found)
        }
        Error(_) -> Nil
      }
    },
  )
}

pub fn the_page_decoder_is_total_test() {
  qcheck.run(config(), json_value(3), fn(value) {
    case remote_top.decode_page(value) {
      Ok(found) -> {
        assert remote_top.decode_page(remote_top.encode_page(found))
          == Ok(found)
      }
      Error(_) -> Nil
    }
  })
  qcheck.run(
    config(),
    qcheck.tuple2(qcheck.bounded_int(0, 80), qcheck.bounded_int(0, 5)),
    fn(drawn) {
      let #(target, how) = drawn
      case
        remote_top.decode_page(mutate(
          remote_top.encode_page(sample_page()),
          target,
          how,
        ))
      {
        Ok(found) -> {
          assert remote_top.decode_page(remote_top.encode_page(found))
            == Ok(found)
        }
        Error(_) -> Nil
      }
    },
  )
}

pub fn the_placement_decoder_is_total_test() {
  qcheck.run(config(), json_value(3), fn(value) {
    case remote_top.decode_placement(value) {
      Ok(found) -> {
        assert remote_top.decode_placement(remote_top.encode_placement(found))
          == Ok(found)
      }
      Error(_) -> Nil
    }
  })
}

pub fn text_over_the_bound_is_cut_in_a_row_and_left_out_of_the_offers_test() {
  let long = string.repeat("é", remote_top.max_text_bytes)
  assert string.byte_size(remote_top.clip(long)) <= remote_top.max_text_bytes
  assert remote_top.clip("work") == "work"
  assert remote_top.fits("work")
  assert !remote_top.fits(long)

  // A row with an over-long name and folder still decodes, so one remembered
  // folder cannot make a page unreadable.
  let wide =
    remote_top.Row(
      ..row(1, []),
      name: long,
      placement: Folder(path: "/" <> long),
    )
  let page = remote_top.SessionsPage(rows: [wide], more: remote_top.Last)
  let assert Ok(read) = remote_top.decode_page(remote_top.encode_page(page))
  let assert [only] = read.rows
  assert remote_top.fits(only.name)

  // The offers drop what the decoder would refuse.
  let offers =
    Offers(
      ..offers(),
      folders: [
        FolderOffer(path: "/" <> long, label: "x"),
        FolderOffer(path: "/srv/work", label: "work"),
      ],
      profiles: [long, "alt"],
    )
  let kept = remote_top.bounded(offers)
  assert kept.folders == [FolderOffer(path: "/srv/work", label: "work")]
  assert kept.profiles == ["alt"]
  assert result.is_ok(remote_top.decode_offers(remote_top.encode_offers(kept)))
}
