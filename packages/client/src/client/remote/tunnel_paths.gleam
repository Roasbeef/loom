//// Whether a tunnelled call names only plain paths (protocol-change/117).
////
//// The executor clears a tunnelled call under the meet of its plane's base
//// with the orchestrator's, and the meet compares roots as text: a root is
//// kept when one of the plane's roots is a component prefix of it. A root
//// spelled `/w/..` is therefore kept under a plane root `/w`, and the helper
//// cleans it to `/` when it builds the jail, which would give the call more
//// than the plane holds. The gateway refuses such a call before it clears it,
//// and this module is the test it applies: every readable and writable root
//// of the spec's base policy and requirements must be absolute and made of
//// plain segments, so its text is what the helper binds.
////
//// The other path-bearing fields are not checked, because no spelling of
//// them can give a call more than the plane holds, and checking them would
//// refuse honest calls whose census base carries an unplain protected path
//// (a daemon whose `HOME` is `/` masks `//.loom/vm`). In `policy.meet` the
//// protected paths are a union, so a spec only adds masks; a mount is kept
//// only when its path equals one of the base's exactly; the scratch is the
//// base's own or a fresh tmpfs; and the working directory is not part of the
//// policy and binds nothing.
////
//// `plain` judges one path, and `plain_spec` the roots of a spec.

import broker/policy.{type SandboxPolicy}
import gleam/bit_array
import gleam/list
import gleam/result

/// Whether `path` is absolute and made of plain segments: no `.`, no `..` and
/// no empty segment, so no `//` and no trailing `/` other than the root. Such
/// a path is unchanged by lexical cleaning.
///
/// The test reads bytes, as the meet's prefix test and the helper's cleaning
/// do. A split of the text would match grapheme clusters, and a slash
/// followed by a combining mark is one cluster, so `/w/../\u{301}x` would
/// pass as two segments while the helper cleans it to `/\u{301}x`.
///
/// ## Examples
///
/// ```gleam
/// assert tunnel_paths.plain("/work/src")
/// assert !tunnel_paths.plain("/work/..")
/// assert !tunnel_paths.plain("work")
/// ```
pub fn plain(path: String) -> Bool {
  // The root alone is plain; anything else is a slash and plain segments.
  case bit_array.from_string(path) {
    <<"/">> -> True
    <<"/", rest:bits>> -> plain_segments(rest, <<>>)
    _relative -> False
  }
}

/// Whether the bytes after a slash are plain segments, with `segment` the
/// bytes of the segment read so far.
fn plain_segments(bytes: BitArray, segment: BitArray) -> Bool {
  // A slash or the end closes a segment, which must be plain; any other byte
  // joins it.
  case bytes {
    <<>> -> plain_segment(segment)
    <<"/", rest:bits>> -> plain_segment(segment) && plain_segments(rest, <<>>)
    <<byte, rest:bits>> -> plain_segments(rest, <<segment:bits, byte>>)
    _unaligned -> False
  }
}

/// Whether one segment's bytes are neither empty, `.` nor `..`.
fn plain_segment(segment: BitArray) -> Bool {
  segment != <<>> && segment != <<".">> && segment != <<"..">>
}

/// Every readable and writable root of a tunnelled call's base policy and
/// requirements is plain; otherwise the reason names the first field that is
/// not.
///
/// ## Examples
///
/// ```gleam
/// // tunnel_paths.plain_spec(spec.base_policy, spec.requirements)
/// ```
pub fn plain_spec(
  base_policy: SandboxPolicy,
  requirements: SandboxPolicy,
) -> Result(Nil, String) {
  use Nil <- result.try(plain_roots(base_policy, "base policy"))
  plain_roots(requirements, "requirements")
}

/// The two root lists of one policy, the only fields the meet keeps by a
/// prefix test.
fn plain_roots(policy: SandboxPolicy, named: String) -> Result(Nil, String) {
  use Nil <- result.try(each_plain(
    policy.writable_roots,
    named <> " writable root",
  ))
  each_plain(policy.readable_roots, named <> " readable root")
}

/// Whether every path of `paths` is plain, naming the field when one is not.
fn each_plain(paths: List(String), field: String) -> Result(Nil, String) {
  // The offending path is not repeated: it is the sender's text.
  case list.all(paths, plain) {
    True -> Ok(Nil)
    False -> Error("a " <> field <> " is not a plain absolute path")
  }
}
