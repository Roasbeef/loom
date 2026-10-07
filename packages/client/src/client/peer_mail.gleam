//// Recipient-owned peer grants and idempotent durable message admission.
////
//// The host invokes this module through the Agency's small endpoint. A send
//// carries authenticated source metadata as data, never a Runtime borrowed
//// from another session. The recipient's grant sequence and receipt absence
//// are compared in the same writer transaction as the delivered prompt.
////
//// A grant is not the only way to be admitted. Under the owner's opt-in
//// `[peers] default_links = "same_owner"` (protocol-change/077) a session is
//// also admitted from every other session that the owner holds alone, `main`
//// to `main`, with the policy's wake permission and no grant recorded. That
//// decision lives in `implicit_wake` and nowhere else: delivery asks it when no
//// grant exists, and the listings the model and the owner read (`Links`,
//// `Grants`, `Roster`) ask it so that what they show is what delivery would
//// admit. An explicit grant for a pair takes precedence over it, and an
//// explicit unlink records a denial that ends it for that direction until the
//// owner grants the pair again.

import client/internal/message_inspection
import core/clock
import core/entry
import core/glance
import core/ids.{type EntryId, type OpId}
import core/json.{type JsonValue}
import core/message
import core/origin
import core/register
import core/tx
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import runtime/api
import runtime/escalation
import runtime/lineage
import runtime/writer
import session/session
import storage/snapshot
import storage/storage
import tools/blob

/// Waking an idle recipient is an independent operator permission.
pub type Wake {
  /// Delivery is allowed only while the target has an active run.
  BusyOnly

  /// Delivery may start a new run on the explicitly exported strand.
  MayWake
}

/// Whether sessions are linked without a per-pair grant
/// (protocol-change/077).
pub type DefaultLinks {
  /// Every link is an explicit owner grant. This is the default.
  NoDefaultLinks

  /// The owner's own sessions are linked to each other, `main` to `main`, in
  /// both directions. A session that has a member or an observer is not one
  /// of them, so the implicit link never reaches a session another person can
  /// read (`Defaults.eligible`).
  SameOwner
}

/// The daemon-wide choice read from the `[peers]` table.
pub type Policy {
  Policy(
    /// Whether implicit links exist at all.
    links: DefaultLinks,
    /// The wake permission every implicit link carries. An explicit grant for
    /// the same pair carries its own and takes precedence.
    wake: Wake,
  )
}

/// What the daemon lends a session's admission so that it can decide an
/// implicit link: the owner's policy and the one fact the session cannot see
/// for itself, which sessions the owner holds alone.
pub type Defaults {
  Defaults(
    /// The owner's choice.
    policy: Policy,
    /// The resident sessions that have no member and no observer, read from
    /// the catalogue each time it is called. It is called only under
    /// `SameOwner`, and it is read at the moment of each admission and listing
    /// rather than remembered, so inviting a person into a session ends its
    /// implicit links at once. A catalogue that cannot answer yields no
    /// sessions, which refuses every implicit link.
    eligible: fn() -> List(String),
  )
}

/// The defaults of a host that links nothing implicitly: every embedded
/// session, and a daemon whose configuration has no `[peers]` table.
pub const no_defaults =
  Defaults(
    policy: Policy(links: NoDefaultLinks, wake: BusyOnly),
    eligible: no_sessions,
  )

fn no_sessions() -> List(String) {
  []
}

/// One directional, exact-strand communication grant.
pub type Grant {
  Grant(
    /// Canonical session identity bound by the sending harness.
    source_session: String,
    /// Exact sending strand, with no wildcard interpretation.
    source_strand: String,
    /// Exact recipient strand explicitly exported by the operator.
    target_strand: String,
    /// Whether admission may wake an idle strand.
    wake: Wake,
  )
}

/// Harness-supplied provenance retained in the atomic receipt.
pub type Source {
  Source(
    /// Canonical sending session identity.
    session: String,
    /// Authenticated sending strand identity.
    strand: String,
    /// Operator-owned display metadata, never parsed as authority.
    metadata: JsonValue,
  )
}

/// Commands reachable only through a harness-owned endpoint.
pub type Command {
  /// Owner-authorized grant replacement.
  Allow(grant: Grant)

  /// Owner-authorized grant removal.
  Revoke(grant: Grant)

  /// Records an outgoing link after recipient authorization is durable.
  Link(source_strand: String, target_session: String, target_strand: String)

  /// Removes discovery before recipient revocation.
  Unlink(source_strand: String, target_session: String, target_strand: String)

  /// Returns this strand's explicit outgoing links.
  Links(source_strand: String)

  /// Returns incoming grants to one exact recipient strand for owner inspection.
  Grants(target_strand: String)

  /// Commits the message and request identity together.
  Deliver(source: Source, target: String, message_id: String, text: String)

  /// Lists only strands this source is authorized to address.
  Describe(strand: String, description: String)
  Activity(strand: String)
  Roster(source_session: String, source_strand: String)

  /// Reads the authenticated caller's pending inputs without consuming them.
  Inbox(strand: String, after: String, limit: Int)

  /// Looks up an ID only within the authenticated caller's pending queues.
  InboxGet(strand: String, entry: String)

  /// Pages materialized user inputs on the caller's conversation branch.
  History(strand: String, before: Int, limit: Int)

  /// Pages existing admission receipts addressed to the caller.
  Received(strand: String, after: String, limit: Int)

  /// Looks up a receipt only when its recorded recipient is the caller.
  ReceivedGet(
    strand: String,
    source_session: String,
    source_strand: String,
    message_id: String,
  )

  /// Looks up an existing receipt for a harness-authenticated sending identity.
  SentReceipt(source_session: String, source_strand: String, message_id: String)

  /// Summarizes the whole session for the owner's cross-session view
  /// (`protocol-change/050`). It reads and never writes, and its answer is
  /// bounded to `overview_row_bytes` whatever the session holds.
  Overview
}

/// A small endpoint; its closure captures an address, never a runtime graph.
pub type Endpoint {
  Endpoint(
    /// Canonical resident identity, checked after directory lookup.
    session: String,
    /// One bounded request to the recipient's Agency actor.
    call: fn(Command) -> Result(JsonValue, String),
  )
}

const grant_prefix = "client/peers/grant/"

const link_prefix = "client/peers/link/"

// A denial records that the owner removed one directional link, so that a
// default link does not bring it back. Both sessions of the pair record it:
// the sender's copy decides what its roster lists and the recipient's decides
// what it admits. Only the pair a default link could join is recorded.
const denial_prefix = "client/peers/denial/"

// The one strand a default link joins on each side. A session's other strands
// (children, branches) are the model's own workers and are linked only by an
// explicit grant naming them.
const default_strand = "main"

/// Maximum number of outgoing links recorded for one source strand.
pub const outgoing_link_limit = 64

/// The encoded size an `Overview` answer never exceeds. The daemon adds a
/// session identity to each answer and places up to 24 of them in one
/// 60,000-byte reply, so this bound is what lets that reply fit without a
/// page cursor.
pub const overview_row_bytes = 2300

// The per-field bounds `protocol-change/050` names. Each is applied with
// `glance.clip`, which cuts on a grapheme boundary.
const overview_message_bytes = 280

const overview_model_bytes = 64

const overview_strand_bytes = 96

const overview_title_bytes = 60

const overview_summary_bytes = 160

const overview_glances = 4

const receipt_prefix = "client/peers/receipt/"

fn digest(value: JsonValue) -> String {
  blob.ref_for(<<json.to_string(value):utf8>>)
}

fn grant_key(grant: Grant) -> String {
  grant_prefix
  <> digest(
    json.Array([
      json.String(grant.source_session),
      json.String(grant.source_strand),
      json.String(grant.target_strand),
    ]),
  )
}

fn grant_value(grant: Grant) -> JsonValue {
  json.Object([
    #("source_session", json.String(grant.source_session)),
    #("source_strand", json.String(grant.source_strand)),
    #("target_strand", json.String(grant.target_strand)),
    #("wake", json.String(wake_word(grant.wake))),
  ])
}

fn link_value(source: String, session: String, target: String) -> JsonValue {
  json.Object([
    #("source_strand", json.String(source)),
    #("session", json.String(session)),
    #("strand", json.String(target)),
  ])
}

fn outgoing_links(
  runtime: api.Runtime,
  source: String,
) -> Result(List(#(String, JsonValue)), String) {
  use links <- result.try(
    api.reserved_facts(runtime, link_prefix)
    |> result.map_error(string.inspect),
  )
  Ok(
    list.filter(links, fn(pair) { text(pair.1, "source_strand") == Ok(source) }),
  )
}

/// Executes one endpoint command in the recipient's serialized Agency actor,
/// for a host that links nothing implicitly.
///
/// ## Examples
///
/// ```gleam
/// // peer_mail.handle(runtime, clock, command)
/// ```
pub fn handle(
  runtime: api.Runtime,
  clock: clock.Clock,
  command: Command,
) -> Result(JsonValue, String) {
  handle_with(runtime, clock, no_defaults, command)
}

/// Executes one endpoint command in the recipient's serialized Agency actor
/// under the daemon's `defaults`.
///
/// ## Examples
///
/// ```gleam
/// // peer_mail.handle_with(runtime, clock, defaults, command)
/// ```
pub fn handle_with(
  runtime: api.Runtime,
  clock: clock.Clock,
  defaults: Defaults,
  command: Command,
) -> Result(JsonValue, String) {
  case command {
    History(strand, before, limit) ->
      message_inspection.history(runtime.session, strand, before, limit)
    Inbox(strand, after, limit) ->
      message_inspection.inbox(runtime.session, strand, after, limit)
    InboxGet(strand, id) ->
      message_inspection.inbox_get(runtime.session, strand, id)
    Received(strand, after, limit) -> received(runtime, strand, after, limit)
    ReceivedGet(strand, source_session, source_strand, id) ->
      receipt(runtime, source_session, source_strand, id, Some(strand))
    SentReceipt(source_session, source_strand, id) ->
      receipt(runtime, source_session, source_strand, id, None)
    Allow(grant) -> {
      use config <- result.try(
        session.strand_configuration(runtime.session, grant.target_strand)
        |> result.map_error(string.inspect),
      )
      use _ <- result.try(option.to_result(
        config,
        "recipient strand does not exist",
      ))
      let own = own_session(runtime)
      put_clearing(
        runtime,
        grant_key(grant),
        grant_value(grant),
        denial_for(
          grant.source_session,
          grant.source_strand,
          own,
          grant.target_strand,
        ),
      )
    }
    Revoke(grant) -> {
      let own = own_session(runtime)
      delete_denying(
        runtime,
        grant_key(grant),
        denial_for(
          grant.source_session,
          grant.source_strand,
          own,
          grant.target_strand,
        ),
      )
    }
    Link(source, session, target) -> {
      let value = link_value(source, session, target)
      let key = link_prefix <> digest(value)
      use links <- result.try(outgoing_links(runtime, source))
      use Nil <- result.try(case list.any(links, fn(pair) { pair.0 == key }) {
        True -> Ok(Nil)
        False ->
          case list.length(links) < outgoing_link_limit {
            True -> Ok(Nil)
            False -> Error("peer roster exceeds the 64-link bound")
          }
      })
      put_clearing(
        runtime,
        key,
        value,
        denial_for(own_session(runtime), source, session, target),
      )
    }
    Unlink(source, session, target) ->
      delete_denying(
        runtime,
        link_prefix <> digest(link_value(source, session, target)),
        denial_for(own_session(runtime), source, session, target),
      )
    Links(source) -> {
      use links <- result.try(outgoing_links(runtime, source))
      use implicit <- result.try(implicit_links(
        runtime,
        defaults,
        source,
        links,
      ))
      Ok(
        json.Array(list.append(list.map(links, fn(pair) { pair.1 }), implicit)),
      )
    }
    Grants(target) -> {
      use grants <- result.try(
        api.reserved_facts(runtime, grant_prefix)
        |> result.map_error(string.inspect),
      )
      use grants <- result.try(
        list.try_map(grants, fn(pair) { decode_grant(pair.1) }),
      )
      let explicit =
        list.filter(grants, fn(grant) { grant.target_strand == target })
      use implicit <- result.try(implicit_grants(
        runtime,
        defaults,
        target,
        explicit,
      ))
      Ok(json.Array(list.append(list.map(explicit, grant_value), implicit)))
    }
    Deliver(source, target, id, body) ->
      deliver(runtime, clock, defaults, source, target, id, body)
    Describe(strand, description) -> {
      case string.byte_size(description) <= 2048 {
        False -> Error("self-description exceeds 2048 bytes")
        True ->
          api.put_reserved_fact(
            runtime,
            "client/peers/description/" <> strand,
            json.String(description),
          )
          |> result.replace(json.Null)
          |> result.map_error(string.inspect)
      }
    }
    Activity(strand) -> activity(runtime, strand)
    Roster(source_session, source_strand) ->
      roster(runtime, defaults, source_session, source_strand)
    Overview -> overview(runtime)
  }
}

fn deliver(
  runtime: api.Runtime,
  clock: clock.Clock,
  defaults: Defaults,
  source: Source,
  target: String,
  id: String,
  body: String,
) -> Result(JsonValue, String) {
  use Nil <- result.try(
    case
      string.byte_size(id) > 0
      && string.byte_size(id) <= 128
      && string.byte_size(body) <= 32_768
    {
      True -> Ok(Nil)
      False -> Error("message id or body exceeds its bound")
    },
  )
  let key = grant_key(Grant(source.session, source.strand, target, BusyOnly))
  use cell <- result.try(
    api.fact_cell(runtime, key) |> result.map_error(string.inspect),
  )

  // A recorded grant is the whole decision when there is one. Only a pair with
  // no grant asks the default, so an explicit grant's wake permission
  // overrides the policy's and an explicit unlink (a grant that is gone, and a
  // denial in its place) is never read as an invitation.
  use #(grant, guards) <- result.try(case cell {
    Some(cell) -> {
      use grant <- result.try(decode_grant(cell.value))
      use Nil <- result.try(
        case
          grant.source_session == source.session
          && grant.source_strand == source.strand
          && grant.target_strand == target
        {
          True -> Ok(Nil)
          False -> Error("peer grant identity mismatch")
        },
      )
      Ok(#(grant, [tx.Expect(register.FactCustom, key, Some(cell.seq))]))
    }
    None -> {
      use implicit <- result.try(implicit_wake(
        runtime,
        defaults,
        source.session,
        source.strand,
        target,
      ))
      case implicit {
        Some(wake) ->
          Ok(
            #(Grant(source.session, source.strand, target, wake), [
              // The default holds only while no grant and no denial has
              // appeared, so a concurrent explicit decision loses the admission
              // as a changed grant does.
              tx.Expect(register.FactCustom, key, None),
              tx.Expect(
                register.FactCustom,
                denial_key(
                  source.session,
                  source.strand,
                  own_session(runtime),
                  target,
                ),
                None,
              ),
            ]),
          )
        None -> Error("no directional peer grant")
      }
    }
  })
  let request =
    json.Object([
      #("source_session", json.String(source.session)),
      #("source_strand", json.String(source.strand)),
      #("target_strand", json.String(target)),
      #("message_id", json.String(id)),
      #("body", json.String(body)),
    ])
  let receipt_key = receipt_key(source.session, source.strand, id)
  let receipt =
    json.Object([
      #("request", request),
      #("source", source.metadata),
      #("admitted", json.Bool(True)),
    ])
  use existing <- result.try(
    api.fact(runtime, receipt_key) |> result.map_error(string.inspect),
  )
  case existing {
    Some(existing) -> same_receipt(existing, request)
    None -> {
      let #(now, _) = clock.read(clock)
      use peer_origin <- result.try(
        origin.validate_peer(source.session, source.strand)
        |> result.map_error(fn(_) { "invalid peer source identity" }),
      )
      let payload =
        message.UserMessage(
          content: [message.UserText(body, None)],
          timestamp: now,
          origin: Some(peer_origin),
        )
      let mark = api.GuardedMark(receipt_key, receipt, guards)
      let accepted = case grant.wake {
        BusyOnly ->
          api.steer_marking(api.on_strand(runtime, target), payload, mark)
          |> result.replace(Nil)
        MayWake ->
          api.send_to_strand_marking(runtime, target, payload, mark)
          |> result.replace(Nil)
      }
      case accepted {
        Ok(Nil) -> {
          api.nudge(api.on_strand(runtime, target))
          Ok(receipt)
        }
        Error(api.FactConflict(_)) -> {
          use existing <- result.try(
            api.fact(runtime, receipt_key) |> result.map_error(string.inspect),
          )
          use existing <- result.try(option.to_result(
            existing,
            "peer grant changed during admission",
          ))
          same_receipt(existing, request)
        }
        Error(error) -> Error(string.inspect(error))
      }
    }
  }
}

fn same_receipt(
  receipt: JsonValue,
  request: JsonValue,
) -> Result(JsonValue, String) {
  case field(receipt, "request") == Ok(request) {
    True -> Ok(receipt)
    False ->
      Error("message id was already used for different content or target")
  }
}

fn roster(
  runtime: api.Runtime,
  defaults: Defaults,
  source: String,
  strand: String,
) -> Result(JsonValue, String) {
  use grants <- result.try(
    api.reserved_facts(runtime, grant_prefix)
    |> result.map_error(string.inspect),
  )
  use grants <- result.try(
    list.try_map(grants, fn(pair) { decode_grant(pair.1) }),
  )
  let explicit =
    list.filter(grants, fn(grant) {
      grant.source_session == source && grant.source_strand == strand
    })

  // A default link is one more row of the same shape, so a model reads it as it
  // reads a grant, and an explicit grant for the pair has already answered.
  use implicit <- result.try(
    case
      list.any(explicit, fn(grant) { grant.target_strand == default_strand })
    {
      True -> Ok(None)
      False -> implicit_wake(runtime, defaults, source, strand, default_strand)
    },
  )
  let targets = case implicit {
    Some(wake) ->
      list.append(explicit, [Grant(source, strand, default_strand, wake)])
    None -> explicit
  }
  use rows <- result.try(
    list.try_map(targets, fn(grant) {
      use state <- result.try(
        session.strand_state(runtime.session, grant.target_strand)
        |> result.map_error(string.inspect),
      )
      use state <- result.try(option.to_result(
        state,
        "recipient strand does not exist",
      ))
      use cell <- result.try(
        api.fact(runtime, lineage.register_key(grant.target_strand))
        |> result.map_error(string.inspect),
      )
      let parent = case cell {
        Some(value) ->
          case lineage.decode(value) {
            Ok(cell) -> json.String(cell.parent)
            Error(_) -> json.Null
          }
        None -> json.Null
      }
      use observed <- result.try(activity(runtime, grant.target_strand))
      Ok(
        json.Object([
          #("activity", observed),
          #("strand", json.String(grant.target_strand)),
          #("parent", parent),
          #("current_operation", case state.value.current_operation {
            None -> json.Null
            Some(op) -> json.String(ids.op_id_to_string(op))
          }),
          #("wake", json.String(wake_word(grant.wake))),
        ]),
      )
    }),
  )
  Ok(json.Array(rows))
}

fn wake_word(wake: Wake) -> String {
  case wake {
    BusyOnly -> "busy_only"
    MayWake -> "may_wake"
  }
}

// The session's own canonical identity, which a default link and a denial
// both name as one end of the pair.
fn own_session(runtime: api.Runtime) -> String {
  ids.session_id_to_string(runtime.session_id)
}

// Decides whether a default link admits `source_strand` of `source_session`
// into `target_strand` of this session, and with which wake permission.
//
// This is the only place a default link is decided. Delivery, the roster, the
// outgoing list and the incoming list all call it or the same predicates it
// is built from, so what they show is what delivery admits and no second path
// can drift from the first. A pair is admitted only when every one of these
// holds:
//
// 1. the owner chose `same_owner`;
// 2. both strands are `main`, so a session's workers are never reachable
//    without a grant naming them;
// 3. the source is another session, since a session does not message itself
//    by default;
// 4. no denial of the pair is recorded here, which an explicit unlink writes;
// 5. the source and this session are both among the sessions the owner holds
//    alone (`Defaults.eligible`).
//
// The caller has already found no grant for the pair. The answer is the
// policy's wake permission, or `None`.
fn implicit_wake(
  runtime: api.Runtime,
  defaults: Defaults,
  source_session: String,
  source_strand: String,
  target_strand: String,
) -> Result(Option(Wake), String) {
  let own = own_session(runtime)
  case defaults.policy.links {
    NoDefaultLinks -> Ok(None)
    SameOwner ->
      case default_pair(source_strand, target_strand) && source_session != own {
        False -> Ok(None)
        True -> {
          use denied <- result.try(denied(
            runtime,
            denial_key(source_session, source_strand, own, target_strand),
          ))
          let held = defaults.eligible()
          case
            !denied
            && list.contains(held, source_session)
            && list.contains(held, own)
          {
            True -> Ok(Some(defaults.policy.wake))
            False -> Ok(None)
          }
        }
      }
  }
}

fn default_pair(source_strand: String, target_strand: String) -> Bool {
  source_strand == default_strand && target_strand == default_strand
}

fn denial_key(
  source_session: String,
  source_strand: String,
  target_session: String,
  target_strand: String,
) -> String {
  denial_prefix
  <> digest(
    json.Array([
      json.String(source_session),
      json.String(source_strand),
      json.String(target_session),
      json.String(target_strand),
    ]),
  )
}

fn denied(runtime: api.Runtime, key: String) -> Result(Bool, String) {
  api.fact(runtime, key)
  |> result.map(option.is_some)
  |> result.map_error(string.inspect)
}

// One recorded denial, ready to write.
type Denial {
  Denial(key: String, value: JsonValue)
}

// The denial an explicit decision about this pair clears or records, or none
// when the pair is not one a default link could join.
fn denial_for(
  source_session: String,
  source_strand: String,
  target_session: String,
  target_strand: String,
) -> Option(Denial) {
  case default_pair(source_strand, target_strand) {
    False -> None
    True ->
      Some(Denial(
        denial_key(source_session, source_strand, target_session, target_strand),
        json.Object([
          #("source_session", json.String(source_session)),
          #("source_strand", json.String(source_strand)),
          #("target_session", json.String(target_session)),
          #("target_strand", json.String(target_strand)),
        ]),
      ))
  }
}

// Writes an explicit cell and, in the same transaction, removes the denial
// that would otherwise outlive the owner's decision to link the pair again.
fn put_clearing(
  runtime: api.Runtime,
  key: String,
  value: JsonValue,
  denial: Option(Denial),
) -> Result(JsonValue, String) {
  use cell <- result.try(
    api.fact_cell(runtime, key) |> result.map_error(string.inspect),
  )
  let write =
    api.ReservedFactSet(api.ReservedFactChange(
      key:,
      value:,
      expected: option.map(cell, fn(held) { held.seq }),
    ))
  use clearing <- result.try(case denial {
    None -> Ok([])
    Some(Denial(key: denial_key, ..)) -> {
      use held <- result.try(
        api.fact_cell(runtime, denial_key) |> result.map_error(string.inspect),
      )
      Ok(case held {
        Some(held) -> [api.ReservedFactRemove(denial_key, held.seq)]
        None -> []
      })
    }
  })
  api.edit_reserved_facts(runtime, [write, ..clearing])
  |> result.replace(json.Null)
  |> result.map_error(string.inspect)
}

// Removes an explicit cell and, in the same transaction, records the denial
// that stops a default link from bringing the pair back. The denial is written
// even when the cell is already gone, because removing a pair that exists only
// as a default link is exactly what the owner may ask for.
fn delete_denying(
  runtime: api.Runtime,
  key: String,
  denial: Option(Denial),
) -> Result(JsonValue, String) {
  use cell <- result.try(
    api.fact_cell(runtime, key) |> result.map_error(string.inspect),
  )
  let removal = case cell {
    Some(held) -> [api.ReservedFactRemove(key, held.seq)]
    None -> []
  }
  use recording <- result.try(case denial {
    None -> Ok([])
    Some(Denial(key: denial_key, value:)) -> {
      use held <- result.try(
        api.fact_cell(runtime, denial_key) |> result.map_error(string.inspect),
      )
      Ok([
        api.ReservedFactSet(api.ReservedFactChange(
          key: denial_key,
          value:,
          expected: option.map(held, fn(held) { held.seq }),
        )),
      ])
    }
  })
  api.edit_reserved_facts(runtime, list.append(recording, removal))
  |> result.replace(json.Null)
  |> result.map_error(string.inspect)
}

// Whether `id` already has a recorded outgoing link to this strand pair.
fn recorded_link(explicit: List(#(String, JsonValue)), id: String) -> Bool {
  list.any(explicit, fn(pair) {
    text(pair.1, "session") == Ok(id)
    && text(pair.1, "strand") == Ok(default_strand)
  })
}

// This session's default outgoing links, as rows of the same shape as a
// recorded link with `default: true`. A pair that already has a recorded link
// is not repeated, a denied pair is left out, and the rows share the explicit
// links' bound. The recipient's own denial is not consulted here: a pair the
// owner unlinked is denied on both sides, so this side's copy is the one that
// decides what the roster lists.
fn implicit_links(
  runtime: api.Runtime,
  defaults: Defaults,
  source_strand: String,
  explicit: List(#(String, JsonValue)),
) -> Result(List(JsonValue), String) {
  let own = own_session(runtime)
  case defaults.policy.links, source_strand == default_strand {
    NoDefaultLinks, _ | SameOwner, False -> Ok([])
    SameOwner, True -> {
      let held = defaults.eligible()
      case list.contains(held, own) {
        False -> Ok([])
        True -> {
          use rows <- result.try(
            held
            |> list.filter(fn(id) { id != own && !recorded_link(explicit, id) })
            |> list.try_map(fn(id) {
              use denied <- result.try(denied(
                runtime,
                denial_key(own, source_strand, id, default_strand),
              ))
              Ok(case denied {
                True -> None
                False ->
                  Some(
                    json.Object([
                      #("source_strand", json.String(source_strand)),
                      #("session", json.String(id)),
                      #("strand", json.String(default_strand)),
                      #("default", json.Bool(True)),
                    ]),
                  )
              })
            }),
          )
          Ok(list.take(
            option.values(rows),
            int.max(outgoing_link_limit - list.length(explicit), 0),
          ))
        }
      }
    }
  }
}

// The default links that reach this session's `target` strand, as rows of the
// same shape as a recorded grant with `default: true`.
fn implicit_grants(
  runtime: api.Runtime,
  defaults: Defaults,
  target: String,
  explicit: List(Grant),
) -> Result(List(JsonValue), String) {
  let own = own_session(runtime)
  case defaults.policy.links, target == default_strand {
    NoDefaultLinks, _ | SameOwner, False -> Ok([])
    SameOwner, True -> {
      let held = defaults.eligible()
      case list.contains(held, own) {
        False -> Ok([])
        True -> {
          use rows <- result.try(
            held
            |> list.filter(fn(id) {
              id != own
              && !list.any(explicit, fn(grant) {
                grant.source_session == id
                && grant.source_strand == default_strand
              })
            })
            |> list.try_map(fn(id) {
              use denied <- result.try(denied(
                runtime,
                denial_key(id, default_strand, own, target),
              ))
              Ok(case denied {
                True -> None
                False ->
                  Some(
                    json.Object([
                      #("source_session", json.String(id)),
                      #("source_strand", json.String(default_strand)),
                      #("target_strand", json.String(target)),
                      #("wake", json.String(wake_word(defaults.policy.wake))),
                      #("default", json.Bool(True)),
                    ]),
                  )
              })
            }),
          )
          Ok(option.values(rows))
        }
      }
    }
  }
}

fn decode_grant(value: JsonValue) -> Result(Grant, String) {
  use source_session <- result.try(text(value, "source_session"))
  use source_strand <- result.try(text(value, "source_strand"))
  use target_strand <- result.try(text(value, "target_strand"))
  use wake <- result.try(text(value, "wake"))
  use wake <- result.try(case wake {
    "busy_only" -> Ok(BusyOnly)
    "may_wake" -> Ok(MayWake)
    _ -> Error("invalid peer wake permission")
  })
  Ok(Grant(source_session:, source_strand:, target_strand:, wake:))
}

fn field(value: JsonValue, key: String) -> Result(JsonValue, String) {
  case value {
    json.Object(fields) ->
      list.key_find(fields, key)
      |> result.map_error(fn(_) { "missing peer field " <> key })
    _ -> Error("expected peer object")
  }
}

fn text(value: JsonValue, key: String) -> Result(String, String) {
  use value <- result.try(field(value, key))
  case value {
    json.String(value) -> Ok(value)
    _ -> Error("expected peer text field " <> key)
  }
}

fn activity(runtime: api.Runtime, strand: String) -> Result(JsonValue, String) {
  use state <- result.try(
    session.strand_state(runtime.session, strand)
    |> result.map_error(string.inspect),
  )
  use state <- result.try(option.to_result(state, "strand does not exist"))
  use terminal <- result.try(
    session.last_result(runtime.session, strand)
    |> result.map_error(string.inspect),
  )
  use description <- result.try(
    api.fact(runtime, "client/peers/description/" <> strand)
    |> result.map_error(string.inspect),
  )
  use git <- result.try(
    api.fact(runtime, "client/peers/git-observation")
    |> result.map_error(string.inspect),
  )
  Ok(
    json.Object([
      #("strand", json.String(strand)),
      #("state_commit_sequence", json.Int(state.seq)),
      #("current_operation", case state.value.current_operation {
        Some(op) -> json.String(ids.op_id_to_string(op))
        None -> json.Null
      }),
      #("last_terminal", case terminal {
        None -> json.Null
        Some(last) ->
          json.Object([
            #("commit_sequence", json.Int(last.seq)),
            #(
              "operation",
              json.String(ids.op_id_to_string(api.result_operation(last.value))),
            ),
            #("outcome", json.String(string.inspect(last.value))),
          ])
      }),
      #(
        "model_claim",
        json.Object([
          #("author", json.String("model")),
          #("description", option.unwrap(description, json.Null)),
        ]),
      ),
      #("git_observation", option.unwrap(git, json.Null)),
    ]),
  )
}

// One session's activity, as the owner's session picker shows it. Every
// read here is a single register, one entry, or one prefix listing, so the
// Agency actor answering it is held for a fixed number of store calls
// rather than a walk over the conversation.
fn overview(runtime: api.Runtime) -> Result(JsonValue, String) {
  use states <- result.try(strand_operations(runtime))
  use escalations <- result.try(
    api.escalations(runtime) |> result.map_error(string.inspect),
  )
  use last <- result.try(
    session.last_result(runtime.session, "main")
    |> result.map_error(string.inspect),
  )
  use configuration <- result.try(
    session.strand_configuration(runtime.session, "main")
    |> result.map_error(string.inspect),
  )
  use glances <- result.try(current_glances(runtime, states))
  let last = option.map(last, fn(cell) { cell.value })
  let approvals =
    list.count(escalations, fn(record) { record.status == escalation.Pending })
  let working = list.count(states, fn(pair) { option.is_some(pair.1) })

  // A failed main run asks for the operator only once main has stopped: a
  // main already running its next operation has moved past the failure.
  let main_running = case list.key_find(states, "main") {
    Ok(Some(_)) -> True
    Ok(None) | Error(Nil) -> False
  }
  let failed = case last {
    Some(operation.RunLastResult(outcome: operation.RunFailed(_), ..)) -> True
    Some(operation.RunLastResult(..))
    | Some(operation.CompactionLastResult(..))
    | Some(operation.NavigationLastResult(..))
    | None -> False
  }
  let state = case approvals > 0 || { failed && !main_running }, working > 0 {
    True, _ -> "needs_you"
    False, True -> "working"
    False, False -> "idle"
  }
  let model = case configuration {
    Some(cell) ->
      json.String(glance.clip(cell.value.model.model_id, overview_model_bytes))
    None -> json.Null
  }
  let base = [
    #("state", json.String(state)),
    #("strands", json.Int(list.length(states))),
    #("working", json.Int(working)),
    #("approvals", json.Int(approvals)),
    #("last_outcome", last_outcome(last)),
    #("model", model),
  ]
  Ok(fit_overview(base, final_message(runtime, last), glances))
}

// Every strand's current operation, from one listing of the strand-state
// namespace rather than one read per strand name.
fn strand_operations(
  runtime: api.Runtime,
) -> Result(List(#(String, Option(OpId))), String) {
  use cells <- result.try(
    writer.list_registers(runtime.tree.writer, register.StrandState, None)
    |> result.map_error(string.inspect),
  )
  list.try_map(cells, fn(pair) {
    let #(strand, storage.Register(value:, ..)) = pair
    codec.decode_strand_state(value.payload)
    |> result.map(fn(state) { #(strand, state.current_operation) })
    |> result.map_error(string.inspect)
  })
}

// The glances a reader may still show, newest first. `core/glance` says a
// glance describes one operation and is shown only while that operation is
// its strand's current one, so a cell left behind by a finished task is
// dropped here rather than reported as present work.
fn current_glances(
  runtime: api.Runtime,
  states: List(#(String, Option(OpId))),
) -> Result(List(JsonValue), String) {
  use cells <- result.try(
    api.reserved_facts(runtime, prefix: glance.key_prefix)
    |> result.map_error(string.inspect),
  )
  let current =
    states
    |> list.filter_map(fn(pair) {
      case pair.1 {
        Some(op) -> Ok(#(pair.0, ids.op_id_to_string(op)))
        None -> Error(Nil)
      }
    })
    |> dict.from_list
  cells
  |> list.filter_map(fn(pair) {
    use strand <- result.try(glance.strand_of(pair.0))
    use cell <- result.try(glance.decode(pair.1) |> result.replace_error(Nil))
    case dict.get(current, strand) == Ok(cell.operation) {
      True -> Ok(#(strand, cell))
      False -> Error(Nil)
    }
  })
  |> list.sort(fn(left, right) { int.compare({ right.1 }.at, { left.1 }.at) })
  |> list.take(overview_glances)
  |> list.map(glance_line)
  |> Ok
}

fn glance_line(pair: #(String, glance.Glance)) -> JsonValue {
  let #(strand, cell) = pair
  json.Object([
    #("strand", json.String(glance.clip(strand, overview_strand_bytes))),
    #("title", json.String(glance.clip(cell.title, overview_title_bytes))),
    #("summary", json.String(glance.clip(cell.summary, overview_summary_bytes))),
  ])
}

fn last_outcome(last: Option(operation.LastResult)) -> JsonValue {
  case last {
    Some(operation.RunLastResult(outcome: operation.RunCompleted(_), ..)) ->
      json.String("completed")
    Some(operation.RunLastResult(outcome: operation.RunFailed(_), ..)) ->
      json.String("failed")
    Some(operation.RunLastResult(outcome: operation.RunAborted, ..)) ->
      json.String("aborted")

    // A compaction or navigation is not a run, so it has no outcome the
    // picker could show as the session's last result.
    Some(operation.CompactionLastResult(..))
    | Some(operation.NavigationLastResult(..))
    | None -> json.Null
  }
}

// The final assistant text of main's last run. `LastResult` holds only the
// entry id, so this is one point read of that entry; a run with no final
// answer, or an entry with no text, reports null.
fn final_message(
  runtime: api.Runtime,
  last: Option(operation.LastResult),
) -> JsonValue {
  case last {
    Some(operation.RunLastResult(final_assistant: Some(id), ..)) ->
      // Clipping collapses whitespace first, so a message of only
      // whitespace is null here rather than an empty string.
      case glance.clip(assistant_text(runtime, id), overview_message_bytes) {
        "" -> json.Null
        text -> json.String(text)
      }
    Some(operation.RunLastResult(final_assistant: None, ..))
    | Some(operation.CompactionLastResult(..))
    | Some(operation.NavigationLastResult(..))
    | None -> json.Null
  }
}

fn assistant_text(runtime: api.Runtime, id: EntryId) -> String {
  case writer.get_entries(runtime.tree.writer, [id]) {
    Error(_) -> ""
    Ok(found) ->
      case dict.get(found, id) {
        Ok(entry.MessageEntry(
          message: message.AssistantMessage(content:, ..),
          ..,
        )) ->
          content
          |> list.filter_map(fn(block) {
            case block {
              message.AssistantText(text:, ..) -> Ok(text)
              _ -> Error(Nil)
            }
          })
          |> string.join(" ")
        _ -> ""
      }
  }
}

// Each field is clipped, but JSON escaping can still grow a clipped string
// several times over, so the encoded row is measured. An oversized row sheds
// its oldest glance first, then the final message. What remains is counts,
// fixed names, and a model clipped to 64 bytes, which fits even escaped.
fn fit_overview(
  base: List(#(String, JsonValue)),
  message: JsonValue,
  glances: List(JsonValue),
) -> JsonValue {
  let row =
    json.Object(
      list.append(base, [
        #("last_message", message),
        #("glances", json.Array(glances)),
      ]),
    )
  let fits = string.byte_size(json.to_string(row)) <= overview_row_bytes
  case fits, glances, message {
    True, _, _ -> row
    False, [_, ..], _ ->
      fit_overview(base, message, list.take(glances, list.length(glances) - 1))
    False, [], json.Null -> row
    False, [], _ -> fit_overview(base, json.Null, [])
  }
}

// Admission history survives operation cleanup. A receipt's stored request
// owns authorization; neither an opaque key nor an input argument grants read
// access to another recipient. Sender calls arrive only from the peer router.
fn receipt_key(
  source_session: String,
  source_strand: String,
  id: String,
) -> String {
  receipt_prefix
  <> digest(
    json.Array([
      json.String(source_session),
      json.String(source_strand),
      json.String(id),
    ]),
  )
}

fn receipt(
  runtime: api.Runtime,
  source_session: String,
  source_strand: String,
  id: String,
  recipient: Option(String),
) -> Result(JsonValue, String) {
  use found <- result.try(
    api.fact(runtime, receipt_key(source_session, source_strand, id))
    |> result.map_error(string.inspect),
  )
  case found {
    None -> Ok(json.Null)
    Some(value) -> {
      use request <- result.try(field(value, "request"))
      use source <- result.try(text(request, "source_session"))
      use strand <- result.try(text(request, "source_strand"))
      use target <- result.try(text(request, "target_strand"))
      use message_id <- result.try(text(request, "message_id"))
      let permitted =
        source == source_session
        && strand == source_strand
        && message_id == id
        && case recipient {
          None -> True
          Some(own) -> target == own
        }
      case permitted {
        True -> message_inspection.bounded(value)
        False -> Ok(json.Null)
      }
    }
  }
}

fn received(
  runtime: api.Runtime,
  strand: String,
  after: String,
  limit: Int,
) -> Result(JsonValue, String) {
  use Nil <- result.try(message_inspection.valid_limit(limit, 64))
  use cut <- result.try(
    runtime.session.snapshot_reader.capture(
      snapshot.Plan(
        selections: [
          snapshot.KeyPage(
            register.FactCustom,
            receipt_prefix,
            after,
            limit + 1,
          ),
        ],
        references: [],
        recent_entries: 0,
      ),
      5000,
    )
    |> result.map_error(string.inspect),
  )
  use rows <- result.try(
    list.try_map(cut.cells, fn(cell) {
      use request <- result.try(field(cell.register.value.payload, "request"))
      use target <- result.try(text(request, "target_strand"))
      Ok(#(cell.key, target, cell.register.value.payload))
    }),
  )
  let scanned = rows |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  let window = list.take(scanned, limit)
  let page = list.filter(window, fn(row) { row.1 == strand })
  let next = case list.last(window), list.length(scanned) > limit {
    Ok(row), True -> json.String(row.0)
    _, _ -> json.Null
  }
  message_inspection.bounded(
    json.Object([
      #(
        "items",
        json.Array(
          list.map(page, fn(row) {
            json.Object([#("cursor", json.String(row.0)), #("receipt", row.2)])
          }),
        ),
      ),
      #("next", next),
    ]),
  )
}
