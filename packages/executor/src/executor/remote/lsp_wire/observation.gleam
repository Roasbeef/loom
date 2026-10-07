//// Complete observation batches retain scope and independently charged facts.
////
//// Source texts are absent from Document rows, so the collector's retained
//// fact_bytes includes them while this decoder checks a lower bound from all
//// returned rows. Echoed input, canonical outlined paths and root are charged
//// separately by the enclosing wire profile. No partial inventory is accepted.

import core/msgpack as m
import executor/remote/lsp_wire/query as q
import executor/remote/lsp_wire/value as v
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lsp/observation as o
import lsp/query

/// Encodes the fixed complete observation tuple in protocol order.
///
/// ## Examples
///
/// Echoed short input paths and canonical outlined paths are distinct fields.
@internal
pub fn batch_value(batch: o.Batch) -> m.MsgPackValue {
  m.ArrayValue([
    q.observation_request_value(batch.requested),
    m.StringValue(batch.root),
    m.StringValue(batch.generation),
    m.IntValue(batch.started_ms),
    m.IntValue(batch.finished_ms),
    v.array(batch.outlined, m.StringValue),
    v.array(batch.documents, document_value),
    v.array(batch.symbols, symbol_value),
    v.array(batch.targets, target_value),
    v.array(batch.references, reference_value),
    m.ArrayValue([
      m.IntValue(batch.counts.requests),
      m.IntValue(batch.counts.withheld),
      m.IntValue(batch.counts.facts),
      m.IntValue(batch.counts.fact_bytes),
    ]),
  ])
}

/// Decodes every complete batch inventory and its original scope/count relation.
///
/// ## Examples
///
/// A forward parent, missing document or mismatched target refuses the batch.
@internal
pub fn parse_batch(value: m.MsgPackValue) -> Result(o.Batch, Nil) {
  case value {
    m.ArrayValue([
      requested,
      root,
      generation,
      started,
      finished,
      outlined,
      documents,
      symbols,
      targets,
      references,
      counts,
    ]) -> {
      use requested <- result.try(q.parse_observation_request(requested))
      use root <- result.try(absolute_path(root))
      use generation <- result.try(v.content_digest(generation))
      use started_ms <- result.try(v.integer(
        started,
        -9_223_372_036_854_775_808,
        9_223_372_036_854_775_807,
      ))
      use finished_ms <- result.try(v.integer(
        finished,
        -9_223_372_036_854_775_808,
        9_223_372_036_854_775_807,
      ))
      use outlined <- result.try(v.items(outlined, 16, absolute_path))
      use documents <- result.try(v.items(documents, 10_000, parse_document))
      use symbols <- result.try(v.items(symbols, 10_000, parse_symbol))
      use targets <- result.try(v.items(targets, 32, parse_target))
      use references <- result.try(v.items(references, 10_000, parse_reference))
      use counts <- result.try(parse_counts(counts))
      let batch =
        o.Batch(
          requested:,
          root:,
          generation:,
          started_ms:,
          finished_ms:,
          outlined:,
          documents:,
          symbols:,
          targets:,
          references:,
          counts:,
        )
      use Nil <- result.try(validate(batch))
      Ok(batch)
    }
    _ -> Error(Nil)
  }
}

fn document_value(row: o.Document) -> m.MsgPackValue {
  m.ArrayValue([
    m.StringValue(row.path),
    m.StringValue(row.digest),
    v.option(row.version, m.IntValue),
  ])
}

fn parse_document(value: m.MsgPackValue) -> Result(o.Document, Nil) {
  case value {
    m.ArrayValue([path, digest, version]) -> {
      use path <- result.try(absolute_path(path))
      use digest <- result.try(v.content_digest(digest))
      use version <- result.try(
        v.optional(version, fn(value) {
          v.integer(value, 1, 9_223_372_036_854_775_807)
        }),
      )
      Ok(o.Document(path:, digest:, version:))
    }
    _ -> Error(Nil)
  }
}

fn symbol_value(row: o.Symbol) -> m.MsgPackValue {
  m.ArrayValue([
    m.IntValue(row.id),
    v.option(row.parent_id, m.IntValue),
    m.StringValue(row.name),
    m.StringValue(row.kind),
    v.option(row.detail, m.StringValue),
    q.site_value(row.site),
  ])
}

fn parse_symbol(value: m.MsgPackValue) -> Result(o.Symbol, Nil) {
  case value {
    m.ArrayValue([id, parent, name, kind, detail, site]) -> {
      use id <- result.try(v.integer(id, 0, 9_223_372_036_854_775_807))
      use parent_id <- result.try(
        v.optional(parent, fn(value) {
          v.integer(value, 0, 9_223_372_036_854_775_807)
        }),
      )
      use name <- result.try(v.text(name, 4_194_304))
      use kind <- result.try(v.text(kind, 4_194_304))
      use detail <- result.try(
        v.optional(detail, fn(value) { v.text(value, 4_194_304) }),
      )
      use site <- result.try(q.parse_site(site))
      Ok(o.Symbol(id:, parent_id:, name:, kind:, detail:, site:))
    }
    _ -> Error(Nil)
  }
}

fn target_value(row: o.Target) -> m.MsgPackValue {
  m.ArrayValue([
    m.IntValue(row.id),
    q.symbol_value(row.asked),
    q.site_value(row.site),
  ])
}

fn parse_target(value: m.MsgPackValue) -> Result(o.Target, Nil) {
  case value {
    m.ArrayValue([id, asked, site]) -> {
      use id <- result.try(v.integer(id, 0, 31))
      use asked <- result.try(q.parse_symbol(asked))
      use site <- result.try(q.parse_site(site))
      Ok(o.Target(id:, asked:, site:))
    }
    _ -> Error(Nil)
  }
}

fn reference_value(row: o.Reference) -> m.MsgPackValue {
  m.ArrayValue([m.IntValue(row.target_id), q.site_value(row.site)])
}

fn parse_reference(value: m.MsgPackValue) -> Result(o.Reference, Nil) {
  case value {
    m.ArrayValue([id, site]) -> {
      use target_id <- result.try(v.integer(id, 0, 31))
      use site <- result.try(q.parse_site(site))
      Ok(o.Reference(target_id:, site:))
    }
    _ -> Error(Nil)
  }
}

fn parse_counts(value: m.MsgPackValue) -> Result(o.Counts, Nil) {
  case value {
    m.ArrayValue([requests, withheld, facts, bytes]) -> {
      use requests <- result.try(v.integer(requests, 0, 128))
      use withheld <- result.try(v.integer(
        withheld,
        0,
        9_223_372_036_854_775_807,
      ))
      use facts <- result.try(v.integer(facts, 0, 10_000))
      use fact_bytes <- result.try(v.integer(bytes, 0, 4_194_304))
      Ok(o.Counts(requests:, withheld:, facts:, fact_bytes:))
    }
    _ -> Error(Nil)
  }
}

fn validate(batch: o.Batch) -> Result(Nil, Nil) {
  let paths = list.map(batch.documents, fn(document) { document.path })
  let documented = dict.from_list(list.map(paths, fn(path) { #(path, Nil) }))
  let outlined =
    dict.from_list(list.map(batch.outlined, fn(path) { #(path, Nil) }))
  let facts =
    list.length(batch.documents)
    + list.length(batch.symbols)
    + list.length(batch.targets)
    + list.length(batch.references)

  // Complete fact and document inventories must agree before any relation is
  // traversed. Canonical outline paths remain separate from echoed input paths.
  // Repeated requests and aliases retain one canonical entry per original entry.

  use Nil <- result.try(
    v.check(fn() {
      string.starts_with(batch.root, "/")
      && batch.finished_ms >= batch.started_ms
      && batch.finished_ms - batch.started_ms <= 75_000
      && batch.counts.facts == facts
      && facts <= 10_000
      && dict.size(documented) == list.length(paths)
      && list.length(batch.outlined) == list.length(batch.requested.outlines)
      && list.all(batch.outlined, fn(path) { dict.has_key(documented, path) })
      && list.all(batch.symbols, fn(row) {
        dict.has_key(outlined, row.site.path)
      })
      && list.length(batch.targets) == list.length(batch.requested.targets)
    }),
  )
  // Backward parent identities make cycles unreachable and establish semantic
  // depth before a consumer reconstructs nested outlines.

  use _ <- result.try(
    list.try_fold(batch.symbols, dict.new(), fn(seen, row) {
      use Nil <- result.try(v.check(fn() { !dict.has_key(seen, row.id) }))
      use depth <- result.try(case row.parent_id {
        None -> Ok(1)
        Some(parent) ->
          dict.get(seen, parent) |> result.map(fn(depth) { depth + 1 })
      })
      use Nil <- result.try(v.check(fn() { depth <= 256 }))
      Ok(dict.insert(seen, row.id, depth))
    }),
  )
  // Every target remains the original request index. References can only name
  // those exact seeds and admitted documents retained by this complete batch.

  use Nil <- result.try(
    v.check(fn() {
      list.all(
        list.index_map(batch.targets, fn(target, index) { #(target, index) }),
        fn(pair) {
          pair.0.id == pair.1
          && list.first(list.drop(batch.requested.targets, pair.1))
          == Ok(pair.0.asked)
          && dict.has_key(documented, pair.0.site.path)
        },
      )
      && list.all(batch.references, fn(row) {
        row.target_id < list.length(batch.targets)
        && dict.has_key(documented, row.site.path)
      })
    }),
  )
  // Source texts are absent from returned Document tuples. The retained
  // collector accounting must cover this returned-payload lower bound as well
  // as its independently charged original source texts.

  let document_bytes =
    list.fold(batch.documents, 0, fn(bytes, row) {
      bytes + string.byte_size(row.path) + 128
    })
  let symbol_bytes =
    list.fold(batch.symbols, 0, fn(bytes, row) {
      bytes
      + site_bytes(row.site)
      + string.byte_size(row.name)
      + string.byte_size(row.kind)
      + optional_bytes(row.detail)
      + 64
    })
  let target_bytes =
    list.fold(batch.targets, 0, fn(bytes, row) {
      bytes
      + site_bytes(row.site)
      + string.byte_size(row.asked.symbol)
      + optional_bytes(row.asked.path)
      + 64
    })
  let reference_bytes =
    list.fold(batch.references, 0, fn(bytes, row) {
      bytes + site_bytes(row.site) + 32
    })
  v.check(fn() {
    document_bytes + symbol_bytes + target_bytes + reference_bytes
    <= batch.counts.fact_bytes
  })
}

fn site_bytes(site: query.Site) -> Int {
  string.byte_size(site.path) + string.byte_size(site.text) + 64
}

fn optional_bytes(value) -> Int {
  case value {
    None -> 0
    Some(text) -> string.byte_size(text)
  }
}

/// Encodes existing observation failures in their source variant order.
///
/// ## Examples
///
/// DeadlineExceeded retains its explicit closed tag.
@internal
pub fn error_value(error: o.Error) -> m.MsgPackValue {
  case error {
    o.InvalidScope(reason) ->
      m.ArrayValue([m.IntValue(0), m.StringValue(reason)])
    o.QueryFailed(error) -> m.ArrayValue([m.IntValue(1), q.error_value(error)])
    o.Changed(reason) -> m.ArrayValue([m.IntValue(2), m.StringValue(reason)])
    o.LimitExceeded(reason) ->
      m.ArrayValue([m.IntValue(3), m.StringValue(reason)])
    o.DeadlineExceeded -> m.ArrayValue([m.IntValue(4)])
  }
}

/// Decodes only the existing complete observation failure vocabulary.
///
/// ## Examples
///
/// Unknown tags never become an empty successful batch.
@internal
pub fn parse_error(value: m.MsgPackValue) -> Result(o.Error, Nil) {
  case value {
    m.ArrayValue([m.IntValue(0), reason]) ->
      v.text(reason, 4_194_304) |> result.map(o.InvalidScope)
    m.ArrayValue([m.IntValue(1), error]) ->
      q.parse_error(error) |> result.map(o.QueryFailed)
    m.ArrayValue([m.IntValue(2), reason]) ->
      v.text(reason, 4_194_304) |> result.map(o.Changed)
    m.ArrayValue([m.IntValue(3), reason]) ->
      v.text(reason, 4_194_304) |> result.map(o.LimitExceeded)
    m.ArrayValue([m.IntValue(4)]) -> Ok(o.DeadlineExceeded)
    _ -> Error(Nil)
  }
}

fn absolute_path(value: m.MsgPackValue) -> Result(String, Nil) {
  use path <- result.try(v.path(value))
  use Nil <- result.try(v.check(fn() { string.starts_with(path, "/") }))
  Ok(path)
}
