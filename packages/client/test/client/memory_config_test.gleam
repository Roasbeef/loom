//// The `[memory]` table of `loom.toml`: the one live key, the retired keys
//// that are still read so an old file keeps loading, and the strictness
//// around both.

import client/catalog
import client/memory_config
import gleam/result
import gleam/string

pub fn an_absent_table_is_the_default_posture_test() {
  assert memory_config.parse("") == Ok(memory_config.default_options())
  assert memory_config.default_options().inject == memory_config.InjectsNotes
}

pub fn inject_chooses_between_the_index_and_nothing_test() {
  assert memory_config.parse("[memory]\ninject = \"notes\"\n")
    == Ok(memory_config.default_options())
  assert memory_config.parse("[memory]\ninject = \"off\"\n")
    == Ok(
      memory_config.Options(inject: memory_config.InjectsNothing, retired: []),
    )

  let assert Error(unknown) =
    memory_config.parse("[memory]\ninject = \"yes\"\n")
    as "an unknown injection mode must be refused"
  assert string.contains(unknown, "off")
  assert string.contains(unknown, "notes")
  let assert Error(_not_a_string) =
    memory_config.parse("[memory]\ninject = true\n")
    as "a non-string injection mode must be refused"
}

/// A file written while the distillation pass existed still loads: every
/// retired setting is accepted with any value, does nothing, and is named so
/// the host can warn once per key.
pub fn the_retired_settings_load_and_are_reported_test() {
  assert memory_config.parse("[memory]\ndistill = \"off\"\n")
    == Ok(
      memory_config.Options(inject: memory_config.InjectsNotes, retired: [
        "distill",
      ]),
    )
  assert memory_config.parse("[memory]\ndistill = \"on-boot\"\n")
    == Ok(
      memory_config.Options(inject: memory_config.InjectsNotes, retired: [
        "distill",
      ]),
    )
  assert memory_config.parse("[memory]\ndistill = 1\ndistill_wall_ms = 5\n")
    == Ok(
      memory_config.Options(inject: memory_config.InjectsNotes, retired: [
        "distill",
        "distill_wall_ms",
      ]),
    )
  assert memory_config.parse("[memory]\ndistill = \"off\"\ninject = \"off\"\n")
    == Ok(
      memory_config.Options(inject: memory_config.InjectsNothing, retired: [
        "distill",
      ]),
    )
}

/// `inject = "digest"` asked for the removed digest, so it reads as the
/// default posture and is reported as retired.
pub fn a_digest_injection_reads_as_notes_test() {
  assert memory_config.parse("[memory]\ninject = \"digest\"\n")
    == Ok(
      memory_config.Options(inject: memory_config.InjectsNotes, retired: [
        "inject",
      ]),
    )
}

/// A typoed key is a refusal, because a setting that is silently ignored is
/// the one failure an operator cannot see.
pub fn an_unknown_key_is_refused_test() {
  let assert Error(unknown) = memory_config.parse("[memory]\ninjct = \"off\"\n")
    as "an unknown key must be refused"
  assert string.contains(unknown, "injct")
  let assert Error(_not_a_table) = memory_config.parse("memory = 3\n")
    as "memory must be a table"
}

/// The top-level check has to know the table exists, or a document carrying
/// it would be refused by the catalogue before this parser ever saw it.
pub fn the_catalogue_accepts_the_memory_table_test() {
  let document =
    "[models.acme]
dialect = \"anthropic\"
base_url = \"https://acme.test\"
api_key_env = \"ACME_KEY\"
model_id = \"loom-1\"
context_window = 100000
max_output_tokens = 4096

[roles]
main = [\"acme\"]

[memory]
inject = \"notes\"
"
  assert result.is_ok(catalog.parse(document))
  assert memory_config.parse(document) == Ok(memory_config.default_options())
}
