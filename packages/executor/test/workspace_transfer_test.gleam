//// Transfer tests distinguish content integrity from semantic authorization.
//// Small model cases exercise malformed framing; real TLS carries both maximum
//// content directions without increasing the existing frame ceiling.

import executor/remote/tls
import executor/remote/workspace_transfer as transfer
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import remote_tls_test
import tools/workspace_codec
import weft

@external(erlang, "executor_remote_tls_test_ffi", "fixture")
fn fixture() -> remote_tls_test.Fixture

pub fn roundtrip_boundaries_test() {
  list.each([1, 65_535, 65_536, 65_537, 131_072], fn(size) {
    let bytes = <<0:size(size * 8)>>
    let assert Ok(#(header, sender)) =
      transfer.begin_send(transfer.Invocation, bytes)
      as "Valid bounded content must construct a sender."
    let assert Ok(receiver) =
      transfer.begin_receive(transfer.Invocation, header)
      as "The matching direction must accept its header."
    let #(actual, count) = collect(sender, receiver, 0)
    let assert True = actual == bytes
      as "Exact bytes must survive chunk boundaries."
    let assert True =
      count == { size + transfer.chunk_bytes - 1 } / transfer.chunk_bytes
      as "Tiny-chunk amplification must not change the frame count."
  })
}

pub fn invalid_header_is_refused_before_chunks_test() {
  let digest = crypto.hash(crypto.Sha256, <<1>>)
  list.each(
    [0, workspace_codec.max_invocation_bytes + 1, 4_294_967_295],
    fn(size) {
      let header = <<"LWC", 1, 0, size:32, digest:bits>>
      let assert Error(transfer.InvalidLength) =
        transfer.begin_receive(transfer.Invocation, header)
        as "No oversized declared body may construct a receiver."
    },
  )
  let assert Ok(#(header, _)) = transfer.begin_send(transfer.Completion, <<1>>)
    as "Valid completion must encode."
  let assert Error(transfer.InvalidFrame) =
    transfer.begin_receive(transfer.Invocation, header)
    as "A completion cannot be mistaken for an invocation."
  let assert Error(transfer.InvalidFrame) =
    transfer.begin_receive(transfer.Completion, <<header:bits, 0>>)
    as "Header surplus is not a protocol extension."
  let assert Error(transfer.InvalidFrame) =
    transfer.begin_receive(transfer.Invocation, <<
      "LWC",
      2,
      0,
      1:32,
      digest:bits,
    >>)
    as "Unsupported framing versions must be refused."
}

pub fn sender_rejects_empty_unaligned_and_oversized_test() {
  let assert Error(transfer.InvalidLength) =
    transfer.begin_send(transfer.Invocation, <<>>)
    as "There is no empty semantic message."
  let assert Error(transfer.InvalidLength) =
    transfer.begin_send(transfer.Invocation, <<0:9>>)
    as "Partial bytes must not be rounded into a content claim."
  let bytes = <<0:size({ workspace_codec.max_invocation_bytes + 1 } * 8)>>
  let assert Error(transfer.InvalidLength) =
    transfer.begin_send(transfer.Invocation, bytes)
    as "The invocation ceiling applies before hashing or sending."
}

pub fn duplicate_reordered_and_short_chunks_are_refused_test() {
  let bytes = <<0:size({ transfer.chunk_bytes + 1 } * 8)>>
  let assert Ok(#(header, sender)) =
    transfer.begin_send(transfer.Invocation, bytes)
    as "Two chunks must construct."
  let assert Ok(receiver) = transfer.begin_receive(transfer.Invocation, header)
    as "Header must construct bounded receiver."
  let assert Some(#(first, tail)) = transfer.next(sender)
    as "First frame must exist."
  let assert Some(#(last, _)) = transfer.next(tail) as "Final frame must exist."
  let assert Error(transfer.InvalidFrame) = transfer.accept(receiver, last)
    as "A later offset cannot skip the first frame."
  let assert Error(transfer.InvalidFrame) =
    transfer.accept(receiver, <<"LWD", 1, 0, 0:32, 0>>)
    as "Nonfinal short frames cannot amplify the frame count."
  let assert Ok(transfer.Receiving(next)) = transfer.accept(receiver, first)
    as "Correct first frame must retain one bounded chunk."
  let assert Error(transfer.InvalidFrame) = transfer.accept(next, first)
    as "A repeated frame must not consume more retention."
  let assert Error(transfer.InvalidFrame) =
    transfer.accept(next, <<last:bits, 0>>)
    as "Final surplus must not be silently ignored."
  let assert Ok(transfer.Complete(actual)) = transfer.accept(next, last)
    as "Exact final bytes close the transfer."
  let assert True = actual == bytes as "The final transfer must be exact."
}

pub fn digest_and_chunk_direction_are_checked_test() {
  let assert Ok(#(header, _)) = transfer.begin_send(transfer.Invocation, <<7>>)
    as "One-byte body must encode."
  let assert Ok(receiver) = transfer.begin_receive(transfer.Invocation, header)
    as "Header must retain the digest."
  let assert Error(transfer.InvalidFrame) =
    transfer.accept(receiver, <<"LWD", 1, 0, 0:32, 8>>)
    as "Length alone cannot establish content integrity."
  let assert Error(transfer.InvalidFrame) =
    transfer.accept(receiver, <<"LWD", 1, 1, 0:32, 7>>)
    as "Chunk direction must match the checked header."
}

pub fn maximum_content_uses_existing_real_tls_frames_test() {
  let assert Ok(Nil) = tls.start() as "SSL must start."
  let credentials = fixture()
  let server = settings(credentials.server, credentials.client)
  let client = settings(credentials.client, credentials.server)
  let assert Ok(listener) = tls.listen(server, tls.Loopback, 0)
    as "Real loopback listener must bind; denied networking is a failure."
  let assert Ok(port) = tls.port(listener) as "Listener must expose its port."
  let done = process.new_subject()

  // Both halves have a finite whole-exchange budget. Test-only sockets stay
  // with the worker that created them, so worker death closes a partial stream.
  let jobs = [
    fn() {
      let outcome = {
        use socket <- result.try(
          tls.accept(listener)
          |> result.map_error(fn(_) { transfer.TransportUncertain }),
        )
        let answer = {
          use bytes <- result.try(transfer.receive(socket, transfer.Invocation))
          let assert True =
            bit_array.byte_size(bytes) == workspace_codec.max_invocation_bytes
            as "Maximum invocation must arrive intact."
          let completion = <<0:size(workspace_codec.max_completion_bytes * 8)>>
          transfer.send(socket, transfer.Completion, completion)
        }
        tls.close(socket)
        answer
      }
      process.send(done, outcome)
      outcome
    },
    fn() {
      use socket <- result.try(
        tls.connect(client, "localhost", port)
        |> result.map_error(fn(_) { transfer.TransportUncertain }),
      )
      let answer = {
        let invocation = <<0:size(workspace_codec.max_invocation_bytes * 8)>>
        use Nil <- result.try(transfer.send(
          socket,
          transfer.Invocation,
          invocation,
        ))
        use completion <- result.try(transfer.receive(
          socket,
          transfer.Completion,
        ))
        let assert True =
          bit_array.byte_size(completion)
          == workspace_codec.max_completion_bytes
          as "Maximum completion must arrive intact."
        let assert True =
          completion == <<0:size(workspace_codec.max_completion_bytes * 8)>>
          as "Real transport must preserve all content bytes."
        Ok(Nil)
      }
      tls.close(socket)
      answer
    },
  ]
  let outcomes = weft.new(jobs) |> weft.deadline(20_000) |> weft.start
  tls.close_listener(listener)
  let assert [weft.Completed(_, Nil), weft.Completed(_, Nil)] = outcomes
    as "Both authenticated maximum-size exchanges must complete."
  let assert Ok(Ok(Nil)) = process.receive(done, 1000)
    as "The server must report actual transport completion."
}

fn collect(
  sender: transfer.Sender,
  receiver: transfer.Receiver,
  count: Int,
) -> #(BitArray, Int) {
  let assert Some(#(frame, tail)) = transfer.next(sender)
    as "An incomplete receiver requires another frame."
  let assert True = bit_array.byte_size(frame) <= tls.max_frame_bytes
    as "Chunk framing must preserve the existing TLS body ceiling."
  let assert Ok(progress) = transfer.accept(receiver, frame)
    as "Valid sender frames must be accepted."
  case progress {
    transfer.Receiving(next) -> collect(tail, next, count + 1)
    transfer.Complete(bytes) -> {
      let assert None = transfer.next(tail)
        as "Completion must consume all sender bytes."
      #(bytes, count + 1)
    }
  }
}

fn settings(
  local: remote_tls_test.Credentials,
  peer: remote_tls_test.Credentials,
) -> tls.Settings {
  let assert Ok(settings) =
    tls.settings(
      local.ca,
      local.certificate,
      local.key,
      peer.pin,
      2000,
      2000,
      1000,
    )
    as "Fixture credentials must parse."
  settings
}
