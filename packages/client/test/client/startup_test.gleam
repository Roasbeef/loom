//// Native loading remains an optional optimization: its reply is decoded
//// totally, missing modules cannot poison ordinary loading, and the fixed
//// inventory can be offered repeatedly without another application cache.

import client/internal/ffi_code
import client/startup
import gleam/dynamic
import gleam/erlang/atom
import gleam/list

pub fn native_ok_atom_is_success_test() {
  assert ffi_code.decode_reply(word("ok")) == Ok(Nil)
}

pub fn documented_native_failure_is_distinct_test() {
  let reply =
    dynamic.array([
      word("error"),
      dynamic.list([dynamic.array([word("missing"), word("nofile")])]),
    ])
  assert ffi_code.decode_reply(reply) == Error(ffi_code.Unavailable)
}

pub fn malformed_native_values_are_total_test() {
  let malformed = [
    dynamic.nil(),
    dynamic.int(42),
    dynamic.string("ok"),
    word("error"),
    dynamic.array([word("ok"), dynamic.nil()]),
    dynamic.array([word("error")]),
    dynamic.array([word("error"), dynamic.string("nofile")]),
    dynamic.array([word("error"), dynamic.list([dynamic.int(1)])]),
    dynamic.array([
      word("error"),
      dynamic.list([dynamic.array([word("missing"), dynamic.string("nofile")])]),
    ]),
    dynamic.list([word("error"), dynamic.list([])]),
    dynamic.properties([
      #(dynamic.int(0), word("error")),
      #(dynamic.int(1), dynamic.list([])),
    ]),
  ]
  list.each(malformed, fn(reply) {
    assert ffi_code.decode_reply(reply) == Error(ffi_code.UnexpectedReply)
  })
}

pub fn extra_failure_fields_still_reject_the_batch_test() {
  let reply =
    dynamic.array([
      word("error"),
      dynamic.list([
        dynamic.array([word("missing"), word("nofile"), dynamic.nil()]),
      ]),
      dynamic.nil(),
    ])
  assert ffi_code.decode_reply(reply) == Error(ffi_code.Unavailable)
}

pub fn missing_module_preserves_subsequent_loading_test() {
  assert ffi_code.ensure_loaded([
      atom.create("loom_startup_fixture_deliberately_missing"),
    ])
    == Error(ffi_code.Unavailable)
  assert ffi_code.ensure_loaded([atom.create("client@startup")]) == Ok(Nil)
  assert startup.prepare() == Nil
}

pub fn repeated_fixed_inventory_loads_through_otp_test() {
  let modules = startup.modules()
  assert list.length(modules) == 25
  assert list.length(list.unique(modules)) == 25
  assert ffi_code.ensure_loaded(modules) == Ok(Nil)
  assert ffi_code.ensure_loaded(modules) == Ok(Nil)
  assert startup.prepare() == Nil
}

fn word(name: String) -> dynamic.Dynamic {
  atom.to_dynamic(atom.create(name))
}
