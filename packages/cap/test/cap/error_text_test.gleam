//// The error-text helpers are plain renderings that programs used to
//// hand-write. These tests pin each module's wording for one constructor
//// and the shape every rendering shares: one line, naming the cause.

import cap/actor
import cap/fs
import cap/git
import cap/job
import cap/kv
import cap/lsp
import cap/lsp_sql
import cap/mcp
import cap/net
import cap/notes
import cap/proc
import cap/report
import cap/schedule
import cap/search
import gleam/string

pub fn lsp_errors_render_with_the_qualified_name_hint_test() {
  assert lsp.error_text(lsp.NotFound("util.Greet"))
    == "symbol not found: util.Greet"
  let bare = lsp.error_text(lsp.NotFound("AcceptForScheme"))
  assert string.starts_with(bare, "symbol not found: AcceptForScheme; ")
  assert string.contains(bare, "Receiver.Method")
  assert lsp.error_text(lsp.Unsupported("gopls", "callHierarchy"))
    == "server gopls does not support callHierarchy"
  assert lsp.error_text(lsp.LspDenied("invalid_argument", "line below 1"))
    == "denied (invalid_argument): line below 1"
}

pub fn lsp_sql_errors_render_test() {
  assert lsp_sql.error_text(lsp_sql.QueryFailed("symbol not found: main"))
    == "query failed: symbol not found: main"
  assert lsp_sql.error_text(lsp_sql.DeadlineExceeded)
    == "capture deadline exceeded"
  assert lsp_sql.query_error_text(lsp_sql.DecodeFailed(2, "expected text"))
    == "row 2 did not decode: expected text"
  assert lsp_sql.query_error_text(lsp_sql.QueryLimitExceeded(
      lsp_sql.Rows,
      "more than 500 rows",
    ))
    == "query limit exceeded (rows): more than 500 rows"
  assert lsp_sql.query_error_text(lsp_sql.MultipleStatements)
    == "more than one statement was submitted"
}

pub fn lsp_sql_cells_render_as_text_test() {
  assert lsp_sql.cell_text(lsp_sql.Null) == "NULL"
  assert lsp_sql.cell_text(lsp_sql.Integer(-7)) == "-7"
  assert lsp_sql.cell_text(lsp_sql.Real(1.5)) == "1.5"
  assert lsp_sql.cell_text(lsp_sql.Text("main")) == "main"
}

pub fn other_module_errors_render_test() {
  assert fs.error_text(fs.NotFound("a.txt")) == "not found: a.txt"
  assert fs.error_text(fs.FsFailed("io", "disk")) == "io: disk"
  assert search.error_text(search.NotFound("src")) == "not found: src"
  assert proc.error_text(proc.SpawnFailed("no such file"))
    == "spawn failed: no such file"
  assert git.error_text(git.CommandFailed(128, "fatal: not a repository\n"))
    == "git exited 128: fatal: not a repository"
  assert git.error_text(git.ProcessError(proc.ProcUnavailable("down")))
    == "proc unavailable: down"
  assert net.error_text(net.NetDenied("host not allowed"))
    == "denied: host not allowed"
  assert kv.error_text(kv.KvUnavailable("no channel"))
    == "kv unavailable: no channel"
  assert notes.error_text(notes.NotesDenied("quota", "full")) == "quota: full"
  assert report.error_text(report.EmitUnavailable("no channel"))
    == "emit unavailable: no channel"
  assert schedule.error_text(schedule.ScheduleUnavailable("no channel"))
    == "schedule unavailable: no channel"
  assert job.error_text(job.JobNotFound("j1")) == "job not found: j1"
  assert actor.error_text(actor.NoReply) == "no reply"
  assert mcp.error_text(mcp.ServerUnavailable("down"))
    == "server unavailable: down"
  assert mcp.error_text(mcp.ToolFailed("bad", [])) == "tool failed: bad"
}
