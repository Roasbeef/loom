//// The executor's execution ledger: which tool calls this machine has started
//// for which sessions, and how each one ended.
////
//// A session whose workspace lives on an executor sends its calls over the
//// network, and the network loses replies, partitions, and outlives either
//// side's VM. The ledger is what lets the orchestrator ask afterward what
//// happened to a call (protocol-change/078, "Execution ledger"). One SQLite
//// file serves the whole executor, with rows keyed by session, and a
//// node-level actor will own the single connection; this module is the storage
//// layer under that actor and has no process of its own.
////
//// ## Scopes
////
//// A `scope` is one session's attachment to this executor. It has an
//// `incarnation`, which rises only when a cleanly closed scope reopens, and an
//// `attach_token`, which every runtime incarnation of the session replaces when
//// it attaches. Admission compares both with the request in the same
//// transaction that inserts the call row, so a request from a dead runtime or a
//// closed incarnation is refused by content, whatever order the network
//// delivered it in. A session has at most one scope here: the key is
//// `(session, workspace)`, but `attach` refuses a second workspace for a
//// session that already has one, which is what lets a call key (which carries
//// no workspace) find its scope.
////
//// A scope moves `open` to `closing` to `closed`, and `closed` carries the
//// close outcome: `AllRetired`, or `UnknownCleanup(n)` when the host could not
//// prove that `n` children are gone. Only `closed` with `AllRetired` may
//// reopen, at exactly one incarnation higher. The executor admits at most
//// `max_unclean_scopes` scopes that are not so closed, and a clean close frees
//// its slot at once. A call still `admitted` when its scope closes is the
//// actor's to settle: it cancels the run and records the outcome with `finish`,
//// or records that the outcome is lost with `mark_unknown`. This module does
//// not look for such calls, so it cannot stop `finish_close` from reporting
//// `AllRetired` over one.
////
//// ## Calls
////
//// A call is keyed by `(session, op, step, source_index)`, the identity the
//// orchestrator's planner already uses. `admit` inserts it `admitted` before
//// the tool starts, and `finish` stores the encoded outcome with its SHA-256
//// digest and moves it to `terminal` before the reply goes out. A second `admit`
//// for the same key inserts nothing and returns what the ledger holds, so one
//// call never starts two runs. `query` verifies the digest against the stored
//// bytes on every read, so a damaged outcome is a typed error and never a
//// silently different result.
////
//// Opening the file turns every `admitted` row into `unknown`. The VM that
//// started those runs is gone, so nothing is relaunched, and `unknown` is the
//// honest record that the call may have run and that its outcome was lost.
////
//// ## Why an acknowledgement deletes the row
////
//// There is no acknowledged state. After the orchestrator durably stages a
//// result it sends `ack`, and `ack` deletes the row. The orchestrator only ever
//// queries calls that are orphaned, which means it holds no staged result for
//// them, and a call it acknowledged has its result staged in its own store, so
//// it is never orphaned again. The orchestrator also sends each `Run` exactly
//// once: after a disconnect it queries the call key and never resends. So once
//// a row is gone no later message can arrive for that key and be mistaken for a
//// fresh call, and a stale runtime's late `Run` is stopped by the attach token
//// whether or not a row exists. A tombstone would guard a resend the protocol
//// does not make, at the price of a row that never frees.
////
//// ## The byte budget
////
//// Admission reserves the call's maximum result size in `outcome_bytes`. The sum
//// over `admitted` and `terminal` rows plus the new reservation must stay within
//// `max_ledger_bytes`, so an executor cannot accept a call whose result it might
//// have nowhere to put. `finish` shrinks the reservation to the outcome's real
//// size, and `ack` releases it. An `unknown` row holds no bytes.
////
//// ## One opener
////
//// `open` is the executor's restart recovery, so exactly one connection per
//// executor VM may open the file: a second `open` while the first has runs in
//// flight would turn them `unknown`. The node-level actor is that one opener.
//// Several connections to the file are safe for everything else, because every
//// check that guards a write runs inside the `BEGIN IMMEDIATE` transaction that
//// performs it.
////
//// ## Flow
////
//// `open` → `attach` → `admit` → `finish` → `query` → `ack` → `begin_close` →
//// `finish_close`
////
//// 1. `open` validates or creates the schema, sets full synchronous durability,
////    and records every run the previous VM had in flight as lost.
//// 2. `attach` creates, rebinds or reopens the session's scope and replies with
////    the call keys whose results the orchestrator has not acknowledged.
//// 3. `admit` checks the scope's state, incarnation and token, then reserves the
////    call, or reports what the ledger already holds for the key.
//// 4. `finish` records the outcome, and `mark_unknown` records that it was lost.
//// 5. `query` answers for any key in any scope state, and `ack` deletes a settled
////    row once the orchestrator has staged it.
//// 6. `begin_close` is the fence that stops new admissions, and `finish_close`
////    records how the cleanup ended.

import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import parrot/dev
import sqlight
import storage/exec_ledger_schema
import storage/sql
import storage/sqlite_policy

/// An open ledger connection, owned by the executor's node-level actor.
pub opaque type Ledger {
  Ledger(connection: sqlight.Connection)
}

/// A call's identity, the one the orchestrator's planner already uses.
pub type Key {
  Key(
    /// The session that owns the call, and therefore its scope.
    session: String,
    /// The operation the call belongs to.
    op: String,
    /// The step within the operation.
    step: String,
    /// The call's position among the step's tool calls.
    source_index: Int,
  )
}

/// The caps one admission or attachment is judged against. The actor passes the
/// same limits on every call; they live outside the ledger so a later change to
/// a limit needs no migration.
pub type Limits {
  Limits(
    /// The most scopes that may be anything but `Closed(AllRetired)`.
    max_unclean_scopes: Int,
    /// The most bytes `admitted` reservations and `terminal` outcomes may hold.
    max_ledger_bytes: Int,
  )
}

/// Why a scope stopped, as the host reported it when the cleanup ended.
pub type CloseOutcome {
  /// The helper pool reported every child retired.
  AllRetired

  /// The host could not prove `count` children are gone. This scope gets no
  /// automatic successor and keeps its slot against `max_unclean_scopes`.
  UnknownCleanup(count: Int)
}

/// Where a scope is in its life.
pub type ScopeState {
  /// Admitting calls under the stored incarnation and token.
  Open

  /// Fenced: no call is admitted, and the host is cancelling live work.
  Closing

  /// Cleanup ended with this outcome.
  Closed(outcome: CloseOutcome)
}

/// A session's attachment to this executor.
pub type Scope {
  Scope(
    /// The orchestrator session.
    session: String,
    /// The workspace path as the executor knows it.
    workspace: String,
    /// The incarnation this scope admits calls under.
    incarnation: Int,
    /// The scope's life stage.
    state: ScopeState,
    /// The only attach token admission accepts.
    token: BitArray,
  )
}

/// What the ledger holds for one call key.
pub type CallState {
  /// The run was admitted and has not recorded an outcome.
  Admitted

  /// The run ended and its outcome is stored, digest verified.
  Terminal(outcome: BitArray)

  /// The executor restarted or the host gave up on the run; the call may have
  /// run and its outcome is lost.
  Unknown
}

/// The answer to `query`.
pub type Lookup {
  /// No row. After an attach, the call never reached this executor and cannot.
  Missing

  /// The call's row.
  Found(CallState)
}

/// The answer to `admit`.
pub type Admission {
  /// The row is new; the caller owns the one run for this key.
  Fresh

  /// The key was admitted before; nothing was inserted, and the caller must not
  /// start a second run.
  Existing(CallState)
}

/// How `attach` changed the ledger.
pub type Attachment {
  /// The session had no scope, and now has an open one.
  Created

  /// A new runtime incarnation of the same orchestrator session replaced the
  /// token on a scope that stayed open.
  Rebound

  /// A cleanly closed scope reopened at the next incarnation.
  Reopened
}

/// The reply to a successful `attach`.
pub type Attached {
  Attached(
    /// What the attach did.
    how: Attachment,
    /// The session's calls with a stored result nobody acknowledged, so the
    /// orchestrator can acknowledge the ones its store already holds.
    terminal: List(Key),
    /// The session's calls whose outcome is lost.
    unknown: List(Key),
  )
}

/// Every way a ledger call can fail, with the refusals named for the rule that
/// produced them.
pub type Error {
  /// An argument is outside its domain, such as a negative incarnation.
  Invalid(reason: String)

  /// The file is another program's database, or a ledger version this build
  /// does not know. A downgrade needs the older file restored.
  Unsupported

  /// The session has no scope here.
  NoSuchScope

  /// The session's scope belongs to another workspace.
  WorkspaceMismatch(stored: String)

  /// The request's incarnation is not the scope's, or not the successor a
  /// reopen needs. `stored` is the scope's current one.
  StaleIncarnation(stored: Int)

  /// The request's attach token is not the scope's current one.
  StaleToken

  /// Admission or `begin_close` needs an open scope.
  ScopeNotOpen(state: ScopeState)

  /// Attachment found the scope mid-close.
  ScopeClosing

  /// `finish_close` needs a closing scope.
  ScopeNotClosing(state: ScopeState)

  /// The scope closed with unknown cleanup and has no automatic successor.
  UncleanClose(count: Int)

  /// The executor already holds `limit` scopes that are not cleanly closed.
  CapacityExhausted(limit: Int)

  /// The call's reservation would push the ledger past `limit` bytes.
  BudgetExhausted(limit: Int)

  /// The key has no row.
  NoSuchCall

  /// The key's row is not `admitted`, so it cannot be finished or marked.
  CallNotAdmitted

  /// The outcome is larger than the bytes `admit` reserved for it.
  OutcomeTooLarge(reserved: Int, size: Int)

  /// The stored outcome does not match its digest or its recorded size.
  DigestMismatch(key: Key)

  /// A stored row decodes to no valid state; the ledger fails closed.
  MalformedRow(reason: String)

  /// SQLite could not complete the operation.
  Database(reason: String)
}

/// The most scopes an executor admits that are not cleanly closed.
pub const max_unclean_scopes = 16

/// The default byte budget: 256 MiB of reservations and unacknowledged outcomes.
pub const default_max_ledger_bytes = 268_435_456

// The `application_id` this ledger stamps: the ASCII bytes "LEDL". It keeps the
// ledger from opening, and recovering rows in, some other SQLite file.
const application_id = 1_279_607_884

const schema_version = 1

/// The limits the design note fixes: sixteen unclean scopes, and the default
/// byte budget.
///
/// ## Examples
///
/// ```gleam
/// assert exec_ledger.default_limits().max_unclean_scopes == 16
/// ```
pub fn default_limits() -> Limits {
  Limits(max_unclean_scopes:, max_ledger_bytes: default_max_ledger_bytes)
}

/// Opens the executor's ledger, creating the schema in an empty file and
/// refusing any other database.
///
/// Every `admitted` row becomes `unknown` in the same call, because the VM that
/// started those runs is gone and nothing is relaunched. A row never moves back.
/// Only the executor's node-level actor may call this (see "One opener" above).
/// The parent directory must exist and be private to the executor.
///
/// ## Examples
///
/// ```gleam
/// // exec_ledger.open(state_root <> "/exec-ledger.db")
/// ```
pub fn open(path: String) -> Result(Ledger, Error) {
  use Nil <- result.try(
    sqlite_policy.refusing_unopenable_path(path)
    |> result.map_error(Database),
  )
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(sql_error),
  )
  case initialize(connection) {
    Ok(Nil) -> Ok(Ledger(connection))
    Error(error) -> {
      let _closed = sqlight.close(connection)
      Error(error)
    }
  }
}

/// Closes the connection. Rows stay as they are.
///
/// ## Examples
///
/// ```gleam
/// // exec_ledger.close(ledger)
/// ```
pub fn close(ledger: Ledger) -> Result(Nil, Error) {
  sqlight.close(ledger.connection) |> result.map_error(sql_error)
}

/// Attaches a runtime incarnation to the session's scope.
///
/// One immediate transaction decides, from the stored scope:
///
/// - No scope: create it `Open` at `incarnation`, unless the executor already
///   holds `limits.max_unclean_scopes` scopes that are not cleanly closed.
/// - `Open` at the same incarnation: store `token` as the only valid token. This
///   is a new runtime of the same session, and its predecessor's requests stop
///   being admitted from this commit on.
/// - `Closed(AllRetired)` and `incarnation` one above the stored one: reopen with
///   the new incarnation and token, under the same capacity check as a new scope.
///
/// Everything else is refused: `StaleIncarnation` for any other incarnation,
/// `ScopeClosing` while the close runs, and `UncleanClose` for a scope that
/// ended with unknown cleanup. The reply lists the session's unacknowledged
/// terminal keys and its unknown keys, so the orchestrator can acknowledge what
/// its store already holds.
///
/// ## Examples
///
/// ```gleam
/// // exec_ledger.attach(ledger, "s", "/work", 0, token, exec_ledger.default_limits())
/// ```
pub fn attach(
  ledger: Ledger,
  session: String,
  workspace: String,
  incarnation: Int,
  token: BitArray,
  limits: Limits,
) -> Result(Attached, Error) {
  use Nil <- result.try(valid_incarnation(incarnation))
  use Nil <- result.try(valid_token(token))
  let connection = ledger.connection
  transaction(connection, fn() {
    use found <- result.try(find_scope(connection, session))
    use how <- result.try(case found {
      None ->
        create_scope(connection, session, workspace, incarnation, token, limits)
      Some(scope) ->
        attach_existing(
          connection,
          scope,
          workspace,
          incarnation,
          token,
          limits,
        )
    })

    // The key lists are read in the attach's own transaction, so the orchestrator
    // sees the rows as they stood when its token took effect.
    use unacked <- result.try(unacked_keys(connection, session))
    Ok(Attached(how:, terminal: unacked.0, unknown: unacked.1))
  })
}

/// Admits one call, or reports what the ledger already holds for its key.
///
/// In one immediate transaction: the scope must be `Open`, and `incarnation` and
/// `token` must equal the stored values, or the call is refused with
/// `ScopeNotOpen`, `StaleIncarnation` or `StaleToken` before anything is
/// written. An existing key is returned as `Existing` and nothing is inserted,
/// even when it is `Terminal`, so a repeated request returns the stored outcome.
/// A new key reserves `max_result_bytes` against `limits.max_ledger_bytes`
/// (`BudgetExhausted` when the total would exceed it) and is inserted
/// `Admitted`. `Fresh` is the caller's only licence to start the tool.
///
/// ## Examples
///
/// ```gleam
/// // exec_ledger.admit(ledger, key, 0, token, "bash", 65_536, exec_ledger.default_limits())
/// ```
pub fn admit(
  ledger: Ledger,
  key: Key,
  incarnation: Int,
  token: BitArray,
  tool: String,
  max_result_bytes: Int,
  limits: Limits,
) -> Result(Admission, Error) {
  use Nil <- result.try(valid_key(key))
  use Nil <- result.try(valid_incarnation(incarnation))
  use Nil <- result.try(valid_token(token))
  use Nil <- result.try(valid_reservation(max_result_bytes))
  let connection = ledger.connection
  transaction(connection, fn() {
    use found <- result.try(find_scope(connection, key.session))
    use scope <- result.try(option.to_result(found, NoSuchScope))
    use Nil <- result.try(require_current(scope, incarnation, token))
    use existing <- result.try(find_call(connection, key))
    case existing {
      Some(state) -> Ok(Existing(state))
      None -> {
        use Nil <- result.try(require_budget(
          connection,
          max_result_bytes,
          limits,
        ))
        use Nil <- result.try(statement(
          connection,
          sql.insert_ledger_call(
            session: key.session,
            op: key.op,
            step: key.step,
            source_index: key.source_index,
            incarnation:,
            tool:,
            outcome_bytes: max_result_bytes,
          ),
        ))
        Ok(Fresh)
      }
    }
  })
}

/// Records an admitted call's outcome: the bytes, their SHA-256 digest and their
/// real size replace the reservation, and the call becomes `Terminal`.
///
/// It does not consult the scope, because a closing scope must still be able to
/// record the outcomes of the runs it cancels. An outcome larger than the
/// reservation is refused with `OutcomeTooLarge` and leaves the row `Admitted`,
/// so the actor can settle it with a smaller failure outcome or `mark_unknown`.
///
/// ## Examples
///
/// ```gleam
/// // exec_ledger.finish(ledger, key, encoded_outcome)
/// ```
pub fn finish(
  ledger: Ledger,
  key: Key,
  outcome: BitArray,
) -> Result(Nil, Error) {
  let connection = ledger.connection
  transaction(connection, fn() {
    use reserved <- result.try(admitted_reservation(connection, key))
    let size = bit_array.byte_size(outcome)
    use <- bool.guard(
      when: size > reserved,
      return: Error(OutcomeTooLarge(reserved:, size:)),
    )

    // The update repeats the `admitted` guard, so the transition cannot touch a
    // row some other path already settled.
    statement(
      connection,
      sql.finish_ledger_call(
        outcome: Some(outcome),
        outcome_digest: Some(crypto.hash(crypto.Sha256, outcome)),
        outcome_bytes: size,
        session: key.session,
        op: key.op,
        step: key.step,
        source_index: key.source_index,
      ),
    )
  })
}

/// Records that an admitted call's outcome is lost: the host cancelled it at
/// close and could not read an outcome, so the call becomes `Unknown` and
/// releases its reservation.
///
/// ## Examples
///
/// ```gleam
/// // exec_ledger.mark_unknown(ledger, key)
/// ```
pub fn mark_unknown(ledger: Ledger, key: Key) -> Result(Nil, Error) {
  let connection = ledger.connection
  transaction(connection, fn() {
    use _reserved <- result.try(admitted_reservation(connection, key))
    statement(
      connection,
      sql.mark_ledger_call_unknown(
        session: key.session,
        op: key.op,
        step: key.step,
        source_index: key.source_index,
      ),
    )
  })
}

/// Reports the ledger's row for a call key, in any scope state and for any
/// incarnation, because rows never move between scopes.
///
/// A `Terminal` outcome is returned only after its SHA-256 digest and size match
/// the stored bytes; a mismatch is `DigestMismatch`, never a different outcome.
///
/// ## Examples
///
/// ```gleam
/// // exec_ledger.query(ledger, key)
/// ```
pub fn query(ledger: Ledger, key: Key) -> Result(Lookup, Error) {
  use found <- result.try(find_call(ledger.connection, key))
  case found {
    Some(state) -> Ok(Found(state))
    None -> Ok(Missing)
  }
}

/// Deletes a settled call's row after the orchestrator durably staged its
/// result (see "Why an acknowledgement deletes the row" above).
///
/// A `Terminal` or `Unknown` row is deleted and its bytes are released. A missing
/// row is already acknowledged, so the call succeeds. An `Admitted` row is
/// untouched, so a misdirected acknowledgement can never discard a live run's
/// reservation.
///
/// ## Examples
///
/// ```gleam
/// // exec_ledger.ack(ledger, key)
/// ```
pub fn ack(ledger: Ledger, key: Key) -> Result(Nil, Error) {
  statement(
    ledger.connection,
    sql.ack_ledger_call(
      session: key.session,
      op: key.op,
      step: key.step,
      source_index: key.source_index,
    ),
  )
}

/// Fences the scope: `Open` becomes `Closing`, and from this commit no `admit`
/// succeeds for the session.
///
/// The scope must be open at `incarnation`. A repeat of the same request on a
/// scope already `Closing` at that incarnation succeeds without a write, so the
/// actor can resume a close after its own restart.
///
/// ## Examples
///
/// ```gleam
/// // exec_ledger.begin_close(ledger, "s", "/work", 0)
/// ```
pub fn begin_close(
  ledger: Ledger,
  session: String,
  workspace: String,
  incarnation: Int,
) -> Result(Nil, Error) {
  let connection = ledger.connection
  transaction(connection, fn() {
    use scope <- result.try(scope_at(
      connection,
      session,
      workspace,
      incarnation,
    ))
    case scope.state {
      Open ->
        statement(
          connection,
          sql.begin_ledger_scope_close(session:, workspace:),
        )
      Closing -> Ok(Nil)
      Closed(_) -> Error(ScopeNotOpen(scope.state))
    }
  })
}

/// Ends a close: `Closing` becomes `Closed` with the host's outcome.
///
/// Missing evidence is not an outcome. A monitor DOWN, a timeout or a lost reply
/// leaves the scope `Closing`, or is recorded as `UnknownCleanup`; only the
/// helper pool's retirement result justifies `AllRetired`.
///
/// ## Examples
///
/// ```gleam
/// // exec_ledger.finish_close(ledger, "s", "/work", 0, exec_ledger.AllRetired)
/// ```
pub fn finish_close(
  ledger: Ledger,
  session: String,
  workspace: String,
  incarnation: Int,
  outcome: CloseOutcome,
) -> Result(Nil, Error) {
  use stored <- result.try(close_outcome_text(outcome))
  let connection = ledger.connection
  transaction(connection, fn() {
    use scope <- result.try(scope_at(
      connection,
      session,
      workspace,
      incarnation,
    ))
    case scope.state {
      Closing ->
        statement(
          connection,
          sql.finish_ledger_scope_close(
            close_outcome: Some(stored),
            session:,
            workspace:,
          ),
        )
      Open | Closed(_) -> Error(ScopeNotClosing(scope.state))
    }
  })
}

/// Reads the session's scope, or `None` when it has none.
///
/// ## Examples
///
/// ```gleam
/// // exec_ledger.scope(ledger, "s")
/// ```
pub fn scope(ledger: Ledger, session: String) -> Result(Option(Scope), Error) {
  find_scope(ledger.connection, session)
}

// The schema is checked inside the transaction that may create it, so two opens
// of a fresh file cannot both decide it is empty. Journal configuration follows
// validation, so an unrelated file is refused before any persistent tuning can
// change its header.
fn initialize(connection: sqlight.Connection) -> Result(Nil, Error) {
  let options = sqlite_policy.defaults()
  use Nil <- result.try(
    sqlite_policy.configure_connection(connection, options)
    |> result.map_error(sql_error),
  )

  // The ledger is a custody record: an outcome the executor replied with must
  // survive power loss, or the orchestrator's later query could find no row for
  // a call that ran. WAL would permit a weaker default on some builds.
  use Nil <- result.try(execute(connection, "PRAGMA synchronous = FULL"))
  use Nil <- result.try(initialize_schema(connection))
  use Nil <- result.try(
    sqlite_policy.configure_database(connection, options)
    |> result.map_error(sql_error),
  )

  // One UPDATE is one atomic transaction. Every run the previous VM admitted is
  // unknown from here on, and no later step can turn it back.
  statement(connection, sql.recover_ledger_calls())
}

fn initialize_schema(connection: sqlight.Connection) -> Result(Nil, Error) {
  transaction(connection, fn() {
    use found <- result.try(number(connection, "PRAGMA application_id"))
    use version <- result.try(number(connection, "PRAGMA user_version"))
    case found, version {
      id, 1 if id == application_id -> Ok(Nil)
      0, 0 -> {
        use tables <- result.try(number(connection, "PRAGMA schema_version"))
        case tables {
          0 -> create_schema(connection)
          _ -> Error(Unsupported)
        }
      }
      _, _ -> Error(Unsupported)
    }
  })
}

fn create_schema(connection: sqlight.Connection) -> Result(Nil, Error) {
  use Nil <- result.try(execute(connection, exec_ledger_schema.schema))
  execute(
    connection,
    "PRAGMA application_id = "
      <> int.to_string(application_id)
      <> "; PRAGMA user_version = "
      <> int.to_string(schema_version),
  )
}

fn create_scope(
  connection: sqlight.Connection,
  session: String,
  workspace: String,
  incarnation: Int,
  token: BitArray,
  limits: Limits,
) -> Result(Attachment, Error) {
  use Nil <- result.try(require_capacity(connection, limits))
  use Nil <- result.try(statement(
    connection,
    sql.insert_ledger_scope(
      session:,
      workspace:,
      incarnation:,
      attach_token: token,
    ),
  ))
  Ok(Created)
}

// The existing scope decides the attach. The workspace is judged first because
// every other answer is about the scope the session already has.
fn attach_existing(
  connection: sqlight.Connection,
  scope: Scope,
  workspace: String,
  incarnation: Int,
  token: BitArray,
  limits: Limits,
) -> Result(Attachment, Error) {
  use Nil <- result.try(same_workspace(scope, workspace))
  case scope.state {
    Open ->
      case incarnation == scope.incarnation {
        True -> {
          use Nil <- result.try(statement(
            connection,
            sql.rebind_ledger_scope(
              attach_token: token,
              session: scope.session,
              workspace:,
            ),
          ))
          Ok(Rebound)
        }
        False -> Error(StaleIncarnation(scope.incarnation))
      }

    // A close is in progress. Neither a rebind nor a reopen may race it.
    Closing -> Error(ScopeClosing)

    Closed(UnknownCleanup(count)) -> Error(UncleanClose(count))

    // The reopen is the one place the incarnation rises, by exactly one, so a
    // request from any earlier incarnation can never match again.
    Closed(AllRetired) ->
      case incarnation == scope.incarnation + 1 {
        True -> {
          use Nil <- result.try(require_capacity(connection, limits))
          use Nil <- result.try(statement(
            connection,
            sql.reopen_ledger_scope(
              incarnation:,
              attach_token: token,
              session: scope.session,
              workspace:,
            ),
          ))
          Ok(Reopened)
        }
        False -> Error(StaleIncarnation(scope.incarnation))
      }
  }
}

// A scope that is not cleanly closed holds a slot. The count excludes a scope
// that is about to reopen, because a clean close freed its slot until then.
fn require_capacity(
  connection: sqlight.Connection,
  limits: Limits,
) -> Result(Nil, Error) {
  use counted <- result.try(rows(connection, sql.ledger_unclean_scope_count()))
  case counted {
    [row] ->
      case row.scopes < limits.max_unclean_scopes {
        True -> Ok(Nil)
        False -> Error(CapacityExhausted(limits.max_unclean_scopes))
      }
    [] | [_, _, ..] -> Error(MalformedRow("expected one unclean scope count"))
  }
}

// The admission check proper. Each comparison is by value against the stored
// row inside the admitting transaction, so no ordering of messages can slip a
// request past it: a runtime that attached later has already replaced the token.
fn require_current(
  scope: Scope,
  incarnation: Int,
  token: BitArray,
) -> Result(Nil, Error) {
  case scope.state {
    Open ->
      case incarnation == scope.incarnation {
        True ->
          case token == scope.token {
            True -> Ok(Nil)
            False -> Error(StaleToken)
          }
        False -> Error(StaleIncarnation(scope.incarnation))
      }
    Closing | Closed(_) -> Error(ScopeNotOpen(scope.state))
  }
}

fn require_budget(
  connection: sqlight.Connection,
  reservation: Int,
  limits: Limits,
) -> Result(Nil, Error) {
  use held <- result.try(rows(connection, sql.ledger_reserved_bytes()))
  case held {
    [row] ->
      case row.bytes + reservation <= limits.max_ledger_bytes {
        True -> Ok(Nil)
        False -> Error(BudgetExhausted(limits.max_ledger_bytes))
      }
    [] | [_, _, ..] -> Error(MalformedRow("expected one reserved byte total"))
  }
}

// The reservation of an admitted row, which is the only row `finish` and
// `mark_unknown` may settle.
fn admitted_reservation(
  connection: sqlight.Connection,
  key: Key,
) -> Result(Int, Error) {
  use found <- result.try(call_rows(connection, key))
  case found {
    [] -> Error(NoSuchCall)
    [row] -> {
      use state <- result.try(call_state(key, row))
      case state {
        Admitted -> Ok(row.outcome_bytes)
        Terminal(_) | Unknown -> Error(CallNotAdmitted)
      }
    }
    [_, _, ..] -> Error(MalformedRow("call key matches several rows"))
  }
}

fn scope_at(
  connection: sqlight.Connection,
  session: String,
  workspace: String,
  incarnation: Int,
) -> Result(Scope, Error) {
  use found <- result.try(find_scope(connection, session))
  use scope <- result.try(option.to_result(found, NoSuchScope))
  use Nil <- result.try(same_workspace(scope, workspace))
  case incarnation == scope.incarnation {
    True -> Ok(scope)
    False -> Error(StaleIncarnation(scope.incarnation))
  }
}

fn same_workspace(scope: Scope, workspace: String) -> Result(Nil, Error) {
  case scope.workspace == workspace {
    True -> Ok(Nil)
    False -> Error(WorkspaceMismatch(scope.workspace))
  }
}

fn find_scope(
  connection: sqlight.Connection,
  session: String,
) -> Result(Option(Scope), Error) {
  use found <- result.try(rows(connection, sql.ledger_scope(session)))
  case found {
    [] -> Ok(None)
    [row] -> result.map(decode_scope(row), Some)
    [_, _, ..] -> Error(MalformedRow("session has several scopes"))
  }
}

fn decode_scope(row: sql.LedgerScope) -> Result(Scope, Error) {
  use state <- result.try(scope_state(row.state, row.close_outcome))
  use <- bool.guard(
    when: row.incarnation < 0,
    return: Error(MalformedRow("scope incarnation is negative")),
  )
  Ok(Scope(
    session: row.session,
    workspace: row.workspace,
    incarnation: row.incarnation,
    state:,
    token: row.attach_token,
  ))
}

// The state and the close outcome are one fact stored in two columns, so they
// decode together. A scope that is not closed has no outcome, and a closed one
// must have a well-formed outcome.
fn scope_state(
  state: String,
  close_outcome: Option(String),
) -> Result(ScopeState, Error) {
  case state, close_outcome {
    "open", None -> Ok(Open)
    "closing", None -> Ok(Closing)
    "closed", Some("all_retired") -> Ok(Closed(AllRetired))
    "closed", Some("unknown:" <> count) ->
      case int.parse(count) {
        Ok(parsed) if parsed >= 0 -> Ok(Closed(UnknownCleanup(parsed)))
        Ok(_) | Error(Nil) -> Error(MalformedRow("unknown cleanup count"))
      }
    _, _ -> Error(MalformedRow("scope state does not match its close outcome"))
  }
}

fn close_outcome_text(outcome: CloseOutcome) -> Result(String, Error) {
  case outcome {
    AllRetired -> Ok("all_retired")
    UnknownCleanup(count) if count >= 0 -> Ok("unknown:" <> int.to_string(count))
    UnknownCleanup(_) -> Error(Invalid("unknown cleanup count is negative"))
  }
}

fn find_call(
  connection: sqlight.Connection,
  key: Key,
) -> Result(Option(CallState), Error) {
  use found <- result.try(call_rows(connection, key))
  case found {
    [] -> Ok(None)
    [row] -> result.map(call_state(key, row), Some)
    [_, _, ..] -> Error(MalformedRow("call key matches several rows"))
  }
}

fn call_rows(
  connection: sqlight.Connection,
  key: Key,
) -> Result(List(sql.LedgerCall), Error) {
  rows(
    connection,
    sql.ledger_call(
      session: key.session,
      op: key.op,
      step: key.step,
      source_index: key.source_index,
    ),
  )
}

// The columns must agree with the state: only a terminal row carries an outcome
// and a digest. A terminal outcome is returned only if it still hashes to its
// stored digest and has its recorded size, which is how a damaged blob becomes
// an error instead of a different tool result.
fn call_state(key: Key, row: sql.LedgerCall) -> Result(CallState, Error) {
  case row.state, row.outcome, row.outcome_digest {
    "admitted", None, None -> Ok(Admitted)
    "unknown", None, None -> Ok(Unknown)
    "terminal", Some(outcome), Some(digest) ->
      case
        crypto.hash(crypto.Sha256, outcome) == digest
        && bit_array.byte_size(outcome) == row.outcome_bytes
      {
        True -> Ok(Terminal(outcome))
        False -> Error(DigestMismatch(key))
      }
    _, _, _ ->
      Error(MalformedRow("call state does not match its outcome columns"))
  }
}

// A row to tell the orchestrator about: its key, and whether it holds a result.
type Unacked {
  Resulted(Key)
  Lost(Key)
}

fn unacked_keys(
  connection: sqlight.Connection,
  session: String,
) -> Result(#(List(Key), List(Key)), Error) {
  use found <- result.try(rows(connection, sql.ledger_unacked_keys(session)))
  use settled <- result.try(
    list.try_map(found, fn(row) {
      let key =
        Key(
          session:,
          op: row.op,
          step: row.step,
          source_index: row.source_index,
        )
      case row.state {
        "terminal" -> Ok(Resulted(key))
        "unknown" -> Ok(Lost(key))
        _ ->
          Error(MalformedRow("unacknowledged call is neither settled nor lost"))
      }
    }),
  )
  Ok(#(
    list.filter_map(settled, fn(entry) {
      case entry {
        Resulted(key) -> Ok(key)
        Lost(_) -> Error(Nil)
      }
    }),
    list.filter_map(settled, fn(entry) {
      case entry {
        Lost(key) -> Ok(key)
        Resulted(_) -> Error(Nil)
      }
    }),
  ))
}

fn valid_key(key: Key) -> Result(Nil, Error) {
  use <- bool.guard(
    when: key.source_index < 0,
    return: Error(Invalid("call source index is negative")),
  )
  Ok(Nil)
}

fn valid_incarnation(incarnation: Int) -> Result(Nil, Error) {
  use <- bool.guard(
    when: incarnation < 0,
    return: Error(Invalid("incarnation is negative")),
  )
  Ok(Nil)
}

fn valid_token(token: BitArray) -> Result(Nil, Error) {
  use <- bool.guard(
    when: bit_array.byte_size(token) == 0,
    return: Error(Invalid("attach token is empty")),
  )
  Ok(Nil)
}

fn valid_reservation(bytes: Int) -> Result(Nil, Error) {
  use <- bool.guard(
    when: bytes < 0,
    return: Error(Invalid("result reservation is negative")),
  )
  Ok(Nil)
}

// Generated queries return a statement, its parameters and a row decoder. These
// bind only strings, integers and blobs. Parrot types a parameter that assigns a
// nullable column as `ParamNullable`, which binds as the value it holds, or as
// SQL NULL when it holds none.
fn parameter(param: dev.Param) -> Result(sqlight.Value, Error) {
  case param {
    dev.ParamInt(value) -> Ok(sqlight.int(value))
    dev.ParamString(value) -> Ok(sqlight.text(value))
    dev.ParamBitArray(value) -> Ok(sqlight.blob(value))
    dev.ParamNullable(Some(inner)) -> parameter(inner)
    dev.ParamNullable(None) -> Ok(sqlight.null())
    dev.ParamFloat(_)
    | dev.ParamBool(_)
    | dev.ParamTimestamp(_)
    | dev.ParamDate(_)
    | dev.ParamList(_)
    | dev.ParamDynamic(_) ->
      Error(Invalid("unsupported generated ledger parameter"))
  }
}

fn rows(
  connection: sqlight.Connection,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
) -> Result(List(a), Error) {
  let #(text, params, decoder) = generated
  use arguments <- result.try(list.try_map(params, parameter))
  sqlight.query(text, on: connection, with: arguments, expecting: decoder)
  |> result.map_error(sql_error)
}

fn statement(
  connection: sqlight.Connection,
  generated: #(String, List(dev.Param)),
) -> Result(Nil, Error) {
  let #(text, params) = generated
  rows(connection, #(text, params, decode.success(Nil)))
  |> result.replace(Nil)
}

fn number(connection: sqlight.Connection, text: String) -> Result(Int, Error) {
  use values <- result.try(
    sqlight.query(
      text,
      on: connection,
      with: [],
      expecting: decode.at([0], decode.int),
    )
    |> result.map_error(sql_error),
  )
  case values {
    [value] -> Ok(value)
    [] | [_, _, ..] -> Error(MalformedRow("expected one metadata row"))
  }
}

// Every write runs in `BEGIN IMMEDIATE`, which takes the database's write lock
// before the first read. The checks that guard a write therefore see the state
// the write will land on, even with several connections to the file. A failure
// rolls back, so a refused admission leaves no row behind.
fn transaction(
  connection: sqlight.Connection,
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  use Nil <- result.try(execute(connection, "BEGIN IMMEDIATE"))
  let outcome =
    run()
    |> result.try(fn(value) {
      execute(connection, "COMMIT") |> result.replace(value)
    })
  case outcome {
    Ok(value) -> Ok(value)
    Error(error) -> {
      let _rolled_back = execute(connection, "ROLLBACK")
      Error(error)
    }
  }
}

fn execute(connection: sqlight.Connection, text: String) -> Result(Nil, Error) {
  sqlight.exec(text, on: connection) |> result.map_error(sql_error)
}

fn sql_error(error: sqlight.Error) -> Error {
  Database(string.inspect(error))
}
