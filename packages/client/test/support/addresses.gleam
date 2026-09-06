//// Reference-address fixtures for restartable client services.
////
//// Each namespace is linked to the test process, so its owner exit retires
//// routing. Tests measuring explicit session shutdown use the production
//// namespace handle instead of this fixture.

import gleam/erlang/process
import gleam/result
import weft/registry as address

pub fn new() -> address.Address(message) {
  let assert Ok(namespace) = address.start()
    as "the test address namespace must start"
  address.new_address(namespace)
}

pub fn owner(name: address.Address(message)) -> Result(process.Pid, Nil) {
  address.lookup(name) |> result.try(process.subject_owner)
}

pub fn subject(name: address.Address(message)) -> process.Subject(message) {
  let assert Ok(subject) = address.lookup(name)
    as "the test requires a registered service incarnation"
  subject
}
