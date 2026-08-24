import core/clock
import core/ids
import core/json
import core/register
import gleam/list
import gleam/option.{None, Some}

const all_namespaces = [
  register.StrandLeaf,
  register.StrandConfig,
  register.StrandState,
  register.StrandLastResult,
  register.OpMeta,
  register.OpState,
  register.OpToolArgs,
  register.OpPreparation,
  register.PendingEntry,
  register.FactName,
  register.FactLabel,
  register.FactCustom,
]

pub fn every_namespace_name_roundtrips_test() {
  list.each(all_namespaces, fn(ns) {
    assert register.parse_ns(register.ns_to_string(ns)) == Ok(ns)
  })
}

pub fn namespace_names_are_unique_test() {
  let names = list.map(all_namespaces, register.ns_to_string)
  assert list.length(list.unique(names)) == list.length(all_namespaces)
}

pub fn parse_ns_rejects_unknown_names_test() {
  let assert Error(_report) = register.parse_ns("strand.unknown")
  let assert Error(_report) = register.parse_ns("")
  let assert Error(_report) = register.parse_ns("op.state ")
  let assert Error(_report) = register.parse_ns("OP.STATE")
}

pub fn value_wraps_the_payload_test() {
  assert register.value(json.Int(1)) == register.RegisterValue(json.Int(1))
}

pub fn leaf_value_roundtrips_test() {
  let #(id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 1000), seed: 1))
  assert register.read_leaf(register.leaf_value(Some(id))) == Ok(Some(id))
  assert register.read_leaf(register.leaf_value(None)) == Ok(None)
}

pub fn read_leaf_rejects_bad_payloads_test() {
  let assert Error(_report) = register.read_leaf(register.value(json.Int(3)))
  let assert Error(_report) =
    register.read_leaf(register.value(json.String("not-a-uuid")))
  let assert Error(_report) = register.read_leaf(register.value(json.Array([])))
}
