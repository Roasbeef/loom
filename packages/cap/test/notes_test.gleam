//// The note facade preserves structured values and routes virtual reads
//// through the separately metered notes capability, never an OS path.

import cap/fs
import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/notes
import cap/report
import gleam/option.{None, Some}

pub fn a_note_put_preserves_nested_data_test() {
  let value =
    report.object([#("items", report.list([report.int(3), report.null()]))])
  dispatch.install(
    channel.Channel(call: fn(cap, args, _deadline) {
      assert cap == "notes.put"
      assert wire.string_field(args, "key") == Ok("analysis")
      assert wire.field(args, "value") == Ok(value)
      Ok(report.null())
    }),
  )
  assert notes.put("analysis", value) == Ok(Nil)
}

pub fn absence_and_stored_null_are_distinct_test() {
  dispatch.install(
    channel.Channel(call: fn(cap, args, _deadline) {
      assert cap == "notes.get"
      case wire.string_field(args, "key") {
        Ok("main/present") ->
          Ok(
            report.object([
              #("found", report.bool(True)),
              #("value", report.null()),
            ]),
          )
        _ -> Ok(report.object([#("found", report.bool(False))]))
      }
    }),
  )
  assert notes.get("main/present") == Ok(Some(report.null()))
  assert notes.get("main/absent") == Ok(None)
}

pub fn virtual_reads_have_a_dedicated_capability_test() {
  dispatch.install(
    channel.Channel(call: fn(cap, args, _deadline) {
      assert cap == "notes.read"
      assert wire.string_field(args, "key") == Ok("main/a/../b")
      Ok(report.object([#("contents", report.string("{\"count\":3}"))]))
    }),
  )
  assert fs.read("note://main/a/../b") == Ok("{\"count\":3}")
}

pub fn virtual_mutations_and_directory_reads_never_dispatch_test() {
  dispatch.install(
    channel.Channel(call: fn(_cap, _args, _deadline) {
      panic as "a virtual mutation must never reach the filesystem"
    }),
  )
  let assert Error(fs.InvalidArgument(_)) = fs.write("note://main/a", "x")
    as "virtual notes are read-only"
  let assert Error(fs.InvalidArgument(_)) = fs.edit("note://main/a", [])
    as "virtual notes cannot be edited as files"
  let assert Error(fs.InvalidArgument(_)) = fs.list("note://main/")
    as "notes.list owns note enumeration"
}

pub fn virtual_missing_and_admission_errors_survive_test() {
  dispatch.install(
    channel.Channel(call: fn(_cap, _args, _deadline) {
      Error(channel.Denied("not_found", "missing"))
    }),
  )
  assert fs.read("note://main/a") == Error(fs.NotFound("note://main/a"))
  dispatch.install(
    channel.Channel(call: fn(_cap, _args, _deadline) {
      Error(channel.Denied("admission_ceiling", "stop"))
    }),
  )
  assert notes.get("main/a")
    == Error(notes.NotesDenied("admission_ceiling", "stop"))
}
