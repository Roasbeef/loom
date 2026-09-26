// Reachability probes. Each probe asserts that one interesting situation
// never happens, so a probe "failing" is the checker finding a witness that
// the model does reach it. They guard against a vacuous model: a spec that
// passes only because the situation it constrains is unreachable proves
// nothing. The tcProbe* cases are expected to report a bug; the single-spec
// cases at the end pass on the unmutated model and exist for mutate.py.

// A sent mutation's reply was lost and reported UnknownOutcome.
spec ProbeUnknownOutcome observes eCmdResolved {
  start state Watching {
    on eCmdResolved do (p: tCmdPayload) {
      assert p.disp != UNKNOWN, "witness: UnknownOutcome reported";
    }
  }
}

// A command waited behind reconciliation and was later sent.
spec ProbeRetainedSent observes eCmdResolved {
  start state Watching {
    on eCmdResolved do (p: tCmdPayload) {
      assert p.disp != SENT, "witness: retained command sent";
    }
  }
}

// A waiting command was reported DefinitelyNotSent.
spec ProbeRetainedNotSent observes eCmdResolved {
  start state Watching {
    on eCmdResolved do (p: tCmdPayload) {
      assert p.disp != NOT_SENT, "witness: retained command not sent";
    }
  }
}

// A replacement was adopted while an earlier session was visible.
spec ProbeReplacementAdopted observes eVisible {
  var seen: int;
  start state Watching {
    on eVisible do (p: tAttemptSockPayload) {
      seen = seen + 1;
      assert seen < 2, "witness: second adoption";
    }
  }
}

// A replacement retired a lane with a sent mutation still unanswered, so the
// retirement itself produced the UnknownOutcome.
spec ProbeRetiredWithSent observes eCmdAdmitted, eCmdResolved, eLaneClosed {
  var outstanding: map[int, machine];
  var unknownOn: set[machine];
  start state Watching {
    on eCmdAdmitted do (p: tCmdPayload) {
      if (p.disp == SENT) {
        outstanding[p.cmd] = p.sock;
      }
    }
    on eCmdResolved do (p: tCmdPayload) {
      if (p.disp == SENT) {
        outstanding[p.cmd] = p.sock;
      } else if (p.cmd in outstanding) {
        if (p.disp == UNKNOWN) {
          unknownOn += (p.sock);
        }
        outstanding -= (p.cmd);
      }
    }
    on eLaneClosed do (p: tLanePayload) {
      assert !(p.why == LOST_RETIRE && p.sock in unknownOn), "witness: retirement reported UnknownOutcome";
    }
  }
}

// A frame from a replaced socket arrived at the terminal after adoption.
spec ProbeLateOldFrame observes eVisible, eFrame {
  var visible: machine;
  var old: set[machine];
  start state Watching {
    on eVisible do (p: tAttemptSockPayload) {
      if (visible != default(machine)) {
        old += (visible);
      }
      visible = p.sock;
    }
    on eFrame do (p: tFramePayload) {
      assert !(p.sock in old), "witness: frame from a replaced socket after adoption";
    }
  }
}

// A candidate failed while another session was visible.
spec ProbeFailedWhileVisible observes eVisible, eCandidateFailed {
  var visible: bool;
  start state Watching {
    on eVisible do (p: tAttemptSockPayload) {
      visible = true;
    }
    on eCandidateFailed do (p: tAttemptPayload) {
      assert !visible, "witness: candidate failed while a session was visible";
    }
  }
}

// A worker that published Prepared was cancelled rather than acknowledged.
spec ProbePreparedThenCancelled observes ePrepared, eCancel {
  var prepared: set[int];
  start state Watching {
    on ePrepared do (p: tPreparedPayload) {
      prepared += (p.attempt);
    }
    on eCancel do (p: tAttemptPayload) {
      assert !(p.attempt in prepared), "witness: prepared worker cancelled";
    }
  }
}

// A catch-up was written after a commit notice was deferred mid-request.
spec ProbeDeferredNotice observes eWrite, eFrame {
  var busy: map[machine, int];
  var deferred: set[machine];
  start state Watching {
    on eWrite do (p: tWritePayload) {
      if (p.sock in deferred && p.req.kind == CATCH_UP) {
        assert false, "witness: deferred notice spent as a catch-up";
      }
      busy[p.sock] = p.req.id;
    }
    on eFrame do (p: tFramePayload) {
      if (p.msg.kind == M_COMMITTED && p.sock in busy) {
        deferred += (p.sock);
      }
      if (p.sock in busy && p.msg.replyTo == busy[p.sock] && p.msg.kind != M_COMMITTED) {
        busy -= (p.sock);
      }
    }
  }
}

test tcProbeUnknown [main = TestReplace]: assert ProbeUnknownOutcome in (union System, { TestReplace });
test tcProbeRetainedSent [main = TestReplace]: assert ProbeRetainedSent in (union System, { TestReplace });
test tcProbeRetainedNotSent [main = TestReplace]: assert ProbeRetainedNotSent in (union System, { TestReplace });
test tcProbeReplacement [main = TestReplace]: assert ProbeReplacementAdopted in (union System, { TestReplace });
test tcProbeRetired [main = TestReplace]: assert ProbeRetiredWithSent in (union System, { TestReplace });
test tcProbeLateOldFrame [main = TestReplace]: assert ProbeLateOldFrame in (union System, { TestReplace });
test tcProbeFailedWhileVisible [main = TestReplace]: assert ProbeFailedWhileVisible in (union System, { TestReplace });
test tcProbePreparedCancelled [main = TestQuit]: assert ProbePreparedThenCancelled in (union System, { TestQuit });
test tcProbeDeferredNotice [main = TestReplace]: assert ProbeDeferredNotice in (union System, { TestReplace });

// Single-spec tests, so a mutation is attributed to the spec that owns the
// rule rather than to whichever spec a run happens to break first.
test tcWriteAfterShutOnly [main = TestReplace]: assert NoWriteAfterShut in (union System, { TestReplace });
test tcCustodyQuitLate [main = TestQuit]: assert QuitReleasesEverything in (union System, { TestQuit });
test tcCustodyQuitEarly [main = TestQuitEarly]: assert QuitReleasesEverything in (union System, { TestQuitEarly });
