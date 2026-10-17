import gleam/option.{None, Some}
import session_view/launch_words

pub fn an_address_the_configuration_gives_is_the_one_in_the_line_test() {
  assert launch_words.launch_line(
      Some("wss://beta.example.com:8443/v2/control"),
      "0198c1aa",
    )
    == "loom --addr wss://beta.example.com:8443/v2/control --session 0198c1aa --token-file <owner token file on that host>"
}

pub fn an_orchestrator_with_no_address_gets_the_placeholder_test() {
  assert launch_words.launch_line(None, "0198c1aa")
    == "loom --addr <its control address> --session 0198c1aa --token-file <owner token file on that host>"
}
