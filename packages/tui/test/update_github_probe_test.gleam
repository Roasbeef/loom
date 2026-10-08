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

fn fixture_name(url) {
  case url {
    "https://api.github.com/repos/Roasbeef/loom/commits/main" -> Ok("main.json")
    "https://api.github.com/repos/Roasbeef/loom/releases?per_page=30&page=1" ->
      Ok("releases.json")
    _ -> {
      case
        string.starts_with(
          url,
          "https://api.github.com/repos/Roasbeef/loom/commits?sha=",
        )
      {
        True -> Ok("history.json")
        False -> {
          case
            string.starts_with(
              url,
              "https://github.com/Roasbeef/loom/releases/download/commit-",
            )
          {
            True -> Ok(filepath.base_name(url))
            False -> Error("unexpected fixture URL: " <> url)
          }
        }
      }
    }
  }
}
