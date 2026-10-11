//// The per-strand ledger that feeds `cache_miss`: which usage row each
//// strand last billed, which pushed rows still wait for a capture, and which
//// strands a model switch has fenced.
////
//// `cache_miss` answers a question about two rows. This module decides which
//// two rows may be compared, and that decision is the same for every host
//// that watches a session: the terminal's footer and transcript notice, and
//// the web view's cache rings and miss rows. It was lifted out of the
//// terminal's reducer so that both hosts fold usage through one rule.
////
//// A usage row reaches a host in one of two ways. A live push names its
//// durable sequence; it is admitted once (`admit`), held until a capture
//// covers that sequence, because only a capture supplies the model
//// configuration the comparison has to be made under, and then settled
//// (`settle`). An older daemon's push carries no sequence and is observed at
//// once (`observe`). A capture that changes a strand's effective model drops
//// that strand's watch and fences its next operation (`capture`), since a
//// cache written by one model does not serve another. An explicit model
//// switch does the same for one strand (`forget`).
////
//// Every instant here is the host's own clock, handed in. The ledger reads
//// none, and it performs no I/O, so a host can drive it from a test.

import core/message
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import machine/strand as machine_strand
import session_view/cache_miss
import session_view/snapshot_view
import session_view/transcript_lines
import session_view/usage_display

/// One pushed usage row waiting for a capture that covers its sequence.
///
/// The capture supplies the model configuration against which a cache
/// comparison is safe. Only the latest row per strand is retained; losing an
/// intermediate comparison can omit a warning but cannot invent one.
pub type Observation {
  Observation(
    /// Durable sequence of the observed usage row.
    seq: Int,
    /// Provider operation, when the gateway could attribute the row.
    operation: Option(String),
    /// Fixed-shape provider counters for this request.
    usage: message.Usage,
    /// Host-clock instant when the push arrived.
    at: Int,
  )
}

/// What the ledger remembers about every strand's prompt cache.
pub type Ledger {
  Ledger(
    /// The last provider usage row each strand billed, with the instant it
    /// arrived, which is all the prompt-cache detector remembers. Keyed by
    /// strand because a sub-agent's request says nothing about whether the
    /// primary's cached prefix survived the operator's pause.
    watches: Dict(String, cache_miss.Watch),
    /// Highest live usage observation already folded on each strand. A
    /// capture owns cumulative totals; this cursor prevents a delayed push
    /// from reporting the same settlement twice.
    seen: Dict(String, Int),
    /// Latest row per strand awaiting a capture that covers its sequence.
    pending: Dict(String, Observation),
    /// A model switch fences the first observed operation on that strand.
    /// Every row from it may bill the old provider, so only a later operation
    /// can establish the new provider's baseline.
    fences: Dict(String, Option(String)),
  )
}

/// Whether the instants a host hands in measure time a person spent.
///
/// A replay plays its file far faster than the session originally ran, so
/// the gaps it would measure are not the gaps that happened, and it
/// observes nothing.
pub type Timing {
  /// The instants are the host's wall clock as frames arrive.
  Live

  /// The instants come from replaying a recording.
  Replayed
}

/// A cache miss one strand's row revealed.
pub type Missed {
  Missed(
    /// The strand whose request paid for the miss.
    strand: String,
    /// The miss itself.
    miss: cache_miss.CacheMiss,
  )
}

/// An empty ledger, as a host holds one before any usage arrives.
///
/// ## Examples
///
/// ```gleam
/// assert cache_watch.new().watches == dict.new()
/// ```
pub fn new() -> Ledger {
  Ledger(
    watches: dict.new(),
    seen: dict.new(),
    pending: dict.new(),
    fences: dict.new(),
  )
}

/// The outlook for one strand's cache at a host-clock instant, or `None`
/// when no row has been seen for it (`cache_miss.outlook`).
///
/// ## Examples
///
/// ```gleam
/// assert cache_watch.outlook(cache_watch.new(), "main", 0) == None
/// ```
pub fn outlook(
  ledger: Ledger,
  strand: String,
  now: Int,
) -> Option(cache_miss.Outlook) {
  ledger.watches
  |> dict.get(strand)
  |> option.from_result
  |> cache_miss.outlook(now)
}

/// Whether a strand is running an operation, which decides whether its
/// outlook is shown at all.
pub type Activity {
  /// An operation is running, or a prompt is on its way to one.
  Running

  /// Nothing is running on the strand.
  Resting
}

/// The outlook a host shows for one strand, or `None` when there is nothing
/// honest to show.
///
/// The reading is suppressed while the strand is running. A request in
/// flight re-writes the prefix whatever the label says, so a countdown shown
/// mid-generation would name an expiry the request in progress is about to
/// reset, and the miss row, not the label, is what reports what the pause
/// before the request cost. A strand that has not held a prefix worth a
/// label (`cache_miss.Unheld`) shows nothing either.
///
/// ## Examples
///
/// ```gleam
/// assert cache_watch.shown(cache_watch.new(), "main", cache_watch.Resting, 0)
///   == None
/// ```
pub fn shown(
  ledger: Ledger,
  strand: String,
  activity: Activity,
  now: Int,
) -> Option(cache_miss.Outlook) {
  case activity {
    Running -> None
    Resting ->
      case outlook(ledger, strand, now) {
        Some(cache_miss.Unheld) | None -> None
        Some(held) -> Some(held)
      }
  }
}

/// Folds one row into its strand's watch at once, reporting any miss it
/// reveals. This is the path for a row with no durable sequence, which has
/// no capture to wait for.
///
/// ## Examples
///
/// ```gleam
/// // let #(ledger, missed) = cache_watch.observe(ledger, "main", usage, now, cache_watch.Live)
/// ```
pub fn observe(
  ledger: Ledger,
  strand: String,
  usage: message.Usage,
  at: Int,
  timing: Timing,
) -> #(Ledger, Option(Missed)) {
  case timing {
    Replayed -> #(ledger, None)
    Live -> {
      let held = dict.get(ledger.watches, strand) |> option.from_result
      let #(miss, watch) = cache_miss.observe(held, usage, at)
      let ledger =
        Ledger(..ledger, watches: case watch {
          None -> ledger.watches
          Some(value) -> dict.insert(ledger.watches, strand, value)
        })
      #(ledger, option.map(miss, Missed(strand, _)))
    }
  }
}

/// Admits one pushed row with a durable sequence, or refuses it as one
/// already folded.
///
/// A push is an observation of one durable row, not a second owner of
/// session totals, and the same row can be pushed twice. A row at or below
/// the strand's cursor is refused, which is what keeps a delayed push from
/// resetting the cache clock. An admitted row is held for `settle`, unless
/// it is the strand's first and the last capture (`covered`, its
/// `next_seq`) already includes it: such a row may have belonged to an
/// operation accepted under the previous model, and the gateway can deliver
/// its push after the cut, so it cannot seed the strand's baseline.
///
/// ## Examples
///
/// ```gleam
/// // case cache_watch.admit(ledger, "main", 41, Some("op"), usage, now, Some(40)) {
/// //   Ok(ledger) -> ..
/// //   Error(Nil) -> // already folded
/// // }
/// ```
pub fn admit(
  ledger: Ledger,
  strand: String,
  seq: Int,
  operation: Option(String),
  usage: message.Usage,
  at: Int,
  covered: Option(Int),
) -> Result(Ledger, Nil) {
  let seen = dict.get(ledger.seen, strand)
  case seq <= result.unwrap(seen, -1) {
    True -> Error(Nil)
    False -> {
      let already_covered = case covered, seen {
        Some(next_seq), Error(Nil) if seq < next_seq -> True
        _, _ -> False
      }
      Ok(
        Ledger(
          ..ledger,
          seen: dict.insert(ledger.seen, strand, seq),
          pending: case already_covered {
            True -> ledger.pending
            False ->
              dict.insert(
                ledger.pending,
                strand,
                Observation(seq:, operation:, usage:, at:),
              )
          },
        ),
      )
    }
  }
}

/// Settles every held row a capture now covers, oldest strand first by the
/// ledger's own order, and reports the misses they reveal in that order.
///
/// A capture covers every committed row below its `next_seq` and supplies
/// the model configuration needed to compare its usage safely. Newer rows
/// stay held; the committed notice or periodic refresh will fetch their
/// cut. A fenced strand's first observed operation only sets the fence,
/// and its rows are skipped until a later operation arrives, whose row
/// becomes the new provider's baseline.
///
/// ## Examples
///
/// ```gleam
/// // let #(ledger, misses) = cache_watch.settle(ledger, cut.next_seq, cache_watch.Live)
/// ```
pub fn settle(
  ledger: Ledger,
  next_seq: Int,
  timing: Timing,
) -> #(Ledger, List(Missed)) {
  let #(ledger, reversed) =
    dict.to_list(ledger.pending)
    |> list.fold(#(ledger, []), fn(acc, item) {
      let #(current, missed) = acc
      let #(strand, Observation(seq:, operation:, usage:, at:)) = item
      case seq < next_seq {
        True -> {
          let current =
            Ledger(..current, pending: dict.delete(current.pending, strand))
          let #(current, found) =
            observed(current, strand, operation, usage, at, timing)
          case found {
            None -> #(current, missed)
            Some(value) -> #(current, [value, ..missed])
          }
        }
        False -> #(current, missed)
      }
    })
  #(ledger, list.reverse(reversed))
}

// One settled row against the strand's fence. An unset fence takes the
// row's operation as the one to skip; the fenced operation's own rows are
// skipped; the first row of any other operation lifts the fence and is
// observed.
fn observed(
  ledger: Ledger,
  strand: String,
  operation: Option(String),
  usage: message.Usage,
  at: Int,
  timing: Timing,
) -> #(Ledger, Option(Missed)) {
  case dict.get(ledger.fences, strand), operation {
    Ok(None), Some(op) -> #(
      Ledger(..ledger, fences: dict.insert(ledger.fences, strand, Some(op))),
      None,
    )
    Ok(None), None -> #(ledger, None)
    Ok(Some(old)), Some(op) if old == op -> #(ledger, None)
    Ok(Some(_)), Some(_) ->
      observe(
        Ledger(..ledger, fences: dict.delete(ledger.fences, strand)),
        strand,
        usage,
        at,
        timing,
      )
    Ok(Some(_)), None -> #(ledger, None)
    Error(Nil), _ -> observe(ledger, strand, usage, at, timing)
  }
}

/// Forgets one strand's watch and fences its next operation, as an explicit
/// model switch on that strand requires.
///
/// A watch describes one provider's prefix. A model change cannot inherit
/// its horizon or compare the new provider's first row with the old
/// provider's last row. Only the affected strand is cleared.
///
/// ## Examples
///
/// ```gleam
/// // cache_watch.forget(ledger, "main")
/// ```
pub fn forget(ledger: Ledger, strand: String) -> Ledger {
  Ledger(
    ..ledger,
    watches: dict.delete(ledger.watches, strand),
    fences: dict.insert(ledger.fences, strand, None),
  )
}

/// Carries the ledger across a new capture, given the capture before it.
///
/// A captured configuration can change on another client. The effective
/// model is compared per strand instead of the whole configuration: changing
/// a directory or another setting does not erase a valid cache observation.
/// A strand whose model changed loses its watch and is fenced. An initially
/// live strand is fenced too, since its operation may have started under a
/// model selected before this client attached; on the first capture every
/// live strand is.
///
/// ## Examples
///
/// ```gleam
/// // cache_watch.capture(ledger, option.map(previous, fn(shown) { shown.1 }), view)
/// ```
pub fn capture(
  ledger: Ledger,
  previous: Option(snapshot_view.View),
  view: snapshot_view.View,
) -> Ledger {
  case previous {
    Some(previous) if previous.configurations != view.configurations -> {
      let watches =
        dict.filter(ledger.watches, fn(strand, _) {
          configured_model(previous, strand) == configured_model(view, strand)
        })
      let fences =
        dict.fold(view.configurations, ledger.fences, fn(fences, strand, _) {
          case
            dict.has_key(previous.configurations, strand)
            && configured_model(previous, strand)
            != configured_model(view, strand)
          {
            True -> dict.insert(fences, strand, None)
            False -> fences
          }
        })
      let fences =
        dict.fold(view.operations, fences, fn(fences, strand, _) {
          case dict.has_key(previous.configurations, strand) {
            True -> fences
            False -> dict.insert(fences, strand, None)
          }
        })
      Ledger(..ledger, watches:, fences:)
    }
    Some(_) -> ledger
    None ->
      Ledger(
        ..ledger,
        fences: dict.fold(view.operations, ledger.fences, fn(fences, strand, _) {
          dict.insert(fences, strand, None)
        }),
      )
  }
}

fn configured_model(
  view: snapshot_view.View,
  strand: String,
) -> Option(machine_strand.ModelIdentity) {
  view.configurations
  |> dict.get(strand)
  |> option.from_result
  |> option.map(fn(config) { config.configuration.model })
}

/// A miss as a person reads it, the line a host files after the turn that
/// paid for it.
///
/// Token counts use the status line's own abbreviation so the two figures
/// can be compared without unit arithmetic, and the money is omitted rather
/// than shown as zero when the model is unpriced: a confident "$0.00" would
/// claim the pause was free.
///
/// ## Examples
///
/// ```gleam
/// // cache_watch.notice_text(miss)
/// //   == "Cache miss after 12m idle: 38.0k tokens re-billed (~$0.41)"
/// ```
pub fn notice_text(miss: cache_miss.CacheMiss) -> String {
  "Cache miss after "
  <> cache_miss.idle_label(miss.idle_ms)
  <> " idle: "
  <> transcript_lines.tokens(miss.tokens)
  <> " tokens re-billed"
  <> case miss.estimate {
    None -> ""
    Some(amount) -> " (~$" <> usage_display.money(amount) <> ")"
  }
}
