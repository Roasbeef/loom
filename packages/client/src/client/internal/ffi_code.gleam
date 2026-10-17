//// OTP's code server can batch independent module loads before session
//// assembly reaches them one at a time. Neither gleam_erlang nor weft exposes
//// `code:ensure_modules_loaded/1`, so this boundary binds directly to stock
//// OTP without an Erlang shim. It creates no processes or custom load cache.
////
//// OTP returns `ok` or `{error, [{Module, Reason}]}`, not a Gleam Result.
//// Reading that reply is total; the caller decides whether loading is required
//// or merely an optional startup hint. Module atoms must come from trusted,
//// bounded application code, never configuration or model input.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}

/// A rejected batch and an unrecognized native reply remain distinguishable.
pub type LoadError {
  /// OTP could not load one or more requested modules.
  Unavailable

  /// The native reply supplied neither success nor the expected failure fields.
  UnexpectedReply
}

@external(erlang, "code", "ensure_modules_loaded")
fn native_ensure_loaded(modules: List(Atom)) -> Dynamic

/// Loads a trusted, bounded set through OTP's existing code cache. Modules
/// already present are left alone; a failed batch does not disable autoload.
///
/// ## Examples
///
/// ```gleam
/// ffi_code.ensure_loaded([]) // -> Ok(Nil)
/// ```
pub fn ensure_loaded(modules: List(Atom)) -> Result(Nil, LoadError) {
  decode_reply(native_ensure_loaded(modules))
}

/// Reads OTP's reply without treating a bare `ok` atom as a Gleam Result.
/// Failure fields are checked; extra tuple fields are immaterial because a
/// rejected batch and an unexpected reply both retain the lazy fallback.
///
/// ## Examples
///
/// ```gleam
/// ffi_code.decode_reply(atom.to_dynamic(atom.create("ok"))) // -> Ok(Nil)
/// ```
@internal
pub fn decode_reply(reply: Dynamic) -> Result(Nil, LoadError) {
  case decode.run(reply, atom.decoder()) {
    Ok(word) ->
      case atom.to_string(word) {
        "ok" -> Ok(Nil)
        _ -> Error(UnexpectedReply)
      }
    Error(_) -> {
      let failure = {
        use tag <- decode.field(0, atom.decoder())
        use _modules <- decode.field(1, decode.list(module_failure()))
        decode.success(atom.to_string(tag))
      }
      case dynamic.classify(reply), decode.run(reply, failure) {
        "Array", Ok("error") -> Error(Unavailable)
        _, _ -> Error(UnexpectedReply)
      }
    }
  }
}

fn module_failure() -> decode.Decoder(Nil) {
  use _module <- decode.field(0, atom.decoder())
  use _reason <- decode.field(1, atom.decoder())
  decode.success(Nil)
}
