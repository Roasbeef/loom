// These controls extend the original owner, not a second storage state machine.
// Replies and monitor announcements come from its actual transition handlers.
enum tReportMode { ReportHappy, ReportLost, ReportFailed, ReportWrongProfile, ReportOversize, ReportQuota }
event mReportScenario: tReportMode;

machine ReportCustodyScenario {
  var mode: tReportMode; var owner: machine; var downstream: machine; var stage: int;
  var saved: tSavedReport;
  start state Init {
    entry (p: tReportMode) {
      mode = p; announce mScenarioBegin; announce mReportScenario, mode;
      downstream = new RunDownstream(this);
      owner = new RunCustodian((driver = this, downstream = downstream));
      saved = report(1, 17039376);
      if (mode == ReportWrongProfile) { send owner, eRunAdmit, (key = 1, commit = RunCommitOk); }
      else { send owner, eRunAdmitReport, (key = 1, commit = RunCommitOk); }
      goto Driving;
    }
  }
  state Driving { on eRunView do (v: tRunView) { drive(v); } }
  state Finished { }
  fun pin(id: int): tRunPin { return (key = id, incarnation = 1); }
  fun report(id: int, bytes: int): tSavedReport { return (identity = id, digest = id + 10, bytes = bytes); }
  fun finish() { announce mScenarioEnd; goto Finished; }
  fun retain(id: int, value: tSavedReport, commit: tRunCommit, lost: bool) {
    send owner, eRunRetainReport, (pin = pin(id), report = value, commit = commit, replyLost = lost);
  }
  fun complete(id: int, value: tSavedReport) {
    send owner, eRunReferenceFinal, (pin = pin(id), outcome = 1, reference = value, commit = RunCommitOk);
  }
  fun drive(v: tRunView) {
    if (stage == 0) {
      assert v.answer == RunFresh, "report control did not obtain original reservation";
      stage = 1; send owner, eRunStart, pin(1); return;
    }
    if (stage == 1) {
      assert v.answer == RunStarted, "report control did not start original worker";
      stage = 2;
      if (mode == ReportOversize) { retain(1, report(1, 17039377), RunCommitOk, false); }
      else if (mode == ReportFailed) { retain(1, saved, RunCommitFailed, false); }
      else { retain(1, saved, RunCommitOk, mode == ReportLost); }
      return;
    }
    if (stage == 2) {
      if (mode == ReportLost) {
        assert v.answer == RunReportReplyLost, "lost report acknowledgement must follow actual COMMIT";
        stage = 20; send owner, eRunRestart; return;
      }
      if (mode == ReportFailed || mode == ReportWrongProfile || mode == ReportOversize) {
        assert v.answer == RunCommitRejected, "invalid report storage must refuse and fence";
        stage = 30; send owner, eRunFinal, (pin = pin(1), outcome = 1, commit = RunCommitOk); return;
      }
      assert v.answer == RunReportStored, "maximum original report did not fit reserved allowance";
      stage = 3; complete(1, (identity = 1, digest = 99, bytes = saved.bytes)); return;
    }
    if (stage == 3) {
      assert v.answer == RunCommitRejected, "foreign report reference must be refused";
      stage = 4; complete(1, saved); return;
    }
    if (stage == 4) {
      assert v.answer == RunFinalStored, "exact report reference did not commit";
      stage = 5; send owner, eRunCollect, 1; return;
    }
    if (stage == 5) {
      assert v.answer == RunCollectionPending, "report cannot substitute for producer drain";
      stage = 6; send owner, eRunDrain, (pin = pin(1), commit = RunCommitOk); return;
    }
    if (stage == 6) {
      assert v.answer == RunDrained, "original producer did not drain";
      stage = 7; send owner, eRunCollect, 1; return;
    }
    if (stage == 7) {
      assert v.answer == RunCollectionPending, "report cannot be collected before exact session readback";
      stage = 8; send owner, eRunSessionCommit, (key = 1, outcome = 2); return;
    }
    if (stage == 8) {
      assert v.answer == RunCommitRejected, "changed session result must be refused";
      stage = 9; send owner, eRunSessionCommit, (key = 1, outcome = 1); return;
    }
    if (stage == 9) {
      assert v.answer == RunSessionStored, "original session result did not commit";
      if (mode == ReportQuota) {
        stage = 40; send owner, eRunAdmitReport, (key = 2, commit = RunCommitOk);
      } else { stage = 10; send owner, eRunCollect, 1; }
      return;
    }
    if (stage == 10) {
      assert v.answer == RunCollected, "fully discharged report did not collect";
      stage = 11; send owner, eRunRead, 1; return;
    }
    if (stage == 11) {
      assert v.row.report == saved && v.row.charge == saved.bytes + 128,
        "collected report lost complete value or its charge";
      stage = 12; send owner, eRunRestart; return;
    }
    if (stage == 12) {
      assert v.answer == RunRebooted, "report owner did not reboot";
      stage = 13; send owner, eRunRead, 1; return;
    }
    if (stage == 13) {
      assert v.row.report == saved && v.row.collection == RunFrozen && v.row.charge == saved.bytes + 128,
        "reboot lost collected report custody";
      finish(); return;
    }
    if (stage == 20) {
      assert v.answer == RunRebooted, "lost reply control did not reboot";
      stage = 21; send owner, eRunRead, 1; return;
    }
    if (stage == 21) {
      assert v.row.report == saved && v.row.outcome == 0 && v.row.charge == 17301648 &&
        v.row.custody == RunUnreleased && v.admission == RunRecoveryOnly,
        "retained report alone reconstructed final or released original custody";
      stage = 22; retain(1, saved, RunCommitOk, false); return;
    }
    if (stage == 22) {
      assert v.answer == RunPinnedRejected, "old report writer rebound to new owner";
      stage = 23; send owner, eRunAdmitReport, (key = 2, commit = RunCommitOk); return;
    }
    if (stage == 23) {
      assert v.answer == RunRefused, "retained report alone reopened execution";
      finish(); return;
    }
    if (stage == 30) {
      assert v.answer == RunFinalStored, "bounded later diagnostic was not retained";
      stage = 31; send owner, eRunDrain, (pin = pin(1), commit = RunCommitOk); return;
    }
    if (stage == 31) {
      assert v.answer == RunDrained, "failure control did not observe real drain";
      stage = 32; send owner, eRunRestart; return;
    }
    if (stage == 32) {
      assert v.answer == RunRebooted, "failure control did not reboot";
      stage = 33; send owner, eRunRead, 1; return;
    }
    if (stage == 33) {
      assert v.row.report.bytes == 0 && v.row.custody == RunUnreleased && v.admission == RunRecoveryOnly,
        "later diagnostic discharged failed report retention";
      stage = 34; send owner, eRunAdmitReport, (key = 2, commit = RunCommitOk); return;
    }
    if (stage == 34) {
      assert v.answer == RunRefused, "failed report retention reopened capacity";
      finish(); return;
    }
    if (stage == 40) {
      assert v.answer == RunFresh, "second preeffect reservation did not fit";
      stage = 41; send owner, eRunStart, pin(2); return;
    }
    if (stage == 41) {
      assert v.answer == RunStarted, "second original worker did not start";
      stage = 42; retain(2, report(2, 17039376), RunCommitOk, false); return;
    }
    if (stage == 42) {
      assert v.answer == RunReportStored, "admitted maximum report could not be retained under full quota";
      stage = 43; complete(2, report(2, 17039376)); return;
    }
    if (stage == 43) {
      assert v.answer == RunFinalStored, "second original final did not commit";
      stage = 44; send owner, eRunDrain, (pin = pin(2), commit = RunCommitOk); return;
    }
    if (stage == 44) {
      assert v.answer == RunDrained, "second producer did not drain";
      stage = 45; send owner, eRunAdmitReport, (key = 3, commit = RunCommitOk); return;
    }
    if (stage == 45) {
      assert v.answer == RunRefused, "quota admitted an unreserved third maximum report";
      stage = 46; send owner, eRunCollect, 1; return;
    }
    if (stage == 46) {
      assert v.answer == RunCollected, "first report could not release unused allowance";
      stage = 47; send owner, eRunAdmitReport, (key = 3, commit = RunCommitOk); return;
    }
    if (stage == 47) {
      assert v.answer == RunRefused, "collection forgot bytes retained for transcript references";
      stage = 48; send owner, eRunRead, 1; return;
    }
    if (stage == 48) {
      assert v.row.report == saved && v.row.charge == saved.bytes + 128,
        "quota pressure changed original collected report";
      finish(); return;
    }
    assert false, "unexpected report control reply";
  }
}

module ReportCustodySystem = { RunCustodian, RunDownstream, ReportCustodyScenario };
machine TestReportHappy { start state Init { entry { new ReportCustodyScenario(ReportHappy); } } }
test tcReportHappy [main = TestReportHappy]: assert OwnerDischargeSafety, DirectedProgress in (union ReportCustodySystem, { TestReportHappy });
machine TestReportLostReply { start state Init { entry { new ReportCustodyScenario(ReportLost); } } }
test tcReportLostReply [main = TestReportLostReply]: assert OwnerDischargeSafety, DirectedProgress in (union ReportCustodySystem, { TestReportLostReply });
machine TestReportFailedCommit { start state Init { entry { new ReportCustodyScenario(ReportFailed); } } }
test tcReportFailedCommit [main = TestReportFailedCommit]: assert OwnerDischargeSafety, DirectedProgress in (union ReportCustodySystem, { TestReportFailedCommit });
machine TestReportWrongProfile { start state Init { entry { new ReportCustodyScenario(ReportWrongProfile); } } }
test tcReportWrongProfile [main = TestReportWrongProfile]: assert OwnerDischargeSafety, DirectedProgress in (union ReportCustodySystem, { TestReportWrongProfile });
machine TestReportOversize { start state Init { entry { new ReportCustodyScenario(ReportOversize); } } }
test tcReportOversize [main = TestReportOversize]: assert OwnerDischargeSafety, DirectedProgress in (union ReportCustodySystem, { TestReportOversize });
machine TestReportQuota { start state Init { entry { new ReportCustodyScenario(ReportQuota); } } }
test tcReportQuota [main = TestReportQuota]: assert OwnerDischargeSafety, DirectedProgress in (union ReportCustodySystem, { TestReportQuota });
test tcProbeReportHappy [main = TestReportHappy]: assert OwnerDischargeSafety, ReportCustodyReachability in (union ReportCustodySystem, { TestReportHappy });
test tcProbeReportLostReply [main = TestReportLostReply]: assert OwnerDischargeSafety, ReportCustodyReachability in (union ReportCustodySystem, { TestReportLostReply });
test tcProbeReportFailedCommit [main = TestReportFailedCommit]: assert OwnerDischargeSafety, ReportCustodyReachability in (union ReportCustodySystem, { TestReportFailedCommit });
test tcProbeReportWrongProfile [main = TestReportWrongProfile]: assert OwnerDischargeSafety, ReportCustodyReachability in (union ReportCustodySystem, { TestReportWrongProfile });
test tcProbeReportOversize [main = TestReportOversize]: assert OwnerDischargeSafety, ReportCustodyReachability in (union ReportCustodySystem, { TestReportOversize });
test tcProbeReportQuota [main = TestReportQuota]: assert OwnerDischargeSafety, ReportCustodyReachability in (union ReportCustodySystem, { TestReportQuota });

// The producer records actual trusted refusal before the owner sees its final.
// Both refusals still need wrapper drain and exact session commit to collect.
enum tRefusalMode { RefusalVet, RefusalCompile, RefusalMissing, RefusalForged }
event mRefusalScenario: tRefusalMode;
machine ReportRefusalScenario {
  var mode: tRefusalMode; var stage: int; var owner: machine;
  var producer: machine; var pin: tRunPin; var refusal: tPrelaunchRefusal;
  start state Init {
    entry (p: tRefusalMode) {
      mode = p; announce mScenarioBegin; announce mRefusalScenario, mode;
      owner = new RunCustodian((driver = this, downstream = new RunDownstream(this)));
      producer = new RunPrelaunchProducer(); pin = (key = 1, incarnation = 1);
      refusal = VetRefused;
      if (mode == RefusalCompile) { refusal = CompileRefused; }
      send owner, eRunAdmitReport, (key = 1, commit = RunCommitOk); goto Driving;
    }
  }
  state Driving {
    on eRunView do (v: tRunView) {
      if (stage == 0) {
        assert v.answer == RunFresh, "refusal fixture lacks original reservation";
        stage = 1; send owner, eRunStart, pin; return;
      }
      if (stage == 1) {
        assert v.answer == RunStarted, "refusal fixture lacks original wrapper";
        stage = 2;
        if (mode == RefusalMissing) {
          send owner, eRunFinal, (pin = pin, outcome = 1, commit = RunCommitOk);
        } else if (mode == RefusalForged) {
          send owner, eRunRefusalFinal, (pin = pin, outcome = 1, stage = refusal, commit = RunCommitOk);
        } else {
          send producer, eRunProduceRefusal, (owner = owner, witness = (pin = pin, stage = refusal));
        }
        return;
      }
      if (stage == 2) {
        if (mode == RefusalMissing || mode == RefusalForged) {
          assert v.answer == RunCommitRejected && v.row.outcome == 0,
            "unwitnessed report-free final was accepted";
          stage = 8; send owner, eRunDrain, (pin = pin, commit = RunCommitOk); return;
        }
        assert v.answer == RunRefusalObserved, "trusted refusal was not observed";
        stage = 3; send owner, eRunRefusalFinal, (pin = pin, outcome = 1, stage = refusal, commit = RunCommitOk); return;
      }
      if (stage == 3) {
        assert v.answer == RunFinalStored && v.row.report.bytes == 0,
          "trusted refusal should retain bounded final without report";
        stage = 4; send owner, eRunCollect, 1; return;
      }
      if (stage == 4) {
        assert v.answer == RunCollectionPending, "refusal substituted for wrapper drain";
        stage = 5; send owner, eRunDrain, (pin = pin, commit = RunCommitOk); return;
      }
      if (stage == 5) {
        assert v.answer == RunDrained, "refusal wrapper did not drain";
        stage = 6; send owner, eRunSessionCommit, (key = 1, outcome = 1); return;
      }
      if (stage == 6) {
        assert v.answer == RunSessionStored, "refusal exact session result did not commit";
        stage = 7; send owner, eRunCollect, 1; return;
      }
      if (stage == 7) {
        assert v.answer == RunCollected && v.row.report.bytes == 0 && v.row.charge == 128,
          "trusted refusal collection retained wrong charge";
        announce mScenarioEnd; goto Finished;
      }
      if (stage == 8) {
        assert v.answer == RunDrained && v.row.custody == RunUnreleased,
          "missing report final was discharged";
        announce mScenarioEnd; goto Finished;
      }
    }
  }
  state Finished { }
}
module ReportRefusalSystem = { RunCustodian, RunDownstream, RunPrelaunchProducer, ReportRefusalScenario };
machine TestReportRefusalVet { start state Init { entry { new ReportRefusalScenario(RefusalVet); } } }
machine TestReportRefusalCompile { start state Init { entry { new ReportRefusalScenario(RefusalCompile); } } }
machine TestReportRefusalMissing { start state Init { entry { new ReportRefusalScenario(RefusalMissing); } } }
machine TestReportRefusalForged { start state Init { entry { new ReportRefusalScenario(RefusalForged); } } }
test tcReportRefusalVet [main = TestReportRefusalVet]: assert OwnerDischargeSafety, DirectedProgress in (union ReportRefusalSystem, { TestReportRefusalVet });
test tcProbeReportRefusalVet [main = TestReportRefusalVet]: assert OwnerDischargeSafety, RefusalReachability in (union ReportRefusalSystem, { TestReportRefusalVet });
test tcReportRefusalCompile [main = TestReportRefusalCompile]: assert OwnerDischargeSafety, DirectedProgress in (union ReportRefusalSystem, { TestReportRefusalCompile });
test tcProbeReportRefusalCompile [main = TestReportRefusalCompile]: assert OwnerDischargeSafety, RefusalReachability in (union ReportRefusalSystem, { TestReportRefusalCompile });
test tcReportRefusalMissing [main = TestReportRefusalMissing]: assert OwnerDischargeSafety, DirectedProgress in (union ReportRefusalSystem, { TestReportRefusalMissing });
test tcProbeReportRefusalMissing [main = TestReportRefusalMissing]: assert OwnerDischargeSafety, RefusalReachability in (union ReportRefusalSystem, { TestReportRefusalMissing });
test tcReportRefusalForged [main = TestReportRefusalForged]: assert OwnerDischargeSafety, DirectedProgress in (union ReportRefusalSystem, { TestReportRefusalForged });
test tcProbeReportRefusalForged [main = TestReportRefusalForged]: assert OwnerDischargeSafety, RefusalReachability in (union ReportRefusalSystem, { TestReportRefusalForged });
