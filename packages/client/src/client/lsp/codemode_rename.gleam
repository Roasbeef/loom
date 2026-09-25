//// The applied rename code mode's `lsp.rename` reaches, composed where the
//// write authority lives.
////
//// # Why the client composes it
////
//// `codemode/lsp` serves `lsp.rename` with `mode: apply` by calling a
//// closure it is handed and never by writing a file itself (its module
//// doc). Somebody has to build that closure out of three things that live
//// in three places: the door's `prepare_rename`, which computes every
//// file's edited text and writes nothing; `tools/lsp.land`, the one
//// hashline landing the `lsp_rename` tool also uses; and the write
//// boundary a code-mode program is held to. Only the client holds all
//// three, so this module is where they meet (ADR-013 §4 and §6).
////
//// # Which write boundary
////
//// A program's rename lands through exactly the resolution a program's
//// `cap/fs.write` and `cap/fs.edit` get: `fs.write_target` over the
//// execution's workspace, its approved writable roots, and the protected
//// list its base policy carries. `client/codemode.workspace_seam` feeds
//// the bridge's writes from the same three values, so a protected path
//// such as `.git/hooks` is refused to a rename for the reason it is
//// refused to `fs.write`, and no rename can reach a root a direct write
//// could not.
////
//// The seam is built per execution rather than once per host because two
//// of those three values are the request's: the workspace and the grants
//// an approval attributed to this call.

import codemode/lsp as codemode_lsp
import core/message
import gleam/list
import gleam/result
import gleam/string
import lsp/query.{
  type Door, type QueryError, type RenameReport, type Served, type SymbolQuery,
}
import tools/fs
import tools/lsp as tools_lsp
import tools/tool.{type FileSystem}

/// The router seam for one code-mode execution: the session's door, and an
/// applied rename bound to the execution's write boundary.
///
/// `workspace` is the execution's workspace root, `roots` the writable
/// roots its approvals widened it to, and `protected` its base policy's
/// protected list — the values `client/codemode.workspace_seam` gives
/// `cap/fs.write`.
///
/// ## Examples
///
/// ```gleam
/// // codemode_rename.seam(door, workspace: "/work", roots: [],
/// //   protected: ["/work/.git"])
/// ```
///
pub fn seam(
  door: Door,
  workspace workspace: String,
  roots roots: List(String),
  protected protected: List(String),
) -> codemode_lsp.Seam {
  codemode_lsp.Seam(
    door:,
    rename: rename(
      door,
      filesystem: fs.real_filesystem(),
      workspace:,
      roots:,
      protected:,
    ),
  )
}

/// The applied rename alone, over any filesystem seam: `prepare_rename`,
/// then `tools/lsp.land` with `fs.write_target` as the target maker, then
/// the door's `after_write` for each landed file.
///
/// A `QueryError` from the door is returned untouched: nothing was
/// computed, so nothing was attempted. Once the server has answered, the
/// outcome is always a report, even when every file was refused, because
/// the report is how a program learns which files landed.
///
/// ## Examples
///
/// ```gleam
/// // let apply = codemode_rename.rename(door, filesystem:, workspace: "/w",
/// //   roots: [], protected: [])
/// // apply(query.SymbolQuery("old", None, None), "new")
/// ```
///
pub fn rename(
  door: Door,
  filesystem filesystem: FileSystem,
  workspace workspace: String,
  roots roots: List(String),
  protected protected: List(String),
) -> fn(SymbolQuery, String) -> Result(Served(RenameReport), QueryError) {
  // The closure outlives this call for the whole execution, so it keeps
  // the two door closures it calls rather than the whole record.
  let prepare = door.prepare_rename
  let after_write = door.after_write
  let target = fn(path) {
    fs.write_target(filesystem:, workspace:, roots:, protected:, path:)
    |> result.map_error(refusal_text)
  }

  fn(symbol_query, new_name) {
    use served <- result.map(prepare(symbol_query, new_name))
    let report =
      tools_lsp.land(edits: served.value, target:, filesystem:, after_write:)
    query.Served(value: report, warmth: served.warmth)
  }
}

// A refused path in the words `fs_write` answers with, protected-path
// wording included, so a program reading a rejected file's reason reads
// the sentence a direct write of that file would have produced.
fn refusal_text(error: fs.PathError) -> String {
  fs.path_outcome(error).content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      message.ToolResultImage(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}
