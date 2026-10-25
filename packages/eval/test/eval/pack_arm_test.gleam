//// A `PromptPack` component reaches the session through `Settings.pack`.
////
//// The falsifier is end to end: two scripted trials differ only in the arm,
//// and the request body the provider receives carries the pack's sentinel
//// paragraph for the pack arm and not for the baseline. A pack that does not
//// decode is refused at `to_settings`, by arm, before any trial opens.

import client/serve
import eval/arm.{type Arm, Arm, Knobs, PromptPack}
import eval/arm_settings
import eval/plan.{Budgets, RowKey}
import eval/repos
import eval/trial
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/http
import support/scripted

const sentinel = "PACK-SENTINEL-7f3a91"

fn pack_source() -> String {
  "%% loom-prompt-pack 1\n%% version arm-test\n%% section identity\nYou are an agent. "
  <> sentinel
  <> "\n"
}

fn pack_arm(source: String) -> Arm {
  let assert Ok(minted) =
    arm.mint(Arm(
      id: "",
      name: "packed",
      components: [#(PromptPack, source)],
      knobs: Knobs(roles: [], thinking: [], disabled_tools: []),
    ))
    as "the pack arm mints"

  minted
}

// A transport that reports every request body to the test before answering
// as the ordinary scripted provider does.
fn recording(sent: process.Subject(String)) -> http.Transport {
  let inner = scripted.transport(1)

  http.Transport(prepare_streaming: fn(request, events) {
    process.send(sent, request.body)
    inner.prepare_streaming(request, events)
  })
}

fn bodies_of(name: String, under: Arm) -> List(String) {
  let root = scripted.scratch(name)
  let sent = process.new_subject()
  let base = scripted.base(root <> "/base", recording(sent))
  let found = scripted.task_named("pack", "hello", "hello")
  let ctx =
    trial.Context(
      base:,
      lane: trial.Live,
      budgets: Budgets(4, 100.0, 60_000, 1),
      plan_id: name,
      seams: trial.default_seams(trial.refuse_program),
      repos: repos.empty(),
      selftest: trial.unprobed,
    )
  let _row =
    trial.run_one(
      ctx,
      found,
      under,
      RowKey(found.id, under.id, 0),
      1,
      root <> "/attempt",
    )

  drain(sent, [])
}

fn drain(sent: process.Subject(String), seen: List(String)) -> List(String) {
  case process.receive(sent, within: 200) {
    Ok(body) -> drain(sent, [body, ..seen])
    Error(Nil) -> seen
  }
}

pub fn a_pack_arm_puts_its_paragraph_in_the_system_text_test_() -> scripted.EunitTest {
  scripted.Timeout(240, fn() {
    scripted.when_available("pack_arm_system_text", fn() {
      let packed = bodies_of("pack-arm", pack_arm(pack_source()))
      let plain = bodies_of("pack-baseline", scripted.baseline())

      assert packed != []
      assert list.all(packed, string.contains(_, sentinel))
      assert plain != []
      assert !list.any(plain, string.contains(_, sentinel))
    })
  })
}

pub fn a_corrupt_pack_is_refused_by_arm_before_any_trial_test() {
  let base =
    scripted.base(scripted.scratch("pack-corrupt"), scripted.transport(1))
  let broken = pack_arm("%% loom-prompt-pack 9\n")

  let assert Error(reason) = arm_settings.to_settings(broken, base)

  assert string.contains(reason, "PromptPack")
  assert string.contains(reason, broken.id)
}

pub fn a_decoding_pack_lands_in_settings_and_keeps_the_base_otherwise_test() {
  let base =
    scripted.base(scripted.scratch("pack-settings"), scripted.transport(1))
  let kept = serve.Settings(..base, pack: Some("operator pack"))

  let assert Ok(applied) =
    arm_settings.to_settings(pack_arm(pack_source()), base)
  let assert Ok(plain) = arm_settings.to_settings(scripted.baseline(), kept)

  assert applied.pack == Some(pack_source())
  assert plain.pack == Some("operator pack")
  assert base.pack == None
  assert arm_settings.profiles(pack_arm(pack_source()), base) == Ok([])
}
