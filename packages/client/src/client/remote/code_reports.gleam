//// Code-mode report custody is bound to the admitted owner incarnation.
////
//// `retained_tool` replaces only the trusted execution and retention callbacks
//// of the ordinary synchronous tool shell. Both retain the original ToolKey.
//// The custodian refuses a reclaimable retention handle, so a runner surviving
//// an owner restart cannot commit its value through a replacement owner.
//// Assembly selects CodeModeReportV1 before invoking this tool; this module
//// neither admits a fresh run nor guesses a profile from a provider tool name.

import client/codemode
import client/remote/custodian
import core/remote_tool
import gleam/result
import tools/call_record
import tools/code_report
import tools/codemode as shell
import tools/tool

/// Constructs the synchronous shell for one already admitted original run.
/// This does not select a remote compiler or launcher; Config owns that choice.
///
/// ## Examples
///
/// ```gleam
/// // code_reports.retained_tool(config, pinned_owner, original_key)
/// ```
pub fn retained_tool(
  config: codemode.Config,
  owner: custodian.Handle,
  parent: remote_tool.ToolKey,
) -> Result(tool.Tool, String) {
  let mode = codemode.seam(config)
  let mode =
    shell.CodeMode(..mode, execute: fn(request) {
      case codemode.execute_managed(config, parent, request) {
        Ok(execution) -> execution
        Error(reason) ->
          shell.Execution(
            result: shell.RunFailed(shell.StartFailed(reason)),
            enforcement: shell.Enforcement(
              shell.Unreported("identity refused before execution"),
              shell.Unreported("identity refused before execution"),
            ),
            refusal: shell.NothingRefused,
            calls: call_record.empty(),
            edits: [],
          )
      }
    })
  shell.retained_tool(mode, retainer(owner, parent))
}

/// Commits only through the original owner's pinned runner handle and identity.
/// The context coordinate check precedes any durable write. Failure leaves the
/// original custody unresolved; a callback never reruns the program.
///
/// ## Examples
///
/// ```gleam
/// // code_reports.retainer(pinned_owner, original_key)(ctx, complete_report)
/// ```
pub fn retainer(
  owner: custodian.Handle,
  parent: remote_tool.ToolKey,
) -> code_report.Retain {
  fn(ctx: tool.Ctx, report) {
    use Nil <- result.try(
      case
        ctx.op_id == remote_tool.operation(parent)
        && ctx.step_id == remote_tool.step(parent)
        && ctx.source_index == remote_tool.source_index(parent)
      {
        True -> Ok(Nil)
        False ->
          Error("complete report changed original invocation coordinates")
      },
    )
    custodian.retain_report(owner, parent, report)
    |> result.replace_error("complete report custody is uncertain")
  }
}
