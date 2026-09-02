//// The interleave recorder's arming contract, which is what decides where
//// a scenario's crash lands.
////
//// The harness admits its own prompt through the same writer the strand
//// driver commits through, and `after_commit` sees commits, not
//// committers. Arming last is therefore the only honest way to keep the
//// test's writes out of the run's numbering, and the count the recorder
//// subtracts is the one thing that can tell whether a drive got in among
//// them.

import support/recorder

/// Two admissions and nothing else: the next commit is boundary one, and
/// a bomb armed for it goes off there.
pub fn arming_behind_clean_admissions_numbers_from_one_test() {
  let rec = recorder.start()

  // Acceptance and steer, as the steer scenario admits them. Neither is
  // the run's, so neither is numbered and neither may explode.
  assert recorder.on_commit(rec) == False
  assert recorder.on_commit(rec) == False

  assert recorder.arm(rec, at: 1, after: 2) == recorder.Clean
  assert recorder.on_commit(rec) == True
  assert recorder.commit_count(rec) == 1
  assert recorder.fired(rec) == True
}

/// A drive among the admissions is reported rather than absorbed. Under the
/// skip count it replaced it took an admission's place, the steer became
/// boundary one, and the bomb went off inside the call admitting it.
pub fn arming_reports_a_drive_among_the_admissions_test() {
  let rec = recorder.start()
  assert recorder.on_commit(rec) == False

  // The strand driver's run-start checkpoint, committed off a poll tick
  // while the test was still admitting.
  assert recorder.on_commit(rec) == False

  assert recorder.on_commit(rec) == False
  assert recorder.arm(rec, at: 1, after: 2) == recorder.Drifted(boundaries: 1)
}

/// Arming at zero numbers the boundaries without ever exploding: the
/// uninterrupted run every scenario's `C` is taken from.
pub fn arming_at_zero_counts_without_exploding_test() {
  let rec = recorder.start()
  assert recorder.on_commit(rec) == False
  assert recorder.arm(rec, at: 0, after: 1) == recorder.Clean
  assert recorder.on_commit(rec) == False
  assert recorder.on_commit(rec) == False
  assert recorder.commit_count(rec) == 2
  assert recorder.fired(rec) == False
}
