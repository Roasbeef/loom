//// An offline retrieval benchmark for `history_search` as the memory tool.
////
//// The corpus is synthetic and deterministic: four sessions of routine
//// filler (builds, module names, compiler chatter) with thirteen distinct
//// facts planted among it, spread over sessions and over the four entry
//// kinds. Nothing here calls a model. What it measures is whether the index,
//// asked in plain words, hands a planted fact back, so "is recall useful"
//// has a number that can be re-run after any change to the index.
////
//// Four properties are asserted: every planted fact is found by two or three
//// of its own words; the `kind` filter narrows and never widens; walking
//// `before` visits older hits without repeating one; and a malformed-looking
//// query is text in `Words` syntax rather than a fault. A fifth test prints
//// how often ten facts are found by paraphrases, each asked three ways, under
//// the old exact-quoted-word matching and under prefix terms with `OR`.

import core/clock
import core/entry.{type Entry}
import core/ids
import events/search
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import support/fixtures

// One planted fact. `lead` is a few of its own words; `paraphrases` are
// wordings the text itself does not use.
type Fact {
  Fact(
    session: Int,
    slot: Int,
    kind: String,
    text: String,
    lead: String,
    paraphrases: List(String),
  )
}

fn facts() -> List(Fact) {
  [
    Fact(
      1,
      3,
      "user",
      "Pin the zephyr toolchain to version 4.2 before shipping",
      "zephyr toolchain",
      ["zephyr toolchains pinned", "zephyr tool", "zephyr OR boreas version"],
    ),
    Fact(
      1,
      9,
      "assistant",
      "The nightly backup job runs at 03:15 UTC and writes to the cobalt bucket",
      "cobalt bucket",
      [
        "backups cobalt bucket",
        "cobalt storage",
        "nightly OR scheduled backup cobalt",
      ],
    ),
    Fact(
      1,
      15,
      "tool",
      "ERROR: handshake timeout contacting quokka gateway after 30 seconds",
      "quokka gateway",
      [
        "quokka gateway timed out",
        "quokka timeout",
        "quokka OR wombat handshake",
      ],
    ),
    Fact(
      1,
      21,
      "user",
      "Default timezone for scheduled reports is Lagos",
      "timezone Lagos",
      [],
    ),
    Fact(
      2,
      4,
      "user",
      "We agreed to deprecate the legacy ledger endpoint after the margarita migration",
      "margarita migration",
      [
        "deprecating ledger endpoint",
        "legacy ledger OR accounts margarita",
        "margarita",
      ],
    ),
    Fact(
      2,
      10,
      "assistant",
      "Decision: use sqlite WAL mode for the walrus cache because readers must not block writers",
      "walrus cache",
      ["walrus cache wal", "walrus caching", "walrus OR seal journal"],
    ),
    Fact(
      2,
      18,
      "assistant",
      "Avoid the tangerine allocator in production, it fragments badly",
      "tangerine allocator",
      [],
    ),
    Fact(
      3,
      5,
      "user",
      "Remember that the staging database password rotates every ninety days",
      "staging password",
      [
        "staging db password rotation",
        "rotates staging password",
        "staging passwords",
      ],
    ),
    Fact(
      3,
      12,
      "summary",
      "Summary: the team chose gleam over elixir for the harness and rejected the orbital scheduler",
      "orbital scheduler",
      [
        "orbital scheduling",
        "gleam elixir harness",
        "orbital OR planetary scheduler",
      ],
    ),
    Fact(
      3,
      20,
      "assistant",
      "Fixed the flaky pelican test by seeding the random generator",
      "pelican test",
      [
        "pelican flakiness seeded",
        "flaky pelican tests",
        "pelican OR heron test fix",
      ],
    ),
    Fact(
      4,
      6,
      "user",
      "Our release manager is Okonkwo and she signs off on every tagged build",
      "Okonkwo release",
      [
        "okonkwo signs releases",
        "release manager",
        "okonkwo OR adeyemi approval",
      ],
    ),
    Fact(
      4,
      14,
      "tool",
      "warning: deprecated flag --xylophone will be removed in v9",
      "xylophone flag",
      [
        "xylophone flags deprecated",
        "xylophone removal",
        "xylophone OR marimba deprecation",
      ],
    ),
    Fact(
      4,
      22,
      "assistant",
      "The latency regression was caused by the lantern connection pool exhausting at 64 sockets",
      "lantern pool",
      [],
    ),
  ]
}

// How many filler entries each session carries.
const filler_per_session = 24

// One through `n`.
fn upto(n: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, n), fn(_, index) { index + 1 })
}

fn sid(n: Int) -> ids.SessionId {
  let #(id, _generator) =
    ids.mint_session(ids.generator(
      clock.fixed(at: 1_700_000_000_000 + n),
      seed: n,
    ))
  id
}

fn filler(session: Int, index: Int) -> #(String, String) {
  let module = int.to_string(session * 100 + index)
  case index % 3 {
    0 -> #("user", "please look at the build output for module " <> module)
    1 -> #(
      "assistant",
      "I reviewed module " <> module <> " and the build is routine",
    )
    _ -> #(
      "tool",
      "compiling module " <> module <> " finished ok, build step done",
    )
  }
}

fn make(
  ctx: fixtures.Ctx,
  parent: Option(ids.EntryId),
  kind: String,
  text: String,
) -> #(Entry, fixtures.Ctx) {
  case kind {
    "user" -> fixtures.message_entry(ctx, parent, text)
    "assistant" -> fixtures.assistant_entry(ctx, parent, text)
    "tool" -> fixtures.tool_entry(ctx, parent, text)
    _ -> fixtures.compaction_entry(ctx, parent, text)
  }
}

// The planted facts paired with the id of the entry that carries each, and
// the open index holding all four sessions.
fn corpus() -> #(search.Search, List(#(Fact, String))) {
  let assert Ok(service) = search.open(":memory:")
    as "in-memory search database must open"
  let #(_ctx, planted) =
    list.fold(upto(4), #(fixtures.new_ctx(), []), fn(state, session) {
      let #(ctx, planted) = state
      let store = fixtures.open_store()
      let specs =
        upto(filler_per_session)
        |> list.flat_map(fn(index) {
          let #(kind, text) = filler(session, index)
          let here =
            list.filter(facts(), fn(fact) {
              fact.session == session && fact.slot == index
            })
          [
            #(kind, text, None),
            ..list.map(here, fn(fact) { #(fact.kind, fact.text, Some(fact)) })
          ]
        })
      let #(ctx, _parent, entries, planted) =
        list.fold(specs, #(ctx, None, [], planted), fn(acc, spec) {
          let #(ctx, parent, entries, planted) = acc
          let #(kind, text, fact) = spec
          let #(made, ctx) = make(ctx, parent, kind, text)
          let planted = case fact {
            Some(fact) -> [#(fact, ids.entry_id_to_string(made.id)), ..planted]
            None -> planted
          }
          #(ctx, Some(made.id), [made, ..entries], planted)
        })
      fixtures.commit_entries(store, list.reverse(entries))
      let assert Ok(Nil) =
        search.sync(service, store, session: sid(session), generation: 0)
      #(ctx, planted)
    })
  #(service, list.reverse(planted))
}

fn hits_for(service: search.Search, query: search.Query) -> List(search.Hit) {
  let assert Ok(hits) = search.query(service, query)
  hits
}

fn finds(service: search.Search, query: search.Query, entry: String) -> Bool {
  case search.query(service, query) {
    Ok(hits) -> list.any(hits, fn(hit) { hit.entry == entry })
    Error(_) -> False
  }
}

pub fn every_planted_fact_is_found_by_its_own_words_test() {
  let #(service, planted) = corpus()
  assert list.length(planted) == 13

  list.each(planted, fn(pair) {
    let #(fact, entry) = pair
    let hits = hits_for(service, search.words(fact.lead, 5))
    let assert Ok(hit) = list.find(hits, fn(hit) { hit.entry == entry })
    assert hit.kind == fact.kind
    assert hit.ts > 0
  })
}

pub fn kind_filter_narrows_and_never_widens_test() {
  let #(service, planted) = corpus()
  let everything = hits_for(service, search.words("build", 50))

  list.each(["user", "assistant", "tool"], fn(kind) {
    let narrowed =
      hits_for(
        service,
        search.Query(..search.words("build", 50), kind: Some(kind)),
      )
    assert narrowed != []
    assert list.all(narrowed, fn(hit) { hit.kind == kind })
    assert list.length(narrowed) <= list.length(everything)
  })

  // The one summary in the corpus is the only hit a summary filter allows.
  let assert [summary] =
    hits_for(
      service,
      search.Query(..search.words("gleam", 10), kind: Some("summary")),
    )
  let assert Ok(#(_, expected)) =
    list.find(planted, fn(pair) { { pair.0 }.kind == "summary" })
  assert summary.entry == expected

  // A kind nothing carries matches nothing, and is not an error.
  assert search.query(
      service,
      search.Query(..search.words("build", 10), kind: Some("bogus")),
    )
    == Ok([])
}

pub fn before_walks_to_older_hits_without_repeating_test() {
  let #(service, planted) = corpus()

  // Without `before` the hits are ranked, and a page honours its limit.
  assert list.length(hits_for(service, search.words("build", 5))) == 5

  // From the newest planted entry, `before` pages strictly downward.
  let assert [newest, ..] =
    planted
    |> list.map(fn(pair) { pair.1 })
    |> list.sort(string.compare)
    |> list.reverse
  let visited = walk(service, Some(newest), [], 0)

  // Five per page over far more matches means the walk really paged, and
  // every entry was seen once.
  assert list.length(visited) > 40
  assert list.length(visited) == list.length(list.unique(visited))
}

fn walk(
  service: search.Search,
  before: Option(String),
  seen: List(String),
  pages: Int,
) -> List(String) {
  assert pages < 50
  let page =
    hits_for(service, search.Query(..search.words("build", 5), before:))
  case page {
    [] -> seen
    _ -> {
      let entries = list.map(page, fn(hit) { hit.entry })

      // Every hit is strictly older than the anchor the page was asked for.
      case before {
        Some(anchor) ->
          list.each(entries, fn(entry) {
            assert string.compare(entry, anchor) == order.Lt
          })
        None -> Nil
      }
      let assert [oldest, ..] = list.sort(entries, string.compare)
      walk(service, Some(oldest), list.append(seen, entries), pages + 1)
    }
  }
}

pub fn words_syntax_treats_punctuation_as_text_test() {
  let #(service, planted) = corpus()

  // None of these is valid FTS5, and none may be a fault.
  list.each(["foo-bar", "a:b", "\"", "it's (odd) *", "NOT", "OR"], fn(text) {
    let assert Ok(_) = search.query(service, search.words(text, 5))
  })

  // A bare OR between two words is the operator; a prefix finds a longer word.
  let assert Ok(#(_, zephyr_id)) =
    list.find(planted, fn(pair) { string.contains({ pair.0 }.text, "zephyr") })
  let assert Ok(#(_, quokka_id)) =
    list.find(planted, fn(pair) { string.contains({ pair.0 }.text, "quokka") })
  let either = hits_for(service, search.words("zephyr OR quokka", 10))
  assert list.any(either, fn(hit) { hit.entry == zephyr_id })
  assert list.any(either, fn(hit) { hit.entry == quokka_id })
  assert finds(service, search.words("tool", 10), zephyr_id)
}

// The exact-quoted-word matching `Words` used before prefix terms: every
// token is a whole quoted word and every token must match.
fn exact_words(text: String) -> search.Query {
  let quoted =
    text
    |> string.split(" ")
    |> list.filter(fn(token) { token != "" })
    |> list.map(fn(token) { "\"" <> token <> "\"" })
    |> string.join(" ")
  search.raw(quoted, 10)
}

pub fn paraphrase_recall_report_test() {
  let #(service, planted) = corpus()
  let asked =
    list.flat_map(planted, fn(pair) {
      let #(fact, entry) = pair
      list.map(fact.paraphrases, fn(wording) { #(wording, entry) })
    })
  let before =
    list.count(asked, fn(pair) { finds(service, exact_words(pair.0), pair.1) })
  let after =
    list.count(asked, fn(pair) {
      finds(service, search.words(pair.0, 10), pair.1)
    })
  io.println(
    "paraphrase recall over "
    <> int.to_string(list.length(asked))
    <> " wordings: exact quoted words found "
    <> int.to_string(before)
    <> ", prefix plus OR found "
    <> int.to_string(after),
  )
  assert list.length(asked) == 30
  assert after >= before
}
