//// The built-in tool registry, unwrapped, for tests.
////
//// `contributions.registry` returns a `Result` because two contributions
//// may claim one tool name, and at the production boot that is a refusal
//// an operator has to read. The built-in contributions alone cannot
//// collide — every plane's tool names are distinct and compiled in — so
//// a test that only wants "the registry this host would build" would
//// otherwise carry the same three lines of unwrapping everywhere. This
//// is those three lines, once.
////
//// Nothing here weakens the check: the `let assert` names the invariant,
//// so a change that made the built-ins collide fails the test suite
//// loudly rather than being papered over.

import client/contributions
import gleam/option.{type Option}
import tools/agent.{type Agency}
import tools/codemode as codemode_tool
import tools/history as history_tool
import tools/remember
import tools/schedule as schedule_tool
import tools/tool.{type Registry}

/// The registry a host with these planes would build.
///
/// ## Examples
///
/// ```gleam
/// let registry =
///   tool_registry.built_in(
///     option.None,
///     option.None,
///     option.None,
///     option.None,
///     option.None,
///   )
/// assert tool.names(registry)
///   == ["bash", "fs_edit", "fs_read", "fs_write", "grep"]
/// ```
///
pub fn built_in(
  agency: Option(Agency),
  code_mode: Option(codemode_tool.CodeMode),
  history: Option(history_tool.History),
  memory: Option(remember.Memory),
  schedules: Option(schedule_tool.Schedules),
) -> Registry {
  let assert Ok(registry) =
    contributions.built_in(agency, code_mode, history, memory, schedules)
    |> contributions.registry
    as "the built-in contributions never claim the same tool name twice"
  registry
}
