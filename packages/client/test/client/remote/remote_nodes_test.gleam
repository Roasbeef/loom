//// Remote tool calls across two real emulators, joined by the production TLS
//// distribution. Each scenario boots an executor that runs the real host over
//// a fake workspace plane and an orchestrator that attaches a real surface.
////
//// The point of running them on real nodes is the connection: an Erlang
//// connection that drops loses the messages in it for good, the monitors on
//// both sides fire with `noconnection`, and the host must keep the call
//// running while the orchestrator reconnects and sends it again.

@external(erlang, "client_distribution_fixture_ffi", "scenario")
fn scenario(name: String) -> Result(Nil, String)

fn proves(name: String, why: String) {
  let assert Ok(Nil) = scenario(name) as why
  Nil
}

pub fn a_remote_call_runs_once_and_round_trips_an_owner_callback_test() {
  proves(
    "remote_run",
    "A call sent over TLS distribution must run once on the executor, and "
      <> "its escalation must reach the orchestrator's owner port and back.",
  )
}

pub fn a_real_workspace_serves_file_tools_to_another_node_test() {
  proves(
    "remote_workspace",
    "The production plane factory must serve a workspace by name: a file "
      <> "written through the surface from another node must land in the "
      <> "executor's checkout, and the census must decode on the far node.",
  )
}

pub fn a_connection_lost_while_the_tool_runs_does_not_run_it_twice_test() {
  proves(
    "remote_short_outage",
    "A re-sent Run after a reconnect must join the live call: one run, one "
      <> "outcome.",
  )
}

pub fn an_outcome_that_finished_during_an_outage_is_recovered_once_test() {
  proves(
    "remote_long_outage",
    "A call that finished while the nodes were apart must keep running to "
      <> "its end and be answered from the ledger after the reconnect.",
  )
}
