//// Who contributed a tool, and the one place a tool registry is built
//// from those contributions.
////
//// The registry used to be a positional function of five `Option`s in
//// `client/serve` — one argument per plane that might or might not have
//// opened on this host. That signature was named as a closed seam in the
//// re-baseline, and it closed the tree to exactly the thing the
//// extension architecture needs: a tool that comes from somewhere the
//// harness did not compile. This module is the seam opened. A registry
//// is built from a *list* of contributions, each naming its `Origin`,
//// and an installed extension is just one more entry on that list.
////
//// ## What a contribution is allowed to do
////
//// Within one contribution, `tool.registry`'s "last registration wins"
//// still holds: a contribution is a single author's list and re-stating
//// a name inside it is that author overriding themselves.
////
//// *Between* contributions, a repeated name is refused outright as a
//// `Collision`. This is the whole security argument for the seam and it
//// is deliberately not a policy knob: if an extension could register
//// `bash`, then installing an extension would silently redefine what the
//// model's `bash` call does, and every sandbox argument in the tree
//// would be arguing about the wrong function. Shadowing a *peer*
//// extension is refused for the same reason at one remove — an install
//// order would decide which of two tools the model actually reached.
//// A collision is therefore a boot refusal naming both origins, never a
//// warning and never a silent last-wins.
////
//// ## Why the origin is not just decoration
////
//// The registry itself is a name → tool table and has no memory of
//// where a tool came from; it does not need one, because dispatch is by
//// name. The origin exists so that the refusal above can say *whose*
//// tool lost, which is the only sentence an operator can act on.

import client/scheduleseam
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tools/agent.{type Agency}
import tools/bash
import tools/codemode as codemode_tool
import tools/fs
import tools/grep
import tools/history as history_tool
import tools/remember
import tools/schedule as schedule_tool
import tools/tool.{type Registry, type Tool}

/// Where a registered tool came from.
///
/// Three variants and no fourth: a tool is either compiled into this
/// harness, produced by the code-mode pipeline, or contributed by an
/// installed extension. The closed set is what makes the collision
/// message decidable — every name has exactly one of these behind it.
pub type Origin {
  /// A tool compiled into the harness itself.
  BuiltIn

  /// A tool the code-mode pipeline offers, which exists only on a host
  /// that wired one.
  CodeModeTools

  /// A tool an installed extension contributed, under the extension's
  /// own manifest name.
  Extension(name: String)
}

/// One origin's tools, in the order that origin wants them read.
///
/// Constructor invariant: `tools` may repeat a name (the later one
/// wins, as it always has), but a name repeated across two
/// contributions is a `Collision` rather than an override.
pub type Contribution {
  Contribution(
    /// Who is contributing.
    origin: Origin,
    /// The tools, in registration order.
    tools: List(Tool),
  )
}

/// Two contributions claimed the same tool name.
///
/// Constructor invariants: `first` is the origin that claimed `name`
/// earlier in the contribution list and `second` the one that tried to
/// take it — so the pair reads in the order an operator's install
/// history happened, and the refusal can name the newcomer as the thing
/// to remove.
pub type Collision {
  Collision(name: String, first: Origin, second: Origin)
}

/// The contributions a host's own planes make, in the order the registry
/// has always been built in: the five core tools, the six `agent_*`
/// tools, `code_mode`, `history_search`, `remember`, and the three
/// `schedule_*` tools.
///
/// Each `Option` is a plane that decided its own presence from the host
/// it found, and the gating is arithmetic rather than tidiness: the wire
/// tool array is built from this registry, renders ahead of the system
/// prompt, and is the byte prefix of the provider's cached region — so a
/// permanently-refusing definition would be paid for on every request of
/// every strand for the life of the session. A host with none of the
/// planes offers five tools.
///
/// `BuiltIn` appears more than once in the returned list, and that is
/// intended. The origin answers *who* contributed a tool rather than
/// when; code mode's tools have always sat between the messaging plane's
/// and the search index's, and reordering them to make the origins
/// contiguous would move the prompt's tool index for no reason anyone
/// could read.
///
/// ## Examples
///
/// ```gleam
/// let assert [contributions.Contribution(origin: contributions.BuiltIn, ..)] =
///   contributions.built_in(
///     option.None,
///     option.None,
///     option.None,
///     option.None,
///     option.None,
///   )
/// ```
///
pub fn built_in(
  agency: Option(Agency),
  code_mode: Option(codemode_tool.CodeMode),
  history: Option(history_tool.History),
  memory: Option(remember.Memory),
  schedules: Option(schedule_tool.Schedules),
) -> List(Contribution) {
  let core =
    list.flatten([
      [
        bash.tool(),
        grep.tool(),
        fs.read_tool(),
        fs.write_tool(),
        fs.edit_tool(),
      ],
      case agency {
        None -> []
        Some(agency) -> agent.tools(agency)
      },
    ])

  let pipeline = case code_mode {
    None -> []
    Some(code_mode) -> codemode_tool.tools(code_mode)
  }

  // The durable planes: a search index, a memory session, a schedule
  // store. Each is absent on a host whose store would not open, and each
  // registers nothing at all in that case rather than a tool that
  // refuses at call time.
  let durable =
    list.flatten([
      case history {
        None -> []
        Some(history) -> [history_tool.tool(history)]
      },
      case memory {
        None -> []
        Some(memory) -> [remember.tool(memory)]
      },
      case schedules {
        None -> []
        Some(schedules) -> schedule_tool.tools(schedules, scheduleseam.limits())
      },
    ])

  [
    Contribution(origin: BuiltIn, tools: core),
    Contribution(origin: CodeModeTools, tools: pipeline),
    Contribution(origin: BuiltIn, tools: durable),
  ]
  |> list.filter(fn(contribution) { contribution.tools != [] })
}

/// Builds the registry from an ordered list of contributions, refusing a
/// name two contributions both claim.
///
/// The resulting registry's registration order is the contributions
/// flattened in list order, which is what the system prompt's tool index
/// reads. Dispatch itself is by name and is order-blind.
///
/// ## Examples
///
/// ```gleam
/// assert contributions.registry([]) |> result.map(tool.names) == Ok([])
/// ```
///
pub fn registry(
  contributions: List(Contribution),
) -> Result(Registry, Collision) {
  // Each contribution is identified by its position rather than by its
  // origin, because `BuiltIn` legitimately appears twice and two
  // separate built-in groups claiming one name is still a collision.
  let indexed =
    list.index_map(contributions, fn(contribution, index) {
      #(index, contribution)
    })

  use #(_claimed, reversed) <- result.map(list.try_fold(
    indexed,
    #(dict.new(), []),
    claim_contribution,
  ))
  tool.registry(list.reverse(reversed))
}

/// The refusal an operator reads when two contributions claim one name.
///
/// ## Examples
///
/// ```gleam
/// assert contributions.collision_message(contributions.Collision(
///   name: "bash",
///   first: contributions.BuiltIn,
///   second: contributions.Extension(name: "websearch"),
/// ))
///   == "the tool `bash` is registered by two contributions: a built-in "
///   <> "tool and the extension `websearch`. A contribution may not "
///   <> "shadow another one's tool; remove or rename the second."
/// ```
///
pub fn collision_message(collision: Collision) -> String {
  "the tool `"
  <> collision.name
  <> "` is registered by two contributions: "
  <> origin_text(collision.first)
  <> " and "
  <> origin_text(collision.second)
  <> ". A contribution may not shadow another one's tool; remove or "
  <> "rename the second."
}

/// How an origin reads inside a sentence.
///
/// ## Examples
///
/// ```gleam
/// assert contributions.origin_text(contributions.CodeModeTools)
///   == "the code-mode pipeline"
/// ```
///
pub fn origin_text(origin: Origin) -> String {
  case origin {
    BuiltIn -> "a built-in tool"
    CodeModeTools -> "the code-mode pipeline"
    Extension(name:) -> "the extension `" <> name <> "`"
  }
}

// The state threaded through the fold: which contribution has claimed
// each name so far, and the tools collected in reverse registration
// order.
type Claiming =
  #(Dict(String, #(Int, Origin)), List(Tool))

// Folds one contribution's tools into the claim table, failing on the
// first name another contribution already holds.
fn claim_contribution(
  state: Claiming,
  entry: #(Int, Contribution),
) -> Result(Claiming, Collision) {
  let #(index, contribution) = entry
  list.try_fold(contribution.tools, state, fn(state, tool) {
    claim_tool(state, index, contribution.origin, tool)
  })
}

// One tool's claim. A name already held by *this* contribution is the
// author overriding themselves and is kept, so that `tool.registry`'s
// last-registration-wins settles it; a name held by any other
// contribution is the refusal this module exists for.
fn claim_tool(
  state: Claiming,
  index: Int,
  origin: Origin,
  tool: Tool,
) -> Result(Claiming, Collision) {
  let #(claimed, _collected) = state
  case dict.get(claimed, tool.name) {
    Ok(#(claimer, first)) if claimer != index ->
      Error(Collision(name: tool.name, first:, second: origin))
    Ok(#(_claimer, _first)) -> Ok(claim(state, index, origin, tool))
    Error(Nil) -> Ok(claim(state, index, origin, tool))
  }
}

fn claim(state: Claiming, index: Int, origin: Origin, tool: Tool) -> Claiming {
  let #(claimed, collected) = state
  #(dict.insert(claimed, tool.name, #(index, origin)), [tool, ..collected])
}
