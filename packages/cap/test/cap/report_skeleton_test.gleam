//// The skeleton `report.value` shows a model is a real program: this module
//// holds a copy of it, so a change that stops it compiling fails here
//// instead of in a model's first attempt. It is compiled, never run, because
//// running it needs a capability channel and a language server.

import cap/lsp_sql
import cap/report
import gleam/option.{None, Some}
import gleam/string

pub fn skeleton() -> report.Outcome {
  let file = "auth/multi_authenticator.go"
  let plan =
    lsp_sql.Plan("gopls", ".", [file], [
      lsp_sql.Target("MultiAuthenticator.AcceptForScheme", file, None),
      lsp_sql.Target("AcceptForScheme", file, Some(69)),
    ])
  case lsp_sql.collect(plan) {
    Error(error) -> report.failure(lsp_sql.error_text(error))
    Ok(observation) ->
      case
        lsp_sql.query(
          observation,
          "SELECT t.symbol, count(r.target_id) FROM targets t "
            <> "LEFT JOIN \"references\" r ON r.target_id = t.id GROUP BY t.id",
          [],
          fn(row) {
            case row {
              [symbol, count] ->
                Ok(
                  lsp_sql.cell_text(symbol) <> ": " <> lsp_sql.cell_text(count),
                )
              _ -> Error("expected two columns")
            }
          },
        )
      {
        Error(error) -> report.failure(lsp_sql.query_error_text(error))
        Ok(answer) ->
          report.value(report.string(string.join(answer.rows, "\n")))
      }
  }
}

pub fn the_documented_skeleton_compiles_test() {
  let _program = skeleton
  Nil
}
