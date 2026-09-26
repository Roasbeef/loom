// The operator and the clock.
//
// The Operator opens the first session, then takes `steps` actions, one per
// scheduling step so that they interleave with network traffic: submit a
// mutation, press Escape, open a replacement (when `replace` holds), or let
// the idle refresh or a request deadline fall due. With `quit` it presses
// Ctrl-C after its last action. Between actions it idles for a random number
// of its own steps, which spreads the actions over the whole run instead of
// spending them all before the first attachment completes.
machine Operator {
  var terminal: machine;
  var remaining: int;
  var replace: bool;
  var quitAtEnd: bool;

  start state Init {
    entry (p: (terminal: machine, steps: int, replace: bool, quit: bool)) {
      terminal = p.terminal;
      remaining = p.steps;
      replace = p.replace;
      quitAtEnd = p.quit;
      send terminal, eOpOpen;
      send this, eNextAction;
      goto Acting;
    }
  }

  state Acting {
    on eNextAction do {
      if (choose(4) != 0) {
        send this, eNextAction;
      } else if (remaining == 0) {
        if (quitAtEnd) {
          send terminal, eOpQuit;
        }
        goto Finished;
      } else {
        act();
        remaining = remaining - 1;
        send this, eNextAction;
      }
    }
  }

  state Finished {
    ignore eNextAction;
  }

  fun act() {
    var a: int;
    a = choose(10);
    if (a < 4) {
      send terminal, eOpSubmit;
    } else if (a == 4) {
      send terminal, eOpEscape;
    } else if (a == 5 || a == 6) {
      if (replace) {
        send terminal, eOpOpen;
      } else {
        send terminal, eOpSubmit;
      }
    } else if (a == 7 || a == 8) {
      send terminal, eClockRefresh;
    } else {
      send terminal, eClockDeadline;
    }
  }
}

// One terminal on one session, submitting mutations; no replacement.
machine TestSubmit {
  start state Init {
    entry {
      var t: machine;
      t = new Terminal();
      new Operator((terminal = t, steps = 8, replace = false, quit = false));
    }
  }
}

// Replacement attempts interleaved with submissions, refreshes and
// deadlines; no quit, so every liveness spec must reach a cold state.
machine TestReplace {
  start state Init {
    entry {
      var t: machine;
      t = new Terminal();
      new Operator((terminal = t, steps = 10, replace = true, quit = false));
    }
  }
}

// The same traffic ending in Ctrl-C, often while an attempt is open.
machine TestQuit {
  start state Init {
    entry {
      var t: machine;
      t = new Terminal();
      new Operator((terminal = t, steps = 6, replace = true, quit = true));
    }
  }
}

// Ctrl-C after at most two actions: quit races the first attachment.
machine TestQuitEarly {
  start state Init {
    entry {
      var t: machine;
      t = new Terminal();
      new Operator((terminal = t, steps = 2, replace = true, quit = true));
    }
  }
}
