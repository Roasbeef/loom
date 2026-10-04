// Positive probes use independent actor facts; scenario completion merely closes
// the observation window after actual refused inputs and genuine readbacks.

spec ProbeLiveOrder observes mProductNativeAssociated, mCommandPermitIssued, mCommandPermitConsumed,
  mStart, mCompileReleased, mCommandAssociationRefused, mCommandPermitRefused,
  mCompileRecovered, mCommandControlForwarded, mCommandControlRefused, mAnswer, mScenarioEnd, mCommandReplyLost {
  var associated: bool; var associatedTwo: bool; var issued: bool; var consumed: bool; var started: bool;
  var fenced: bool; var refused: bool; var stale: bool; var recovered: bool; var historical: bool;
  var replyLost: bool; var foreignIssuer: bool; var foreignClaim: bool; var duplicate: bool; var refusedControls: int; var forwardedControls: int; var genuineRead: bool;
  start state Watching {
    on mCommandReplyLost do (a: tAssociationRequest) { replyLost = true; }
    on mProductNativeAssociated do (p: tPreparedProduct) { associated = true; if (p.native.key.execution == 2) { associatedTwo = true; } }
    on mCommandPermitIssued do (a: tAssociationRequest) { issued = associated; }
    on mCommandPermitConsumed do (a: tAssociationRequest) { consumed = issued; }
    on mStart do (n: tNative) { started = consumed; }
    on mCompileReleased do (s: tService) { fenced = true; }
    on mCommandAssociationRefused do (a: tAssociationRequest) {
      refused = true;
      if (a.command.claim.issuer != a.command.resource) { foreignIssuer = true; }
      if (a.command.claim.incarnation == 2) { foreignClaim = true; }
      if (associated && a.command.claim.incarnation == 1) { duplicate = true; }
    }
    on mCommandPermitRefused do (a: tAssociationRequest) { stale = true; }
    on mCompileRecovered do (v: tCompileView) { recovered = v.associated && !v.retained; }
    on mCommandControlForwarded do (c: tCommandControl) { forwardedControls = forwardedControls + 1; }
    on mCommandControlRefused do (c: tCommandControl) { refusedControls = refusedControls + 1; }
    on mAnswer do (v: tReply) {
      if (recovered && refused && v.answer == Prior && v.row.phase == Admitted) { historical = true; }
      if (associatedTwo && refusedControls >= 4 && v.request == request(2, 1, 1) &&
          v.answer == Prior && v.row.phase == Running && !v.row.receipt && !v.row.retired) { genuineRead = true; }
    }
    on mScenarioEnd do { assert !(issued && consumed && started), "witness: original live association permit preceded actual native Intent and start"; }
  }
}
test tcProbeLiveOrder [main = TestLiveAssociationOrder]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, ProbeLiveOrder in (union LiveAssociationSystem, { TestLiveAssociationOrder });

spec ProbeLiveFenceBefore observes mProductNativeAssociated, mCommandPermitIssued, mCommandPermitConsumed,
  mStart, mCompileReleased, mCommandAssociationRefused, mCommandPermitRefused,
  mCompileRecovered, mCommandControlForwarded, mCommandControlRefused, mAnswer, mScenarioEnd, mCommandReplyLost {
  var associated: bool; var associatedTwo: bool; var issued: bool; var consumed: bool; var started: bool;
  var fenced: bool; var refused: bool; var stale: bool; var recovered: bool; var historical: bool;
  var replyLost: bool; var foreignIssuer: bool; var foreignClaim: bool; var duplicate: bool; var refusedControls: int; var forwardedControls: int; var genuineRead: bool;
  start state Watching {
    on mCommandReplyLost do (a: tAssociationRequest) { replyLost = true; }
    on mProductNativeAssociated do (p: tPreparedProduct) { associated = true; if (p.native.key.execution == 2) { associatedTwo = true; } }
    on mCommandPermitIssued do (a: tAssociationRequest) { issued = associated; }
    on mCommandPermitConsumed do (a: tAssociationRequest) { consumed = issued; }
    on mStart do (n: tNative) { started = consumed; }
    on mCompileReleased do (s: tService) { fenced = true; }
    on mCommandAssociationRefused do (a: tAssociationRequest) {
      refused = true;
      if (a.command.claim.issuer != a.command.resource) { foreignIssuer = true; }
      if (a.command.claim.incarnation == 2) { foreignClaim = true; }
      if (associated && a.command.claim.incarnation == 1) { duplicate = true; }
    }
    on mCommandPermitRefused do (a: tAssociationRequest) { stale = true; }
    on mCompileRecovered do (v: tCompileView) { recovered = v.associated && !v.retained; }
    on mCommandControlForwarded do (c: tCommandControl) { forwardedControls = forwardedControls + 1; }
    on mCommandControlRefused do (c: tCommandControl) { refusedControls = refusedControls + 1; }
    on mAnswer do (v: tReply) {
      if (recovered && refused && v.answer == Prior && v.row.phase == Admitted) { historical = true; }
      if (associatedTwo && refusedControls >= 4 && v.request == request(2, 1, 1) &&
          v.answer == Prior && v.row.phase == Running && !v.row.receipt && !v.row.retired) { genuineRead = true; }
    }
    on mScenarioEnd do { assert !(fenced && !associated && refused && !started && refusedControls > 0), "witness: resource fence before live association refused permit and duplicate controls"; }
  }
}
test tcProbeLiveFenceBefore [main = TestLiveAssociationOrder]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, ProbeLiveFenceBefore in (union LiveAssociationSystem, { TestLiveAssociationOrder });

spec ProbeLiveFenceAfter observes mProductNativeAssociated, mCommandPermitIssued, mCommandPermitConsumed,
  mStart, mCompileReleased, mCommandAssociationRefused, mCommandPermitRefused,
  mCompileRecovered, mCommandControlForwarded, mCommandControlRefused, mAnswer, mScenarioEnd, mCommandReplyLost {
  var associated: bool; var associatedTwo: bool; var issued: bool; var consumed: bool; var started: bool;
  var fenced: bool; var refused: bool; var stale: bool; var recovered: bool; var historical: bool;
  var replyLost: bool; var foreignIssuer: bool; var foreignClaim: bool; var duplicate: bool; var refusedControls: int; var forwardedControls: int; var genuineRead: bool;
  start state Watching {
    on mCommandReplyLost do (a: tAssociationRequest) { replyLost = true; }
    on mProductNativeAssociated do (p: tPreparedProduct) { associated = true; if (p.native.key.execution == 2) { associatedTwo = true; } }
    on mCommandPermitIssued do (a: tAssociationRequest) { issued = associated; }
    on mCommandPermitConsumed do (a: tAssociationRequest) { consumed = issued; }
    on mStart do (n: tNative) { started = consumed; }
    on mCompileReleased do (s: tService) { fenced = true; }
    on mCommandAssociationRefused do (a: tAssociationRequest) {
      refused = true;
      if (a.command.claim.issuer != a.command.resource) { foreignIssuer = true; }
      if (a.command.claim.incarnation == 2) { foreignClaim = true; }
      if (associated && a.command.claim.incarnation == 1) { duplicate = true; }
    }
    on mCommandPermitRefused do (a: tAssociationRequest) { stale = true; }
    on mCompileRecovered do (v: tCompileView) { recovered = v.associated && !v.retained; }
    on mCommandControlForwarded do (c: tCommandControl) { forwardedControls = forwardedControls + 1; }
    on mCommandControlRefused do (c: tCommandControl) { refusedControls = refusedControls + 1; }
    on mAnswer do (v: tReply) {
      if (recovered && refused && v.answer == Prior && v.row.phase == Admitted) { historical = true; }
      if (associatedTwo && refusedControls >= 4 && v.request == request(2, 1, 1) &&
          v.answer == Prior && v.row.phase == Running && !v.row.receipt && !v.row.retired) { genuineRead = true; }
    }
    on mScenarioEnd do { assert !(associated && issued && consumed && started && fenced && forwardedControls > 0), "witness: association before fence retained exact native cancellation route"; }
  }
}
test tcProbeLiveFenceAfter [main = TestLiveAssociationOrder]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, ProbeLiveFenceAfter in (union LiveAssociationSystem, { TestLiveAssociationOrder });

spec ProbeLiveLostReply observes mProductNativeAssociated, mCommandPermitIssued, mCommandPermitConsumed,
  mStart, mCompileReleased, mCommandAssociationRefused, mCommandPermitRefused,
  mCompileRecovered, mCommandControlForwarded, mCommandControlRefused, mAnswer, mScenarioEnd, mCommandReplyLost {
  var associated: bool; var associatedTwo: bool; var issued: bool; var consumed: bool; var started: bool;
  var fenced: bool; var refused: bool; var stale: bool; var recovered: bool; var historical: bool;
  var replyLost: bool; var foreignIssuer: bool; var foreignClaim: bool; var duplicate: bool; var refusedControls: int; var forwardedControls: int; var genuineRead: bool;
  start state Watching {
    on mCommandReplyLost do (a: tAssociationRequest) { replyLost = true; }
    on mProductNativeAssociated do (p: tPreparedProduct) { associated = true; if (p.native.key.execution == 2) { associatedTwo = true; } }
    on mCommandPermitIssued do (a: tAssociationRequest) { issued = associated; }
    on mCommandPermitConsumed do (a: tAssociationRequest) { consumed = issued; }
    on mStart do (n: tNative) { started = consumed; }
    on mCompileReleased do (s: tService) { fenced = true; }
    on mCommandAssociationRefused do (a: tAssociationRequest) {
      refused = true;
      if (a.command.claim.issuer != a.command.resource) { foreignIssuer = true; }
      if (a.command.claim.incarnation == 2) { foreignClaim = true; }
      if (associated && a.command.claim.incarnation == 1) { duplicate = true; }
    }
    on mCommandPermitRefused do (a: tAssociationRequest) { stale = true; }
    on mCompileRecovered do (v: tCompileView) { recovered = v.associated && !v.retained; }
    on mCommandControlForwarded do (c: tCommandControl) { forwardedControls = forwardedControls + 1; }
    on mCommandControlRefused do (c: tCommandControl) { refusedControls = refusedControls + 1; }
    on mAnswer do (v: tReply) {
      if (recovered && refused && v.answer == Prior && v.row.phase == Admitted) { historical = true; }
      if (associatedTwo && refusedControls >= 4 && v.request == request(2, 1, 1) &&
          v.answer == Prior && v.row.phase == Running && !v.row.receipt && !v.row.retired) { genuineRead = true; }
    }
    on mScenarioEnd do { assert !(associated && issued && replyLost && !consumed && !stale && recovered && refused && historical && !started), "witness: lost association reply retained history without recreating original permit"; }
  }
}
test tcProbeLiveLostReply [main = TestLiveAssociationLoss]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, ProbeLiveLostReply in (union LiveAssociationSystem, { TestLiveAssociationLoss });

spec ProbeLiveStaleReply observes mProductNativeAssociated, mCommandPermitIssued, mCommandPermitConsumed,
  mStart, mCompileReleased, mCommandAssociationRefused, mCommandPermitRefused,
  mCompileRecovered, mCommandControlForwarded, mCommandControlRefused, mAnswer, mScenarioEnd, mCommandReplyLost {
  var associated: bool; var associatedTwo: bool; var issued: bool; var consumed: bool; var started: bool;
  var fenced: bool; var refused: bool; var stale: bool; var recovered: bool; var historical: bool;
  var replyLost: bool; var foreignIssuer: bool; var foreignClaim: bool; var duplicate: bool; var refusedControls: int; var forwardedControls: int; var genuineRead: bool;
  start state Watching {
    on mCommandReplyLost do (a: tAssociationRequest) { replyLost = true; }
    on mProductNativeAssociated do (p: tPreparedProduct) { associated = true; if (p.native.key.execution == 2) { associatedTwo = true; } }
    on mCommandPermitIssued do (a: tAssociationRequest) { issued = associated; }
    on mCommandPermitConsumed do (a: tAssociationRequest) { consumed = issued; }
    on mStart do (n: tNative) { started = consumed; }
    on mCompileReleased do (s: tService) { fenced = true; }
    on mCommandAssociationRefused do (a: tAssociationRequest) {
      refused = true;
      if (a.command.claim.issuer != a.command.resource) { foreignIssuer = true; }
      if (a.command.claim.incarnation == 2) { foreignClaim = true; }
      if (associated && a.command.claim.incarnation == 1) { duplicate = true; }
    }
    on mCommandPermitRefused do (a: tAssociationRequest) { stale = true; }
    on mCompileRecovered do (v: tCompileView) { recovered = v.associated && !v.retained; }
    on mCommandControlForwarded do (c: tCommandControl) { forwardedControls = forwardedControls + 1; }
    on mCommandControlRefused do (c: tCommandControl) { refusedControls = refusedControls + 1; }
    on mAnswer do (v: tReply) {
      if (recovered && refused && v.answer == Prior && v.row.phase == Admitted) { historical = true; }
      if (associatedTwo && refusedControls >= 4 && v.request == request(2, 1, 1) &&
          v.answer == Prior && v.row.phase == Running && !v.row.receipt && !v.row.retired) { genuineRead = true; }
    }
    on mScenarioEnd do { assert !(associated && issued && !consumed && stale && recovered && refused && historical && !started), "witness: stale boot permit refused and recovered association remained data only"; }
  }
}
test tcProbeLiveStaleReply [main = TestLiveAssociationLoss]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, ProbeLiveStaleReply in (union LiveAssociationSystem, { TestLiveAssociationLoss });

spec ProbeLiveClaim observes mProductNativeAssociated, mCommandPermitIssued, mCommandPermitConsumed,
  mStart, mCompileReleased, mCommandAssociationRefused, mCommandPermitRefused,
  mCompileRecovered, mCommandControlForwarded, mCommandControlRefused, mAnswer, mScenarioEnd, mCommandReplyLost {
  var associated: bool; var associatedTwo: bool; var issued: bool; var consumed: bool; var started: bool;
  var fenced: bool; var refused: bool; var stale: bool; var recovered: bool; var historical: bool;
  var replyLost: bool; var foreignIssuer: bool; var foreignClaim: bool; var duplicate: bool; var refusedControls: int; var forwardedControls: int; var genuineRead: bool;
  start state Watching {
    on mCommandReplyLost do (a: tAssociationRequest) { replyLost = true; }
    on mProductNativeAssociated do (p: tPreparedProduct) { associated = true; if (p.native.key.execution == 2) { associatedTwo = true; } }
    on mCommandPermitIssued do (a: tAssociationRequest) { issued = associated; }
    on mCommandPermitConsumed do (a: tAssociationRequest) { consumed = issued; }
    on mStart do (n: tNative) { started = consumed; }
    on mCompileReleased do (s: tService) { fenced = true; }
    on mCommandAssociationRefused do (a: tAssociationRequest) {
      refused = true;
      if (a.command.claim.issuer != a.command.resource) { foreignIssuer = true; }
      if (a.command.claim.incarnation == 2) { foreignClaim = true; }
      if (associated && a.command.claim.incarnation == 1) { duplicate = true; }
    }
    on mCommandPermitRefused do (a: tAssociationRequest) { stale = true; }
    on mCompileRecovered do (v: tCompileView) { recovered = v.associated && !v.retained; }
    on mCommandControlForwarded do (c: tCommandControl) { forwardedControls = forwardedControls + 1; }
    on mCommandControlRefused do (c: tCommandControl) { refusedControls = refusedControls + 1; }
    on mAnswer do (v: tReply) {
      if (recovered && refused && v.answer == Prior && v.row.phase == Admitted) { historical = true; }
      if (associatedTwo && refusedControls >= 4 && v.request == request(2, 1, 1) &&
          v.answer == Prior && v.row.phase == Running && !v.row.receipt && !v.row.retired) { genuineRead = true; }
    }
    on mScenarioEnd do { assert !(foreignClaim && foreignIssuer && duplicate && issued && consumed && started), "witness: changed original Claim and duplicate association refused before genuine launch"; }
  }
}
test tcProbeLiveClaim [main = TestLiveAssociationClaim]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, ProbeLiveClaim in (union LiveAssociationSystem, { TestLiveAssociationClaim });

spec ProbeLiveControls observes mProductNativeAssociated, mCommandPermitIssued, mCommandPermitConsumed,
  mStart, mCompileReleased, mCommandAssociationRefused, mCommandPermitRefused,
  mCompileRecovered, mCommandControlForwarded, mCommandControlRefused, mAnswer, mScenarioEnd, mCommandReplyLost {
  var associated: bool; var associatedTwo: bool; var issued: bool; var consumed: bool; var started: bool;
  var fenced: bool; var refused: bool; var stale: bool; var recovered: bool; var historical: bool;
  var replyLost: bool; var foreignIssuer: bool; var foreignClaim: bool; var duplicate: bool; var refusedControls: int; var forwardedControls: int; var genuineRead: bool;
  start state Watching {
    on mCommandReplyLost do (a: tAssociationRequest) { replyLost = true; }
    on mProductNativeAssociated do (p: tPreparedProduct) { associated = true; if (p.native.key.execution == 2) { associatedTwo = true; } }
    on mCommandPermitIssued do (a: tAssociationRequest) { issued = associated; }
    on mCommandPermitConsumed do (a: tAssociationRequest) { consumed = issued; }
    on mStart do (n: tNative) { started = consumed; }
    on mCompileReleased do (s: tService) { fenced = true; }
    on mCommandAssociationRefused do (a: tAssociationRequest) {
      refused = true;
      if (a.command.claim.issuer != a.command.resource) { foreignIssuer = true; }
      if (a.command.claim.incarnation == 2) { foreignClaim = true; }
      if (associated && a.command.claim.incarnation == 1) { duplicate = true; }
    }
    on mCommandPermitRefused do (a: tAssociationRequest) { stale = true; }
    on mCompileRecovered do (v: tCompileView) { recovered = v.associated && !v.retained; }
    on mCommandControlForwarded do (c: tCommandControl) { forwardedControls = forwardedControls + 1; }
    on mCommandControlRefused do (c: tCommandControl) { refusedControls = refusedControls + 1; }
    on mAnswer do (v: tReply) {
      if (recovered && refused && v.answer == Prior && v.row.phase == Admitted) { historical = true; }
      if (associatedTwo && refusedControls >= 4 && v.request == request(2, 1, 1) &&
          v.answer == Prior && v.row.phase == Running && !v.row.receipt && !v.row.retired) { genuineRead = true; }
    }
    on mScenarioEnd do { assert !(associatedTwo && refusedControls >= 4 && genuineRead && started), "witness: four foreign controls refused while exact second native row remained unchanged"; }
  }
}
test tcProbeLiveControls [main = TestLiveAssociationControls]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, ProbeLiveControls in (union LiveAssociationSystem, { TestLiveAssociationControls });
