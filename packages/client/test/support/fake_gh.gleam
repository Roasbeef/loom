//// A fake `gh` executable for the tests of project mode's GitHub source.
////
//// Nothing here reaches GitHub. The fake is a shell script that answers a
//// `gh api` call from a file named after the call's path, and logs the
//// arguments of every call it gets. A response file holds exactly what
//// `gh api --include` prints, headers first, so a test controls the status,
//// the rate-limit headers and the body, and a status of 400 or more makes the
//// script exit 1 the way the real one does. A write (`--method POST`) is
//// answered from a file with the prefix `post_`, and its `body=` field is kept.

import client/internal/ffi_os
import client/project_publish
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import host/bootstrap
import simplifile

const script =
  "#!/bin/sh
d=$(dirname \"$0\")
echo \"$*\" >> \"$d/calls\"
method=GET
path=
prev=
for a in \"$@\"; do
  if [ \"$prev\" = --method ]; then method=\"$a\"; fi
  case \"$a\" in
    repos/*|user) path=\"$a\" ;;
    body=*) printf '%s' \"${a#body=}\" > \"$d/body\" ;;
  esac
  prev=\"$a\"
done
name=$(printf '%s' \"$path\" | tr '/' '_')
file=\"$d/resp/$name\"
if [ \"$method\" = POST ]; then
  printf '%s\\n' \"$(echo \"$*\" | tr '\\n' ' ')\" >> \"$d/posts\"
  file=\"$d/resp/post_$name\"
fi
if [ -f \"$file\" ]; then
  cat \"$file\"
  code=$(head -n 1 \"$file\" | cut -d' ' -f2)
  if [ \"$code\" -ge 400 ]; then exit 1; fi
  exit 0
fi
printf 'HTTP/2.0 404 Not Found\\r\\n\\r\\n{}'
exit 1
"

/// A fake `gh` and the directory it keeps its files in.
pub type Fake {
  Fake(
    /// The directory holding the script, `calls`, `posts` and `resp/`.
    directory: String,
    /// The tools a poll or a publish takes, with `gh` set to the fake.
    tools: project_publish.Tools,
  )
}

/// Installs a fake in a directory of its own under `build/`.
///
/// ## Examples
///
/// ```gleam
/// // fake_gh.install("poller")
/// ```
pub fn install(name: String) -> Fake {
  let directory =
    "build/fake-gh-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory <> "/resp")
    as "the fake gh directory is made"
  let assert Ok(directory) = bootstrap.canonical_directory(directory)
    as "the fake gh directory resolves"
  let assert Ok(Nil) = simplifile.write(directory <> "/gh", script)
    as "the fake gh is written"
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(directory <> "/gh", 0o755)
    as "the fake gh is executable"
  Fake(
    directory:,
    tools: project_publish.Tools(
      git: "git",
      env: "/usr/bin/env",
      gh: Some(directory <> "/gh"),
    ),
  )
}

/// Sets the answer to a GET of `path` to a 200 reply with these headers and
/// this body.
///
/// ## Examples
///
/// ```gleam
/// // fake_gh.ok(fake, "repos/o/r/issues", "[]")
/// ```
pub fn ok(fake: Fake, path: String, body: String) -> Nil {
  answer(fake, path, "HTTP/2.0 200 OK", [], body)
}

/// Sets the answer to a GET of `path`: a status line, extra headers and a body.
pub fn answer(
  fake: Fake,
  path: String,
  status: String,
  headers: List(String),
  body: String,
) -> Nil {
  write(fake, file_name(path), status, headers, body)
}

/// Sets the answer to a POST to `path`.
pub fn answer_post(fake: Fake, path: String, body: String) -> Nil {
  write(fake, "post_" <> file_name(path), "HTTP/2.0 201 Created", [], body)
}

fn write(
  fake: Fake,
  name: String,
  status: String,
  headers: List(String),
  body: String,
) -> Nil {
  let head = string.join([status, ..headers], "\r\n")
  let assert Ok(Nil) =
    simplifile.write(
      fake.directory <> "/resp/" <> name,
      head <> "\r\n\r\n" <> body,
    )
    as "the fake gh answer is written"
  Nil
}

fn file_name(path: String) -> String {
  string.replace(path, "/", "_")
}

/// Every call the fake got, one line of arguments each, oldest first.
pub fn calls(fake: Fake) -> List(String) {
  lines(fake.directory <> "/calls")
}

/// Every write the fake got, one line of arguments each, oldest first.
pub fn posts(fake: Fake) -> List(String) {
  lines(fake.directory <> "/posts")
}

/// The `body=` field of the last write, or an empty string.
pub fn last_body(fake: Fake) -> String {
  case simplifile.read(fake.directory <> "/body") {
    Ok(text) -> text
    Error(_) -> ""
  }
}

fn lines(path: String) -> List(String) {
  case simplifile.read(path) {
    Ok(text) -> string.split(text, "\n") |> list.filter(fn(line) { line != "" })
    Error(_) -> []
  }
}
