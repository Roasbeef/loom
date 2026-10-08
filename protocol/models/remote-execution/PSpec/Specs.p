// The properties the model checks. Each spec is named after the rule it
// encodes, and the comment above it cites where that rule lives. The rules
// come from protocol-change/078 and the "Remote tool calls" section of
// packages/client/CLAUDE.md.

// The tool body for a key starts at most once, ever. This is what makes a
// re-send safe: host.admit_run starts a run only for a row it just inserted
// (host.gleam, "One run per call key"), and exec_ledger.admit inserts the row
// and checks the scope in one transaction.
spec AtMostOnceStart observes eStart {
  var started: set[tKey];

  start state Watching {
    on eStart do (p: (key: tKey, runToken: int, scopeToken: int)) {
      assert !(p.key in started), format("the tool body for key {0} started twice", p.key);
      started += (p.key);
    }
  }
}

// Once recovery has told the orchestrator that a ReplayNever call did not
// start, or the ledger holds its fence, the key never starts. This is
// `exec_ledger.query_or_fence` and surface.recover ("A missing row is not yet
// an answer"): a plain Query that finds no row leaves a window in which a dead
// runtime's `Run` is still in flight. A report of "not started" is also a claim
// about the past, so it must not follow a start.
spec NoStartAfterFence observes eFenced, eReportedNotStarted, eStart {
  var fenced: set[tKey];
  var started: set[tKey];

  start state Watching {
    on eFenced do (key: tKey) {
      fenced += (key);
    }

    on eReportedNotStarted do (key: tKey) {
      assert !(key in started), format("key {0} was reported as not started after it started", key);
      fenced += (key);
    }

    on eStart do (p: (key: tKey, runToken: int, scopeToken: int)) {
      assert !(p.key in fenced), format("the tool body for key {0} started after the key was fenced", p.key);
      started += (p.key);
    }
  }
}

// An unknown key is final: it is never started again, never given a terminal
// outcome, and never staged for the model as finished or as "did not run".
// host.cancel_run marks the row unknown before the worker dies, a request for
// an unknown key answers RunLost, and exec_ledger.open turns every admitted row
// unknown on a new VM (client/CLAUDE.md, "a request for an `unknown` key never
// starts the call again").
spec UnknownIsFinal observes eUnknown, eStart, eTerminal, eDelivered {
  var unknown: set[tKey];

  start state Watching {
    on eUnknown do (key: tKey) {
      unknown += (key);
    }

    on eStart do (p: (key: tKey, runToken: int, scopeToken: int)) {
      assert !(p.key in unknown), format("key {0} started after it became unknown", p.key);
    }

    on eTerminal do (p: (key: tKey, outcome: int)) {
      assert !(p.key in unknown), format("key {0} got a terminal outcome after it became unknown", p.key);
    }

    on eDelivered do (p: (key: tKey, kind: tDelivery, outcome: int)) {
      if (p.key in unknown) {
        assert p.kind != D_FINISHED && p.kind != D_NOT_RUN, format("key {0} is unknown and was staged as another outcome", p.key);
      }
    }
  }
}

// An outcome the orchestrator stages as finished is the outcome the ledger
// stored as terminal for the key, and was stored before the orchestrator could
// have heard it. host.run_finished commits `finish` before any reply, and
// exec_ledger.query verifies the stored digest. A key is staged at most once.
spec OutcomeFaithful observes eTerminal, eDelivered {
  var stored: map[tKey, int];
  var staged: set[tKey];

  start state Watching {
    on eTerminal do (p: (key: tKey, outcome: int)) {
      stored[p.key] = p.outcome;
    }

    on eDelivered do (p: (key: tKey, kind: tDelivery, outcome: int)) {
      assert !(p.key in staged), format("key {0} was staged twice", p.key);
      staged += (p.key);
      if (p.kind == D_FINISHED) {
        assert p.key in stored, format("key {0} was staged as finished with no terminal row in the ledger", p.key);
        assert stored[p.key] == p.outcome, format("key {0} was staged as {1} and the ledger stored {2}", p.key, p.outcome, stored[p.key]);
      }
    }
  }
}

// A `Run` carrying a token that is not the scope's current token never starts
// a tool body. exec_ledger.require_current compares by value inside the
// admitting transaction, so no ordering of messages slips a dead open's `Run`
// past it (surface.gleam, "Attach first, once per session open").
spec StaleTokenRefused observes eStart {
  start state Watching {
    on eStart do (p: (key: tKey, runToken: int, scopeToken: int)) {
      assert p.runToken == p.scopeToken, format("key {0} started for token {1} while the scope held {2}", p.key, p.runToken, p.scopeToken);
    }
  }
}

// The host cancels a live run only for a waiter that went away on purpose.
// A `noconnection` DOWN means the orchestrator is unreachable, and the run
// goes on with its outcome in the ledger (host.cancels_run, client/CLAUDE.md
// "The host cancels a run only when its last waiter exits with a reason other
// than `noconnection`").
spec CancelOnlyOnAbort observes eCancelled {
  start state Watching {
    on eCancelled do (p: (key: tKey, noconn: bool)) {
      assert !p.noconn, format("key {0} was cancelled because the connection dropped", p.key);
    }
  }
}

// Every call the session made durable eventually has its outcome staged. A
// dropped connection is repaired by sending again, a dead open is recovered by
// the next, and a restarted executor answers every key from the ledger, so
// bounded faults delay the outcome and cannot lose it. P reports a violation
// when a run ends with the monitor in the hot state.
spec EveryKeyDelivered observes eIntent, eDelivered {
  var pending: set[tKey];

  start cold state Settled {
    on eIntent do (key: tKey) {
      pending += (key);
      goto Waiting;
    }
  }

  hot state Waiting {
    on eIntent do (key: tKey) {
      pending += (key);
    }

    on eDelivered do (p: (key: tKey, kind: tDelivery, outcome: int)) {
      pending -= (p.key);
      if (sizeof(pending) == 0) {
        goto Settled;
      }
    }
  }
}

// A refusal staged for the model means the executor never started the call.
// surface.run stages a RunRefused as the refusal's text, which reads as "the
// call did not happen". This is not a rule the code states; it is the rule the
// text implies. It does not hold today (README.md, "Defects found"), so it is
// asserted only by the case that demonstrates the defect.
spec RefusalMeansUntouched observes eStart, eDelivered {
  var started: set[tKey];

  start state Watching {
    on eStart do (p: (key: tKey, runToken: int, scopeToken: int)) {
      started += (p.key);
    }

    on eDelivered do (p: (key: tKey, kind: tDelivery, outcome: int)) {
      if (p.kind == D_NOPLANE || p.kind == D_STALE) {
        assert !(p.key in started), format("key {0} started, and the model was told the executor refused it", p.key);
      }
    }
  }
}
