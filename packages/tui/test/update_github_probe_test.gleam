//// The release integration driver supplies GitHub metadata and binary assets
//// through a local directory. Production resolution, archive verification and
//// publication run unchanged; this adapter has no network capability.

import argv
import filepath
import gleam/io
import gleam/result
import gleam/string
import host/bootstrap as host
import simplifile
import tui/internal/ffi_terminal
import tui/update
import tui/update/options
import tui/update/source

pub fn main() {
  let outcome = {
    use fixture <- result.try(
      host.getenv("LOOM_UPDATE_FIXTURE_DIR")
      |> result.replace_error("missing fixture directory"),
    )
    use choices <- result.try(options.parse(argv.load().arguments))
    update.run(choices, "linux-x86_64", "/tmp", fn(url, destination, _) {
      use name <- result.try(fixture_name(url))
      let path = fixture <> "/" <> name
      case simplifile.is_file(path) {
        Ok(True) -> {
          use Nil <- result.try(
            simplifile.copy_file(path, destination)
            |> result.map_error(fn(_) { "fixture copy failed" }),
          )
          Ok(source.Present)
        }
        _ -> Ok(source.Absent)
      }
    })
  }
  case outcome {
    Ok(Nil) -> Nil
    Error(reason) -> {
      io.println_error(reason)
      ffi_terminal.halt(1)
    }
  }
}

// Maps each URL the resolver may request to a file in the fixture directory.
// Anything else is an error, so a resolver change that requests a new URL
// fails here instead of silently reading the wrong fixture.
fn fixture_name(url) {
  let api = "https://api.github.com/repos/Roasbeef/loom/"
  let download = "https://github.com/Roasbeef/loom/releases/download/commit-"
  case url {
    _ if url == api <> "commits/main" -> Ok("main.json")
    _ if url == api <> "releases?per_page=30&page=1" -> Ok("releases.json")
    _ ->
      case
        string.starts_with(url, api <> "commits?sha=")
        && string.ends_with(url, "&per_page=30&page=1"),
        string.starts_with(url, download)
      {
        True, _ -> Ok("history.json")
        _, True -> Ok(filepath.base_name(url))
        _, _ -> Error("unexpected fixture URL: " <> url)
      }
  }
}
