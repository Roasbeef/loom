//// The `[directory]` table is strict and absent by default
//// (protocol-change/081). Its members are pinned peers and this daemon, three
//// to seven of them, and every orchestrator this daemon lists must be one.

import client/catalog
import client/directory/settings.{Settings}
import client/distribution
import gleam/dict
import gleam/option.{None, Some}
import gleam/string

const distribution_table =
  "[distribution]
node = \"alpha@10.0.0.1\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"bravo@10.0.0.2\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[[distribution.peers]]
node = \"exec@10.0.0.3\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000002\"

[[distribution.peers]]
node = \"other@10.0.0.4\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000003\"
"

const three =
  "[directory]
members = [\"alpha@10.0.0.1\", \"bravo@10.0.0.2\", \"exec@10.0.0.3\"]
"

fn with(table: String) -> String {
  distribution_table <> "\n" <> table
}

fn refused(text: String, fragment: String) {
  let assert Error(reason) = settings.parse(text)
    as "the table is refused by its own parser"
  assert string.contains(reason, fragment)
}

pub fn an_absent_table_is_not_a_member_test() {
  assert settings.parse("") == Ok(None)
  assert settings.parse(distribution_table) == Ok(None)
  assert settings.from_document(dict.new()) == Ok(None)
  assert settings.cluster(None) == distribution.NotMember
}

pub fn three_pinned_members_including_this_daemon_parse_test() {
  let members = ["alpha@10.0.0.1", "bravo@10.0.0.2", "exec@10.0.0.3"]
  assert settings.parse(with(three)) == Ok(Some(Settings(members:)))
  assert settings.cluster(Some(Settings(members:)))
    == distribution.Member(members:)
  assert settings.others(Settings(members:), "alpha@10.0.0.1")
    == ["bravo@10.0.0.2", "exec@10.0.0.3"]
  assert !settings.even(Settings(members:))
}

pub fn an_even_count_is_accepted_and_reported_test() {
  let text =
    with(
      "[directory]
members = [\"alpha@10.0.0.1\", \"bravo@10.0.0.2\", \"exec@10.0.0.3\", \"other@10.0.0.4\"]
",
    )
  let assert Ok(Some(found)) = settings.parse(text) as "four members parse"
  assert settings.even(found)
}

pub fn the_table_needs_distribution_test() {
  refused(three, "needs a [distribution] table")
}

pub fn this_daemon_must_be_a_member_test() {
  refused(
    with(
      "[directory]
members = [\"bravo@10.0.0.2\", \"exec@10.0.0.3\", \"other@10.0.0.4\"]
",
    ),
    "must include this daemon's own node alpha@10.0.0.1",
  )
}

pub fn every_other_member_must_be_a_pinned_peer_test() {
  refused(
    with(
      "[directory]
members = [\"alpha@10.0.0.1\", \"bravo@10.0.0.2\", \"stranger@10.0.0.9\"]
",
    ),
    "stranger@10.0.0.9, which is not a node in [[distribution.peers]]",
  )
}

pub fn the_count_is_three_to_seven_test() {
  refused(
    with("[directory]\nmembers = [\"alpha@10.0.0.1\", \"bravo@10.0.0.2\"]\n"),
    "between 3 and 7 nodes, not 2",
  )
}

pub fn a_member_listed_twice_is_refused_test() {
  refused(
    with(
      "[directory]
members = [\"alpha@10.0.0.1\", \"bravo@10.0.0.2\", \"bravo@10.0.0.2\"]
",
    ),
    "lists bravo@10.0.0.2 twice",
  )
}

pub fn a_malformed_name_or_key_is_refused_test() {
  refused(
    with("[directory]\nmembers = [\"alpha@10.0.0.1\", \"bravo\", \"x@y.z\"]\n"),
    "directory.members",
  )
  refused(with("[directory]\nmembers = \"alpha@10.0.0.1\"\n"), "list of node")
  refused(with("[directory]\n"), "directory.members is required")
  refused(with(three <> "colour = \"blue\"\n"), "unknown key `colour`")
}

pub fn every_listed_orchestrator_must_be_a_member_test() {
  refused(with(three <> "\n[orchestrators.other]
node = \"other@10.0.0.4\"
"), "orchestrators.other.node other@10.0.0.4 must be one of directory.members")
  let assert Ok(Some(_)) =
    settings.parse(with(
      three <> "\n[orchestrators.bravo]\nnode = \"bravo@10.0.0.2\"\n",
    ))
    as "an orchestrator that is a member is accepted"
  Nil
}

pub fn the_catalogue_parser_refuses_a_bad_table_too_test() {
  let assert Error(reason) =
    catalog.parse(
      "[models.m]\nprovider = \"anthropic\"\nmodel = \"x\"\n[roles]\nmain = \"m\"\n"
      <> three,
    )
    as "the catalogue validates [directory]"
  assert string.contains(reason, "directory")
}
