//// The state object needs no repository and no process: its codec, its
//// validation, the thin-or-full choice and the bundle header comparison are
//// all functions of their arguments.

import client/state_object.{Clean, Dirty, Full, State, Thin}
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const tip = "0123456789abcdef0123456789abcdef01234567"

const base = "89abcdef0123456789abcdef0123456789abcdef"

const other = "fedcba9876543210fedcba9876543210fedcba98"

fn state() -> state_object.State {
  State(
    hash: state_object.hash_of(<<"a bundle":utf8>>),
    size: 8,
    tip:,
    base: Some(base),
    dirty: Dirty,
  )
}

fn header_text(prerequisites: List(String), refs: List(String)) -> BitArray {
  let lines =
    string.join(["# v2 git bundle", ..list.append(prerequisites, refs)], "\n")
  bit_array.from_string(lines <> "\n\nPACK\u{0}\u{1}binary")
}

pub fn the_hash_is_the_lower_case_sha256_of_the_bytes_test() {
  assert state_object.hash_of(<<>>)
    == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  assert state_object.hash_of(<<"abc":utf8>>)
    == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
}

pub fn a_state_round_trips_through_its_json_test() {
  assert state_object.decode(state_object.encode(state())) == Ok(state())
  let full = State(..state(), base: None, dirty: Clean)
  assert state_object.decode(state_object.encode(full)) == Ok(full)
  assert string.contains(state_object.encode(full), "\"base\":null")
  assert string.contains(state_object.encode(full), "\"dirty\":false")
}

pub fn a_state_without_a_base_field_is_a_full_state_test() {
  let text =
    "{\"hash\":\""
    <> state().hash
    <> "\",\"size\":8,\"tip\":\""
    <> tip
    <> "\",\"dirty\":true}"
  assert state_object.decode(text) == Ok(State(..state(), base: None))
}

pub fn decoding_refuses_text_that_is_not_a_state_test() {
  assert state_object.decode("{}") == Error("the text is not a state object")
  assert state_object.decode("[]") == Error("the text is not a state object")
  assert state_object.decode("not json")
    == Error("the text is not a state object")
  let wrong_type =
    "{\"hash\":1,\"size\":8,\"tip\":\"" <> tip <> "\",\"dirty\":true}"
  assert state_object.decode(wrong_type)
    == Error("the text is not a state object")
  let dirty_string =
    "{\"hash\":\""
    <> state().hash
    <> "\",\"size\":8,\"tip\":\""
    <> tip
    <> "\",\"dirty\":\"yes\"}"
  assert state_object.decode(dirty_string)
    == Error("the text is not a state object")
}

pub fn validation_refuses_values_a_path_or_command_could_not_use_test() {
  assert state_object.validate(state()) == Ok(state())
  assert state_object.validate(State(..state(), hash: "../../etc/passwd"))
    == Error("the state's hash is not a SHA-256")
  assert state_object.validate(
      State(..state(), hash: string.uppercase(state().hash)),
    )
    == Error("the state's hash is not a SHA-256")
  assert state_object.validate(State(..state(), size: 0))
    == Error("the state's size is not positive")
  assert state_object.validate(State(..state(), size: -3))
    == Error("the state's size is not positive")
  assert state_object.validate(State(..state(), tip: "HEAD"))
    == Error("the state's tip is not a full object id")
  assert state_object.validate(State(..state(), tip: "--upload-pack=x"))
    == Error("the state's tip is not a full object id")
  assert state_object.validate(State(..state(), base: Some("abc")))
    == Error("the state's base is not a full object id")
}

pub fn decoding_applies_the_same_validation_test() {
  let text =
    state_object.encode(State(..state(), hash: "not-a-hash-but-is-a-string"))
  assert state_object.decode(text) == Error("the state's hash is not a SHA-256")
}

pub fn object_ids_are_forty_or_sixty_four_lower_case_hex_digits_test() {
  assert state_object.is_object_id(tip)
  assert state_object.is_object_id(string.repeat("a", 64))
  assert !state_object.is_object_id(string.repeat("a", 41))
  assert !state_object.is_object_id(string.uppercase(tip))
  assert !state_object.is_object_id("")
  assert !state_object.is_object_id(string.repeat("g", 40))
}

pub fn the_incoming_ref_is_named_for_the_first_eight_digits_test() {
  let hash = state().hash
  assert state_object.short(hash) == string.slice(hash, 0, 8)
  assert state_object.incoming_ref(hash)
    == "refs/loom/in/" <> string.slice(hash, 0, 8)
  assert string.starts_with(state_object.incoming_ref(hash), "refs/loom/in/")
}

pub fn the_newest_candidate_the_receiver_holds_becomes_the_base_test() {
  assert state_object.choose_basis([tip, base, other], [other, base])
    == Thin(base)
  assert state_object.choose_basis([tip, base, other], [tip, other])
    == Thin(tip)
}

pub fn a_receiver_that_holds_no_candidate_gets_a_full_bundle_test() {
  assert state_object.choose_basis([tip, base], []) == Full
  assert state_object.choose_basis([tip, base], [other]) == Full
  assert state_object.choose_basis([], [tip]) == Full
}

pub fn a_full_bundle_header_has_no_prerequisites_test() {
  let assert Ok(header) =
    state_object.parse_header(
      header_text([], [tip <> " " <> state_object.bundle_ref]),
    )
  assert header.prerequisites == []
  assert header.refs == [#(tip, state_object.bundle_ref)]
}

pub fn a_thin_bundle_header_lists_its_prerequisites_test() {
  let assert Ok(header) =
    state_object.parse_header(
      header_text(["-" <> base <> " first", "-" <> other], [
        tip <> " " <> state_object.bundle_ref,
      ]),
    )
  assert header.prerequisites == [base, other]
  assert header.refs == [#(tip, state_object.bundle_ref)]
}

pub fn a_version_three_header_may_name_the_object_format_only_test() {
  let sha1 =
    bit_array.from_string(
      "# v3 git bundle\n@object-format=sha1\n"
      <> tip
      <> " "
      <> state_object.bundle_ref
      <> "\n\nPACK",
    )
  let assert Ok(header) = state_object.parse_header(sha1)
  assert header.refs == [#(tip, state_object.bundle_ref)]
  let filtered =
    bit_array.from_string(
      "# v3 git bundle\n@filter=blob:none\n"
      <> tip
      <> " "
      <> state_object.bundle_ref
      <> "\n\nPACK",
    )
  assert state_object.parse_header(filtered)
    == Error("the bundle uses a capability apply does not accept")
}

pub fn a_prerequisite_may_carry_a_subject_in_any_bytes_test() {
  // The bundle writer puts the base commit's subject after its id, as the
  // author wrote it.
  let subject = "Fix \u{2014} the \u{e9} thing \u{1f600}"
  let utf8 =
    bit_array.from_string(
      "# v2 git bundle\n-"
      <> base
      <> " "
      <> subject
      <> "\n"
      <> tip
      <> " "
      <> state_object.bundle_ref
      <> "\n\nPACK",
    )
  let assert Ok(header) = state_object.parse_header(utf8)
  assert header.prerequisites == [base]
  assert header.refs == [#(tip, state_object.bundle_ref)]

  // A subject in an encoding that is not UTF-8 is still only a comment.
  let latin1 = <<
    "# v2 git bundle\n-":utf8,
    base:utf8,
    " caf":utf8,
    233,
    "\n":utf8,
    tip:utf8,
    " ":utf8,
    state_object.bundle_ref:utf8,
    "\n\nPACK":utf8,
  >>
  let assert Ok(header) = state_object.parse_header(latin1)
  assert header.prerequisites == [base]
}

pub fn headers_that_are_not_bundles_are_refused_test() {
  assert state_object.parse_header(<<>>)
    == Error("the bundle header is truncated or malformed")
  assert state_object.parse_header(<<"not a bundle\n\n":utf8>>)
    == Error("the file is not a Git bundle")
  assert state_object.parse_header(<<"\n":utf8>>)
    == Error("the file is not a Git bundle")

  // A header with no empty line before the bytes end is truncated.
  assert state_object.parse_header(<<"# v2 git bundle\n":utf8>>)
    == Error("the bundle header is truncated or malformed")

  // A ref line must be text, so bytes that are not UTF-8 on one are refused.
  assert state_object.parse_header(<<
      "# v2 git bundle\n":utf8,
      tip:utf8,
      " refs/x":utf8,
      200,
      "\n\n":utf8,
    >>)
    == Error("a bundle ref line is malformed")
  assert state_object.parse_header(bit_array.from_string(
      "# v2 git bundle\n-nothex x\n\n",
    ))
    == Error("a bundle prerequisite is not an object id")
  assert state_object.parse_header(bit_array.from_string(
      "# v2 git bundle\nnothex refs/x\n\n",
    ))
    == Error("a bundle ref line is malformed")
}

pub fn a_header_agrees_with_the_state_it_describes_test() {
  let thin = state_object.Header([base], [#(tip, state_object.bundle_ref)])
  assert state_object.agrees(state(), thin) == Ok(Nil)
  let full = state_object.Header([], [#(tip, state_object.bundle_ref)])
  assert state_object.agrees(State(..state(), base: None), full) == Ok(Nil)
}

pub fn a_header_that_contradicts_the_state_is_refused_test() {
  let thin = state_object.Header([base], [#(tip, state_object.bundle_ref)])
  let full = state_object.Header([], [#(tip, state_object.bundle_ref)])

  // A state that says it is thin cannot be given a full bundle, nor the other
  // way round.
  assert state_object.agrees(state(), full)
    == Error("the state declares a base but the bundle is full")
  assert state_object.agrees(State(..state(), base: None), thin)
    == Error(
      "the state declares a full bundle but the bundle has prerequisites",
    )

  // The bundle's one ref must be at the declared tip, under the fixed name.
  assert state_object.agrees(State(..state(), tip: other), thin)
    == Error("the bundle's ref is not the state's tip")
  assert state_object.agrees(
      state(),
      state_object.Header([base], [#(tip, "refs/heads/main")]),
    )
    == Error("the bundle's ref is not the state's tip")
  assert state_object.agrees(state(), state_object.Header([base], []))
    == Error("the bundle must carry exactly one ref")
  assert state_object.agrees(
      state(),
      state_object.Header([base], [
        #(tip, state_object.bundle_ref),
        #(other, "refs/heads/extra"),
      ]),
    )
    == Error("the bundle must carry exactly one ref")
}

pub fn verifying_a_bundle_checks_size_then_hash_then_header_test() {
  let bytes = header_text([], [tip <> " " <> state_object.bundle_ref])
  let size = bit_array.byte_size(bytes)
  let good =
    State(
      hash: state_object.hash_of(bytes),
      size:,
      tip:,
      base: None,
      dirty: Clean,
    )
  assert state_object.verify_bundle(good, bytes) == Ok(Nil)

  // A file cut short fails on its size before anything is hashed.
  let assert Ok(cut) = bit_array.slice(bytes, 0, size - 3)
  assert state_object.verify_bundle(good, cut)
    == Error(
      "the bundle is "
      <> string.inspect(size - 3)
      <> " bytes but the state declares "
      <> string.inspect(size),
    )

  // The same length with other bytes fails on the hash.
  let changed = bit_array.append(cut, <<"xyz":utf8>>)
  assert state_object.verify_bundle(good, changed)
    == Error("the bundle's SHA-256 is not the state's hash")

  // Whole bytes that are not the described bundle fail on the header.
  assert state_object.verify_bundle(State(..good, tip: other), bytes)
    == Error("the bundle's ref is not the state's tip")
  assert state_object.verify_bundle(State(..good, base: Some(base)), bytes)
    == Error("the state declares a base but the bundle is full")
}
