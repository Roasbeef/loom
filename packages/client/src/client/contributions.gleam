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
//// ## An extension never overrides a built-in; an operator may
////
//// pi extensions like `hashline-edit` register a tool over a built-in
//// name and expect to replace it. Loom refuses that, and the refusal is
//// the collision above: an install that silently redefined what the
//// model's `fs_edit` call does would make every sandbox argument in the
//// tree an argument about the wrong function, and nothing in the
//// manifest an operator reads would say which one they got.
////
//// What an operator may do is *deactivate* the built-in. `deactivate`
//// drops named tools from the built-in contribution before the registry
//// is built, so the name is genuinely free and an extension's tool of
//// that name is admitted with no collision to refuse. The two directions
//// are the whole ruling: an active built-in still collides, and a
//// deactivated one yields. The decision stays the operator's, it is made
//// in the server's own configuration rather than in the extension's
//// manifest, and it is visible in `server.tools` at boot.
////
//// Deactivation frees a name and is not a capability control. Dropping
//// `fs_edit` stops the model calling that tool by that name; it does not
//// narrow what the session may do, because `code_mode`'s prelude still
//// reaches `cap/proc.run`, `cap/fs.write` and `cap/fs.edit` through the
//// broker. An operator who wants the *ability* gone narrows the base
//// policy, which is the layer that is actually enforced.
////
//// Deactivation reaches built-ins only. Deactivating an *extension's*
//// tool would be a way to hand one extension's name to another by
//// configuration, which is the shadowing this module refuses at one
//// remove; the way to stop an extension's tool is to uninstall the
//// extension.
////
//// ## Why the origin is not just decoration
////
//// The registry itself is a name → tool table and has no memory of
//// where a tool came from; it does not need one, because dispatch is by
//// name. The origin exists so that the refusal above can say *whose*
//// tool lost, which is the only sentence an operator can act on.
////
//// ## What a session sees, and when
////
//// A registry built here reaches a session exactly once. The system
//// prompt is rendered at session creation and pinned, and the strand's
//// durable `active_tool_names` is seeded from the same registry at the
//// same moment, so a session created before an extension was installed
//// keeps the tool array and the prompt index it was created with for its
//// whole life. Installing an extension changes what the *next* session
//// sees. That is the pinning contract rather than a gap in it: the
//// prompt sits inside a one-hour cache breakpoint, and a registry that
//// could grow under a live session would move bytes every strand had
//// already paid for.

import client/scheduleseam
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tools/agent.{type Agency}
import tools/bash
import tools/codemode as codemode_tool
import tools/context as context_tool
import tools/fs
import tools/grep
import tools/history as history_tool
import tools/remember
import tools/schedule as schedule_tool
import tools/tool.{type Registry, type Tool}

/// Where a registered tool came from.
///
/// Two variants and no third: a tool is either compiled into this
/// harness or contributed by an installed extension. `code_mode` belongs
/// to the first even though it only exists on a host with a toolchain,
/// because gating on a plane is what `history_search`, `remember` and
/// the `schedule_*` tools already do and none of them is a separate
/// origin either. The closed set is what makes the collision message
/// decidable — every name has exactly one of these behind it.
pub type Origin {
  /// A tool compiled into the harness itself.
  BuiltIn

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

/// The one contribution a host's own planes make, in the order the
/// registry has always been built in: the five core tools, the six
/// `agent_*` tools, `code_mode`, `history_search`, `remember`, the three
/// `schedule_*` tools, and `context_remaining`.
///
/// Each `Option` is a plane that decided its own presence from the host
/// it found, and the gating is arithmetic rather than tidiness: the wire
/// tool array is built from this registry, renders ahead of the system
/// prompt, and is the byte prefix of the provider's cached region — so a
/// permanently-refusing definition would be paid for on every request of
/// every strand for the life of the session. A host with none of the
/// planes offers five tools. `context_remaining` is the one whose plane
/// every served session has — it needs the session store and the
/// compaction settings and nothing else — so its `Option` is for a
/// registry built with no session behind it, which only a test does.
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
  context: Option(context_tool.Context),
) -> List(Contribution) {
  [
    Contribution(
      origin: BuiltIn,
      tools: list.flatten([
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
        case code_mode {
          None -> []
          Some(code_mode) -> codemode_tool.tools(code_mode)
        },
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
          Some(schedules) ->
            schedule_tool.tools(schedules, scheduleseam.limits())
        },
        case context {
          None -> []
          Some(context) -> [context_tool.tool(context)]
        },
      ]),
    ),
  ]
}

/// Drops the named tools from every built-in contribution, leaving
/// contributions from extensions untouched.
///
/// This is what makes an extension's tool of a built-in name installable:
/// with the built-in gone the name is unclaimed, so `registry` finds no
/// collision and the extension's tool is the only one registered under
/// it. A name nothing offers is not an error — an operator naming a tool
/// this host never built is stating a posture, and refusing the boot over
/// it would make a shared configuration unusable across hosts whose
/// planes differ.
///
/// ## Examples
///
/// ```gleam
/// assert contributions.deactivate([], ["fs_edit"]) == []
/// ```
///
pub fn deactivate(
  contributions: List(Contribution),
  names: List(String),
) -> List(Contribution) {
  use contribution <- list.map(contributions)
  case contribution.origin {
    Extension(..) -> contribution

    BuiltIn ->
      Contribution(
        ..contribution,
        tools: list.filter(contribution.tools, fn(each) {
          !list.contains(names, each.name)
        }),
      )
  }
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
  // The check and the build are separate passes because they answer
  // different questions. The fold below only decides whether any name
  // crosses a contribution boundary; what actually goes into the table,
  // and in what order, is the flattened list, where "the order is the
  // contributions in order" is visible at a glance.
  use _claimed <- result.map(list.try_fold(contributions, dict.new(), claim))
  tool.registry(list.flat_map(contributions, fn(each) { each.tools }))
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
/// assert contributions.origin_text(contributions.BuiltIn)
///   == "a built-in tool"
/// ```
///
pub fn origin_text(origin: Origin) -> String {
  case origin {
    BuiltIn -> "a built-in tool"
    Extension(name:) -> "the extension `" <> name <> "`"
  }
}

// One contribution's claim on the names earlier contributions have not
// taken. Its own repeats are de-duplicated first, so a single author
// restating a name never collides with themselves — that is the
// override `tool.registry` settles by last-registration-wins.
fn claim(
  claimed: Dict(String, Origin),
  contribution: Contribution,
) -> Result(Dict(String, Origin), Collision) {
  let names = list.unique(list.map(contribution.tools, fn(each) { each.name }))

  case first_taken(names, claimed, contribution.origin) {
    Ok(collision) -> Error(collision)
    Error(Nil) ->
      Ok(
        list.fold(names, claimed, fn(claimed, name) {
          dict.insert(claimed, name, contribution.origin)
        }),
      )
  }
}

// The first of these names an earlier contribution already holds, as the
// collision it would be. `Error(Nil)` is the clear path.
fn first_taken(
  names: List(String),
  claimed: Dict(String, Origin),
  origin: Origin,
) -> Result(Collision, Nil) {
  list.find_map(names, fn(name) {
    case dict.get(claimed, name) {
      Ok(first) -> Ok(Collision(name:, first:, second: origin))
      Error(Nil) -> Error(Nil)
    }
  })
}
