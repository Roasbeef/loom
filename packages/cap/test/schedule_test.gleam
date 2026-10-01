//// Schedule results preserve the host's resolved cadence across the channel.
//// Malformed records fail in band before a caller can branch on false data.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/schedule
import core/msgpack
import gleam/list

fn expiry() -> msgpack.MsgPackValue {
  wire.args([
    #("max_fires", wire.int(4)),
    #("expires_after_s", wire.int(3600)),
  ])
}

fn interval() -> msgpack.MsgPackValue {
  wire.args([
    #("kind", wire.string("interval")),
    #("seconds", wire.int(300)),
    #("expiry", expiry()),
  ])
}

fn row(cadence: msgpack.MsgPackValue) -> msgpack.MsgPackValue {
  wire.args([
    #("name", wire.string("watch")),
    #("target", wire.string("main")),
    #("when", wire.string("display wording is not parsed")),
    #("cadence", cadence),
    #("wake", wire.bool(False)),
    #("fired", wire.int(2)),
    #("body", wire.string("Check the build.")),
  ])
}

fn install(value: msgpack.MsgPackValue) -> Nil {
  let assert Ok(bytes) = msgpack.encode(value)
  let assert Ok(value) = msgpack.decode(bytes)
  dispatch.install(
    channel.Channel(call: fn(capability, _args, _deadline) {
      case capability {
        "schedule.create" -> Ok(value)
        "schedule.list" ->
          Ok(
            wire.args([
              #("schedules", msgpack.ArrayValue([value])),
            ]),
          )
        _ -> Error(channel.Denied("unexpected", capability))
      }
    }),
  )
}

pub fn create_and_list_read_the_same_resolved_interval_test() {
  install(row(interval()))
  let assert Ok(created) =
    schedule.every_within(
      "watch",
      300,
      schedule.Bounds(4, 3600),
      schedule.SteersOnly,
      "Check.",
    )
  let assert Ok([listed]) = schedule.list()
  assert created.cadence == schedule.Interval(300, schedule.Expiry(4, 3600))
  assert listed.cadence == created.cadence
  assert listed.when == "display wording is not parsed"
  assert listed.fired == 2
  dispatch.reset()
}

pub fn cron_keeps_its_expression_fixed_offset_and_both_bounds_test() {
  install(
    row(
      wire.args([
        #("kind", wire.string("cron")),
        #("expression", wire.string("0 9 * * 1-5")),
        #("utc_offset_s", wire.int(-19_800)),
        #("expiry", expiry()),
      ]),
    ),
  )
  let assert Ok([listed]) = schedule.list()
  assert listed.cadence
    == schedule.Cron("0 9 * * 1-5", -19_800, schedule.Expiry(4, 3600))
  dispatch.reset()
}

pub fn relative_one_shot_returns_the_host_resolved_unix_time_test() {
  install(
    row(
      wire.args([
        #("kind", wire.string("one_shot")),
        #("at_unix_s", wire.int(2700)),
      ]),
    ),
  )
  let assert Ok(created) =
    schedule.after("watch", 2700, schedule.SteersOnly, "Check.")
  assert created.cadence == schedule.OneShot(at_unix_s: 2700)
  dispatch.reset()
}

pub fn malformed_cadence_is_explicit_on_create_and_list_test() {
  let invalid = [
    msgpack.NilValue,
    wire.args([]),
    wire.args([#("kind", wire.string("unknown"))]),
    wire.args([#("kind", wire.int(1))]),
    wire.args([#("kind", wire.string("interval")), #("seconds", wire.int(300))]),
    wire.args([
      #("kind", wire.string("interval")),
      #("seconds", wire.int(0)),
      #("expiry", expiry()),
    ]),
    wire.args([
      #("kind", wire.string("interval")),
      #("seconds", wire.int(300)),
      #(
        "expiry",
        wire.args([
          #("max_fires", wire.int(4)),
          #("expires_after_s", wire.int(-1)),
        ]),
      ),
    ]),
    wire.args([
      #("kind", wire.string("one_shot")),
      #("at_unix_s", wire.string("2700")),
    ]),
    wire.args([
      #("kind", wire.string("cron")),
      #("expression", wire.string("0 9 * * *")),
      #("utc_offset_s", wire.int(50_460)),
      #("expiry", expiry()),
    ]),
    wire.args([
      #("kind", wire.string("cron")),
      #("expression", wire.string("0 9 * * *")),
      #("utc_offset_s", wire.int(1)),
      #("expiry", expiry()),
    ]),
  ]
  list.each(invalid, fn(cadence) {
    install(row(cadence))
    let assert Error(schedule.MalformedScheduleResult(_)) = schedule.list()
    let assert Error(schedule.MalformedScheduleResult(_)) =
      schedule.every("watch", 300, schedule.SteersOnly, "Check.")
    dispatch.reset()
  })
}

pub fn missing_cadence_and_negative_fired_are_malformed_test() {
  install(
    wire.args([
      #("name", wire.string("watch")),
      #("target", wire.string("main")),
      #("when", wire.string("display")),
      #("wake", wire.bool(False)),
    ]),
  )
  let assert Error(schedule.MalformedScheduleResult("missing field cadence")) =
    schedule.every("watch", 300, schedule.SteersOnly, "Check.")
  install(
    wire.args([
      #("name", wire.string("watch")),
      #("target", wire.string("main")),
      #("when", wire.string("display")),
      #("cadence", interval()),
      #("wake", wire.bool(False)),
      #("body", wire.string("Check.")),
      #("fired", wire.int(-1)),
    ]),
  )
  assert schedule.list()
    == Error(schedule.MalformedScheduleResult("negative fired count"))
  dispatch.reset()
}

pub fn a_nil_schedule_array_is_not_an_empty_listing_test() {
  dispatch.install(
    channel.Channel(call: fn(_capability, _args, _deadline) {
      Ok(wire.args([#("schedules", msgpack.NilValue)]))
    }),
  )
  assert schedule.list()
    == Error(schedule.MalformedScheduleResult("field schedules is not an array"))
  dispatch.reset()
}
