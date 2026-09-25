//// Which language servers a session runs: the operator's `loom.toml`
//// tables and every installed profile that does not collide with them
//// (ADR-014 §4).
////
//// # Why this is its own module
////
//// A language profile can reach a session from two places, the operator's
//// `[lsp.<name>]` tables and a `tier = "profile"` extension, and the two
//// have to be combined into the one list the language-server plane and
//// `lsp_definition`'s hints are built from. The rule for combining them is
//// small, decides what binary the harness runs in a jail, and is exactly
//// the kind of rule a boot hides, so it lives here as one pure function a
//// test can drive with values rather than with an installed extension and
//// a booted session.
////
//// # The rule
////
//// The operator's file wins, whole. A `loom.toml` table replaces an
//// installed profile of the same name entirely, never field by field,
//// because a merged profile would be a grant nobody wrote down.
////
//// What is left of the installed profiles is then judged as a set, and a
//// conflict refuses every installed profile involved in it: two installed
//// profiles sharing a server name, or a file extension claimed twice
//// across the whole combined set. The operator's own tables are never the
//// refused side; within `loom.toml` a conflict is already a parse error
//// (ADR-013). Nothing is first-wins. Install order is not an order anybody
//// chose, so letting the earlier install keep `.go` would decide by
//// accident which server answers for every Go file. Judging every
//// candidate against the whole candidate set, rather than removing losers
//// as they are found, is also what makes the answer independent of the
//// order the extensions were discovered in.

import client/lsp/profile.{type LspServer}
import gleam/list
import gleam/result
import gleam/string

/// The other side of a conflict, named for the operator who reads the
/// refusal.
pub type Claimant {
  /// A `[lsp.<name>]` table in `loom.toml`.
  Configured(server: String)

  /// A profile an installed extension ships.
  Installed(extension: String, server: String)
}

/// What two profiles collided over.
pub type Conflict {
  /// Both name the same server. Two installed profiles named alike leave
  /// no way to tell which one a tool result means.
  SameServer

  /// Both claim this file extension, which has exactly one owning server.
  SameFileExtension(file_extension: String)
}

/// One installed profile refused, naming the claimant it collided with.
///
/// A profile in conflict with several claimants is refused once per
/// claimant, so the log names every one of them.
pub type Refusal {
  Refusal(
    /// The installed extension whose profile was refused.
    extension: String,
    /// The refused profile's server name.
    server: String,
    /// The other claimant.
    other: Claimant,
    /// What they collided over.
    conflict: Conflict,
  )
}

/// The servers a session runs, sorted by name, and every installed
/// profile refused on the way there.
///
/// `configured` are the `loom.toml` tables, already free of conflicts
/// among themselves (`profile.decode_servers` refuses one). `installed`
/// pairs each loaded profile with the extension that ships it. The answer
/// keeps every configured server, drops each installed profile a
/// configured one of the same name replaces, and refuses every remaining
/// installed profile that shares a server name with another installed
/// profile or a file extension with any server at all. The servers come
/// back in name order because everything built from them, the hints above
/// all, must be the same on every boot whatever order the extensions were
/// found in.
///
/// ## Examples
///
/// ```gleam
/// // go_toml and go_ext are both named "go"; the file's table wins whole.
/// assert profiles.effective_lsp_servers([go_toml], [#("lsp_go", go_ext)])
///   == #([go_toml], [])
/// ```
///
/// ```gleam
/// // Two installed profiles both claiming .go are both refused.
/// let #(servers, refusals) =
///   profiles.effective_lsp_servers([], [#("a", go_a), #("b", go_b)])
/// assert servers == []
/// assert list.length(refusals) == 2
/// ```
///
pub fn effective_lsp_servers(
  configured configured: List(LspServer),
  installed installed: List(#(String, LspServer)),
) -> #(List(LspServer), List(Refusal)) {
  let configured_names = list.map(configured, fn(server) { server.name })

  // Replacement first, and it is not a refusal: the operator wrote a
  // table for this name, so the installed one never enters the set that
  // conflicts are judged over.
  let candidates =
    installed
    |> list.filter(fn(entry) {
      !list.contains(configured_names, { entry.1 }.name)
    })
    |> list.sort(fn(left, right) {
      string.compare(identity(left), identity(right))
    })

  // Every candidate is judged against the whole candidate set, never
  // against what survived so far, so both sides of a conflict are found
  // and discovery order decides nothing.
  let refusals =
    list.flat_map(candidates, fn(candidate) {
      conflicts(candidate, configured, candidates)
    })
  let refused =
    list.map(refusals, fn(refusal) { named(refusal.extension, refusal.server) })
  let kept =
    candidates
    |> list.filter(fn(entry) { !list.contains(refused, identity(entry)) })
    |> list.map(fn(entry) { entry.1 })
  let servers =
    list.append(configured, kept)
    |> list.sort(fn(left, right) { string.compare(left.name, right.name) })
  #(servers, refusals)
}

/// The claimant as a refusal line names it.
///
/// ## Examples
///
/// ```gleam
/// assert profiles.describe_claimant(profiles.Configured("go"))
///   == "loom.toml [lsp.go]"
/// ```
///
pub fn describe_claimant(claimant: Claimant) -> String {
  case claimant {
    Configured(server:) -> "loom.toml [lsp." <> server <> "]"
    Installed(extension:, server:) ->
      "extension " <> extension <> " [lsp." <> server <> "]"
  }
}

/// The conflict as a refusal line names it.
///
/// ## Examples
///
/// ```gleam
/// assert profiles.describe_conflict(profiles.SameFileExtension(".go"))
///   == "both claim .go"
/// ```
///
pub fn describe_conflict(conflict: Conflict) -> String {
  case conflict {
    SameServer -> "both name the same server"
    SameFileExtension(file_extension:) -> "both claim " <> file_extension
  }
}

// One installed profile's conflicts: with each configured server, then
// with each other candidate. A pair that shares a name and an extension
// is reported once, as the name, since that is the collision an operator
// has to resolve first.
fn conflicts(
  candidate: #(String, LspServer),
  configured: List(LspServer),
  candidates: List(#(String, LspServer)),
) -> List(Refusal) {
  let #(extension, server) = candidate
  let refuse = fn(other, conflict) {
    Refusal(extension:, server: server.name, other:, conflict:)
  }
  let with_configured =
    list.filter_map(configured, fn(owner) {
      shared_extension(server, owner)
      |> result.map(fn(shared) {
        refuse(Configured(owner.name), SameFileExtension(shared))
      })
    })
  let with_installed =
    list.filter_map(candidates, fn(peer) {
      let other = Installed(extension: peer.0, server: { peer.1 }.name)
      case
        identity(peer) == identity(candidate),
        { peer.1 }.name == server.name
      {
        True, _ -> Error(Nil)
        False, True -> Ok(refuse(other, SameServer))
        False, False ->
          shared_extension(server, peer.1)
          |> result.map(fn(shared) { refuse(other, SameFileExtension(shared)) })
      }
    })
  list.append(with_configured, with_installed)
}

// The first of `server`'s extensions `other` also claims, in `server`'s
// own order.
fn shared_extension(
  server: LspServer,
  other: LspServer,
) -> Result(String, Nil) {
  list.find(server.extensions, fn(extension) {
    list.contains(other.extensions, extension)
  })
}

// An installed profile's identity: its extension and its server name. An
// extension's own servers have distinct names, so the pair is unique, and
// the separator cannot occur in either half, both being
// `[a-z][a-z0-9_]*`.
fn identity(entry: #(String, LspServer)) -> String {
  named(entry.0, { entry.1 }.name)
}

fn named(extension: String, server: String) -> String {
  extension <> "/" <> server
}
