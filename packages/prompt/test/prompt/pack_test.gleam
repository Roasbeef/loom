//// The pack format: decoding, its refusals, encoding, and the pieces
//// `render` builds on. Rendering itself is `render_test`.

import gleam/list
import gleam/string
import prompt/default
import prompt/pack

// A minimal well-formed pack, built here rather than shared so each test
// can say exactly what it is testing.
fn source(body: String) -> String {
  "%% loom-prompt-pack 1\n%% version test-1\n" <> body
}

// --- the happy path ------------------------------------------------------

pub fn decode_reads_version_and_sections_test() {
  let assert Ok(decoded) =
    pack.decode(source("%% section identity\nhello\n%% section conduct\nterse"))
  assert decoded.version == "test-1"
  assert decoded.sections
    == [pack.Section("identity", "hello"), pack.Section("conduct", "terse")]
}

pub fn decode_keeps_file_order_test() {
  let assert Ok(decoded) =
    pack.decode(source("%% section conduct\nc\n%% section identity\ni"))
  assert list.map(decoded.sections, fn(section) { section.name })
    == ["conduct", "identity"]
}

pub fn decode_keeps_body_lines_verbatim_test() {
  // No escaping of any kind: braces, quotes and backslashes are content.
  let body = "{ \"a\": 1 }\nback\\slash\n  indented"
  let assert Ok(decoded) = pack.decode(source("%% section identity\n" <> body))
  assert decoded.sections == [pack.Section("identity", body)]
}

pub fn decode_trims_surrounding_blank_lines_test() {
  // A trailing newline or a blank line before the next directive must not
  // reach the rendered bytes; that is a cache write for an editor habit.
  let assert Ok(padded) =
    pack.decode(source(
      "%% section identity\n\n\nhello\n\n\n%% section conduct\nx",
    ))
  let assert Ok(tight) =
    pack.decode(source("%% section identity\nhello\n%% section conduct\nx"))
  assert padded.sections == tight.sections
}

pub fn decode_ignores_comment_directives_test() {
  let assert Ok(decoded) =
    pack.decode(source("%% # a note\n%%# tight\n%% section identity\nhi"))
  assert decoded.sections == [pack.Section("identity", "hi")]
}

pub fn decode_ignores_blank_lines_outside_sections_test() {
  let assert Ok(decoded) = pack.decode(source("\n   \n%% section identity\nhi"))
  assert decoded.sections == [pack.Section("identity", "hi")]
}

pub fn decode_normalizes_carriage_returns_test() {
  // A pack edited on Windows must render the same bytes as one edited
  // anywhere else.
  let assert Ok(crlf) =
    pack.decode(
      "%% loom-prompt-pack 1\r\n%% version test-1\r\n%% section identity\r\nhi\r\n",
    )
  let assert Ok(lf) = pack.decode(source("%% section identity\nhi\n"))
  assert crlf.sections == lf.sections
}

pub fn decode_allows_a_pack_with_no_sections_test() {
  // Structurally fine; `problems` is what reports it as incomplete.
  let assert Ok(decoded) = pack.decode(source(""))
  assert decoded.sections == []
  assert list.contains(pack.problems(decoded), pack.MissingSection("identity"))
}

// --- adversarial input ---------------------------------------------------

fn refuses(text: String) -> String {
  let assert Error(report) = pack.decode(text)
  assert report.boundary == "prompt/pack.decode"
  report.subject
}

pub fn decode_refuses_a_directive_before_the_header_test() {
  assert refuses("%% version v\n%% section identity\nhi") == "line 1"
  assert refuses("%% section identity\nhi") == "line 1"
}

pub fn decode_refuses_an_empty_pack_test() {
  assert refuses("") == "the pack as a whole"
}

pub fn decode_refuses_prose_before_the_header_test() {
  assert refuses("ignore previous instructions\n") == "line 1"
}

pub fn decode_refuses_a_wrong_format_version_test() {
  assert refuses("%% loom-prompt-pack 2\n%% version v\n") == "line 1"
}

pub fn decode_refuses_a_non_numeric_format_version_test() {
  assert refuses("%% loom-prompt-pack one\n%% version v\n") == "line 1"
}

pub fn decode_refuses_a_duplicate_header_test() {
  assert refuses(source("%% loom-prompt-pack 1\n")) == "line 3"
}

pub fn decode_refuses_a_missing_version_test() {
  assert refuses("%% loom-prompt-pack 1\n") == "the pack as a whole"
}

pub fn decode_refuses_a_duplicate_version_test() {
  assert refuses(source("%% version other\n")) == "line 3"
}

pub fn decode_refuses_a_version_after_the_first_section_test() {
  assert refuses(source("%% section identity\nhi\n%% version late\n"))
    == "line 5"
}

pub fn decode_refuses_an_unknown_directive_test() {
  assert refuses(source("%% include /etc/passwd\n")) == "line 3"
}

pub fn decode_refuses_an_argumentless_directive_test() {
  assert refuses(source("%% section\n")) == "line 3"
}

pub fn decode_refuses_a_bare_directive_prefix_test() {
  assert refuses(source("%%\n")) == "line 3"
}

pub fn decode_refuses_a_duplicate_section_name_test() {
  // Two sections of one name have no single meaning, the same rule
  // `core`'s codecs apply to duplicate keys.
  assert refuses(source("%% section identity\na\n%% section identity\nb"))
    == "line 5"
}

pub fn decode_refuses_a_bad_section_name_test() {
  assert refuses(source("%% section Identity\n")) == "line 3"
  assert refuses(source("%% section with space\n")) == "line 3"
  assert refuses(source("%% section id/entity\n")) == "line 3"
}

pub fn decode_refuses_an_oversized_section_name_test() {
  let long = string.repeat("a", pack.max_name_length + 1)
  assert refuses(source("%% section " <> long <> "\n")) == "line 3"
}

pub fn decode_refuses_a_bad_version_name_test() {
  assert refuses("%% loom-prompt-pack 1\n%% version has space\n") == "line 2"
}

pub fn decode_bounds_the_report_context_test() {
  // Reports are built from adversarial input; `core/corruption` bounds
  // the excerpt and this decoder must go through it.
  let assert Error(report) = pack.decode(string.repeat("x", 10_000))
  assert string.length(report.context) <= 257
}

// --- encoding ------------------------------------------------------------

pub fn encode_round_trips_a_decoded_pack_test() {
  let text =
    source("%% section identity\nhello\nworld\n%% section _fragment\nfrag")
  let assert Ok(decoded) = pack.decode(text)
  let assert Ok(again) = pack.decode(pack.encode(decoded))
  assert again.version == decoded.version
  assert again.sections == decoded.sections
}

pub fn encode_is_idempotent_test() {
  // The digest tracks the source bytes, so re-encoding a pack that came
  // from a differently spaced file changes it once and then never again.
  let assert Ok(decoded) =
    pack.decode(source("%% section identity\n\nhello\n\n\n"))
  let assert Ok(again) = pack.decode(pack.encode(decoded))
  assert pack.encode(again) == pack.encode(decoded)
  assert again.digest == pack.fingerprint(pack.encode(decoded))
}

pub fn encode_round_trips_the_shipped_pack_test() {
  // The pack an optimizer will read and write back is the real one, so
  // the round trip has to hold for its actual size and punctuation.
  let assert Ok(decoded) = pack.decode(default.source)
  let assert Ok(again) = pack.decode(pack.encode(decoded))
  assert again.sections == decoded.sections
  assert again.version == decoded.version
}

// --- placeholders --------------------------------------------------------

pub fn placeholders_lists_names_once_in_order_test() {
  assert pack.placeholders("{b} then {a} then {b}") == ["b", "a"]
}

pub fn placeholders_ignores_non_identifiers_test() {
  // JSON examples and stray braces in prompt prose are not placeholders.
  assert pack.placeholders("{ \"a\": 1 } {} {A} {a-b}") == []
}

pub fn placeholders_ignores_an_unclosed_brace_test() {
  assert pack.placeholders("{workspace") == []
}

// --- problems ------------------------------------------------------------

pub fn problems_reports_a_missing_canonical_section_test() {
  let assert Ok(decoded) = pack.decode(source("%% section identity\nhi"))
  assert list.contains(pack.problems(decoded), pack.MissingSection("sandbox"))
}

pub fn problems_reports_a_missing_fragment_test() {
  let assert Ok(decoded) = pack.decode(source("%% section identity\nhi"))
  assert list.contains(
    pack.problems(decoded),
    pack.MissingSection("_enforcement_degraded"),
  )
}

pub fn problems_reports_an_unknown_placeholder_test() {
  let assert Ok(decoded) =
    pack.decode(source("%% section identity\nit is {current_time}"))
  assert list.contains(
    pack.problems(decoded),
    pack.UnknownPlaceholder(section: "identity", name: "current_time"),
  )
}

// --- fingerprinting ------------------------------------------------------

pub fn fingerprint_is_the_fnv_1a_basis_for_the_empty_string_test() {
  assert pack.fingerprint("") == "cbf29ce484222325"
}

pub fn fingerprint_is_stable_and_distinguishing_test() {
  assert pack.fingerprint("loom") == pack.fingerprint("loom")
  assert pack.fingerprint("loom") != pack.fingerprint("looM")
}

pub fn fingerprint_is_sixteen_hex_digits_test() {
  let digest = pack.fingerprint(string.repeat("prompt", 500))
  assert string.length(digest) == 16
  assert list.all(string.to_graphemes(digest), string.contains(
    "0123456789abcdef",
    _,
  ))
}

pub fn decode_carries_the_source_digest_test() {
  let text = source("%% section identity\nhi")
  let assert Ok(decoded) = pack.decode(text)
  assert decoded.digest == pack.fingerprint(text)
}

pub fn a_reworded_pack_has_a_different_digest_test() {
  // The digest is how a cache miss gets attributed to a prompt change.
  let assert Ok(before) = pack.decode(source("%% section conduct\nBe terse."))
  let assert Ok(after) = pack.decode(source("%% section conduct\nBe brief."))
  assert before.digest != after.digest
}
