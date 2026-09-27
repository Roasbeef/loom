// Test cases. The four system tests check every spec but ShutAtMostOnce;
// the two ShutOnce tests check it alone over the same traffic, so a
// regression of finding F1 (README.md) is reported under its own name.
// tcDroppedClosedQuitEarly checks S8 alone, for mutate.py.

module System = { Terminal, AttachmentWorker, Socket, Fuse, Deadline, Operator };

test tcSubmit [main = TestSubmit]:
  assert ReplacementIsFailPreserving, NoStaleRepaint, MutationCustody, NoWriteAfterShut, WorkerNeverStranded, QuitReleasesEverything, OneRequestInFlight, DroppedPreparedClosed in
  (union System, { TestSubmit });

test tcReplace [main = TestReplace]:
  assert ReplacementIsFailPreserving, NoStaleRepaint, MutationCustody, NoWriteAfterShut, WorkerNeverStranded, QuitReleasesEverything, OneRequestInFlight, DroppedPreparedClosed in
  (union System, { TestReplace });

test tcQuitLate [main = TestQuit]:
  assert ReplacementIsFailPreserving, NoStaleRepaint, MutationCustody, NoWriteAfterShut, WorkerNeverStranded, QuitReleasesEverything, OneRequestInFlight, DroppedPreparedClosed in
  (union System, { TestQuit });

test tcQuitEarly [main = TestQuitEarly]:
  assert ReplacementIsFailPreserving, NoStaleRepaint, MutationCustody, NoWriteAfterShut, WorkerNeverStranded, QuitReleasesEverything, OneRequestInFlight, DroppedPreparedClosed in
  (union System, { TestQuitEarly });

test tcShutOnceReplace [main = TestReplace]:
  assert ShutAtMostOnce in (union System, { TestReplace });

test tcShutOnceAtQuit [main = TestQuit]:
  assert ShutAtMostOnce in (union System, { TestQuit });

test tcDroppedClosedQuitEarly [main = TestQuitEarly]:
  assert DroppedPreparedClosed in (union System, { TestQuitEarly });
