//// The wire form of a membership ledger entry (protocol-change/086): the body
//// bytes, the line, and the total decoder. Every refusal of `read` is driven
//// by hand-built bytes, and the body layout is pinned by a golden string so a
//// change to the key order is a failing test and not a silent format change.

import client/distribution_plan.{Executor, Orchestrator}
import client/membership_entry.{
  type Entry, Authentic, BadSignature, BodyNotJson, BodyNotObject, BodyNotText,
  BodyTooLarge, Entry, FieldInvalid, Forged, Genesis, KeysNotExact, Learner,
  LineShape, Malformed, Member, NotInDirectory, Revoke, SignatureTooLarge,
  SigningFailed, TooLarge, UnsupportedFormat, Upsert, Voter,
}
import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support/membership_fixture as fixture

const zeros = "0000000000000000000000000000000000000000000000000000000000000000"

fn hex(bytes: BitArray) -> String {
  string.lowercase(bit_array.base16_encode(bytes))
}

fn sample_member() -> membership_entry.Member {
  Member(
    name: "laptop2",
    node: "loom@laptop2.example.net",
    host: "laptop2.example.net",
    listen_port: Some(40_000),
    role: Orchestrator,
    directory: Learner,
    links: ["hub", "devbox"],
    pin: fixture.pin_for("laptop2", 0),
  )
}

fn sample_entry() -> Entry {
  fixture.entry(
    4,
    membership_entry.genesis_prev(),
    Upsert(member: sample_member()),
  )
}

// A body from text, signed under the fixture key, as a line.
fn signed_text(text: String) -> BitArray {
  let body = bit_array.from_string(text)
  let assert Ok(signature) =
    fixture.signer()(membership_entry.signing_input(body))
  membership_entry.frame_line(body, signature)
}

fn read(line: BitArray) {
  membership_entry.read(line, fixture.verifier())
}

fn refused_as(line: BitArray, expected: membership_entry.ReadError) {
  assert read(line) == Error(expected)
}

// The five keys every body opens with, then the kind's own.
fn body_with(kind: String, rest: String) -> String {
  "{\"format\":\"loom-membership-ledger/1\",\"seq\":1,\"prev\":\""
  <> zeros
  <> "\",\"time\":\"2026-10-11T18:02:11Z\",\"kind\":\""
  <> kind
  <> "\""
  <> rest
  <> "}"
}

fn member_rest(overrides: List(#(String, String))) -> String {
  let fields = [
    #("name", "\"hub\""),
    #("node", "\"loom@hub.example.net\""),
    #("host", "\"hub.example.net\""),
    #("role", "\"orchestrator\""),
    #("directory", "\"voter\""),
    #("links", "[]"),
    #("pin", "\"" <> hex(fixture.pin_for("hub", 0)) <> "\""),
  ]
  let replaced =
    list.map(fields, fn(field) {
      case list.key_find(overrides, field.0) {
        Ok(value) -> #(field.0, value)
        Error(Nil) -> field
      }
    })
  list.fold(replaced, "", fn(text, field) {
    text <> ",\"" <> field.0 <> "\":" <> field.1
  })
}

fn invalid_field(overrides: List(#(String, String)), key: String) {
  let line = signed_text(body_with("member", member_rest(overrides)))
  refused_as(line, Malformed(FieldInvalid(key)))
}

// --- the body layout -----------------------------------------------------------

pub fn genesis_body_golden_test() {
  let authority = crypto.hash(crypto.Sha256, <<"ca":utf8>>)
  let entry =
    Entry(
      seq: 0,
      prev: membership_entry.genesis_prev(),
      time: fixture.stamp,
      kind: fixture.genesis_kind(),
    )
  let expected =
    "{\"format\":\"loom-membership-ledger/1\",\"seq\":0,\"prev\":\""
    <> zeros
    <> "\",\"time\":\"2026-10-11T18:02:11Z\",\"kind\":\"genesis\","
    <> "\"deployment\":\"3f9c00112233445566778899aabbccdd\",\"authority\":\""
    <> hex(authority)
    <> "\"}"
  assert membership_entry.encode_body(entry) == bit_array.from_string(expected)
}

pub fn member_body_golden_test() {
  let expected =
    "{\"format\":\"loom-membership-ledger/1\",\"seq\":4,\"prev\":\""
    <> zeros
    <> "\",\"time\":\"2026-10-11T18:02:11Z\",\"kind\":\"member\","
    <> "\"name\":\"laptop2\",\"node\":\"loom@laptop2.example.net\","
    <> "\"host\":\"laptop2.example.net\",\"listen_port\":40000,"
    <> "\"role\":\"orchestrator\",\"directory\":\"learner\","
    <> "\"links\":[\"hub\",\"devbox\"],\"pin\":\""
    <> hex(fixture.pin_for("laptop2", 0))
    <> "\"}"
  assert membership_entry.encode_body(sample_entry())
    == bit_array.from_string(expected)
}

pub fn member_without_port_omits_the_key_test() {
  let entry =
    fixture.entry(
      1,
      membership_entry.genesis_prev(),
      Upsert(Member(..sample_member(), listen_port: None)),
    )
  let assert Ok(text) = bit_array.to_string(membership_entry.encode_body(entry))
  assert !string.contains(text, "listen_port")
}

pub fn revoke_body_golden_test() {
  let entry =
    fixture.entry(
      5,
      membership_entry.genesis_prev(),
      Revoke(
        name: "laptop2",
        pin: fixture.pin_for("laptop2", 0),
        reason: "laptop lost",
      ),
    )
  let expected =
    "{\"format\":\"loom-membership-ledger/1\",\"seq\":5,\"prev\":\""
    <> zeros
    <> "\",\"time\":\"2026-10-11T18:02:11Z\",\"kind\":\"revoke\","
    <> "\"name\":\"laptop2\",\"pin\":\""
    <> hex(fixture.pin_for("laptop2", 0))
    <> "\",\"reason\":\"laptop lost\"}"
  assert membership_entry.encode_body(entry) == bit_array.from_string(expected)
}

pub fn identity_is_the_hash_of_the_body_bytes_test() {
  let signed = fixture.seal(sample_entry())
  assert signed.id == membership_entry.id_of_body(signed.body)
  assert membership_entry.id_to_bytes(signed.id)
    == crypto.hash(crypto.Sha256, signed.body)
}

pub fn identity_ignores_the_signature_test() {
  let entry = sample_entry()
  let first = fixture.seal(entry)
  let assert Ok(second) =
    membership_entry.seal(entry, fixture.stranger_signer())
  assert first.signature != second.signature
  assert first.id == second.id
}

pub fn signing_input_has_the_domain_prefix_test() {
  assert membership_entry.signing_input(<<"body":utf8>>)
    == <<"loom-membership-ledger/1":utf8, 0, "body":utf8>>
}

// --- round trips ---------------------------------------------------------------

pub fn every_kind_round_trips_test() {
  let entries = [
    Entry(
      seq: 0,
      prev: membership_entry.genesis_prev(),
      time: fixture.stamp,
      kind: fixture.genesis_kind(),
    ),
    sample_entry(),
    fixture.entry(
      2,
      membership_entry.genesis_prev(),
      Upsert(Member(..sample_member(), role: Executor, directory: Voter)),
    ),
    fixture.entry(
      3,
      membership_entry.genesis_prev(),
      Upsert(Member(..sample_member(), directory: NotInDirectory, links: [])),
    ),
    fixture.entry(6, membership_entry.genesis_prev(), fixture.revoke_kind("a")),
  ]
  list.each(entries, fn(entry) {
    assert membership_entry.decode_body(membership_entry.encode_body(entry))
      == Ok(entry)
    let signed = fixture.seal(entry)
    assert read(membership_entry.line(signed)) == Ok(signed)
  })
}

pub fn a_reordered_body_still_decodes_test() {
  // The signer writes the keys in a fixed order, but a reader does not
  // require it: it requires exactly the keys.
  let text =
    "{\"kind\":\"revoke\",\"reason\":\"x\",\"pin\":\""
    <> hex(fixture.pin_for("a", 0))
    <> "\",\"name\":\"a\",\"time\":\"2026-10-11T18:02:11Z\",\"prev\":\""
    <> zeros
    <> "\",\"seq\":3,\"format\":\"loom-membership-ledger/1\"}"
  let assert Ok(entry) =
    bit_array.from_string(text) |> membership_entry.decode_body
  assert entry.seq == 3
}

// --- the line ------------------------------------------------------------------

pub fn frame_line_is_unpadded_url_safe_base64_test() {
  assert membership_entry.frame_line(<<"a":utf8>>, <<"b":utf8>>)
    == <<"YQ.Yg":utf8>>
  assert membership_entry.frame_line(<<251, 255>>, <<255, 254>>)
    == <<"-_8.__4":utf8>>
}

pub fn parse_line_returns_both_halves_test() {
  assert membership_entry.parse_line(<<"YQ.Yg":utf8>>)
    == Ok(membership_entry.RawLine(body: <<"a":utf8>>, signature: <<"b":utf8>>))
}

pub fn a_line_without_a_dot_is_refused_test() {
  assert membership_entry.parse_line(<<"YQYg":utf8>>) == Error(LineShape)
}

pub fn a_line_with_two_dots_is_refused_test() {
  assert membership_entry.parse_line(<<"YQ.Yg.Yw":utf8>>) == Error(LineShape)
}

pub fn an_empty_half_is_refused_test() {
  assert membership_entry.parse_line(<<".Yg":utf8>>) == Error(LineShape)
  assert membership_entry.parse_line(<<"YQ.":utf8>>) == Error(LineShape)
  assert membership_entry.parse_line(<<>>) == Error(LineShape)
}

pub fn padding_is_refused_test() {
  assert membership_entry.parse_line(<<"YQ==.Yg":utf8>>) == Error(LineShape)
  assert membership_entry.parse_line(<<"YQ.Yg==":utf8>>) == Error(LineShape)
}

pub fn whitespace_is_refused_test() {
  assert membership_entry.parse_line(<<"YQ .Yg":utf8>>) == Error(LineShape)
  assert membership_entry.parse_line(<<"YQ.Yg\n":utf8>>) == Error(LineShape)
  assert membership_entry.parse_line(<<"YQ.Yg\r":utf8>>) == Error(LineShape)
  assert membership_entry.parse_line(<<"YQ.\tYg":utf8>>) == Error(LineShape)
}

pub fn a_character_outside_the_alphabet_is_refused_test() {
  assert membership_entry.parse_line(<<"Y+.Yg":utf8>>) == Error(LineShape)
  assert membership_entry.parse_line(<<"Y/.Yg":utf8>>) == Error(LineShape)
  assert membership_entry.parse_line(<<"Y*.Yg":utf8>>) == Error(LineShape)
}

pub fn a_line_that_is_not_utf8_is_refused_test() {
  assert membership_entry.parse_line(<<255, 254, 46, 255>>) == Error(LineShape)
}

pub fn a_non_canonical_encoding_is_refused_test() {
  // "YR" decodes to the same byte as "YQ", because the last character
  // carries four bits the byte does not use. Accepting it would let a line
  // change without changing what it means.
  assert membership_entry.parse_line(<<"YR.Yg":utf8>>) == Error(LineShape)
  assert membership_entry.parse_line(<<"YQ.Yh":utf8>>) == Error(LineShape)
}

pub fn a_length_that_no_byte_string_encodes_to_is_refused_test() {
  assert membership_entry.parse_line(<<"Y.Yg":utf8>>) == Error(LineShape)
}

pub fn a_body_of_exactly_the_limit_parses_test() {
  let body = bit_array.from_string(string.repeat("a", 4096))
  let line = membership_entry.frame_line(body, <<"s":utf8>>)
  assert membership_entry.parse_line(line)
    == Ok(membership_entry.RawLine(body:, signature: <<"s":utf8>>))
}

pub fn a_body_over_the_limit_is_refused_test() {
  let body = bit_array.from_string(string.repeat("a", 4097))
  let line = membership_entry.frame_line(body, <<"s":utf8>>)
  assert membership_entry.parse_line(line) == Error(BodyTooLarge)
}

pub fn a_signature_of_exactly_the_limit_parses_test() {
  let signature = bit_array.from_string(string.repeat("s", 80))
  let line = membership_entry.frame_line(<<"b":utf8>>, signature)
  assert membership_entry.parse_line(line)
    == Ok(membership_entry.RawLine(body: <<"b":utf8>>, signature:))
}

pub fn a_signature_over_the_limit_is_refused_test() {
  let signature = bit_array.from_string(string.repeat("s", 81))
  let line = membership_entry.frame_line(<<"b":utf8>>, signature)
  assert membership_entry.parse_line(line) == Error(SignatureTooLarge)
}

pub fn a_huge_half_is_refused_before_decoding_test() {
  let line = bit_array.from_string(string.repeat("A", 200_000) <> ".Yg")
  assert membership_entry.parse_line(line) == Error(BodyTooLarge)
}

// --- reading -------------------------------------------------------------------

pub fn a_forged_signature_is_refused_test() {
  let assert Ok(forged) =
    membership_entry.seal(sample_entry(), fixture.stranger_signer())
  refused_as(membership_entry.line(forged), BadSignature)
}

pub fn the_signature_is_checked_before_the_body_is_parsed_test() {
  // A body that is not JSON, signed by a stranger, is a bad signature and
  // not a malformed body: nothing is parsed until the signature passes.
  let body = <<"not json":utf8>>
  let assert Ok(signature) =
    fixture.stranger_signer()(membership_entry.signing_input(body))
  refused_as(membership_entry.frame_line(body, signature), BadSignature)
}

pub fn a_signature_over_the_bare_body_is_refused_test() {
  // The domain prefix is part of what is signed, so a signature made over
  // the body alone, as any other use of the key might make, does not verify.
  let signed = fixture.seal(sample_entry())
  let assert Ok(bare) = fixture.signer()(signed.body)
  refused_as(membership_entry.frame_line(signed.body, bare), BadSignature)
}

pub fn a_verifier_decides_by_the_message_and_signature_test() {
  let raw =
    membership_entry.RawLine(body: <<"b":utf8>>, signature: <<"s":utf8>>)
  assert membership_entry.verify(raw, fn(_, _) { Authentic }) == Authentic
  assert membership_entry.verify(raw, fn(_, _) { Forged }) == Forged
  assert membership_entry.verify(raw, fn(message, signature) {
      case
        message == membership_entry.signing_input(<<"b":utf8>>)
        && signature == <<"s":utf8>>
      {
        True -> Authentic
        False -> Forged
      }
    })
    == Authentic
}

pub fn a_body_that_is_not_utf8_is_malformed_test() {
  let body = <<255, 254, 253>>
  let assert Ok(signature) =
    fixture.signer()(membership_entry.signing_input(body))
  refused_as(
    membership_entry.frame_line(body, signature),
    Malformed(BodyNotText),
  )
}

pub fn a_body_that_is_not_json_is_malformed_test() {
  refused_as(signed_text("{\"format\":"), Malformed(BodyNotJson))
}

pub fn an_empty_body_is_a_line_shape_failure_test() {
  refused_as(signed_text(""), Malformed(LineShape))
}

pub fn a_body_that_is_not_an_object_is_malformed_test() {
  refused_as(signed_text("[]"), Malformed(BodyNotObject))
  refused_as(signed_text("null"), Malformed(BodyNotObject))
  refused_as(signed_text("7"), Malformed(BodyNotObject))
  refused_as(signed_text("\"text\""), Malformed(BodyNotObject))
}

pub fn another_format_is_reported_as_such_test() {
  // The other format may have other keys, so the marker is read first.
  refused_as(
    signed_text("{\"format\":\"loom-membership-ledger/2\",\"anything\":1}"),
    UnsupportedFormat,
  )
}

pub fn a_missing_or_non_text_format_is_malformed_test() {
  refused_as(signed_text("{}"), Malformed(FieldInvalid("format")))
  refused_as(signed_text("{\"format\":7}"), Malformed(FieldInvalid("format")))
}

pub fn an_unknown_kind_is_malformed_test() {
  refused_as(
    signed_text(body_with("rename", "")),
    Malformed(FieldInvalid("kind")),
  )
  refused_as(
    signed_text("{\"format\":\"loom-membership-ledger/1\",\"seq\":1}"),
    Malformed(FieldInvalid("kind")),
  )
}

pub fn a_missing_key_is_refused_test() {
  refused_as(
    signed_text(body_with(
      "revoke",
      ",\"name\":\"a\",\"pin\":\"" <> zeros <> "\"",
    )),
    Malformed(KeysNotExact),
  )
}

pub fn an_extra_key_is_refused_test() {
  refused_as(
    signed_text(body_with(
      "revoke",
      ",\"name\":\"a\",\"pin\":\"" <> zeros <> "\",\"reason\":\"x\",\"extra\":1",
    )),
    Malformed(KeysNotExact),
  )
}

pub fn a_key_of_another_kind_is_refused_test() {
  // A member body must not carry a revoke's `reason`.
  refused_as(
    signed_text(body_with("member", member_rest([]) <> ",\"reason\":\"x\"")),
    Malformed(KeysNotExact),
  )
  refused_as(
    signed_text(body_with(
      "genesis",
      ",\"deployment\":\"3f9c00112233445566778899aabbccdd\",\"authority\":\""
        <> zeros
        <> "\",\"name\":\"x\"",
    )),
    Malformed(KeysNotExact),
  )
}

pub fn the_member_listen_port_is_optional_test() {
  let without = signed_text(body_with("member", member_rest([])))
  let assert Ok(signed) = read(without)
  let assert Upsert(member) = signed.entry.kind
  assert member.listen_port == None

  let with =
    signed_text(body_with("member", member_rest([]) <> ",\"listen_port\":4369"))
  let assert Ok(signed) = read(with)
  let assert Upsert(member) = signed.entry.kind
  assert member.listen_port == Some(4369)
}

pub fn a_field_of_the_wrong_type_is_refused_test() {
  invalid_field([#("name", "7")], "name")
  invalid_field([#("links", "\"hub\"")], "links")
  invalid_field([#("links", "[1]")], "links")
  invalid_field([#("pin", "null")], "pin")
}

pub fn a_node_name_must_be_a_full_name_test() {
  invalid_field([#("node", "\"hub\"")], "node")
  invalid_field([#("node", "\"loom@hub\"")], "node")
  invalid_field([#("node", "\"loom@hub.example net\"")], "node")
}

pub fn a_member_name_must_be_a_plan_name_test() {
  invalid_field([#("name", "\"Hub\"")], "name")
  invalid_field([#("name", "\"\"")], "name")
  invalid_field([#("name", "\"1hub\"")], "name")
  invalid_field([#("name", "\"" <> string.repeat("a", 33) <> "\"")], "name")
}

pub fn a_host_must_be_a_dns_name_or_address_test() {
  invalid_field([#("host", "\"\"")], "host")
  invalid_field([#("host", "\"a b\"")], "host")
  invalid_field([#("host", "\"" <> string.repeat("a", 254) <> "\"")], "host")
}

pub fn a_role_must_be_a_known_word_test() {
  invalid_field([#("role", "\"wizard\"")], "role")
}

pub fn a_directory_standing_must_be_a_known_word_test() {
  invalid_field([#("directory", "\"observer\"")], "directory")
}

pub fn a_port_must_be_in_range_test() {
  let bad = fn(port: String) {
    refused_as(
      signed_text(body_with(
        "member",
        member_rest([]) <> ",\"listen_port\":" <> port,
      )),
      Malformed(FieldInvalid("listen_port")),
    )
  }
  bad("0")
  bad("65536")
  bad("-1")
  bad("\"4369\"")
  bad("null")
  bad("1.5")
}

pub fn at_most_63_links_are_accepted_test() {
  let links = fn(count: Int) {
    "["
    <> string.join(
      list.index_map(list.repeat(Nil, count), fn(_, index) {
        "\"n" <> string.inspect(index) <> "\""
      }),
      ",",
    )
    <> "]"
  }
  let assert Ok(_) =
    read(signed_text(body_with("member", member_rest([#("links", links(63))]))))
  invalid_field([#("links", links(64))], "links")
}

pub fn a_link_must_be_a_plan_name_test() {
  invalid_field([#("links", "[\"Hub\"]")], "links")
}

pub fn a_pin_is_exactly_64_lowercase_hex_digits_test() {
  let bad = fn(pin: String) {
    invalid_field([#("pin", "\"" <> pin <> "\"")], "pin")
  }
  bad(string.repeat("a", 63))
  bad(string.repeat("a", 65))
  bad(string.repeat("A", 64))
  bad(string.repeat("g", 64))
  bad("")
}

pub fn prev_seq_and_time_are_checked_test() {
  let with = fn(seq: String, prev: String, time: String) {
    signed_text(
      "{\"format\":\"loom-membership-ledger/1\",\"seq\":"
      <> seq
      <> ",\"prev\":\""
      <> prev
      <> "\",\"time\":\""
      <> time
      <> "\",\"kind\":\"revoke\",\"name\":\"a\",\"pin\":\""
      <> zeros
      <> "\",\"reason\":\"x\"}",
    )
  }
  let assert Ok(_) = read(with("3", zeros, "2026-10-11T18:02:11Z"))
  refused_as(
    with("-1", zeros, "2026-10-11T18:02:11Z"),
    Malformed(FieldInvalid("seq")),
  )
  refused_as(
    with("1.0", zeros, "2026-10-11T18:02:11Z"),
    Malformed(FieldInvalid("seq")),
  )
  refused_as(
    with("1", "abc", "2026-10-11T18:02:11Z"),
    Malformed(FieldInvalid("prev")),
  )
  refused_as(
    with("1", zeros, "2026-10-11 18:02:11"),
    Malformed(FieldInvalid("time")),
  )
  refused_as(
    with("1", zeros, "2026-10-11T18:02:11+00:00"),
    Malformed(FieldInvalid("time")),
  )
}

pub fn a_genesis_needs_a_deployment_and_an_authority_test() {
  let genesis = fn(deployment: String, authority: String) {
    signed_text(body_with(
      "genesis",
      ",\"deployment\":\""
        <> deployment
        <> "\",\"authority\":\""
        <> authority
        <> "\"",
    ))
  }
  let assert Ok(_) = read(genesis("3f9c00112233445566778899aabbccdd", zeros))
  refused_as(genesis("3f9c", zeros), Malformed(FieldInvalid("deployment")))
  refused_as(
    genesis("3f9c00112233445566778899aabbccdd", "abc"),
    Malformed(FieldInvalid("authority")),
  )
}

pub fn a_revoke_reason_is_bounded_and_printable_test() {
  let revoke = fn(reason: String) {
    signed_text(body_with(
      "revoke",
      ",\"name\":\"a\",\"pin\":\"" <> zeros <> "\",\"reason\":" <> reason,
    ))
  }
  let assert Ok(_) = read(revoke("\"" <> string.repeat("x", 200) <> "\""))
  refused_as(
    revoke("\"" <> string.repeat("x", 201) <> "\""),
    Malformed(FieldInvalid("reason")),
  )
  refused_as(revoke("\"a\\nb\""), Malformed(FieldInvalid("reason")))
  refused_as(revoke("\"a\\u0000b\""), Malformed(FieldInvalid("reason")))
  let assert Ok(_) = read(revoke("\"\""))
}

// --- sealing -------------------------------------------------------------------

pub fn a_signer_that_fails_yields_no_entry_test() {
  assert membership_entry.seal(sample_entry(), fn(_) { Error(Nil) })
    == Error(SigningFailed)
}

pub fn a_signature_a_reader_would_refuse_is_not_sealed_test() {
  let long = bit_array.from_string(string.repeat("s", 81))
  assert membership_entry.seal(sample_entry(), fn(_) { Ok(long) })
    == Error(TooLarge)
}

pub fn a_body_a_reader_would_refuse_is_not_sealed_test() {
  let reason = string.repeat("x", 5000)
  let entry =
    fixture.entry(
      1,
      membership_entry.genesis_prev(),
      Revoke(name: "a", pin: <<>>, reason:),
    )
  assert membership_entry.seal(entry, fixture.signer()) == Error(TooLarge)
}

// --- identities ----------------------------------------------------------------

pub fn an_identity_is_32_bytes_test() {
  assert membership_entry.id_from_bytes(<<1, 2, 3>>) == Error(Nil)
  let assert Ok(id) = membership_entry.id_from_bytes(<<7:size(256)>>)
  assert membership_entry.id_to_bytes(id) == <<7:size(256)>>
  assert string.length(membership_entry.id_to_hex(id)) == 64
}

pub fn the_genesis_prev_is_32_zero_bytes_test() {
  assert membership_entry.id_to_bytes(membership_entry.genesis_prev())
    == <<0:size(256)>>
  assert membership_entry.id_to_hex(membership_entry.genesis_prev()) == zeros
}

pub fn the_word_helpers_cover_every_variant_test() {
  assert list.map(
      [Voter, Learner, NotInDirectory],
      membership_entry.directory_word,
    )
    == ["voter", "learner", "none"]
  assert list.map(
      [
        Genesis(deployment: "", authority: <<>>),
        Upsert(sample_member()),
        Revoke(name: "", pin: <<>>, reason: ""),
      ],
      membership_entry.kind_word,
    )
    == ["genesis", "member", "revoke"]
  assert list.map(
      [
        Malformed(LineShape),
        BadSignature,
        UnsupportedFormat,
      ],
      membership_entry.read_error_word,
    )
    == ["malformed", "bad_signature", "unsupported_format"]
}
