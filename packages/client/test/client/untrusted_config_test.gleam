//// The untrusted link's configuration (protocol-change/109): the two tables
//// of `client/untrusted_config` and the `trust` of an `[executors.<name>]`
//// row.

import client/executors
import client/untrusted_config
import gleam/bit_array
import gleam/option.{None, Some}
import gleam/string
import tom

const pin = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

fn parsed(text: String) -> Result(untrusted_config.Settings, String) {
  let assert Ok(document) = tom.parse(text) as "the fixture is TOML"
  untrusted_config.from_document(document)
}

pub fn no_tables_is_no_link_and_no_listener_test() {
  assert parsed("") == Ok(untrusted_config.none)
}

pub fn a_listener_reads_its_address_credentials_and_pins_test() {
  let assert Ok(untrusted_config.Settings(link: None, listener: Some(listener))) =
    parsed(
      "[executor_listener]\nlisten = \"0.0.0.0:7443\"\nca = \"/ca\"\n"
      <> "certificate = \"/c\"\nkey = \"/k\"\norchestrators = [\""
      <> pin
      <> "\"]\n",
    )
  assert listener.address == ""
  assert listener.port == 7443
  let assert Ok(bytes) = bit_array.base16_decode(string.uppercase(pin))
  assert listener.orchestrators == [bytes]
}

pub fn a_listener_beside_distribution_is_refused_test() {
  let assert Error(reason) =
    parsed(
      "[distribution]\nnode = \"a@b\"\n[executor_listener]\nlisten = \"127.0.0.1:7443\"\n"
      <> "ca = \"/ca\"\ncertificate = \"/c\"\nkey = \"/k\"\norchestrators = [\""
      <> pin
      <> "\"]\n",
    )
  assert string.contains(reason, "never a distribution peer")
}

pub fn a_listener_refuses_bad_pins_and_addresses_test() {
  let listener = fn(listen, pins) {
    parsed(
      "[executor_listener]\nlisten = \""
      <> listen
      <> "\"\nca = \"/ca\"\ncertificate = \"/c\"\nkey = \"/k\"\norchestrators = "
      <> pins
      <> "\n",
    )
  }
  let assert Error(_) = listener("127.0.0.1:7443", "[]")
  let assert Error(_) = listener("127.0.0.1:7443", "[\"abc\"]")
  let assert Error(_) =
    listener("127.0.0.1:7443", "[\"" <> string.uppercase(pin) <> "\"]")
  let assert Error(_) =
    listener("127.0.0.1:7443", "[\"" <> pin <> "\", \"" <> pin <> "\"]")
  let assert Error(_) = listener("127.0.0.1:99999", "[\"" <> pin <> "\"]")
  let assert Error(_) = listener("nowhere", "[\"" <> pin <> "\"]")
}

pub fn a_link_needs_all_three_credentials_test() {
  let assert Ok(untrusted_config.Settings(link: Some(_), listener: None)) =
    parsed(
      "[executor_link]\nca = \"/ca\"\ncertificate = \"/c\"\nkey = \"/k\"\n",
    )
  let assert Error(_) = parsed("[executor_link]\nca = \"/ca\"\n")
  let assert Error(_) =
    parsed(
      "[executor_link]\nca = \"/ca\"\ncertificate = \"/c\"\nkey = \"/k\"\nnode = \"x\"\n",
    )
}

pub fn an_untrusted_executor_needs_no_distribution_test() {
  let assert Ok([executor]) =
    executors.parse(
      "[executors.pod]\ntrust = \"untrusted\"\naddress = \"pod.internal:7443\"\npin = \""
      <> pin
      <> "\"\n",
    )
  let assert executors.Untrusted(host: "pod.internal", port: 7443, pin: bytes) =
    executor.trust
  assert bit_array.byte_size(bytes) == 32
  assert executor.node == ""
}

pub fn an_untrusted_executor_refuses_a_node_and_a_trusted_one_a_pin_test() {
  let assert Error(reason) =
    executors.parse(
      "[executors.pod]\ntrust = \"untrusted\"\nnode = \"a@b\"\naddress = \"pod:1\"\npin = \""
      <> pin
      <> "\"\n",
    )
  assert string.contains(reason, "node")
  let assert Error(reason) =
    executors.parse(
      "[executors.box]\nnode = \"a@b\"\npin = \"" <> pin <> "\"\n",
    )
  assert string.contains(reason, "pin")
  let assert Error(_) =
    executors.parse("[executors.pod]\ntrust = \"maybe\"\naddress = \"pod:1\"\n")
}

pub fn an_untrusted_executor_needs_an_address_and_a_pin_test() {
  let assert Error(_) =
    executors.parse(
      "[executors.pod]\ntrust = \"untrusted\"\npin = \"" <> pin <> "\"\n",
    )
  let assert Error(_) =
    executors.parse(
      "[executors.pod]\ntrust = \"untrusted\"\naddress = \"pod:7443\"\n",
    )
  let assert Error(_) =
    executors.parse(
      "[executors.pod]\ntrust = \"untrusted\"\naddress = \"pod\"\npin = \""
      <> pin
      <> "\"\n",
    )
}

pub fn an_ipv6_address_is_written_in_brackets_test() {
  let assert Ok([executor]) =
    executors.parse(
      "[executors.pod]\ntrust = \"untrusted\"\naddress = \"[::1]:7443\"\npin = \""
      <> pin
      <> "\"\n",
    )
  let assert executors.Untrusted(host: "::1", port: 7443, ..) = executor.trust
}

pub fn an_ipv6_address_without_brackets_is_refused_test() {
  assert untrusted_config.host_port("::1") == Error(Nil)
  assert untrusted_config.host_port("::1:7443") == Error(Nil)
  assert untrusted_config.host_port("[::1]:7443") == Ok(#("::1", 7443))
  assert untrusted_config.host_port("10.0.0.2:7443") == Ok(#("10.0.0.2", 7443))
}
