import core/clock

pub fn fixed_clock_always_reads_the_same_instant_test() {
  let fixture = clock.fixed(at: 42)
  let #(first, fixture) = clock.read(fixture)
  let #(second, _fixture) = clock.read(fixture)
  assert first == 42
  assert second == 42
}

pub fn stepping_clock_advances_by_its_step_test() {
  let fixture = clock.stepping(from: 100, by: 10)
  let #(first, fixture) = clock.read(fixture)
  let #(second, fixture) = clock.read(fixture)
  let #(third, _fixture) = clock.read(fixture)
  assert first == 100
  assert second == 110
  assert third == 120
}

pub fn stepping_clock_clamps_negative_steps_test() {
  let fixture = clock.stepping(from: 100, by: -5)
  let #(first, fixture) = clock.read(fixture)
  let #(second, _fixture) = clock.read(fixture)
  assert first == 100
  assert second == 100
}

pub fn injected_clock_calls_the_supplied_function_test() {
  let fixture = clock.from_function(fn() { 1_700_000_000_000 })
  let #(now, fixture) = clock.read(fixture)
  let #(again, _fixture) = clock.read(fixture)
  assert now == 1_700_000_000_000
  assert again == 1_700_000_000_000
}

pub fn unthreaded_stepping_clock_rereads_the_same_instant_test() {
  let fixture = clock.stepping(from: 5, by: 5)
  let #(first, _ignored) = clock.read(fixture)
  let #(second, _ignored) = clock.read(fixture)
  assert first == second
}
