//// Skill metadata chooses discovery and invocation; bodies stay exact data.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import host/skill
import simplifile

fn document(name: String, description: String, body: String) -> String {
  "---\nname: " <> name <> "\ndescription: " <> description <> "\n---\n" <> body
}

pub fn metadata_formats_preserve_every_body_test() {
  let descriptions = [
    #("Plain description # comment", "Plain description"),
    #("\"Quoted  café # value\"", "Quoted  café # value"),
    #("'It''s quoted'", "It's quoted"),
    #(">\n  First line\n  second line", "First line second line"),
  ]
  let bodies = [
    "Keep this.\n",
    "\n# Heading\r\n!`do-not-run`\n",
    "$ARGUMENTS $5\n",
  ]
  list.each(descriptions, fn(description) {
    list.each(bodies, fn(body) {
      let assert Ok(loaded) =
        skill.parse(
          "/skills/example/SKILL.md",
          document("example", description.0, body),
        )
        as "supported scalars parse without rewriting the Markdown body"
      assert loaded.description == description.1
      assert loaded.body == body
      assert loaded.user_invocation == skill.UserInvocable
      assert loaded.model_invocation == skill.ModelSelectable
    })
  })
}

pub fn invalid_metadata_is_refused_test() {
  let bad = [
    "---\nname: valid\n---\nBody.",
    document("../escape", "Description", "Body."),
    document("Upper", "Description", "Body."),
    document("two--hyphens", "Description", "Body."),
    document("valid", "Description\nname: duplicate", "Body."),
    document("valid", "Description\nuser-invocable: maybe", "Body."),
    document("valid", "Description", string.repeat("x", skill.max_file_bytes)),
  ]
  list.each(bad, fn(text) {
    let assert Error(_) = skill.parse("/skills/valid/SKILL.md", text)
      as "a malformed supported field refuses its document"
  })
}

pub fn invocation_flags_and_literal_arguments_test() {
  let assert Ok(loaded) =
    skill.parse(
      "/skills/example/SKILL.md",
      document(
        "example",
        "Description\nuser-invocable: false\ndisable-model-invocation: true\nallowed-tools: Bash\ncontext: fork",
        "Use $ARGUMENTS, keep $5 and !`shell`.",
      ),
    )
    as "foreign execution metadata stays inert"
  assert loaded.user_invocation == skill.HiddenFromCommands
  assert loaded.model_invocation == skill.ExplicitOnly
  let assert Ok(expanded) = skill.expand(loaded, "the queue")
    as "invocation substitutes arguments into the activated document"
  assert string.starts_with(
    expanded,
    "/example the queue\n\nSkill instructions from \"/skills/example/SKILL.md\":\n\n---\n",
  )
  assert string.contains(expanded, "allowed-tools: Bash")
  assert string.ends_with(expanded, "Use the queue, keep $5 and !`shell`.")
  assert skill.directories(None) == []
  assert list.length(skill.directories(Some("/home/example"))) == 4
}

pub fn discovery_deduplicates_aliases_and_captures_bodies_test() {
  let assert Ok(root) =
    bootstrap.absolute_path(
      "build/skills-"
      <> int.to_string(bootstrap.system_time_ms())
      <> "-"
      <> int.to_string(int.random(1_000_000_000)),
    )
    as "the fixture has its own absolute root"
  let first = root <> "/first"
  let second = root <> "/second"
  assert simplifile.create_directory_all(first <> "/sample") == Ok(Nil)
  assert simplifile.create_directory_all(second <> "/sample") == Ok(Nil)
  assert simplifile.create_symlink(first, root <> "/alias") == Ok(Nil)
  assert simplifile.write(
      first <> "/sample/SKILL.md",
      document("sample", "First", "Original."),
    )
    == Ok(Nil)
  assert simplifile.write(
      second <> "/sample/SKILL.md",
      document("sample", "Second", "Collision."),
    )
    == Ok(Nil)
  let catalogue =
    skill.discover([first, root <> "/alias", second, root <> "/missing"])
  let assert [loaded] = skill.entries(catalogue)
    as "an alias cannot duplicate a document"
  assert loaded.description == "First"
  assert list.length(skill.warnings(catalogue)) == 1
  assert simplifile.write(
      first <> "/sample/SKILL.md",
      document("sample", "Changed", "Changed."),
    )
    == Ok(Nil)
  assert skill.lookup(catalogue, "sample") == Ok(loaded)
  assert loaded.body == "Original."
  assert simplifile.delete(root) == Ok(Nil)
}

// The bound is checked before repeated arguments are materialized.
pub fn repeated_arguments_are_bounded_before_expansion_test() {
  let assert Ok(loaded) =
    skill.parse(
      "/sample/SKILL.md",
      document("sample", "Description", string.repeat("$ARGUMENTS", 100)),
    )
    as "the small instruction file is valid"
  assert skill.expand(loaded, string.repeat("x", 3000))
    == Error("expanded skill exceeds 256 KiB")
}

pub fn metadata_limits_count_characters_and_bind_the_directory_test() {
  let assert Ok(_) =
    skill.parse(
      "/sample/SKILL.md",
      document("sample", string.repeat("é", 1024), "Instructions."),
    )
    as "multibyte descriptions retain the specification's character budget"
  let assert Error(_) =
    skill.parse(
      "/sample/SKILL.md",
      document("sample", string.repeat("a", 1025), "Instructions."),
    )
    as "the description cannot exceed 1024 characters"
  assert skill.parse(
      "/different/SKILL.md",
      document("sample", "Description", "Instructions."),
    )
    == Error("skill name must match its parent directory")
}

pub fn yaml_collections_quotes_comments_and_unicode_names_test() {
  let assert Ok(loaded) =
    skill.parse(
      "/café/SKILL.md",
      "---\nname: café\ndescription: \"quoted # text\" # comment\ncompatibility: Erlang\nmetadata: {author: \"example\", version: \"1\"}\n---\nBody.\n",
    )
    as "the YAML library accepts valid metadata beyond the former scalar subset"
  assert loaded.description == "quoted # text"
  assert loaded.name == "café"
  let assert Ok(_) =
    skill.parse("/数据/SKILL.md", document("数据", "Description", ""))
    as "Unicode alphanumeric names and an empty body match the format spec"
  let assert Error(_) =
    skill.parse(
      "/sample/SKILL.md",
      document("sample", "[not, a, string]", "Body."),
    )
    as "a YAML collection cannot masquerade as a text description"
}

pub fn malformed_invocation_flag_reports_the_flag_error_test() {
  assert skill.parse(
      "/valid/SKILL.md",
      document("valid", "Description\nuser-invocable: maybe", "Body."),
    )
    == Error("user-invocable must be true or false")
}
