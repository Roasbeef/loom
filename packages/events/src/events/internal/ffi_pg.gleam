//// Confined FFI over OTP's `pg` process-group module (spec §0.2: every
//// `@external` lives in an `internal/ffi_*` module, names the OTP
//// function it binds, and says why no pure alternative exists). The
//// Erlang side is `events_ffi.erl`.
////
//// Why FFI at all: `pg` is the OTP-native process-group registry — an
//// ETS-backed membership table with automatic monitor-based cleanup
//// when members die — and `gleam_erlang` ships no binding for it.
//// Re-implementing membership tracking as a Gleam actor would lose the
//// crash-cleanup and local-speed lookup properties the design names
//// (`loom-design.md` §3.6), so the bus binds `pg` directly.
////
//// Type-safety note: `pg` stores plain pids and delivery is a plain
//// Erlang send, so the typed boundary is re-established here. Only
//// `publish` ever sends the `{loom_event, _}` tuple, and it only sends
//// the caller's typed payload; `published_payload` is the matching
//// unwrap. That pairing is the documented invariant that makes the
//// unchecked `Dynamic -> payload` coercion sound.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Selector}

/// The one `pg` scope the event bus uses, as a Gleam standin for the
/// compile-time atom `loom_events` (no atom is built at runtime).
///
/// Constructor invariants: `LoomEvents` is the only scope; per-session
/// isolation comes from the group keys, not from separate scopes.
pub type Scope {
  /// The `loom_events` scope atom.
  LoomEvents
}

/// The Erlang message tag `loom_event` that `pg_publish` wraps every
/// delivered event in, as a compile-time atom standin.
///
/// Constructor invariants: distinct from the `Scope` atom so the two
/// can never be confused in a match.
type Tag {
  /// The `loom_event` tuple tag atom.
  LoomEvent
}

/// Starts (idempotently) the `pg` scope process for the bus.
///
/// Binds `pg:start/1` via `events_ffi:pg_start/1`; an already-running
/// scope is success.
@external(erlang, "events_ffi", "pg_start")
pub fn start(scope: Scope) -> Nil

/// Starts the `pg` scope process linked to the caller, for supervised
/// embedding. Fails if the scope is already running.
///
/// Binds `pg:start_link/1` via `events_ffi:pg_start_link/1`.
@external(erlang, "events_ffi", "pg_start_link")
pub fn start_link(scope: Scope) -> Result(Pid, Nil)

/// Joins the *calling process* to a group. Membership is cleaned up by
/// `pg` automatically when the process dies.
///
/// Binds `pg:join/3` via `events_ffi:pg_join/2` (always `self()`).
@external(erlang, "events_ffi", "pg_join")
pub fn join(scope: Scope, group: group) -> Nil

/// Whether the *calling process* is already a local member of a group.
/// `pg` counts multiplicity — joining twice makes two memberships, not
/// one — so this is what makes `join` idempotent per `{scope, group,
/// pid}` from the caller's side: check before joining.
///
/// Binds `pg:get_local_members/2` via `events_ffi:pg_is_member/2`.
@external(erlang, "events_ffi", "pg_is_member")
pub fn is_member(scope: Scope, group: group) -> Bool

/// Removes the calling process from a group; a no-op if it never
/// joined.
///
/// Binds `pg:leave/3` via `events_ffi:pg_leave/2` (always `self()`).
@external(erlang, "events_ffi", "pg_leave")
pub fn leave(scope: Scope, group: group) -> Nil

/// The number of local members in a group — an ETS lookup, the
/// local-speed query the design asks of the bus.
///
/// Binds `pg:get_local_members/2` via `events_ffi:pg_member_count/2`.
@external(erlang, "events_ffi", "pg_member_count")
pub fn member_count(scope: Scope, group: group) -> Int

/// Sends `payload` to every local member of the group as a
/// `{loom_event, payload}` message. Best-effort: no acks, no retries —
/// events are hints and loss is legal.
///
/// Binds `pg:get_local_members/2` plus plain sends via
/// `events_ffi:pg_publish/3`.
@external(erlang, "events_ffi", "pg_publish")
pub fn publish(scope: Scope, group: group, payload: payload) -> Nil

/// Unwraps a `{loom_event, payload}` message received by a group
/// member. Unchecked coercion — sound because only `publish` builds
/// that tuple, and it only carries the typed payload (see module doc).
///
/// Binds `events_ffi:published_payload/1` (pure unwrap; it lives in the
/// shim because the tuple shape is an Erlang-side detail).
@external(erlang, "events_ffi", "published_payload")
fn published_payload(message: Dynamic) -> payload

/// Extends a selector to receive published bus events, mapping each
/// unwrapped payload into the caller's message type.
///
/// ## Examples
///
/// ```gleam
/// // process.new_selector() |> ffi_pg.select_published(Hint)
/// ```
///
pub fn select_published(
  selector: Selector(message),
  map: fn(payload) -> message,
) -> Selector(message) {
  process.select_record(selector, tag: LoomEvent, fields: 1, mapping: fn(raw) {
    map(published_payload(raw))
  })
}
