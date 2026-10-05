//// A bounded read-only witness distinguishes a real queued workspace Submit
//// from a merely occupied endpoint credit. Only the fixed executor role reads
//// its concrete suspended service mailbox. No message is sent or evaluated.
//// `queued` limits the snapshot before inspecting entries; `submitted` totally
//// decodes the private fixed Submit shape and its exact original UUID bits.

import core/ids
import gleam/bit_array
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/workspace_codec as codec

// Stock process_info returns exactly this closed shape, or undefined when the
// local actor has exited. Its message list is a proper list supplied by OTP.
type Snapshot {
  Messages(List(Dynamic))
  Undefined
}

// Gleam process and OTP system APIs cannot observe queued message content.
// This test-only stock BIF reads one fixed property of the executor-local actor;
// no custom Erlang, arbitrary property, cast or production hook is introduced.
@external(erlang, "erlang", "process_info")
fn snapshot(pid: process.Pid, property: atom.Atom) -> Snapshot

/// Observes exactly one queued Submit with original content and entry identity.
/// The full returned message also lets the second observation prove that its
/// stable actor tag and reply subject stayed unchanged after caller death.
///
/// ## Examples
/// `queued(service.pid(server), original_bytes, original_id)` returns a witness.
pub fn queued(
  pid: process.Pid,
  bytes: BitArray,
  id: ids.EntryId,
) -> Result(Dynamic, Nil) {
  use <- bool.guard(
    bit_array.byte_size(bytes) > codec.max_invocation_bytes,
    Error(Nil),
  )
  let messages = case snapshot(pid, atom.create("messages")) {
    Messages(messages) -> Ok(messages)
    Undefined -> Error(Nil)
  }
  use messages <- result.try(messages)

  // A single suspended fixture has at most the six endpoint credits plus fixed
  // system reports. Refuse more than sixteen before decoding or traversing all.
  use <- bool.guard(list.drop(messages, 16) != [], Error(Nil))
  use submissions <- result.try(list.try_map(messages, submitted))
  let submissions =
    list.filter_map(submissions, fn(value) {
      case value {
        Some(value) -> Ok(value)
        None -> Error(Nil)
      }
    })
  use expected_id <- result.try(
    ids.entry_id_to_string(id)
    |> string.replace("-", "")
    |> bit_array.base16_decode,
  )
  case submissions {
    [#(message, submitted_bytes, submitted_id)]
      if submitted_bytes == bytes && submitted_id == expected_id
    -> Ok(message)
    [] | [_, _, ..] | [_] -> Error(Nil)
  }
}

fn submitted(
  message: Dynamic,
) -> Result(Option(#(Dynamic, BitArray, BitArray)), Nil) {
  let command = {
    use body <- decode.field(1, decode.dynamic)
    use tag <- decode.subfield([1, 0], atom.decoder())
    decode.success(#(body, atom.to_string(tag)))
  }
  case decode.run(message, command) {
    Ok(#(_, "submit")) -> {
      let envelope = {
        use tag <- decode.field(0, decode.dynamic)
        use body <- decode.field(1, decode.dynamic)
        use extra <- decode.optional_field(
          2,
          None,
          decode.map(decode.dynamic, Some),
        )
        decode.success(#(tag, body, extra))
      }
      use outer <- result.try(
        decode.run(message, envelope) |> result.replace_error(Nil),
      )
      use <- bool.guard(
        dynamic.classify(outer.0) != "Reference" || outer.2 != None,
        Error(Nil),
      )
      let submit = {
        use _ <- decode.field(0, atom.decoder())
        use validated <- decode.field(1, decode.dynamic)
        use reply <- decode.field(2, decode.dynamic)
        use extra <- decode.optional_field(
          3,
          None,
          decode.map(decode.dynamic, Some),
        )
        decode.success(#(validated, reply, extra))
      }
      use fields <- result.try(
        decode.run(outer.1, submit) |> result.replace_error(Nil),
      )
      use <- bool.guard(fields.2 != None, Error(Nil))
      use _ <- result.try(reply_subject(fields.1))
      use input <- result.try(validated(fields.0))
      Ok(Some(#(message, input.0, input.1)))
    }
    Ok(#(_, _)) | Error(_) -> Ok(None)
  }
}

fn reply_subject(value: Dynamic) -> Result(Nil, Nil) {
  let decoder = {
    use tag <- decode.field(0, atom.decoder())
    use owner <- decode.field(1, decode.dynamic)
    use reference <- decode.field(2, decode.dynamic)
    use extra <- decode.optional_field(
      3,
      None,
      decode.map(decode.dynamic, Some),
    )
    decode.success(#(atom.to_string(tag), owner, reference, extra))
  }
  use fields <- result.try(
    decode.run(value, decoder) |> result.replace_error(Nil),
  )
  case
    fields.0 == "subject"
    && dynamic.classify(fields.1) == "Pid"
    && dynamic.classify(fields.2) == "Reference"
    && fields.3 == None
  {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

fn validated(value: Dynamic) -> Result(#(BitArray, BitArray), Nil) {
  let decoder = {
    use tag <- decode.field(0, atom.decoder())
    use bytes <- decode.field(1, decode.bit_array)
    use id <- decode.field(2, decode.dynamic)
    use extra <- decode.optional_field(
      3,
      None,
      decode.map(decode.dynamic, Some),
    )
    decode.success(#(atom.to_string(tag), bytes, id, extra))
  }
  use fields <- result.try(
    decode.run(value, decoder) |> result.replace_error(Nil),
  )
  use <- bool.guard(
    fields.0 != "validated"
      || fields.3 != None
      || bit_array.byte_size(fields.1) > codec.max_invocation_bytes,
    Error(Nil),
  )
  use id <- result.try(entry_bits(fields.2))
  Ok(#(fields.1, id))
}

fn entry_bits(value: Dynamic) -> Result(BitArray, Nil) {
  let decoder = {
    use tag <- decode.field(0, atom.decoder())
    use uuid <- decode.field(1, decode.dynamic)
    use extra <- decode.optional_field(
      2,
      None,
      decode.map(decode.dynamic, Some),
    )
    decode.success(#(atom.to_string(tag), uuid, extra))
  }
  use entry <- result.try(
    decode.run(value, decoder) |> result.replace_error(Nil),
  )
  use <- bool.guard(entry.0 != "entry_id" || entry.2 != None, Error(Nil))
  let decoder = {
    use tag <- decode.field(0, atom.decoder())
    use ms <- decode.field(1, decode.int)
    use a <- decode.field(2, decode.int)
    use b <- decode.field(3, decode.int)
    use extra <- decode.optional_field(
      4,
      None,
      decode.map(decode.dynamic, Some),
    )
    decode.success(#(atom.to_string(tag), ms, a, b, extra))
  }
  use uuid <- result.try(
    decode.run(entry.1, decoder) |> result.replace_error(Nil),
  )
  use <- bool.guard(
    uuid.0 != "uuid"
      || uuid.4 != None
      || uuid.1 < 0
      || uuid.1 >= 281_474_976_710_656
      || uuid.2 < 0
      || uuid.2 >= 4096
      || uuid.3 < 0
      || uuid.3 >= 4_611_686_018_427_387_904,
    Error(Nil),
  )
  Ok(<<uuid.1:size(48), 7:size(4), uuid.2:size(12), 2:size(2), uuid.3:size(62)>>)
}
