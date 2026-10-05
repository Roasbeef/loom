//// The browser login's token: its grammar, its chain, its intersection rules
//// and the root key's three start cases (protocol-change/065).

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import host/login
import simplifile

// Deterministic entropy: `count` copies of one byte.
fn fixed(byte: Int) -> fn(Int) -> BitArray {
  fn(count) { list.repeat(<<byte>>, count) |> bit_array.concat }
}

fn root() -> login.RootKey {
  login.draw_root(fixed(0x11))
}

fn other_root() -> login.RootKey {
  login.draw_root(fixed(0x22))
}

const now = 1_000_000

const nonce = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

fn key() -> String {
  login.fresh_key(fixed(0xab))
}

fn id() -> String {
  login.fresh_id(fixed(0xcd))
}

fn minting() -> login.Minting {
  login.Minting(
    principal: "owner-1",
    ceiling: login.Operator,
    expires_at_ms: now + login.lifetime_ms,
    key: key(),
    nonce_digest: login.nonce_digest(nonce),
  )
}

fn token() -> String {
  login.issue(root(), id(), minting())
}

fn opened(text: String) -> Result(login.Login, login.Refusal) {
  login.open(root(), text, now_ms: now, key: key(), nonce: nonce)
}

fn parsed(text: String) -> login.Parsed {
  let assert Ok(found) = login.parse(text) as "the token parses"
  found
}

fn allowed(text: String) -> Result(login.Allowance, login.Refusal) {
  login.intersect(parsed(text))
}

pub fn a_minted_token_opens_with_its_six_caveats_test() {
  let text = token()
  assert string.starts_with(text, "loomb1:" <> id() <> ":p=owner-1|c=operator|")
  assert string.contains(text, "|r=workspace|e=2593000000|k=" <> key() <> "|n=")

  let assert Ok(found) = opened(text)
  assert found.id == id()
  assert found.allowance.principal == "owner-1"
  assert found.allowance.ceiling == login.Operator
  assert found.allowance.expires_at_ms == now + login.lifetime_ms
  assert found.allowance.key == key()
  assert found.allowance.session == None
}

pub fn the_chain_is_hmac_sha256_over_the_text_each_caveat_makes_test() {
  // The first signature is keyed by the root key over "loomb1:" and the
  // identifier, and each caveat is signed with the signature before it. The
  // expectation is built here from `crypto.hmac` alone, so it checks the
  // construction and not the module's own helper.
  let root_bytes = list.repeat(<<0x11>>, 32) |> bit_array.concat
  let first =
    crypto.hmac(
      bit_array.from_string("loomb1:" <> id()),
      crypto.Sha256,
      root_bytes,
    )
  let signed =
    login.sign(root(), id(), [login.Caveat("p", "a"), login.Caveat("c", "b")])
  let second = crypto.hmac(<<"p=a">>, crypto.Sha256, first)
  let third = crypto.hmac(<<"c=b">>, crypto.Sha256, second)
  let expected = bit_array.base16_encode(third) |> string.lowercase
  assert string.ends_with(signed, ":" <> expected)
}

pub fn the_longest_token_the_grammar_allows_fits_the_bound_test() {
  let longest =
    login.issue(
      root(),
      id(),
      login.Minting(
        ..minting(),
        principal: string.repeat("p", 128),
        expires_at_ms: 9_999_999_999_999,
      ),
    )
  assert string.byte_size(longest) <= login.max_token_bytes
  let assert Ok(_) = login.parse(longest)
}

pub fn a_token_over_the_bound_is_refused_before_a_field_is_read_test() {
  let padded = token() <> string.repeat("a", login.max_token_bytes)
  assert login.parse(padded) == Error(login.TooLong)
  assert opened(padded) == Error(login.TooLong)
}

pub fn the_grammar_refuses_what_it_does_not_define_test() {
  let text = token()
  let good_id = id()
  assert login.parse("") == Error(login.Malformed)
  assert login.parse("loomb2" <> string.drop_start(text, 6))
    == Error(login.Malformed)
  assert login.parse("loomb1:short:p=a:" <> string.repeat("0", 64))
    == Error(login.Malformed)
  assert login.parse("loomb1:" <> good_id <> ":p=a") == Error(login.Malformed)
  assert login.parse("loomb1:" <> good_id <> ":p=a:" <> string.repeat("0", 63))
    == Error(login.Malformed)
  assert login.parse("loomb1:" <> good_id <> ":P=a:" <> string.repeat("0", 64))
    == Error(login.Malformed)
  assert login.parse("loomb1:" <> good_id <> ":pp=a:" <> string.repeat("0", 64))
    == Error(login.Malformed)
  assert login.parse("loomb1:" <> good_id <> ":p=:" <> string.repeat("0", 64))
    == Error(login.Malformed)
  assert login.parse(
      "loomb1:" <> good_id <> ":p=a b:" <> string.repeat("0", 64),
    )
    == Error(login.Malformed)
  assert login.parse("loomb1:" <> good_id <> ":p=é:" <> string.repeat("0", 64))
    == Error(login.Malformed)
  assert login.parse(
      "loomb1:" <> good_id <> ":p=a=b:" <> string.repeat("0", 64),
    )
    == Error(login.Malformed)
  assert login.parse(
      "loomb1:"
      <> good_id
      <> ":p="
      <> string.repeat("a", 129)
      <> ":"
      <> string.repeat("0", 64),
    )
    == Error(login.Malformed)
  assert login.parse("loomb1:" <> good_id <> "::" <> string.repeat("0", 64))
    == Error(login.Malformed)
}

pub fn uppercase_hex_is_refused_wherever_it_appears_test() {
  let text = token()
  assert login.parse(string.replace(text, id(), string.uppercase(id())))
    == Error(login.Malformed)
  let signature = string.slice(text, string.length(text) - 64, 64)
  assert login.parse(string.replace(
      text,
      signature,
      string.uppercase(signature),
    ))
    == Error(login.Malformed)

  // A key or a nonce digest in capitals parses as a value, so it is the
  // intersection that refuses it, on a token whose chain is genuine.
  let upper_key =
    login.sign(root(), id(), [
      login.Caveat("p", "owner-1"),
      login.Caveat("c", "operator"),
      login.Caveat("r", "workspace"),
      login.Caveat("e", "2000000"),
      login.Caveat("k", string.uppercase(key())),
      login.Caveat("n", login.nonce_digest(nonce)),
    ])
  assert allowed(upper_key) == Error(login.BadCaveat("k"))
  let upper_nonce =
    login.sign(root(), id(), [
      login.Caveat("p", "owner-1"),
      login.Caveat("c", "operator"),
      login.Caveat("r", "workspace"),
      login.Caveat("e", "2000000"),
      login.Caveat("k", key()),
      login.Caveat("n", string.uppercase(login.nonce_digest(nonce))),
    ])
  assert allowed(upper_nonce) == Error(login.BadCaveat("n"))
}

pub fn a_signature_that_is_not_the_chains_is_refused_test() {
  let text = token()

  // A different root key, one altered caveat and one removed caveat each
  // leave a token that parses and does not verify.
  assert login.verify(other_root(), parsed(text)) == Error(login.BadSignature)
  assert login.verify(
      root(),
      parsed(string.replace(text, "owner-1", "owner-2")),
    )
    == Error(login.BadSignature)
  assert login.verify(root(), parsed(string.replace(text, "c=operator|", "")))
    == Error(login.BadSignature)
  assert login.verify(root(), parsed(text)) == Ok(Nil)
  assert opened(login.issue(other_root(), id(), minting()))
    == Error(login.BadSignature)
}

pub fn a_token_missing_any_of_the_six_caveats_is_refused_test() {
  let all = [
    login.Caveat("p", "owner-1"),
    login.Caveat("c", "operator"),
    login.Caveat("r", "workspace"),
    login.Caveat("e", "2000000"),
    login.Caveat("k", key()),
    login.Caveat("n", login.nonce_digest(nonce)),
  ]
  list.each(["p", "c", "r", "e", "k", "n"], fn(name) {
    let without = list.filter(all, fn(caveat) { caveat.name != name })
    assert allowed(login.sign(root(), id(), without))
      == Error(login.MissingCaveat(name))
  })
}

pub fn an_unknown_caveat_name_refuses_the_token_test() {
  let text =
    login.sign(root(), id(), [
      login.Caveat("p", "owner-1"),
      login.Caveat("c", "operator"),
      login.Caveat("r", "workspace"),
      login.Caveat("e", "2000000"),
      login.Caveat("k", key()),
      login.Caveat("n", login.nonce_digest(nonce)),
      login.Caveat("x", "1"),
    ])
  assert allowed(text) == Error(login.UnknownCaveat("x"))
  assert login.verify(root(), parsed(text)) == Ok(Nil)
}

pub fn values_a_caveat_does_not_take_are_refused_test() {
  let base = fn(name, value) {
    login.sign(root(), id(), [
      login.Caveat("p", "owner-1"),
      login.Caveat("c", "operator"),
      login.Caveat("r", "workspace"),
      login.Caveat("e", "2000000"),
      login.Caveat("k", key()),
      login.Caveat("n", login.nonce_digest(nonce)),
      login.Caveat(name, value),
    ])
  }
  assert allowed(base("c", "root")) == Error(login.BadCaveat("c"))
  assert allowed(base("e", "soon")) == Error(login.BadCaveat("e"))
  assert allowed(base("e", "-1")) == Error(login.BadCaveat("e"))
  assert allowed(
      login.sign(root(), id(), [
        login.Caveat("p", "owner-1"),
        login.Caveat("c", "operator"),
        login.Caveat("r", "everywhere"),
        login.Caveat("e", "2000000"),
        login.Caveat("k", key()),
        login.Caveat("n", login.nonce_digest(nonce)),
      ]),
    )
    == Error(login.BadCaveat("r"))
}

pub fn the_request_is_held_to_the_key_nonce_and_clock_test() {
  let text = token()
  let wrong_key = login.fresh_key(fixed(0xee))
  assert login.open(root(), text, now_ms: now, key: wrong_key, nonce: nonce)
    == Error(login.WrongKey)
  assert login.open(root(), text, now_ms: now, key: key(), nonce: "00")
    == Error(login.WrongNonce)
  let expiry = now + login.lifetime_ms

  // The login is honoured strictly before its instant and refused at it.
  let assert Ok(_) =
    login.open(root(), text, now_ms: expiry - 1, key: key(), nonce: nonce)
  assert login.open(root(), text, now_ms: expiry, key: key(), nonce: nonce)
    == Error(login.Expired)
  assert login.open(root(), text, now_ms: expiry + 1, key: key(), nonce: nonce)
    == Error(login.Expired)
}

pub fn a_repeated_ceiling_narrows_in_either_order_test() {
  let parsed_token = parsed(token())
  let narrowed = login.append(parsed_token, login.Caveat("c", "observer"))
  let assert Ok(allowance) = allowed(narrowed)
  assert allowance.ceiling == login.Observer

  // A wider repeat after a narrow one is ignored and the narrow value holds.
  let observer_first =
    login.sign(root(), id(), [
      login.Caveat("p", "owner-1"),
      login.Caveat("c", "observer"),
      login.Caveat("r", "workspace"),
      login.Caveat("e", "2000000"),
      login.Caveat("k", key()),
      login.Caveat("n", login.nonce_digest(nonce)),
      login.Caveat("c", "operator"),
    ])
  let assert Ok(held) = allowed(observer_first)
  assert held.ceiling == login.Observer
}

pub fn a_repeated_expiry_takes_the_earlier_instant_test() {
  let parsed_token = parsed(token())
  let earlier = login.append(parsed_token, login.Caveat("e", "1500000"))
  let assert Ok(allowance) = allowed(earlier)
  assert allowance.expires_at_ms == 1_500_000

  // A later instant appended afterwards does not extend it.
  let later = login.append(parsed(earlier), login.Caveat("e", "9999999999"))
  let assert Ok(held) = allowed(later)
  assert held.expires_at_ms == 1_500_000
  assert login.open(root(), later, now_ms: 1_500_000, key: key(), nonce: nonce)
    == Error(login.Expired)
}

pub fn a_session_caveat_narrows_and_two_different_ones_allow_nothing_test() {
  let parsed_token = parsed(token())
  let narrowed = login.append(parsed_token, login.Caveat("s", "0198-abc"))
  let assert Ok(allowance) = allowed(narrowed)
  assert allowance.session == Some("0198-abc")

  let again = login.append(parsed(narrowed), login.Caveat("s", "0198-abc"))
  let assert Ok(same) = allowed(again)
  assert same.session == Some("0198-abc")

  let other = login.append(parsed(narrowed), login.Caveat("s", "0199-def"))
  assert allowed(other) == Error(login.NothingAllowed)
  assert login.verify(root(), parsed(other)) == Ok(Nil)
}

pub fn the_other_caveats_may_not_repeat_with_another_value_test() {
  let parsed_token = parsed(token())
  let repeat = fn(name, value) {
    allowed(login.append(parsed_token, login.Caveat(name, value)))
  }
  assert repeat("p", "owner-2") == Error(login.ConflictingCaveat("p"))
  assert repeat("k", login.fresh_key(fixed(0x01)))
    == Error(login.ConflictingCaveat("k"))
  assert repeat("n", login.nonce_digest("other"))
    == Error(login.ConflictingCaveat("n"))

  // The same value again is no conflict.
  let assert Ok(_) = repeat("p", "owner-1")
  let assert Ok(_) = repeat("k", key())
}

pub fn an_appended_caveat_verifies_against_the_same_root_key_test() {
  let wide = token()
  let narrow = login.append(parsed(wide), login.Caveat("c", "observer"))
  assert narrow != wide
  assert login.verify(root(), parsed(narrow)) == Ok(Nil)
  assert login.id(parsed(narrow)) == id()

  // The appended token opens as the narrower one, on the same row.
  let assert Ok(found) =
    login.open(root(), narrow, now_ms: now, key: key(), nonce: nonce)
  assert found.allowance.ceiling == login.Observer
  assert login.row_digest(found.id) == login.row_digest(id())
}

pub fn the_row_digest_hashes_the_identifiers_text_not_its_bytes_test() {
  let digest = login.row_digest(id())
  let expected =
    crypto.hash(crypto.Sha256, bit_array.from_string(id()))
    |> bit_array.base16_encode
    |> string.lowercase
  assert digest == expected
  assert string.byte_size(digest) == 64

  // The nonce's digest is over its text as well.
  assert login.nonce_digest(nonce)
    == crypto.hash(crypto.Sha256, bit_array.from_string(nonce))
    |> bit_array.base16_encode
    |> string.lowercase
}

// A directory for one root-key test, removed by the test.
fn state_root() -> String {
  let assert Ok(path) =
    bootstrap.absolute_path(
      "build/login-test-"
      <> int.to_string(bootstrap.system_time_ms())
      <> "-"
      <> int.to_string(int.random(1_000_000_000)),
    )
    as "the login fixture has an absolute path"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
  path
}

pub fn a_missing_key_file_is_absent_and_a_written_one_is_kept_test() {
  let directory = state_root()
  assert login.probe_root(directory) == Ok(login.Absent)

  let assert Ok(drawn) = login.write_root(directory, fixed(0x33))
  let assert Ok(text) = simplifile.read(directory <> "/browser.key")
  assert text == string.repeat("33", 32)
  let assert Ok(info) = simplifile.file_info(directory <> "/browser.key")
  assert int.bitwise_and(simplifile.file_info_permissions_octal(info), 0o777)
    == 0o600

  // The next start reads the same key back, and a token the drawn key signed
  // verifies under it.
  let assert Ok(login.Present(kept)) = login.probe_root(directory)
  let minted = login.issue(drawn, id(), minting())
  assert login.verify(kept, parsed(minted)) == Ok(Nil)
  assert simplifile.delete(directory) == Ok(Nil)
}

pub fn a_key_file_that_is_not_the_daemons_private_key_refuses_start_test() {
  let directory = state_root()
  let path = directory <> "/browser.key"

  // Too short, too long, not hex and uppercase hex are each another size or
  // another alphabet, and none is replaced.
  list.each(
    [
      string.repeat("33", 31),
      string.repeat("33", 33),
      string.repeat("zz", 32),
      string.repeat("AA", 32),
      "",
    ],
    fn(contents) {
      let assert Ok(Nil) = bootstrap.atomic_write_private(path, contents)
      let assert Error(_) = login.probe_root(directory)
      assert simplifile.read(path) == Ok(contents)
    },
  )

  // Another reader's access refuses it too.
  let assert Ok(Nil) =
    bootstrap.atomic_write_private(path, string.repeat("33", 32))
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o644)
  let assert Error(_) = login.probe_root(directory)
  assert simplifile.delete(directory) == Ok(Nil)
}

pub fn a_key_file_that_is_a_link_or_a_directory_refuses_start_test() {
  let directory = state_root()
  let path = directory <> "/browser.key"
  let target = directory <> "/elsewhere"
  let assert Ok(Nil) =
    bootstrap.atomic_write_private(target, string.repeat("33", 32))
  let assert Ok(Nil) = simplifile.create_symlink(target, path)
  let assert Error(_) = login.probe_root(directory)
  let assert Ok(Nil) = simplifile.delete(path)
  let assert Ok(Nil) = simplifile.create_directory(path)
  let assert Error(_) = login.probe_root(directory)

  // A dangling link is an entry too, and is not replaced by a fresh key.
  let assert Ok(Nil) = simplifile.delete(path)
  let assert Ok(Nil) = simplifile.create_symlink(directory <> "/nowhere", path)
  let assert Error(_) = login.probe_root(directory)
  assert simplifile.delete(directory) == Ok(Nil)
}

// Every comparison of a signature, a login key or a nonce digest goes through
// `crypto.secure_compare`, never `==`. Equality of two strings cannot tell the
// difference, so a test of behaviour cannot hold this: the source is read, and
// no executable line of it may compare one of those values with `==` or `!=`.
// The module's own comparisons of non-secret values (the reach, a count) are the
// only equalities in it.
pub fn no_secret_is_compared_with_equality_test() {
  let assert Ok(source) = simplifile.read("src/host/login.gleam")
    as "the module's source is readable"
  let code =
    string.split(source, "\n")
    |> list.filter(fn(line) { !string.starts_with(string.trim(line), "//") })

  // The two secret comparisons exist and use the constant-time function.
  assert list.any(code, fn(line) {
    string.contains(line, "crypto.secure_compare(expected, token.signature)")
  })
  assert list.length(
      list.filter(code, fn(line) {
        string.contains(line, "crypto.secure_compare(")
      }),
    )
    >= 2

  // No line compares a signature, a key or a digest with an operator.
  let secret_words = ["signature", "allowance.key", "nonce_digest", "expected"]
  list.each(code, fn(line) {
    let compares =
      string.contains(line, " == ") || string.contains(line, " != ")
    let names = list.any(secret_words, fn(word) { string.contains(line, word) })
    assert !{ compares && names }
  })
}
