//// The host name the Admin page's "This machine" card is titled by
//// (`ffi_os.host_name`, protocol-change/085, the addendum of 2026-10-19): what
//// `inet:gethostname/0` answers is decoded totally, and every shape it does not
//// answer is refused rather than drawn.

import client/internal/ffi_os
import gleam/dynamic
import gleam/erlang/atom
import gleam/list
import gleam/string

// The term `inet:gethostname/0` answers for a host name, given its characters
// as code points.
fn answered(tag: String, characters: List(Int)) -> dynamic.Dynamic {
  dynamic.array([
    atom.to_dynamic(atom.create(tag)),
    dynamic.list(list.map(characters, dynamic.int)),
  ])
}

fn points(text: String) -> List(Int) {
  list.map(string.to_utf_codepoints(text), string.utf_codepoint_to_int)
}

// The machine running the test has a host name, and it is one the decoder
// keeps.
pub fn this_machine_has_a_host_name_test() {
  let assert Ok(name) = ffi_os.host_name()
  assert name != ""
  assert string.byte_size(name) <= ffi_os.host_name_limit
}

// `{ok, Charlist}` is the host name, a non-ASCII one included.
pub fn an_ok_charlist_is_the_host_name_test() {
  assert ffi_os.host_name_of(answered("ok", points("studio"))) == Ok("studio")
  assert ffi_os.host_name_of(answered("ok", points("café-box")))
    == Ok("café-box")
}

// Any other shape is refused: another tag, an empty or overlong name, a
// character that is not a code point, and a term that is not the tuple.
pub fn every_other_shape_is_refused_test() {
  assert ffi_os.host_name_of(answered("error", points("studio"))) == Error(Nil)
  assert ffi_os.host_name_of(answered("ok", [])) == Error(Nil)
  assert ffi_os.host_name_of(answered(
      "ok",
      list.repeat(97, ffi_os.host_name_limit + 1),
    ))
    == Error(Nil)
  assert ffi_os.host_name_of(answered("ok", [0xD800])) == Error(Nil)
  assert ffi_os.host_name_of(answered("ok", [-1])) == Error(Nil)
  assert ffi_os.host_name_of(dynamic.string("studio")) == Error(Nil)
  assert ffi_os.host_name_of(dynamic.nil()) == Error(Nil)
}
