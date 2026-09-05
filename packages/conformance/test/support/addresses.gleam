//// Test-process-owned reference addresses for restartable client services.

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
