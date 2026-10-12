//// What an operator's `enroll`, `revoke` and `renew` decide, apart from the
//// files and the socket (protocol-change/086).
////
//// Each command turns a request and the ledger as it stands into one entry to
//// sign. This module is that step, and it is pure: the certificate's pin, the
//// clock and the ledger are arguments, so every refusal and every concern has a
//// test that needs no key, no file and no daemon.
////
//// ## The entry comes from the fold
////
//// A `member` entry for `renew` is built from the member's fields in the
//// current fold state, with only the pin replaced. It is not copied from the
//// member's last entry, because that entry may name links to members that have
//// been revoked since, and the fold would refuse it for naming a member that is
//// no longer active (the fold section of 086). `enroll` builds a new entry
//// from the request alone.
////
//// ## Pre-flight
////
//// `check_enrollment` refuses a request that is wrong in itself before the
//// authority key is unlocked. `membership_ledger.check` runs the fold on the
//// entry before it is signed, and so before anything is appended to the
//// operator's copy or a bundle is written. It needs the entry, which carries
//// the pin of the certificate, so it runs after the certificate is minted. A
//// refusal is turned into a sentence for the operator naming the member or
//// link at fault (`describe`).
////
//// ## What `revoke` checks, and what it cannot
////
//// A revoke is safe to sign but not always wise to send. `concerns` lists what
//// the revoke would newly break in the link graph: an executor left with no
//// orchestrator to use it, and members cut off from the rest. 086 also asks the
//// tool to check that the revoked member owns no sessions or scopes. A session
//// is owned by a daemon, and no daemon can ask another what it owns until the
//// admin surface of protocol-change/085 carries it (phase 2), so this build does
//// not check it and says so in its output.

import client/distribution
import client/distribution_plan.{
  type Role, type Workspace, Executor, Orchestrator,
}
import client/ledger_control.{type StatusView}
import client/membership_entry.{
  type Entry, type Member, Entry, Member, NotInDirectory, Revoke, Upsert,
}
import client/membership_ledger.{type Ledger}
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import storage/catalogue

/// What `enroll` was asked to do.
pub type Enrollment {
  Enrollment(
    /// The plan name: the bundle's name and an executor's `[executors.<name>]`
    /// key on the orchestrators that use it.
    name: String,
    /// The full Erlang node name the certificate is issued for.
    node: String,
    /// What the daemon does.
    role: Role,
    /// The host others reach it at. The host of `node` when absent.
    host: Option(String),
    /// The fixed distribution port, if the operator wants a firewall rule.
    listen_port: Option(Int),
    /// The names of the members it may connect to. Explicit, because deriving
    /// them from roles would let any laptop attach to every executor.
    links: List(String),
    /// The workspaces an executor registers.
    workspaces: List(Workspace),
    /// Where the node's credentials go on its machine, if not the default.
    bundle_dir: Option(String),
  )
}

/// Checks an enrollment's own fields, before any key is unlocked.
///
/// An executor must name at least one orchestrator in `links`. A member is
/// reached through an edge that one end lists, and `enroll` refuses a name that
/// is already a member, so links cannot be added to an executor later without
/// revoking it and enrolling it again. An executor enrolled with none would be
/// reachable only by an orchestrator enrolled after it that lists it, which is
/// a surprise worth refusing here, where the operator is reading the sentence.
///
/// ## Examples
///
/// ```gleam
/// ledger_operator.check_enrollment(request) // -> Ok(Nil)
/// ```
pub fn check_enrollment(request: Enrollment) -> Result(Nil, String) {
  use Nil <- result.try(case catalogue.is_executor_name(request.name) {
    True -> Ok(Nil)
    False ->
      Error(
        request.name
        <> " is not a node name: lowercase letters, numbers, _ and -, "
        <> "starting with a letter, at most 32 characters",
      )
  })
  use Nil <- result.try(distribution.check_node_name("--node", request.node))
  use Nil <- result.try(case request.listen_port {
    Some(port) if port < 1 || port > 65_535 ->
      Error("--port must be 1 through 65535")
    _ -> Ok(Nil)
  })
  use Nil <- result.try(case request.role, request.links {
    Executor, [] ->
      Error(
        request.name
        <> " is an executor with no --links, so no orchestrator would be "
        <> "linked to it, and links cannot be added to a member later without "
        <> "revoking it and enrolling it again. Name at least one "
        <> "orchestrator with --links.",
      )
    _, _ -> Ok(Nil)
  })
  use Nil <- result.try(case request.role, request.workspaces {
    Orchestrator, [_, ..] ->
      Error(
        "--workspace belongs to an executor, and this node is an orchestrator",
      )
    _, _ -> Ok(Nil)
  })
  list.try_each(request.workspaces, fn(workspace) {
    case
      catalogue.is_workspace_name(workspace.name),
      distribution_plan.is_absolute_path(workspace.root)
    {
      True, True -> Ok(Nil)
      False, _ ->
        Error("--workspace name is not a workspace name: " <> workspace.name)
      _, False ->
        Error("--workspace root must be an absolute path: " <> workspace.root)
    }
  })
}

/// The host a node is reached at: the given one, or the host of its name.
///
/// ## Examples
///
/// ```gleam
/// assert ledger_operator.host(request) == "laptop2.example.net"
/// ```
pub fn host(request: Enrollment) -> String {
  option.lazy_unwrap(request.host, fn() {
    distribution_plan.host_of(request.node)
  })
}

/// The entry that enrolls a new member, or the sentence that says why not.
///
/// A name that is an active member is refused: `renew` replaces its
/// certificate, and a name is enrolled again only after a revoke. A name that
/// was revoked may be enrolled again, with whatever node and links the request
/// gives.
///
/// ## Examples
///
/// ```gleam
/// ledger_operator.enroll(ledger, request, pin, "2026-10-12T09:00:00Z")
/// ```
pub fn enroll(
  ledger: Ledger,
  request: Enrollment,
  pin: BitArray,
  time: String,
) -> Result(Entry, String) {
  use Nil <- result.try(case membership_ledger.member(ledger, request.name) {
    Ok(_) ->
      Error(
        request.name
        <> " is already a member; `renew` replaces its certificate, and a "
        <> "different node takes the name only after a `revoke`",
      )
    Error(Nil) -> Ok(Nil)
  })
  let member =
    Member(
      name: request.name,
      node: request.node,
      host: host(request),
      listen_port: request.listen_port,
      role: request.role,
      directory: NotInDirectory,
      links: list.unique(request.links),
      pin:,
    )
  preflight(ledger, entry_after(ledger, time, Upsert(member)))
}

/// The entry that replaces a member's certificate, and the member as it will
/// be: the fields of the fold state with the new pin.
///
/// ## Examples
///
/// ```gleam
/// ledger_operator.renew(ledger, "laptop", new_pin, time)
/// ```
pub fn renew(
  ledger: Ledger,
  name: String,
  pin: BitArray,
  time: String,
) -> Result(#(Entry, Member), String) {
  use current <- result.try(
    membership_ledger.member(ledger, name)
    |> result.map_error(fn(_) { not_a_member(ledger, name) }),
  )
  let member = Member(..current, pin:)
  use entry <- result.map(preflight(
    ledger,
    entry_after(ledger, time, Upsert(member)),
  ))
  #(entry, member)
}

/// The entry that removes a member. `reason` is at most 200 bytes of text with
/// no control character, which the entry's reader enforces and this refuses
/// first.
///
/// ## Examples
///
/// ```gleam
/// ledger_operator.revoke(ledger, "laptop", "lost", time)
/// ```
pub fn revoke(
  ledger: Ledger,
  name: String,
  reason: String,
  time: String,
) -> Result(Entry, String) {
  use current <- result.try(
    membership_ledger.member(ledger, name)
    |> result.map_error(fn(_) { not_a_member(ledger, name) }),
  )
  use Nil <- result.try(
    case string.byte_size(reason) <= 200 && !has_control(reason) {
      True -> Ok(Nil)
      False ->
        Error("--reason must be at most 200 bytes with no control character")
    },
  )
  preflight(
    ledger,
    entry_after(ledger, time, Revoke(name: name, pin: current.pin, reason:)),
  )
}

fn has_control(text: String) -> Bool {
  list.any(string.to_utf_codepoints(text), fn(point) {
    let code = string.utf_codepoint_to_int(point)
    code < 32 || code == 127
  })
}

fn not_a_member(ledger: Ledger, name: String) -> String {
  case membership_ledger.enrollment(ledger, name) {
    membership_ledger.Revoked -> name <> " was revoked and is not a member"
    _ -> name <> " is not a member of this ledger"
  }
}

fn entry_after(
  ledger: Ledger,
  time: String,
  kind: membership_entry.Kind,
) -> Entry {
  let head = membership_ledger.head(ledger)
  Entry(seq: head.seq + 1, prev: head.id, time:, kind:)
}

// The fold, run before anything is signed. A refusal becomes a sentence.
fn preflight(ledger: Ledger, entry: Entry) -> Result(Entry, String) {
  membership_ledger.check(ledger, entry)
  |> result.replace(entry)
  |> result.map_error(describe)
}

/// A sentence for a refusal of the fold, naming what is at fault.
///
/// ## Examples
///
/// ```gleam
/// ledger_operator.describe(membership_ledger.Invalid(membership_ledger.PinInUse))
/// ```
pub fn describe(refusal: membership_ledger.Refusal) -> String {
  case refusal {
    membership_ledger.Invalid(rule) ->
      case rule {
        membership_ledger.NodeInUse(node:) ->
          "the node " <> node <> " already belongs to another member"
        membership_ledger.PinInUse ->
          "another member already holds this certificate"
        membership_ledger.UnknownLink(name:) ->
          name
          <> " cannot be linked: it is not an active member, or it is the "
          <> "node itself"
        membership_ledger.TooManyActive ->
          "the ledger would have more than "
          <> int.to_string(membership_ledger.max_active)
          <> " active members"
        membership_ledger.TooManyNames ->
          "the ledger would have named more than "
          <> int.to_string(membership_ledger.max_names)
          <> " members over its life; provision again to start a new one"
        membership_ledger.NotActive(name:) -> name <> " is not an active member"
        membership_ledger.LedgerFull ->
          "the ledger holds its limit of "
          <> int.to_string(membership_ledger.max_entries)
          <> " entries; provision again to start a new one"
        membership_ledger.FirstEntryNotGenesis
        | membership_ledger.GenesisNotFirst ->
          "the entry is out of order in the ledger"
      }
    other -> "the entry is refused at step " <> membership_ledger.step(other)
  }
}

// --- what a revoke would break -----------------------------------------------

/// Something a revoke would newly break in the link graph.
pub type Concern {
  /// An executor that no orchestrator is linked to any longer. It serves
  /// orchestrators and is dialed only by them, so it would never hear of a
  /// later entry (design note section 9.2).
  Orphaned(executor: String)

  /// Members that can no longer reach the largest group of members by any
  /// chain of links.
  Cut(names: List(String))
}

/// The concerns the ledger after a revoke has that the ledger before it did
/// not. A concern that was there already is not the revoke's doing and does not
/// stop it.
///
/// ## Examples
///
/// ```gleam
/// ledger_operator.concerns(before, after) // -> [Orphaned("devbox")]
/// ```
pub fn concerns(before: Ledger, after: Ledger) -> List(Concern) {
  let already = all_concerns(before)
  list.filter(all_concerns(after), fn(concern) {
    !list.contains(already, concern)
  })
}

fn all_concerns(ledger: Ledger) -> List(Concern) {
  let members = membership_ledger.members(ledger)
  let orphans =
    list.filter_map(members, fn(member) {
      let users =
        membership_ledger.pin_table(ledger, member.name)
        |> membership_ledger.peers
        |> list.filter(fn(peer) { peer.role == Orchestrator })
      case member.role, users {
        Executor, [] -> Ok(Orphaned(member.name))
        _, _ -> Error(Nil)
      }
    })
  let groups =
    components(ledger, list.map(members, fn(member) { member.name }), [])
    |> list.map(fn(group) { list.sort(set.to_list(group), string.compare) })
    |> list.sort(fn(a, b) {
      case int.compare(list.length(b), list.length(a)) {
        order.Eq -> string.compare(first_of(a), first_of(b))
        other -> other
      }
    })

  // The largest group is the deployment as it stays, and the others are what
  // the revoke cuts off from it. Of two groups of one size the one whose first
  // name sorts earlier stays.
  let cut = case groups {
    [] | [_] -> []
    [_, ..others] -> [
      Cut(list.sort(list.flatten(others), string.compare)),
    ]
  }
  list.append(orphans, cut)
}

fn first_of(names: List(String)) -> String {
  case names {
    [first, ..] -> first
    [] -> ""
  }
}

// The groups of names that reach one another by links, each as a set.
fn components(
  ledger: Ledger,
  names: List(String),
  found: List(set.Set(String)),
) -> List(set.Set(String)) {
  case names {
    [] -> list.reverse(found)
    [name, ..rest] -> {
      let group = reach(ledger, [name], set.new())
      components(
        ledger,
        list.filter(rest, fn(other) { !set.contains(group, other) }),
        [group, ..found],
      )
    }
  }
}

// The names reachable from a frontier by links, in the sense of the pin table
// (either end lists the other, or both are in the directory).
fn reach(
  ledger: Ledger,
  frontier: List(String),
  seen: set.Set(String),
) -> set.Set(String) {
  case frontier {
    [] -> seen
    [name, ..rest] ->
      case set.contains(seen, name) {
        True -> reach(ledger, rest, seen)
        False -> {
          let next =
            membership_ledger.pin_table(ledger, name)
            |> membership_ledger.peers
            |> list.map(fn(peer) { peer.name })
          reach(ledger, list.append(next, rest), set.insert(seen, name))
        }
      }
  }
}

/// A concern in the words the operator reads.
///
/// ## Examples
///
/// ```gleam
/// ledger_operator.describe_concern(Orphaned("devbox"))
/// ```
pub fn describe_concern(concern: Concern) -> String {
  case concern {
    Orphaned(executor:) ->
      executor
      <> " would have no orchestrator linked to it, so it would never hear of "
      <> "a later entry"
    Cut(names:) ->
      "the members "
      <> string.join(names, ", ")
      <> " would no longer be linked to the rest"
  }
}

// --- who has confirmed -------------------------------------------------------

/// Whether a member holds the entry.
pub type Confirmation {
  /// The member reported a head at or past the entry.
  Confirmed

  /// The member has not reported the entry. `reported` is the newest sequence
  /// number it did report, or `None` if it has not reported at all.
  Pending(reported: Option(Int))
}

/// Each active member of a daemon's status with whether it holds the entry at
/// `seq`, ordered by name. The answering daemon reports itself at its own head.
/// A member that has not connected to the daemon, such as a node that has not
/// started yet, is pending with no reported number.
///
/// ## Examples
///
/// ```gleam
/// ledger_operator.confirmations(status, 4)
/// // -> [#("devbox", Pending(Some(3))), #("hub", Confirmed)]
/// ```
pub fn confirmations(
  status: StatusView,
  seq: Int,
) -> List(#(String, Confirmation)) {
  list.map(status.members, fn(member) {
    case member.reported_seq {
      Some(reported) if reported >= seq -> #(member.name, Confirmed)
      reported -> #(member.name, Pending(reported))
    }
  })
}

/// Whether every member in a list of confirmations holds the entry.
///
/// ## Examples
///
/// ```gleam
/// assert ledger_operator.all_confirmed([#("hub", Confirmed)])
/// ```
pub fn all_confirmed(rows: List(#(String, Confirmation))) -> Bool {
  list.all(rows, fn(row) { row.1 == Confirmed })
}
