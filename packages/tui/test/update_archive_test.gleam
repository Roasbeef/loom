import gleam/bit_array
import gleeunit/should
import tui/update/archive
import tui/update/manifest
import tui/update/options

pub fn canonical_release_preserves_executable_and_alias_test() {
  let assert Ok(bytes) =
    bit_array.base64_decode(
      "H4sIAAAAAAAC/+3VwQqCMACH8Z17Cl+g3Nzmrr2KioE0G+iCHj+LCBIigrTC73fZbh4+/tOH0K5j3cdUTEYOnLXXczA+H+7K6eHunNQisWIGxz4W3fBJsUz+3r9sDumP9FfSWPp/oX/hm6Kfpr9zb/TPdG5EksUQPP1n7F+Frt5WPlT7TVkX7Qf758Y876/MqL/WRopEsv/JXTInu+YUj10tsPD9T/Pgvvz/q/H7r7Sx7H8Ot+mvWAIAAAAAAAAAAADw/875b0JNACgAAA==",
    )
    as "fixture is base64"
  archive.decode(bytes, "loom-test")
  |> should.equal(
    Ok([
      archive.Directory(""),
      archive.Directory("bin"),
      archive.Alias("bin/alias", "tool"),
      archive.File("bin/core@clock.beam", <<"beam fixture":utf8>>, archive.Data),
      archive.File("bin/tool", <<"fixture\n":utf8>>, archive.Executable),
    ]),
  )
  archive.decode(bytes, "different-root") |> should.be_error
}

pub fn commit_selection_is_explicit_and_bounded_test() {
  let assert Ok(parsed) = options.parse(["abcdef123", "--install-only"])
    as "valid update selection"
  parsed.selection |> should.equal(options.Commit("abcdef123"))
  parsed.action |> should.equal(options.InstallOnly)
  options.parse(["--commit", "abc"]) |> should.be_error
  options.parse(["--commit", "ABCDEF123"]) |> should.be_error
  options.parse(["v0.3.0", "v0.4.0"]) |> should.be_error
}

pub fn manifest_paths_are_single_basenames_test() {
  manifest.basename("loom-0.2.0-linux-arm64.tar.gz") |> should.be_true
  manifest.basename("../loom") |> should.be_false
  manifest.basename("/loom") |> should.be_false
  manifest.basename(".") |> should.be_false
  manifest.decode("{\"schema\":1,\"schema\":1}") |> should.be_error
}
