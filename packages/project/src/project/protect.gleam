//// Which changed files a project does not let its check run on without a
//// person: the protected paths.
////
//// The check command comes from the project's policy, and it runs the
//// project's own build files: a Makefile, a CI definition, a script. A worker
//// that could edit one of those and then have the check run would be choosing
//// what the host executes. So the host compares the files a worker changed
//// with the project's protected paths before it runs anything, and a change
//// that touches one goes to a person with no check run (`model.PathScope`).
////
//// A pattern is either a literal path or a directory prefix written with a
//// trailing `/**`. There is no regular expression and no other wildcard, so
//// what a pattern covers can be read off it. Matching ignores case, because
//// the machines these projects run on include ones whose file systems do:
//// `makefile` and `Makefile` are one file there, and a protection that a
//// change of case could step around would protect nothing.
////
//// The module is pure. The host reads the changed paths from Git and passes
//// them in, along with the patterns from `[project].protected_paths`.

import gleam/list
import gleam/string
import project/model.{type PathScope}

/// The patterns a project protects when it names none: the build files that
/// `make` reads, and the CI definitions. `GNUmakefile` and `makefile` are
/// here because GNU make reads them ahead of `Makefile`, so a worker that
/// added either would change what `make check` runs without touching
/// `Makefile`.
pub const default_paths: List(String) = [
  "Makefile", "GNUmakefile", "makefile", ".github/**",
]

/// Whether any changed path matches any pattern.
///
/// ## Examples
///
/// ```gleam
/// assert protect.scope(["src/a.go", ".github/workflows/ci.yml"], protect.default_paths)
///   == model.ProtectedPathsTouched
/// ```
///
/// ```gleam
/// assert protect.scope(["src/a.go"], protect.default_paths)
///   == model.ProtectedPathsUntouched
/// ```
pub fn scope(changed: List(String), patterns: List(String)) -> PathScope {
  let touched =
    list.any(changed, fn(path) {
      list.any(patterns, fn(pattern) { matches(path, pattern) })
    })

  // One matching pair is enough, because a single protected file is enough to
  // change what the check runs.
  case touched {
    True -> model.ProtectedPathsTouched
    False -> model.ProtectedPathsUntouched
  }
}

/// Whether a path matches a pattern. A pattern ending in `/**` covers every
/// path beneath that directory; any other pattern covers exactly one path.
///
/// ## Examples
///
/// ```gleam
/// assert protect.matches(".github/workflows/ci.yml", ".github/**")
/// ```
///
/// ```gleam
/// assert !protect.matches("docs/Makefile", "Makefile")
/// ```
pub fn matches(path: String, pattern: String) -> Bool {
  let wanted = normal(pattern)
  let found = normal(path)

  // A directory pattern is a prefix with its slash, so `.github/**` covers
  // `.github/x` and not `.githubx`.
  case string.ends_with(wanted, "/**") {
    True -> string.starts_with(found, string.drop_end(wanted, 2))
    False -> found == wanted
  }
}

/// The patterns the check's own command adds to the configured ones. Every
/// word of the command that is not an option or an assignment is protected as
/// a literal path, so `bash scripts/check.sh` protects `bash` and
/// `scripts/check.sh`, and `make check` protects `make` and `check`. That
/// covers more than the script the command runs, which is the safe side: the
/// words a command is made of are the files it can be pointed at, and a
/// protection that names a file nobody has costs nothing.
///
/// ## Examples
///
/// ```gleam
/// assert protect.with_check(["Makefile"], "bash ./scripts/check.sh --fast")
///   == ["Makefile", "bash", "scripts/check.sh"]
/// ```
pub fn with_check(patterns: List(String), command: String) -> List(String) {
  let named =
    command
    |> string.split(" ")
    |> list.filter(fn(word) {
      word != ""
      && !string.starts_with(word, "-")
      && !string.contains(word, "=")
    })
    |> list.map(normal)
  list.unique(list.append(patterns, named))
}

/// A path or pattern as compared: lower case, with a leading `./` removed.
fn normal(text: String) -> String {
  let lowered = string.lowercase(text)

  // `./Makefile` names the same file as `Makefile`, so the prefix is cut.
  case string.starts_with(lowered, "./") {
    True -> string.drop_start(lowered, 2)
    False -> lowered
  }
}
