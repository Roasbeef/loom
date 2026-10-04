//// The ownership label an external inspector reads. Each test runs its
//// body in a fresh process, because a label is per process and a test
//// process reused across tests would carry the previous one.

import gleam/erlang/process
import gleam/option.{None, Some}
import support/internal/ffi_format
import telemetry/context
import telemetry/log
import telemetry/owner

fn in_fresh_process(body: fn() -> a) -> a {
  let reply = process.new_subject()
  let _pid = process.spawn_unlinked(fn() { process.send(reply, body()) })
  let assert Ok(seen) = process.receive(reply, within: 2000)
    as "the spawned process must report back"
  seen
}

pub fn a_process_that_never_labelled_has_no_label_test() {
  assert in_fresh_process(ffi_format.owner_label) == None
}

pub fn adopting_a_logger_labels_the_process_with_session_strand_and_role_test() {
  let scoped =
    log.scoped(
      log.discard(),
      context.for_session("sess-9") |> context.with_strand("main"),
    )
  let seen =
    in_fresh_process(fn() {
      log.adopt(scoped, owner.StrandDriver)
      ffi_format.owner_label()
    })
  assert seen
    == Some(#([#("session", "sess-9"), #("strand", "main")], "strand_driver"))
}

pub fn a_context_with_no_session_yields_the_empty_path_test() {
  let seen =
    in_fresh_process(fn() {
      log.adopt(log.discard(), owner.EffectWorker)
      ffi_format.owner_label()
    })
  assert seen == Some(#([], "effect_worker"))
}

pub fn labelling_directly_takes_the_path_it_is_given_test() {
  let seen =
    in_fresh_process(fn() {
      owner.label([#("session", "sess-3")], owner.Gateway)
      ffi_format.owner_label()
    })
  assert seen == Some(#([#("session", "sess-3")], "gateway"))
}

pub fn a_second_label_replaces_the_first_test() {
  let seen =
    in_fresh_process(fn() {
      owner.label([], owner.PageSessions)
      owner.label([#("session", "sess-3")], owner.Gateway)
      ffi_format.owner_label()
    })
  assert seen == Some(#([#("session", "sess-3")], "gateway"))
}

pub fn role_names_are_the_frozen_lowercase_snake_case_words_test() {
  assert owner.role_name(owner.StrandDriver) == "strand_driver"
  assert owner.role_name(owner.EffectWorker) == "effect_worker"
  assert owner.role_name(owner.ProviderEffectWorker) == "provider_effect_worker"
  assert owner.role_name(owner.Gateway) == "gateway"
  assert owner.role_name(owner.PageSocket) == "page_socket"
  assert owner.role_name(owner.PageSessions) == "page_sessions"
  assert owner.role_name(owner.SessionHost) == "session_host"
  assert owner.role_name(owner.DomainHost) == "domain_host"
  assert owner.role_name(owner.Agency) == "agency"
  assert owner.role_name(owner.Escalation) == "escalation"
  assert owner.role_name(owner.AsyncRuns) == "async_runs"
  assert owner.role_name(owner.BackgroundJobs) == "background_jobs"
  assert owner.role_name(owner.Advisor) == "advisor"
  assert owner.role_name(owner.Glance) == "glance"
  assert owner.role_name(owner.BlockSummarizer) == "block_summarizer"
  assert owner.role_name(owner.RuleScanner) == "rule_scanner"
  assert owner.role_name(owner.ScheduleScanner) == "schedule_scanner"
}
