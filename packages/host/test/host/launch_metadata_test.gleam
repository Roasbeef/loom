import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/endpoint
import host/launch_metadata

pub fn round_trip_retains_the_fence_and_modes_test() {
  let fence = endpoint.Fence(42, "linux:birth", 123)
  let records = [
    launch_metadata.Record(fence, "epoch", None, launch_metadata.LocalOnly),
    launch_metadata.Record(
      fence,
      "epoch",
      Some("/a config.toml"),
      launch_metadata.Tls("/tls options"),
    ),
  ]
  records
  |> list.each(fn(record) {
    assert launch_metadata.decode(launch_metadata.encode(record)) == Ok(record)
  })
}

pub fn malformed_and_unbounded_records_are_refused_test() {
  let record =
    launch_metadata.Record(
      endpoint.Fence(42, "birth", 123),
      "epoch",
      None,
      launch_metadata.LocalOnly,
    )
  let text = launch_metadata.encode(record)
  let assert Error(_) =
    launch_metadata.decode(string.replace(
      text,
      "\"version\":1",
      "\"version\":2",
    ))
  let assert Error(_) =
    launch_metadata.decode(string.replace(
      text,
      "\"options\":null",
      "\"options\":\"/unexpected\"",
    ))
  let assert Error(_) =
    launch_metadata.decode(string.replace(
      text,
      "\"config\":null",
      "\"config\":\"relative\"",
    ))
  let assert Error(_) =
    launch_metadata.decode(string.append(text, string.repeat("x", 4097)))
}
