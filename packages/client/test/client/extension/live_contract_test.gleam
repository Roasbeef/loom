import client/extension/live_contract
import gleam/option.{Some}
import gleam/string
import gleeunit/should

const contract =
  "[live]\nentry = \"counter/entry\"\nmigration = \"counter/migration\"\nboundary = \"counter-v1\"\nstate_version = \"v1\"\naccepts = [\"v1\"]\npause_ms = 1000\nmax_state_bytes = 65536\n"

pub fn explicit_bounded_contract_test() {
  let assert Ok(Some(decoded)) =
    live_contract.decode(contract, ["counter/entry", "counter/migration"])
    as "valid explicit contract decodes"
  decoded.pause_ms |> should.equal(1000)
  live_contract.compatible(decoded, decoded, "v1") |> should.equal(Ok(Nil))
  live_contract.compatible(decoded, decoded, "v2") |> should.be_error
}

pub fn native_bounds_cannot_be_widened_test() {
  contract
  |> string.replace("pause_ms = 1000", "pause_ms = 1001")
  |> live_contract.decode(["counter/entry", "counter/migration"])
  |> should.be_error
  contract
  |> string.replace("max_state_bytes = 65536", "max_state_bytes = 65537")
  |> live_contract.decode(["counter/entry", "counter/migration"])
  |> should.be_error
}

pub fn migration_module_must_be_shipped_test() {
  live_contract.decode(contract, ["counter/entry"]) |> should.be_error
}
