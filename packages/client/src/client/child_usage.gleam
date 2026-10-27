//// What each child strand of a session has cost, read from the session's usage
//// ledger.
////
//// The ledger is one list of rows for the whole session, and a row names the
//// assistant entry it priced, not the strand that made the request. A delegate
//// session's children (protocol-change/084) are each created fresh, forked at
//// no entry, so every entry on a child's branch, from its leaf back to the root,
//// is the child's own and no other strand's. A child's usage is therefore the
//// sum of the rows whose entry sits on its branch, and the sum is already
//// priced: the gateway wrote each row's cost when it priced the response, and
//// nothing here reprices it.
////
//// The read is one scan of the ledger for any number of children, because a
//// join asks about every settled child at once and the ledger is the larger
//// side. A child whose branch cannot be read refuses the whole read, as the
//// Agency refuses a join whose notes cannot be read: a zero in its place would
//// look like a child that cost nothing.

import client/remote_spawn.{type ChildUsage, ChildUsage}
import core/accounting
import core/entry
import core/ids
import core/message
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import runtime/api
import runtime/writer
import session/session
import storage/storage

/// The usage of each named strand, summed over its branch.
///
/// A strand with no leaf has no entries and so costs nothing. The answer has a
/// key for every strand asked about.
///
/// ## Examples
///
/// ```gleam
/// // child_usage.of_strands(runtime, ["sub:^main/review-7b1c0a4e2d95f318"])
/// // == Ok(dict.from_list([#("sub:^main/review-7b1c0a4e2d95f318", usage)]))
/// ```
pub fn of_strands(
  runtime: api.Runtime,
  strands: List(String),
) -> Result(Dict(String, ChildUsage), String) {
  use branches <- result.try(
    list.try_map(strands, fn(strand) {
      use found <- result.map(branch_of(runtime, strand))
      #(strand, found)
    }),
  )
  use rows <- result.map(
    writer.scan_usage(runtime.tree.writer, storage.usage_scan())
    |> result.replace_error("the usage ledger is unreadable"),
  )
  list.map(branches, fn(branch) { #(branch.0, summed(rows, branch.1)) })
  |> dict.from_list
}

/// Reads the message entry ids for `strand` back from its current leaf.
///
/// The ids of the entries on a strand's branch, leaf to root. Only message
/// entries are asked for, since a usage row prices an assistant response.
fn branch_of(
  runtime: api.Runtime,
  strand: String,
) -> Result(Set(String), String) {
  use leaf <- result.try(
    session.strand_leaf(runtime.session, strand)
    |> result.map_error(fn(_) { "strand.leaf is unreadable for " <> strand }),
  )

  // Scan the branch when the leaf is present, otherwise return an empty set.
  case leaf {
    Some(session.Cell(value: Some(leaf), ..)) ->
      writer.scan_branch(
        runtime.tree.writer,
        storage.branch_scan(from: leaf) |> storage.branch_kind(storage.Message),
      )
      |> result.map_error(fn(_) {
        "the branch of " <> strand <> " is unreadable"
      })
      |> result.map(fn(entries) {
        entries
        |> list.map(entry_id)
        |> set.from_list
      })
    Some(session.Cell(value: None, ..)) | None -> Ok(set.new())
  }
}

/// Extracts the string entry id from an entry row.
fn entry_id(row: entry.Entry) -> String {
  case row {
    entry.MessageEntry(id:, ..)
    | entry.CompactionEntry(id:, ..)
    | entry.BranchSummaryEntry(id:, ..)
    | entry.CustomEntry(id:, ..) -> ids.entry_id_to_string(id)
  }
}

/// Sums the usage of rows whose entry id is present on the given branch.
fn summed(rows: List(entry.UsageRow), branch: Set(String)) -> ChildUsage {
  let total =
    list.fold(rows, accounting.zero_usage(), fn(total, row) {
      case row.entry_id {
        Some(id) ->
          case set.contains(branch, ids.entry_id_to_string(id)) {
            True -> accounting.add_usage(total, row.usage)
            False -> total
          }
        None -> total
      }
    })
  from_message(total)
}

/// Converts an accumulated message usage into a `ChildUsage` record.
fn from_message(usage: message.Usage) -> ChildUsage {
  ChildUsage(
    input: usage.input,
    output: usage.output,
    cache_read: usage.cache_read,
    cache_write: usage.cache_write,
    cost: usage.cost.total,
  )
}
