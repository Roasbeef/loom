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
import gleam/string
import lsp/query
import tools/agent.{type Agency}
import tools/bash
import tools/codemode as codemode_tool
import tools/context as context_tool
import tools/fs
import tools/grep
import tools/history as history_tool
import tools/job as job_tool
import tools/lsp as lsp_tool
import tools/remember
import tools/schedule as schedule_tool
import tools/tool.{type Registry, type Tool}
import tools/working_directory

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

// A call hint is paid only by a host whose default program can actually
// make the call. Import permission alone does not imply a serviced router.
type CodeModeHint {
  CodeModeHint(
    tool_name: String,
    module: String,
    capability: String,
    text: String,
  )
}

// Keep the direct tool's contract beside its program alternative. Reads
// return plain text, edits match unique strings, and processes take argv;
// none is a claim that the direct tool's wire schema works inside a program.
fn code_mode_hints() -> List(CodeModeHint) {
  [
    CodeModeHint(
      "fs_read",
      "cap/fs",
      "fs.read",
      "When `code_mode` is available: `fs.read(path)` from `cap/fs` returns `Result(String, FsError)` for whole-file text; use `fs_read` for images, windows or edit anchors.",
    ),
    CodeModeHint(
      "fs_write",
      "cap/fs",
      "fs.write",
      "When `code_mode` is available: `fs.write(path, contents)` from `cap/fs` returns `Result(Nil, FsError)`; serialize writes to the same path.",
    ),
    CodeModeHint(
      "fs_edit",
      "cap/fs",
      "fs.edit",
      "When `code_mode` is available: `fs.edit(path, replacements)` from `cap/fs` returns `Result(Nil, FsError)`; each `fs.Replacement(find:, replace_with:)` must match exactly once. It takes no hashline anchors or digest.",
    ),
    CodeModeHint(
      "grep",
      "cap/search",
      "search.grep",
      "When `code_mode` is available: `search.grep(search.grep_query(under: path, matching: pattern))` from `cap/search` returns `Result(Found, SearchError)`; filter matches inside the program and check completeness.",
    ),
    CodeModeHint(
      "bash",
      "cap/proc",
      "proc.run",
      "When `code_mode` is available: `proc.run(proc.command(argv))` from `cap/proc` returns `Result(Output, ProcError)` for a foreground process with no shell expansion; check exit_code, timed_out and output truncation.",
    ),
  ]
}

// Default-seam hints need no extra choice at the call site. An alternative
// seam's wider surface remains discoverable through code_mode and cap://.
fn with_code_mode_hints(
  tools: List(Tool),
  mode: Option(codemode_tool.CodeMode),
) -> List(Tool) {
  case mode {
    None -> tools
    Some(mode) -> {
      let offer = mode.seams.default
      let hints =
        list.filter(code_mode_hints(), fn(hint) {
          list.contains(offer.allowed_imports, hint.module)
          && list.contains(offer.serviced_caps, hint.capability)
        })
      use original <- list.map(tools)
      list.find(hints, fn(hint) { hint.tool_name == original.name })
      |> result.map(fn(hint) {
        tool.Tool(
          ..original,
          description: original.description <> " " <> hint.text,
        )
      })
      |> result.unwrap(original)
    }
  }
}

// Profiles describe the native door, so they follow its admission on each
// offer rather than the presence of a compiler or a configured catalogue.
fn with_lsp_guidance(
  mode: codemode_tool.CodeMode,
  hints: List(#(String, String)),
) -> codemode_tool.CodeMode {
  let seams = mode.seams
  codemode_tool.CodeMode(
    ..mode,
    seams: codemode_tool.Seams(
      default: lsp_offer_guidance(seams.default, hints),
      alternates: list.map(seams.alternates, lsp_offer_guidance(_, hints)),
    ),
  )
}

fn lsp_offer_guidance(
  offer: codemode_tool.SeamOffer,
  hints: List(#(String, String)),
) -> codemode_tool.SeamOffer {
  case
    list.contains(offer.allowed_imports, "cap/lsp")
    && list.contains(offer.serviced_caps, "lsp.definition")
  {
    False -> offer
    True -> {
      let profiles =
        list.map(hints, fn(profile) { "- `" <> profile.0 <> "`: " <> profile.1 })
      let notes = string.join(profiles, "\n")
      case notes {
        "" -> offer
        _ ->
          codemode_tool.SeamOffer(
            ..offer,
            extra_surfaces: list.append(offer.extra_surfaces, [
              "### cap/lsp\n\nLanguage-server guidance for this seam:\n"
              <> notes,
            ]),
          )
      }
    }
  }
}

/// The one contribution a host's own planes make, in the order the
/// registry has always been built in: the five core tools, the six
/// `agent_*` tools, `code_mode`, `history_search`, `remember`, the three
/// `schedule_*` tools, `context_remaining` and the three `job_*` tools.
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
/// `lsp` is the session's language-server door, `None` when no
/// `[lsp.<name>]` server is configured (ADR-015 §6). It reaches core
/// tools too: with a door, `fs_write` and `fs_edit` are built with
/// `tools/lsp.diagnostics_observer` so a landed write's result gains its
/// settled diagnostics. Without one they are the plain tools, byte for
/// byte. Language-server calls are available through code mode rather
/// than separate top-level tools. `lsp_hints` are the served profiles'
/// hints in server-name order; they extend discovery only on offers
/// admitting and servicing `cap/lsp`.
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
///     option.None,
///     option.None,
///     [],
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
  jobs: Option(job_tool.Jobs),
  lsp: Option(query.Door),
  lsp_hints: List(#(String, String)),
) -> List(Contribution) {
  let code_mode = case lsp {
    None -> code_mode
    Some(_door) -> option.map(code_mode, with_lsp_guidance(_, lsp_hints))
  }

  // The jobs plane is the one that reaches a *core* tool: `bash` takes
  // the door whether or not there is one behind it, because `mode:
  // "background"` has to be answered on a host with no jobs actor rather
  // than absent from a schema that is otherwise identical everywhere.
  // The three `job_*` definitions are gated the way every other plane's
  // are — a host without the actor pays no cached bytes for tools that
  // could only refuse.
  let door = option.unwrap(jobs, job_tool.unavailable())

  // The observer is the only difference a door makes to the two write
  // tools, and `fs.write_tool()` is `write_tool_with` over an observer
  // that always answers `None`, so the no-door arm is the tools every
  // host without a language server has always registered.
  let #(write_tool, edit_tool) = case lsp {
    None -> #(fs.write_tool(), fs.edit_tool())
    Some(lsp_door) -> {
      let observer = lsp_tool.diagnostics_observer(lsp_door)
      #(fs.write_tool_with(observer), fs.edit_tool_with(observer))
    }
  }
  let read_schemes =
    list.flatten([
      case code_mode {
        None -> []
        Some(mode) -> [codemode_tool.cap_scheme(mode)]
      },
      case jobs {
        None -> []
        Some(available) -> [job_tool.scheme(available)]
      },
    ])
  [
    Contribution(
      origin: BuiltIn,
      tools: list.flatten([
        with_code_mode_hints(
          [
            bash.tool(door),
            grep.tool(),
            fs.read_tool_with(read_schemes),
            write_tool,
            edit_tool,
          ],
          code_mode,
        ),
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
        case jobs {
          None -> []
          Some(jobs) -> job_tool.tools(jobs)
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

/// Adds persistent shell directories to the built-in contribution only.
///
/// ## Examples
///
/// ```gleam
/// // contributions.with_directory(builtins, jobs, directory)
/// ```
pub fn with_directory(
  builtins: List(Contribution),
  jobs: job_tool.Jobs,
  directory: working_directory.Door,
) -> List(Contribution) {
  list.map(builtins, fn(contribution) {
    Contribution(
      ..contribution,
      tools: list.append(
        list.map(contribution.tools, fn(offered) {
          case offered.name {
            "bash" -> {
              let selected = bash.tool_with_directory(jobs, directory)
              tool.Tool(..offered, schema: selected.schema, run: selected.run)
            }
            _ -> offered
          }
        }),
        [working_directory.tool(directory)],
      ),
    )
  })
}
