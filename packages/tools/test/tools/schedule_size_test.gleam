//// A regression pin for the `schedule_*` family's narrowed capture.
////
//// `docs/design-notes/daemon-memory.md`'s "option A evaluated" section
//// measured each `schedule_*` tool at 0.044 MiB because its closure held
//// the whole `Schedules` record rather than the one slot it calls. The
//// fix binds each tool to its own slot before building its closure
//// (`packages/tools/src/tools/schedule.gleam`, mirrored on the host side
//// by `client/scheduleseam`'s `door`); this test would fail again if a
//// future edit went back to closing a tool's `run` over the whole
//// `Schedules` value.

import gleam/list
import support/internal/ffi_memory
import tools/schedule

// A `Schedules` identical in every slot `schedule_create` never touches,
// except that `list`'s closure additionally holds a list of the given
// length. `schedule_create` calls only `create`, so a `create_tool` built
// correctly must not see this padding at all.
fn padded_schedules(padding_words: Int) -> schedule.Schedules {
  let padding = list.repeat(0, padding_words)
  schedule.Schedules(
    create: fn(ctx, request) {
      Ok(schedule.Created(
        name: request.name,
        target: ctx.strand,
        when: "once",
        wake: request.wake,
      ))
    },
    // The padded slot. `list.length` keeps the capture live rather than
    // one the compiler could drop as unused.
    list: fn(_ctx) {
      case list.length(padding) {
        0 -> Ok([])
        _ -> Ok([])
      }
    },
    cancel: fn(_ctx, _name, _target) { Ok(Nil) },
  )
}

pub fn create_tool_does_not_capture_whole_schedules_test() {
  let light = padded_schedules(1)
  let heavy = padded_schedules(4096)

  // Sanity: the padding actually lands where the closure said it would.
  assert ffi_memory.flat_words(heavy.list)
    > ffi_memory.flat_words(light.list) + 4096

  let limits =
    schedule.Limits(
      min_interval_seconds: 60,
      default_max_fires: 1000,
      max_schedules: 16,
      max_in_seconds: 604_800,
      max_max_fires: 1000,
      max_expires_after_s: 604_800,
    )
  let tools_light = schedule.tools(light, limits)
  let tools_heavy = schedule.tools(heavy, limits)

  // `schedule_create` is always first — see `schedule.tools`.
  let assert [create_light, ..] = tools_light
  let assert [create_heavy, ..] = tools_heavy
  assert ffi_memory.flat_words(create_heavy.run)
    == ffi_memory.flat_words(create_light.run)
}
