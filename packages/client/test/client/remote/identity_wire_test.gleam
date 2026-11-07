//// The author of a session's commits crosses the link (protocol-change/107,
//// "Git identity on an executor"). The identity is checked by the one function
//// both ends use, answered by the owner port from what the orchestrator
//// resolved, asked by the executor's host while it builds a scope's plane, and
//// handed to the plane's factory. An identity that is empty, unbounded or carries
//// a control character is never sent, and one that is sent anyway is refused when
//// it is received.

import client/git_identity.{type Identity, Identity}
import client/lsp/profile
import client/remote/address
import client/remote/host
import client/remote/owner_link
import client/remote/owner_port
import client/remote/protocol.{type GitIdentity, GitIdentity}
import core/clock
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import support/remote_fixtures as fixtures

// --- the check ----------------------------------------------------------------

pub fn a_name_and_an_email_make_an_identity_and_are_trimmed_test() {
  assert protocol.git_identity_of("  Ada Lovelace ", "\tada@example.invalid  ")
    == Some(GitIdentity("Ada Lovelace", "ada@example.invalid"))
}

pub fn a_value_that_is_empty_after_trimming_is_no_identity_test() {
  assert protocol.git_identity_of("", "ada@example.invalid") == None
  assert protocol.git_identity_of("Ada", "") == None
  assert protocol.git_identity_of("   ", "ada@example.invalid") == None
  assert protocol.git_identity_of("Ada", "\u{20}\u{20}") == None
}

pub fn a_control_character_makes_the_whole_identity_none_test() {
  // The NUL and the line breaks are the ones that could end a line of Git
  // configuration or an environment entry, and the rest of the class is the tab,
  // the escape and DEL. One bad value fails the pair, and nothing is repaired.
  let each = fn(value) {
    assert protocol.git_identity_of(value, "ada@example.invalid") == None
    assert protocol.git_identity_of("Ada", value) == None
  }
  each("Ada\u{0}Lovelace")
  each("Ada\u{0}")
  each("Ada\nLovelace")
  each("Ada\n[core]\nhooksPath = /tmp/x")
  each("Ada\rLovelace")
  each("Ada\tLovelace")
  each("Ada\u{1b}[31m")
  each("Ada\u{7f}")
}

pub fn the_length_bound_is_in_bytes_and_inclusive_test() {
  let at_the_bound = string.repeat("a", protocol.max_identity_bytes)
  let over = string.repeat("a", protocol.max_identity_bytes + 1)
  assert protocol.git_identity_of(at_the_bound, "ada@example.invalid")
    == Some(GitIdentity(at_the_bound, "ada@example.invalid"))
  assert protocol.git_identity_of(over, "ada@example.invalid") == None
  assert protocol.git_identity_of("Ada", over) == None

  // Two bytes each, so half the bound is already the bound.
  let wide = string.repeat("\u{e9}", protocol.max_identity_bytes / 2)
  assert protocol.git_identity_of(wide, "ada@example.invalid")
    == Some(GitIdentity(wide, "ada@example.invalid"))
  assert protocol.git_identity_of(wide <> "\u{e9}", "ada@example.invalid")
    == None
}

pub fn the_names_the_pin_sets_are_the_names_a_configuration_may_not_set_test() {
  // The refusal list and the environment the plane pins are two lists that must
  // be one: a name pinned and not refused is a table that can fight the pin.
  assert list.all(git_identity.author_names, fn(name) {
    result.is_error(profile.not_server_owned("tools.env", name))
  })
  assert profile.not_server_owned("tools.env", "GOFLAGS") == Ok(Nil)
}

// --- the owner's answer -------------------------------------------------------

fn port_with(
  identity: option.Option(Identity),
) -> process.Subject(protocol.OwnerMessage) {
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services: fixtures.quiet_services(),
      clock: clock.fixed(at: 5000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
      mcp: protocol.empty_mcp_plan(),
      git_identity: identity,
    ))
    as "the port starts"
  owner_port.inbox(port)
}

fn asked(inbox: process.Subject(protocol.OwnerMessage)) {
  let reply = process.new_subject()
  process.send(inbox, protocol.AskGitIdentity(reply:))
  let assert Ok(answer) = process.receive(reply, 2000)
    as "the owner port answers"
  answer
}

pub fn the_owner_answers_the_identity_it_resolved_test() {
  let inbox =
    port_with(Some(Identity(Some("Ada"), Some("ada@example.invalid"))))
  assert asked(inbox) == Some(GitIdentity("Ada", "ada@example.invalid"))
}

pub fn the_owner_answers_none_for_an_identity_it_cannot_vouch_for_test() {
  let none = port_with(None)
  let half_name = port_with(Some(Identity(Some("Ada"), None)))
  let half_email = port_with(Some(Identity(None, Some("ada@example.invalid"))))
  let blank = port_with(Some(Identity(Some("  "), Some("ada@example.invalid"))))
  let hostile =
    port_with(
      Some(Identity(
        Some("Ada\n[core]\nhooksPath = x"),
        Some("a@example.invalid"),
      )),
    )
  let nul =
    port_with(Some(Identity(Some("Ada"), Some("a@\u{0}example.invalid"))))

  assert asked(none) == None
  assert asked(half_name) == None
  assert asked(half_email) == None
  assert asked(blank) == None
  assert asked(hostile) == None
  assert asked(nul) == None
}

pub fn the_executor_side_asks_through_the_link_and_hears_the_answer_test() {
  let inbox =
    port_with(Some(Identity(Some("Ada"), Some("ada@example.invalid"))))
  let assert Ok(link) = owner_link.start(inbox)
  assert owner_link.git_identity(link, 2000)
    == Some(GitIdentity("Ada", "ada@example.invalid"))

  let silent = port_with(None)
  let assert Ok(quiet) = owner_link.start(silent)
  assert owner_link.git_identity(quiet, 200) == None
}

// --- the host hands it to the plane's factory -----------------------------------

// A host over a factory that reports the identity its attach spec carried, and
// then builds the fixture plane.
fn attach_with(
  inbox: process.Subject(protocol.OwnerMessage),
) -> option.Option(GitIdentity) {
  let heard = process.new_subject()
  let probe = fixtures.probe(fixtures.Open)
  let base = fixtures.factory(probe, fixtures.AsksNothing, protocol.AllRetired)
  let factory = fn(spec: host.AttachSpec) {
    process.send(heard, spec.git_identity)
    base(spec)
  }
  let path = fixtures.scratch("identity-host") <> "/ledger.db"
  let assert Ok(started) = host.start(fixtures.host_config(path, factory))
    as "the host starts"
  let reply = process.new_subject()
  address.deliver(
    started.data,
    protocol.Attach(
      version: protocol.version,
      session: "s1",
      workspace: "/work",
      incarnation: 0,
      token: <<1>>,
      owner_port: inbox,
      reply:,
    ),
  )
  let assert Ok(Ok(_attached)) = process.receive(reply, 5000)
    as "the host attaches"
  let assert Ok(identity) = process.receive(heard, 2000)
    as "the factory saw the spec"
  identity
}

pub fn the_host_gives_the_plane_the_identity_the_owner_sent_test() {
  let inbox =
    port_with(Some(Identity(Some("Ada"), Some("ada@example.invalid"))))
  assert attach_with(inbox) == Some(GitIdentity("Ada", "ada@example.invalid"))
}

pub fn an_owner_with_no_identity_leaves_the_plane_as_it_was_test() {
  assert attach_with(port_with(None)) == None
}

pub fn an_owner_that_never_answers_the_identity_is_no_identity_test() {
  // This owner answers the MCP plan, which fails a build when it is missing, and
  // reads the identity question without replying to it.
  let ready = process.new_subject()
  let _owner =
    process.spawn(fn() {
      let inbox = process.new_subject()
      process.send(ready, inbox)
      answer_plan_only(inbox)
    })
  let assert Ok(inbox) = process.receive(ready, 2000) as "the owner starts"
  let assert Ok(link) = owner_link.start(inbox)

  assert owner_link.git_identity(link, 200) == None
}

// An owner that answers the MCP plan and never the identity.
fn answer_plan_only(inbox: process.Subject(protocol.OwnerMessage)) -> Nil {
  case process.receive_forever(inbox) {
    protocol.AskMcpPlan(reply:) -> {
      process.send(reply, protocol.empty_mcp_plan())
      answer_plan_only(inbox)
    }
    _ -> answer_plan_only(inbox)
  }
}
