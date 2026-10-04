module System = { Owner, Executor, Helper, Lifecycle, UncertainScenario, FaultScenario, RetentionScenario };
test tcLifecycle [main = TestLifecycle]:
  assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, DirectedProgress in (union System, { TestLifecycle });
test tcCrashAfterSend [main = TestCrashAfterSend]:
  assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, DirectedProgress in (union System, { TestCrashAfterSend });
test tcUncertain [main = UncertainScenario]:
  assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, DirectedProgress in System;
test tcFaults [main = FaultScenario]:
  assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, DirectedProgress in System;

test tcReceiptPending [main = TestReceiptPending]:
  assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, DirectedProgress in (union System, { TestReceiptPending });
test tcRetirementPending [main = TestRetirementPending]:
  assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, DirectedProgress in (union System, { TestRetirementPending });
