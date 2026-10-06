//// The production whole Launch consumer runs under original Fresh custody.
//// Two TLS runtimes own independent service journals and the actual satellite.

import client/remote/launch_client_fixture
import gleam/erlang/atom

pub fn production_remote_compile_launch_capability_final_and_custody_test_() {
  #(atom.create("timeout"), 35, fn() { launch_client_fixture.live_control(0) })
}

pub fn original_native_scope_loss_retires_companion_with_unknown_custody_test_() {
  #(atom.create("timeout"), 35, fn() { launch_client_fixture.live_control(1) })
}

pub fn mutated_producer_manifest_has_no_launch_effects_test_() {
  #(atom.create("timeout"), 35, fn() { launch_client_fixture.live_control(2) })
}

pub fn changed_compile_producer_uuid_has_no_launch_effects_test_() {
  #(atom.create("timeout"), 35, fn() { launch_client_fixture.live_control(3) })
}

pub fn changed_enrollment_epoch_has_no_launch_effects_test_() {
  #(atom.create("timeout"), 35, fn() { launch_client_fixture.live_control(4) })
}

pub fn definite_original_clearance_refusal_retains_no_native_completion_test_() {
  #(atom.create("timeout"), 35, fn() { launch_client_fixture.live_control(5) })
}

pub fn unavailable_original_clearance_remains_unknown_test_() {
  #(atom.create("timeout"), 35, fn() { launch_client_fixture.live_control(6) })
}

pub fn canonical_channel_parent_is_portable_test() {
  launch_client_fixture.channel_parent_control()
}

pub fn lost_original_clearance_reply_stays_unknown_without_refusal_test_() {
  #(atom.create("timeout"), 35, fn() { launch_client_fixture.live_control(8) })
}

/// The real first compiler failure authorizes only one immutable rewritten build.
pub fn real_unused_import_rewrite_compile_then_exact_launch_test_() {
  #(atom.create("timeout"), 60, fn() { launch_client_fixture.live_control(9) })
}
