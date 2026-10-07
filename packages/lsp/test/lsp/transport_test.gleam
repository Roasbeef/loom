import gleam/erlang/process
import lsp/transport.{
  ChannelTransport, Connection, TransportClosed, TransportData,
}

// The peer is handed the actor's subject, writes through the connection the
// actor got back, and reports its close through the same subject.
pub fn a_channel_peer_receives_the_subject_and_delivers_events_test() {
  let inbound = process.new_subject()
  let outbound = process.new_subject()
  let ChannelTransport(connect:) =
    ChannelTransport(connect: fn(subject) {
      process.send(subject, TransportData(bytes: <<"hi":utf8>>))
      process.send(subject, TransportClosed(reason: "bye"))
      Connection(
        send: fn(line) {
          process.send(outbound, line)
          Ok(Nil)
        },
        close: fn() { Nil },
      )
    })

  let connection = connect(inbound)

  assert process.receive(inbound, 100) == Ok(TransportData(<<"hi":utf8>>))
  assert process.receive(inbound, 100) == Ok(TransportClosed("bye"))
  assert connection.send("out") == Ok(Nil)
  assert process.receive(outbound, 100) == Ok("out")
}
