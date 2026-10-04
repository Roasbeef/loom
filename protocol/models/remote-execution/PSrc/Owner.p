// The owner persists a reconciliation handle before transmission. Terminal
// delivery commits locally, but only an explicit receipt message authorizes
// executor compaction. Restart retains both stores and changes connection.
machine Owner {
  var driver: machine;
  var executor: machine;
  var mode: tMode;
  var connection: int;
  var custody: map[tKey, int];
  var outcomes: map[tKey, int];

  start state Init {
    entry (p: (driver: machine, executor: machine, mode: tMode)) {
      driver = p.driver;
      executor = p.executor;
      mode = p.mode;
      connection = 1;
      goto Ready;
    }
  }

  state Ready {
    on ePrepare do (r: tRequest) {
      if (!(r.key in custody)) {
        custody[r.key] = r.digest;
        announce mCustody, r;
      }
      transmit(eAdmit, r);
    }
    on eOwnerReconcile do (r: tRequest) { transmit(eReconcile, r); }
    on eRetry do (r: tRequest) { transmit(eAdmit, r); }
    on eOwnerCancel do (r: tRequest) { transmit(eCancel, r); }
    on eOwnerReceipt do (r: tRequest) {
      if (r.key in outcomes && outcomes[r.key] == r.digest) {
        transmit(eReceipt, r);
      }
    }
    on eReconnect do { connection = connection + 1; }
    on eOwnerCrash do {
      connection = connection + 1;
      send driver, eControlDone;
    }
    on eReply do (p: tReply) {
      // An obsolete connection can lose a reply, but cannot erase custody.
      if (p.connection != connection) {
        announce mWitness, LostTransport;
        return;
      }
      if (p.answer == Prior && p.row.phase == Terminal) {
        if (!(p.request.key in outcomes)) {
          outcomes[p.request.key] = p.request.digest;
          announce mOwnerStored, p.request;
        }
      }
      send driver, eView, p;
    }
  }

  fun transmit(ev: event, r: tRequest) {
    assert r.key in custody, "owner transmitted without durable custody";
    if (mode == Lossy && choose()) {
      announce mWitness, LostTransport;
      if (ev == eAdmit) { announce mWitness, AdmissionLost; }
      if (ev == eReceipt) { announce mWitness, ReceiptLost; }
      if (ev == eCancel) { announce mWitness, CancelLost; }
      return;
    }
    send executor, ev, (owner = this, request = r, connection = connection);
  }
}
