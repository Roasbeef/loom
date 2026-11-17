//// The plain-path test a tunnelled call's spec passes (protocol-change/117).
////
//// A path `tunnel_paths.plain` accepts must be one the helper binds as it is
//// spelled: lexical cleaning, which is what the helper applies, leaves it
//// unchanged. The property draws paths from segments that include `.`, `..`
//// and empty ones, and the cases name each spelling the gateway refuses.

import broker/policy
import client/remote/tunnel_paths
import client/workspace_policy
import gleam/bit_array
import gleam/list
import gleam/string
import qcheck

// Cleans a path as Go's `filepath.Clean` does for an absolute path, on bytes
// as the helper does: empty and `.` segments go, and `..` removes the segment
// before it, or nothing at the root.
fn cleaned(path: String) -> String {
  let kept =
    byte_segments(bit_array.from_string(path), <<>>, [])
    |> list.fold([], fn(kept, segment) {
      case segment, kept {
        <<>>, _ | <<".">>, _ -> kept
        <<"..">>, [] -> []
        <<"..">>, [_, ..rest] -> rest
        other, _ -> [other, ..kept]
      }
    })
  let joined =
    list.reverse(kept)
    |> list.intersperse(<<"/">>)
    |> bit_array.concat
  let assert Ok(text) = bit_array.to_string(<<"/", joined:bits>>)
    as "a cleaned path is text"
  text
}

// The segments between slash bytes, in order.
fn byte_segments(
  bytes: BitArray,
  current: BitArray,
  done: List(BitArray),
) -> List(BitArray) {
  case bytes {
    <<>> -> list.reverse([current, ..done])
    <<"/", rest:bits>> -> byte_segments(rest, <<>>, [current, ..done])
    <<byte, rest:bits>> -> byte_segments(rest, <<current:bits, byte>>, done)
    _ -> list.reverse([current, ..done])
  }
}

fn paths() -> qcheck.Generator(String) {
  let segment =
    qcheck.from_generators(qcheck.return("w"), [
      qcheck.return("src"),
      qcheck.return("."),
      qcheck.return(".."),
      qcheck.return(""),
      qcheck.return("a.b"),
      qcheck.return("..x"),
      // A combining mark joins the slash before it into one grapheme cluster,
      // which a split of the text would not cut at.
      qcheck.return("\u{301}x"),
      qcheck.return("..\u{301}"),
      qcheck.return("\u{301}"),
    ])
  let lead =
    qcheck.from_weighted_generators(#(9, qcheck.return("/")), [
      #(1, qcheck.return("")),
    ])
  qcheck.map2(lead, qcheck.list_from(segment), fn(lead, segments) {
    lead <> string.join(segments, "/")
  })
}

pub fn a_plain_path_is_unchanged_by_cleaning_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(2000)
    |> qcheck.with_seed(qcheck.seed(1171))
  qcheck.run(config, paths(), fn(path) {
    case tunnel_paths.plain(path) {
      True -> {
        assert cleaned(path) == path
        Nil
      }
      False -> Nil
    }
  })
}

pub fn each_unplain_spelling_is_refused_test() {
  assert tunnel_paths.plain("/")
  assert tunnel_paths.plain("/w/src")
  assert tunnel_paths.plain("/w/..x/a.b")
  assert !tunnel_paths.plain("/w/..")
  assert !tunnel_paths.plain("/w/../etc")
  assert !tunnel_paths.plain("/w/./x")
  assert !tunnel_paths.plain("/w//x")
  assert !tunnel_paths.plain("/w/")
  assert !tunnel_paths.plain("w")
  assert !tunnel_paths.plain("")

  // A slash followed by a combining mark is one grapheme cluster but still a
  // slash byte, and the helper cleans by bytes.
  assert !tunnel_paths.plain("/w/../\u{301}x")
  assert !tunnel_paths.plain("/w/./\u{301}x")
  assert !tunnel_paths.plain("/w//\u{301}x")
  assert tunnel_paths.plain("/w/\u{301}x")
}

// Every path-bearing field of either policy, and the working directory, is
// checked.
pub fn every_path_field_of_a_spec_is_checked_test() {
  let base = workspace_policy.base_policy("/w")
  let bad = "/w/.."
  assert tunnel_paths.plain_spec(base, base, "/w") == Ok(Nil)
  let spoiled = [
    policy.SandboxPolicy(..base, writable_roots: [bad]),
    policy.SandboxPolicy(..base, readable_roots: [bad]),
    policy.SandboxPolicy(..base, protected: [bad]),
    policy.SandboxPolicy(..base, scratch: policy.ScratchPath(bad)),
    policy.SandboxPolicy(..base, mounts: [
      policy.Mount(
        path: bad,
        access: policy.MountReadOnly,
        requirement: policy.MountRequired,
      ),
    ]),
  ]
  list.each(spoiled, fn(spoilt) {
    let assert Error(_) = tunnel_paths.plain_spec(spoilt, base, "/w")
      as "a base policy field is checked"
    let assert Error(_) = tunnel_paths.plain_spec(base, spoilt, "/w")
      as "a requirements field is checked"
    Nil
  })
  let assert Error(_) = tunnel_paths.plain_spec(base, base, "/w/../etc")
    as "the working directory is checked"
  Nil
}
