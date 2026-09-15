//// Process entry point for the offline updater integration test. Its source
//// adapter refuses network access, so a local fixture cannot reach GitHub.

import argv
import gleam/io
import gleam/result
import tui/internal/ffi_terminal
import tui/update
import tui/update/options

pub fn main() {
  let outcome = {
    use choices <- result.try(options.parse(argv.load().arguments))
    update.run(choices, "linux-x86_64", "/tmp", fn(_, _, _) {
      Error("offline fixture attempted a network fetch")
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
