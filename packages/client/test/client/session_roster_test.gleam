//// The effective surface survives default changes without editing requests,
//// prompts, or strand configuration registers.

import client/catalog
import client/codemode
import client/daemon/protocol
import client/serve
import client/session_roster
import core/clock
import core/json
import core/register
import core/tx
import gleam/option.{None}
import machine/codec
import machine/strand
import session/session
import storage/storage

fn opened() {
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 0))
  opened
}

fn prepare(opened, requested, configured) {
  session_roster.prepare(opened, requested, configured, fn(roster) {
    serve.seams_for(None, roster)
  })
}

pub fn inherited_surface_survives_both_default_flips_test() {
  let first = opened()
  assert prepare(first, protocol.InheritRoster, catalog.Minimal)
    == Ok(session_roster.Surface(catalog.Minimal, codemode.BothSeams))
  assert prepare(first, protocol.InheritRoster, catalog.Full)
    == Ok(session_roster.Surface(catalog.Minimal, codemode.BothSeams))

  let second = opened()
  assert prepare(second, protocol.InheritRoster, catalog.Full)
    == Ok(session_roster.Surface(catalog.Full, codemode.WorkspaceOnly))
  assert prepare(second, protocol.InheritRoster, catalog.Minimal)
    == Ok(session_roster.Surface(catalog.Full, codemode.WorkspaceOnly))
}

fn put(opened: session.Session, ns, key, payload) -> Nil {
  let assert Ok(_) =
    storage.commit(
      opened.store,
      tx.Tx(
        writes: [tx.SetRegister(ns, key, register.value(payload))],
        expected: [tx.Expect(ns, key, None)],
      ),
    )
  Nil
}

pub fn legacy_session_keeps_full_and_existing_registers_test() {
  let opened = opened()
  let prompt = json.String("Legacy full prompt")
  let narrow = configuration(["fs_read"])
  put(opened, register.FactCustom, "prompt/system", prompt)
  put(opened, register.StrandConfig, "child", narrow)
  let prompt_before =
    storage.get_register(opened.store, register.FactCustom, "prompt/system")
  let child_before =
    storage.get_register(opened.store, register.StrandConfig, "child")
  assert prepare(opened, protocol.InheritRoster, catalog.Minimal)
    == Ok(session_roster.Surface(catalog.Full, codemode.WorkspaceOnly))
  assert storage.get_register(
      opened.store,
      register.FactCustom,
      "prompt/system",
    )
    == prompt_before
  assert storage.get_register(opened.store, register.StrandConfig, "child")
    == child_before
}

pub fn failed_first_boot_with_seeded_primary_is_legacy_test() {
  let opened = opened()
  put(opened, register.StrandConfig, "main", configuration(["fs_read"]))
  assert prepare(opened, protocol.InheritRoster, catalog.Minimal)
    == Ok(session_roster.Surface(catalog.Full, codemode.WorkspaceOnly))
}

pub fn explicit_unreleased_roster_survives_first_migration_test() {
  let opened = opened()
  put(
    opened,
    register.FactCustom,
    "prompt/system",
    json.String("Minimal prompt"),
  )
  assert prepare(opened, protocol.MinimalRoster, catalog.Minimal)
    == Ok(session_roster.Surface(catalog.Minimal, codemode.BothSeams))
}

pub fn explicit_seams_are_recorded_with_the_roster_test() {
  let opened = opened()
  assert session_roster.prepare(
      opened,
      protocol.MinimalRoster,
      catalog.Minimal,
      fn(_) { Ok(codemode.WorkspaceOnly) },
    )
    == Ok(session_roster.Surface(catalog.Minimal, codemode.WorkspaceOnly))
  assert prepare(opened, protocol.InheritRoster, catalog.Full)
    == Ok(session_roster.Surface(catalog.Minimal, codemode.WorkspaceOnly))
}

pub fn corrupt_surface_refuses_instead_of_inheriting_test() {
  let opened = opened()
  put(
    opened,
    register.FactCustom,
    session_roster.key,
    json.Object([
      #("roster", json.String("minimal")),
      #("seams", json.String("typo")),
    ]),
  )
  assert prepare(opened, protocol.InheritRoster, catalog.Full)
    == Error("Invalid session tool seams")
}

// Use the production codec so preservation is proved on a recoverable config.
fn configuration(names) {
  codec.encode_configuration(strand.StrandConfiguration(
    model: strand.ModelIdentity(provider: "fixture", model_id: "test"),
    thinking_level: strand.ThinkingOff,
    active_tool_names: names,
  ))
}
