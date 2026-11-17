//// Whether a tunnelled call names only plain paths (protocol-change/117).
////
//// The executor clears a tunnelled call under the meet of its plane's base
//// with the orchestrator's, and the meet compares roots as text: a root is
//// kept when one of the plane's roots is a component prefix of it. A root
//// spelled `/w/..` is therefore kept under a plane root `/w`, and the helper
//// cleans it to `/` when it builds the jail, which would give the call more
//// than the plane holds. The gateway refuses such a call before it clears it,
//// and this module is the test it applies: every path the meet or the jail
//// reads must be absolute and made of plain segments, so its text is what the
//// helper binds.
////
//// `plain` judges one path, and `plain_spec` every path-bearing field of a
//// spec's base policy and requirements, and its working directory.

import broker/policy.{type SandboxPolicy}
import gleam/list
import gleam/result
import gleam/string

/// Whether `path` is absolute and made of plain segments: no `.`, no `..` and
/// no empty segment, so no `//` and no trailing `/` other than the root. Such
/// a path is unchanged by lexical cleaning.
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
  case path {
    "/" -> True
    "/" <> rest ->
      string.split(rest, "/")
      |> list.all(fn(segment) {
        segment != "" && segment != "." && segment != ".."
      })
    _relative -> False
  }
}

/// Every path a tunnelled call's spec names, with the field it is in, is
/// plain; otherwise the reason names the first one that is not.
///
/// ## Examples
///
/// ```gleam
/// // tunnel_paths.plain_spec(spec.base_policy, spec.requirements, spec.cwd)
/// ```
pub fn plain_spec(
  base_policy: SandboxPolicy,
  requirements: SandboxPolicy,
  cwd: String,
) -> Result(Nil, String) {
  use Nil <- result.try(plain_policy(base_policy, "base policy"))
  use Nil <- result.try(plain_policy(requirements, "requirements"))
  each_plain([cwd], "working directory")
}

/// Every path of one policy: its roots, its protected paths, its mounts and a
/// scratch directory bound from the host.
fn plain_policy(policy: SandboxPolicy, named: String) -> Result(Nil, String) {
  // Only a scratch bound from the host names a path; a tmpfs names none.
  let scratch = case policy.scratch {
    policy.ScratchPath(path:) -> [path]
    policy.ScratchTmpfs -> []
  }

  use Nil <- result.try(each_plain(
    policy.writable_roots,
    named <> " writable root",
  ))
  use Nil <- result.try(each_plain(
    policy.readable_roots,
    named <> " readable root",
  ))
  use Nil <- result.try(each_plain(policy.protected, named <> " protected path"))
  use Nil <- result.try(each_plain(
    list.map(policy.mounts, fn(mount) { mount.path }),
    named <> " mount",
  ))
  each_plain(scratch, named <> " scratch")
}

/// Whether every path of `paths` is plain, naming the field when one is not.
fn each_plain(paths: List(String), field: String) -> Result(Nil, String) {
  // The offending path is not repeated: it is the sender's text.
  case list.all(paths, plain) {
    True -> Ok(Nil)
    False -> Error("a " <> field <> " is not a plain absolute path")
  }
}
