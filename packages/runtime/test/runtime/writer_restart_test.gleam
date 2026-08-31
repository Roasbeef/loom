//// Structural regression coverage for writer renewal ownership.
////
//// Erlang timers addressed through a registered name may survive the process
//// which created them and reach whatever replacement later claims that name.
//// Timing a restart against the old deadline cannot prove this boundary on a
//// delayed CI runner, so the writer exposes its internal subject constructor
//// with `@internal`. The production initializer calls that same constructor;
//// this test proves the resulting address has one PID owner and no stable name
//// a later incarnation could inherit.

import gleam/erlang/process
import runtime/writer

pub fn renewal_timer_subject_is_incarnation_local_test() {
  let renewal = writer.renewal_subject()
  assert process.subject_name(renewal) == Error(Nil)
  let assert Ok(owner) = process.subject_owner(renewal)
    as "the renewal subject must retain its creating process"
  assert owner == process.self()
}
