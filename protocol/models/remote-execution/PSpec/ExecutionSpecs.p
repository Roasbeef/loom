// The properties of background executions (protocol-change/078, the addendum
// on background code mode, "The P model"). `AtMostOnceStart`, `UnknownIsFinal`
// and `StaleTokenRefused` in Specs.p already cover execution keys, which share
// the host's admission with tool calls.

// Once the host has processed a stop for a key, no program for the key starts.
// exec_ledger.stop_or_fence bars a key with no row in the same transaction, so a
// start a dead worker sent before the record closed finds the key taken.
spec ExecNoStartAfterStop observes eStopProcessed, eStart {
  var stopped: set[tKey];

  start state Watching {
    on eStopProcessed do (key: tKey) {
      stopped += (key);
    }

    on eStart do (p: (key: tKey, runToken: int, scopeToken: int)) {
      assert !(p.key in stopped), format("execution {0} started after the host processed its stop", p.key);
    }
  }
}

// A record finished with a value only if the ledger stored that value as the
// execution's terminal row. host.run_finished commits before any answer, and
// recovery reads only a terminal row.
spec ExecFinishedIsStored observes eTerminal, eRecordFinished {
  var stored: map[tKey, int];

  start state Watching {
    on eTerminal do (p: (key: tKey, outcome: int)) {
      stored[p.key] = p.outcome;
    }

    on eRecordFinished do (p: (key: tKey, outcome: int)) {
      assert p.key in stored, format("execution {0} finished with no terminal row", p.key);
      assert stored[p.key] == p.outcome, format("execution {0} finished as {1} and the ledger stored {2}", p.key, p.outcome, stored[p.key]);
    }
  }
}

// A stop reaches the host only for an execution whose record the service had
// decided to close. A dropped connection is not such a decision: the worker
// sends the same start again and the program runs on.
spec ExecStopOnlyOnDecision observes eStopDecided, eStopProcessed {
  var decided: set[tKey];

  start state Watching {
    on eStopDecided do (key: tKey) {
      decided += (key);
    }

    on eStopProcessed do (key: tKey) {
      assert key in decided, format("execution {0} was stopped though its record was never closed", key);
    }
  }
}

// A program that committed its value while its record was live, with no stop
// decided, ends finished. An answer from the executor that calls such an
// execution lost would mean its stored value was thrown away before the
// worker read it.
spec ExecNotLostWhenFinished observes eTerminal, eStopDecided, eRecordLost {
  var committed: set[tKey];
  var decided: set[tKey];

  start state Watching {
    on eTerminal do (p: (key: tKey, outcome: int)) {
      if (isExecution(p.key)) {
        committed += (p.key);
      }
    }

    on eStopDecided do (key: tKey) {
      decided += (key);
    }

    on eRecordLost do (p: (key: tKey, decided: bool)) {
      if (!p.decided && p.key in committed) {
        assert p.key in decided, format("execution {0} stored its value and was recorded lost", p.key);
      }
    }
  }
}

// The reconciler acknowledges an execution's row only while its record is
// finished or lost (`workspace.settled_by_kind`). An acknowledgement while the
// record is live leaves a tombstone that answers the worker's re-send as lost.
spec ExecAckOnlyWhenRecordTerminal observes eExecCreated, eRecordFinished, eRecordLost, eExecAckSent {
  var live: set[tKey];

  start state Watching {
    on eExecCreated do (key: tKey) {
      live += (key);
    }

    on eRecordFinished do (p: (key: tKey, outcome: int)) {
      live -= (p.key);
    }

    on eRecordLost do (p: (key: tKey, decided: bool)) {
      live -= (p.key);
    }

    on eExecAckSent do (key: tKey) {
      assert !(key in live), format("execution {0} was acknowledged while its record was live", key);
    }
  }
}

// Liveness: every claimed record ends finished or lost, and every program that
// started ends terminal or unknown. The deadline closes every record, so a
// program still running at the end is one nobody stopped.
spec EveryExecutionSettles observes eExecCreated, eRecordFinished, eRecordLost, eStart, eTerminal, eUnknown {
  var records: set[tKey];
  var programs: set[tKey];

  start cold state Settled {
    on eExecCreated do (key: tKey) {
      records += (key);
      goto Waiting;
    }

    on eStart do (p: (key: tKey, runToken: int, scopeToken: int)) {
      if (isExecution(p.key)) {
        programs += (p.key);
        goto Waiting;
      }
    }

    ignore eRecordFinished, eRecordLost, eTerminal, eUnknown;
  }

  hot state Waiting {
    on eExecCreated do (key: tKey) {
      records += (key);
    }

    on eStart do (p: (key: tKey, runToken: int, scopeToken: int)) {
      if (isExecution(p.key)) {
        programs += (p.key);
      }
    }

    on eRecordFinished do (p: (key: tKey, outcome: int)) {
      records -= (p.key);
      settle();
    }

    on eRecordLost do (p: (key: tKey, decided: bool)) {
      records -= (p.key);
      settle();
    }

    on eTerminal do (p: (key: tKey, outcome: int)) {
      programs -= (p.key);
      settle();
    }

    on eUnknown do (key: tKey) {
      programs -= (key);
      settle();
    }
  }

  fun settle() {
    if (sizeof(records) == 0 && sizeof(programs) == 0) {
      goto Settled;
    }
  }
}

// Probes for the execution paths the specs above are meaningful only if the
// model reaches.

// A start found its key barred by a stop that arrived first.
spec ProbeExecStartBarred observes eBarredStart {
  start state Watching {
    on eBarredStart do (key: tKey) {
      assert false, "witness: a late start found its key barred";
    }
  }
}

// Recovery after an orchestrator restart kept a value the executor stored.
spec ProbeExecRecoveredValue observes eExecRecovered {
  start state Watching {
    on eExecRecovered do (key: tKey) {
      assert false, "witness: recovery kept a stored execution value";
    }
  }
}
