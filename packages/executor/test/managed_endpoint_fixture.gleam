//// Component witnesses in this fixed TLS fixture validate synthetic retirement
//// metadata explicitly. They establish no native/resource/full-host cleanup.
//// Original publication/removal uses real endpoint actors and SQL transactions.

import beam_endpoint_fixture as credit_fixture
import broker/enrollment
import broker/exec
import broker/executor as local
import broker/policy
import codemode/service_input as input
import codemode/vet/policy as vet
import core/generation as g
import core/ids
import core/msgpack as mp
import core/workspace
import distribution_fixture as fixture
import executor/generation_registry as r
import executor/remote/admission
import executor/remote/beam_endpoint as e
import executor/remote/compile_service as compile
import executor/remote/distribution
import executor/remote/identity
import executor/remote/journal
import executor/remote/resource_journal as resources
import executor/remote/service
import executor/remote/wire
import gleam/crypto
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile
import telemetry/log
import weft/poll

type NativeRow {
  NativeRow(
    row: e.Registration,
    native: service.Service,
    book: journal.Journal,
    path: String,
  )
}

/// Runs one closed component control in its original TLS executor.
///
/// ## Examples
///
/// `run(root, "removal")` exercises original removal acknowledgements.
pub fn run(root: String, name: String) {
  let assert Ok(provisioned) = fixture.read_provisioned(root <> "/fixture.term")
    as "original TLS fixture"
  let assert Ok(membership) = distribution.start(provisioned.executor_config)
    as "actual executor membership"
  let assert Ok(owner) = distribution.peer(membership, provisioned.owner_name)
    as "original owner peer"
  case name {
    "compatibility" -> compatibility(root, owner)
    "validation" -> validation(root, owner)
    "removal" -> removal(root, owner)
    "capacity" -> capacity(root, owner)
    "quota" -> quota(root, owner)
    "credits" -> credits(root, owner)
    "enrollment" -> enrolled_control(root, owner)
    _ -> panic as "Only fixed component controls are callable."
  }
  assert simplifile.write(root <> "/success", name) == Ok(Nil)
}

fn compatibility(root: String, owner: distribution.Peer) {
  let n = native_row(root, owner, 1, 1)
  let assert Ok(config) = e.configure_server([n.row], 1000)
    as "legacy configuration"
  let assert Ok(server) = e.start(config) as "legacy concrete row"
  assert e.inspect(server) == Ok(e.Capacity(1, 4, 2))
  assert e.register(server, n.row) == Error(e.ConflictingRegistration)
  assert e.publication_endpoint(server, n.row) == Error(e.InvalidConfiguration)
  stop(server)
  let store = new_store(root, "registry", 4)
  let server = managed(store)
  assert e.register(server, n.row) == Error(e.InvalidConfiguration)
  let associated = association(1, 1, digest(2))
  let claim = new_claim(store, associated)
  assert e.register_generation(server, n.row, claim)
    == Error(e.InvalidConfiguration)
  publish(store, server, n.row, claim)
  assert e.inspect(server) == Ok(e.Capacity(1, 4, 2))
  assert e.register(server, n.row) == Error(e.InvalidConfiguration)
  stop(server)
  clean(n)
  assert r.release(store) == Ok(Nil)
}

fn validation(root: String, owner: distribution.Peer) {
  let store = new_store(root, "original", 8)
  let other = new_store(root, "other", 8)
  let server = managed(store)
  let n = native_row(root, owner, 1, 1)
  let changed = native_row(root, owner, 1, 1)
  let wrong_scope = native_row(root, owner, 2, 1)
  let wrong_generation = native_row(root, owner, 1, 2)
  let original = association(1, 1, digest(2))
  let claim = new_claim(store, original)
  let other_claim = new_claim(other, original)
  let assert Ok(endpoint) = e.publication_endpoint(server, n.row)
    as "original row endpoint"
  let assert Ok(permit) = r.prepare_publication(claim, endpoint)
    as "original intent"
  let assert Ok(_) = r.prepare_publication(other_claim, endpoint)
    as "other original store"
  assert e.register_generation(server, n.row, other_claim)
    == Error(e.InvalidConfiguration)
  assert e.register_generation(server, changed.row, claim)
    == Error(e.InvalidConfiguration)
  assert e.register_generation(server, wrong_scope.row, claim)
    == Error(e.InvalidConfiguration)
  assert e.register_generation(server, wrong_generation.row, claim)
    == Error(e.InvalidConfiguration)
  assert e.register_generation(server, n.row, claim) == Ok(Nil)
  assert r.published(permit) == Ok(Nil)
  let #(full, _, _) = g.key_fields(g.association_key(original))
  let assert Ok(changed_key) = g.key(full, digest(3), 1)
    as "distinct same-Scope generation key"
  assert r.admit(
      store,
      g.association(changed_key, digest(2), uuid(200), g.FirstGeneration),
      doors(),
      1,
      None,
    )
    == Error(r.Conflict)
  assert e.register_generation(server, n.row, claim)
    == Error(e.InvalidConfiguration)

  // Durable Close precedes any delayed publication of a separately admitted row.
  let original2 = association(2, 1, digest(2))
  let claim2 = new_claim(store, original2)
  let assert Ok(endpoint2) = e.publication_endpoint(server, wrong_scope.row)
    as "second row"
  let assert Ok(_) = r.prepare_publication(claim2, endpoint2) as "second intent"
  assert r.close_generation(store, g.association_key(original2))
    == Ok(r.Closing)
  assert e.register_generation(server, wrong_scope.row, claim2)
    == Error(e.InvalidConfiguration)
  assert e.inspect(server) == Ok(e.Capacity(1, 4, 2))
  stop(server)
  list.each([n, changed, wrong_scope, wrong_generation], clean)
  assert r.release(store) == Ok(Nil)
  assert r.release(other) == Ok(Nil)
}

fn removal(root: String, owner: distribution.Peer) {
  let store = new_store(root, "registry", 8)
  let server = managed(store)
  let n = native_row(root, owner, 1, 1)
  let changed = native_row(root, owner, 1, 1)
  let original = association(1, 1, digest(2))
  let claim = new_claim(store, original)
  publish(store, server, n.row, claim)
  let retired = retire(store, server, n.row, claim)
  assert e.retire_registration(server, n.row, retired) == Error(e.Uncertain)
  assert e.fence(server, n.row) == Ok(Nil)
  assert e.inspect_drain(server, n.row) == Ok(e.Drained)
  assert e.retire_registration(server, changed.row, retired)
    == Error(e.InvalidConfiguration)
  assert e.retire_registration(server, n.row, retired) == Ok(Nil)
  assert e.inspect(server) == Ok(e.Capacity(0, 4, 2))
  assert e.retire_registration(server, n.row, retired) == Ok(Nil)
  assert r.observe(store, g.association_key(original)) == Ok(r.Retired)
  assert r.remove(store, retired, fn(record) {
      e.retire_registration(server, n.row, record)
      |> result.replace_error(r.Uncertain)
    })
    == Ok(Nil)
  assert e.retire_registration(server, n.row, retired) == Ok(Nil)
  assert e.register_generation(server, n.row, claim)
    == Error(e.InvalidConfiguration)

  // An interrupted Publishing intent never establishes original hot-row removal.
  let absent = native_row(root, owner, 2, 1)
  let absent_claim = new_claim(store, association(2, 1, digest(2)))
  let assert Ok(ep) = e.publication_endpoint(server, absent.row)
    as "unforwarded intent"
  let assert Ok(_) = r.prepare_publication(absent_claim, ep)
    as "possible publication"
  let absent_record = retire(store, server, absent.row, absent_claim)
  assert e.retire_registration(server, absent.row, absent_record)
    == Error(e.InvalidConfiguration)
  assert e.retire_registration(server, n.row, absent_record)
    == Error(e.InvalidConfiguration)
  assert e.retire_registration(server, absent.row, retired)
    == Error(e.InvalidConfiguration)
  stop(server)
  let replacement = managed(store)
  assert e.retire_registration(replacement, n.row, retired)
    == Error(e.InvalidConfiguration)
  stop(replacement)
  list.each([n, changed, absent], clean)
  assert r.release(store) == Ok(Nil)
}

fn capacity(root: String, owner: distribution.Peer) {
  let store = new_store(root, "registry", 20)
  let server = managed(store)
  list.each(
    list.index_map(list.repeat(Nil, 20), fn(_, index) { index + 1 }),
    fn(number) {
      let n = native_row(root, owner, number, 1)
      let claim = new_claim(store, association(number, 1, digest(2)))
      publish(store, server, n.row, claim)
      assert e.inspect(server) == Ok(e.Capacity(1, 4, 2))
      assert e.fence(server, n.row) == Ok(Nil)
      let record = retire(store, server, n.row, claim)
      assert r.remove(store, record, fn(record) {
          e.retire_registration(server, n.row, record)
          |> result.replace_error(r.Uncertain)
        })
        == Ok(Nil)
      assert e.inspect(server) == Ok(e.Capacity(0, 4, 2))
      clean(n)
    },
  )
  assert r.admit(store, association(21, 1, digest(2)), doors(), 1, None)
    == Error(r.Capacity)
  stop(server)
  assert r.release(store) == Ok(Nil)
}

fn quota(root: String, owner: distribution.Peer) {
  let store = new_store(root, "registry", 32)
  let server = managed(store)
  let rows =
    list.index_map(list.repeat(Nil, 16), fn(_, index) {
      let number = index + 1
      let n = native_row(root, owner, number, 1)
      let claim = new_claim(store, association(number, 1, digest(2)))
      #(n, claim)
    })
  let assert [#(first, _), ..] = rows as "first admitted original"

  // Fifteen physical rows and one admitted startup still consume sixteen slots.
  list.each(list.drop(rows, 1), fn(pair) {
    publish(store, server, pair.0.row, pair.1)
  })
  assert e.inspect(server) == Ok(e.Capacity(15, 4, 2))
  assert r.admit(store, association(17, 1, digest(2)), doors(), 1, None)
    == Error(r.Capacity)
  let assert [#(_, claim), ..] = rows as "original unpublished claim"
  publish(store, server, first.row, claim)
  assert e.inspect(server) == Ok(e.Capacity(16, 4, 2))
  stop(server)
  list.each(rows, fn(pair) { clean(pair.0) })
  assert r.release(store) == Ok(Nil)
}

fn credits(root: String, owner: distribution.Peer) {
  let n = native_row(root, owner, 1, 1)
  credit_fixture.hold_managed_service(service.pid(n.native))
  let store = new_store(root, "registry", 2)
  let server = managed(store)
  let claim = new_claim(store, association(1, 1, digest(2)))
  publish(store, server, n.row, claim)
  assert simplifile.write(root <> "/ready", "ready") == Ok(Nil)
  let assert poll.Answered(Nil) =
    poll.until(1000, 1, fn() {
      case e.inspect(server) == Ok(e.Capacity(1, 3, 2)) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "actual original endpoint assignment precedes fencing"
  assert e.fence(server, n.row) == Ok(Nil)
  let retired = retire(store, server, n.row, claim)
  assert e.inspect_drain(server, n.row) == Ok(e.Busy)
  assert e.retire_registration(server, n.row, retired) == Error(e.Uncertain)
  credit_fixture.retire_managed_busy(e.pid(server))
  let assert poll.Answered(Nil) =
    poll.until(1000, 1, fn() {
      case e.inspect_drain(server, n.row) {
        Ok(e.DrainUncertain) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "actual original credit death retains assignment"
  assert e.retire_registration(server, n.row, retired) == Error(e.Uncertain)
  assert e.inspect(server) == Ok(e.Capacity(1, 3, 2))
  credit_fixture.release_managed_service(service.pid(n.native))
  await(root, "owner-done")
  stop(server)
  clean(n)
  assert r.release(store) == Ok(Nil)
}

/// Sends one actual exchange against the original assigned credit.
///
/// ## Examples
///
/// `owner_run(root)` waits for the fixed executor fixture to publish.
pub fn owner_run(root: String) {
  let assert Ok(provisioned) = fixture.read_provisioned(root <> "/fixture.term")
    as "original owner fixture"
  let assert Ok(membership) = distribution.start(provisioned.owner_config)
    as "actual owner membership"
  let assert Ok(peer) = distribution.peer(membership, provisioned.executor_name)
    as "original executor"
  await(root, "ready")
  let assert Ok(request) =
    identity.request_id("00000000-0000-7000-8000-000000000002")
    as "original request"
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000003")
    as "original operation"
  let key = identity.request_key(scope(1), operation, request)
  let assert Ok(digest) = identity.digest(<<1:size(256)>>)
    as "fixed request digest"
  assert e.exchange(
      e.Config(peer, "owner", "executor", scope(1), 1, 200),
      wire.ChallengeRequest(key, digest),
    )
    == Error(e.Uncertain)
  assert simplifile.write(root <> "/owner-done", "done") == Ok(Nil)
}

fn enrolled_control(root: String, owner: distribution.Peer) {
  let n = native_row(root, owner, 1, 1)
  let base =
    policy.SandboxPolicy(
      writable_roots: ["/work", "/alloc"],
      readable_roots: ["/tc", "/seed", "/work"],
      protected: ["/work/.git"],
      network: policy.NetworkOff,
      limits: policy.Limits(11, 12, 13, 14, 15, 16),
      env_allow: ["PATH", "HOME"],
      scratch: policy.ScratchTmpfs,
      mounts: [
        policy.Mount("/tc", policy.MountReadOnly, policy.MountRequired),
        policy.Mount("/seed", policy.MountReadOnly, policy.MountOptional),
      ],
    )
  let full = g.key_scope(g.association_key(association(1, 1, digest(2))))
  let assert Ok(enrolled) =
    enrollment.new(
      enrollment.NativeFacts(full, ["/"], base, exec.PlatformEnforcement),
      enrollment.CodeModeFacts(
        "/work",
        "/alloc/build",
        "/alloc/channel",
        "/tc/bin/gleam",
        "/tc/bin/erl",
        "/seed",
        ["/tc"],
        base.mounts,
        "/tc/bin",
      ),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "fixed complete enrollment"
  let assert Ok(limits) = resources.limits(2, 40_000_000) as "resource bounds"
  let assert Ok(resources) =
    resources.fresh(root <> "/resources.sqlite", enrolled, limits, n.book)
    as "real enrolled journal"
  let assert Ok(contract) =
    input.trusted_contract(
      enrolled,
      input.WorkspaceProgram,
      vet.workspace_effects(),
      [],
    )
    as "fixed contract"
  let assert Ok(config) = compile.configure(resources, n.native, contract, 1)
    as "exact scoped owner"
  let assert Ok(whole) = compile.start(config) as "original whole Compile owner"
  let assert Ok(row) =
    e.compile_registration(owner, whole, None, process.self())
    as "checked full row"
  let store = new_store(root, "registry", 3)
  let server = managed(store)
  let claim = new_claim(store, association(1, 1, digest(2)))
  let assert Ok(endpoint) = e.publication_endpoint(server, row)
    as "full original endpoint"
  let assert Ok(_) = r.prepare_publication(claim, endpoint)
    as "claimed incorrect enrollment"
  assert e.register_generation(server, row, claim)
    == Error(e.InvalidConfiguration)
  assert e.inspect(server) == Ok(e.Capacity(0, 4, 2))
  stop(server)
  assert r.release(store) == Ok(Nil)

  // A separate original writer can publish the exact complete enrollment bytes.
  let store = new_store(root, "correct", 2)
  let server = managed(store)
  let assert Ok(bytes) = enrollment.encode(enrolled) as "canonical enrollment"
  let assert Ok(hash) = g.digest(crypto.hash(crypto.Sha256, bytes))
    as "complete enrollment digest"
  let claim = new_claim(store, association(1, 1, hash))
  publish(store, server, row, claim)
  assert e.inspect(server) == Ok(e.Capacity(1, 4, 2))
  stop(server)
  assert compile.close(whole) == Ok(Nil)
  assert resources.release_endpoint(resources) == Ok(Nil)
  clean(n)
  assert r.release(store) == Ok(Nil)
}

fn native_row(
  root: String,
  owner: distribution.Peer,
  number: Int,
  generation: Int,
) -> NativeRow {
  let assert Ok(pool) =
    local.start(local.ExecutorConfig(
      fn() { Error(exec.PoolUnavailable) },
      fn(_) { Nil },
      fn() { Error(exec.PoolUnavailable) },
      fn(_) { Ok(Nil) },
      17,
      log.discard(),
    ))
    as "real idle native actor"
  let assert Ok(capacity) = admission.capacity(8) as "native inventory"
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    root
    <> "/native-"
    <> int.to_string(seconds)
    <> int.to_string(nanos)
    <> ".sqlite"
  let assert Ok(book) = journal.fresh(path, scope(number), capacity)
    as "real original native journal"
  let assert Ok(native) =
    service.start(
      service.Config(
        "owner",
        "executor",
        scope(number),
        generation,
        book,
        pool,
        fn(_, _) { Ok(Nil) },
        fn() { 0 },
      ),
    )
    as "real original scoped actor"
  let assert Ok(row) = e.registration(owner, native, None, process.self())
    as "checked concrete row"
  NativeRow(row, native, book, path)
}

fn scope(number: Int) -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "session"
  let assert Ok(name) =
    identity.workspace_id("checkout-" <> int.to_string(number))
    as "workspace"
  let assert Ok(executor) = identity.executor_id("executor") as "executor"
  let assert Ok(epoch) = identity.epoch(1) as "epoch"
  identity.scope(session, name, executor, epoch, epoch)
}

fn association(
  number: Int,
  generation: Int,
  enrollment: g.Digest,
) -> g.GenerationAssociation {
  let assert Ok(full) =
    workspace.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout-" <> int.to_string(number),
      "executor",
      1,
      1,
    )
    as "full scope"
  let assert Ok(key) = g.key(full, digest(1), generation) as "generation key"
  g.association(key, enrollment, uuid(number), g.FirstGeneration)
}

fn uuid(number: Int) -> ids.EntryId {
  let assert Ok(id) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "original UUID"
  id
}

fn digest(number: Int) -> g.Digest {
  let assert Ok(digest) = g.digest(<<number:size(256)>>) as "fixed digest"
  digest
}

fn doors() -> BitArray {
  let assert Ok(bytes) =
    mp.encode(mp.ArrayValue([mp.StringValue("fixed original fixture doors")]))
    as "canonical doors"
  bytes
}

fn new_store(root: String, name: String, rows: Int) -> r.Store {
  let assert Ok(limits) = r.limits(16, rows, 1_000_000) as "finite ledger"
  let assert Ok(store) =
    r.fresh(root <> "/" <> name <> ".sqlite", uuid(100), limits)
    as "original registry actor"
  store
}

fn managed(store: r.Store) -> e.Server {
  let assert Ok(config) =
    e.configure_managed_server(store, 1000, e.RetiredSlots16)
    as "closed managed bootstrap"
  let assert Ok(server) = e.start(config) as "original shared endpoint"
  server
}

fn new_claim(
  store: r.Store,
  associated: g.GenerationAssociation,
) -> r.StartupClaim {
  let assert Ok(r.Fresh(claim)) = r.admit(store, associated, doors(), 1, None)
    as "sole original claim"
  claim
}

fn publish(
  store: r.Store,
  server: e.Server,
  row: e.Registration,
  claim: r.StartupClaim,
) {
  let assert Ok(endpoint) = e.publication_endpoint(server, row)
    as "original row-bound endpoint"
  let assert Ok(permit) = r.prepare_publication(claim, endpoint)
    as "Publishing COMMIT"
  assert e.register_generation(server, row, claim) == Ok(Nil)
  assert r.published(permit) == Ok(Nil)
  assert r.observe(store, g.association_key(r.original(claim)))
    == Ok(r.Published)
}

fn retire(
  store: r.Store,
  server: e.Server,
  row: e.Registration,
  claim: r.StartupClaim,
) -> r.RetirementRecord {
  let assert Ok(endpoint) = e.publication_endpoint(server, row)
    as "original endpoint evidence"
  assert r.close_generation(store, g.association_key(r.original(claim)))
    == Ok(r.Closing)
  let evidence =
    r.StartedEvidence(
      r.PublishedFencedDrained(endpoint),
      digest(11),
      digest(12),
      digest(13),
      digest(14),
      digest(15),
      digest(16),
      digest(17),
    )
  let assert Ok(record) =
    r.retire_started(claim, evidence, trusted_component_retirement_verifier)
    as "committed fixture witnesses"
  record
}

fn trusted_component_retirement_verifier(
  _claim: r.StartupClaim,
  evidence: r.StartedEvidence,
) -> Result(Nil, r.Error) {
  // This explicitly synthetic component seam grants no production cleanup proof.
  case
    evidence.continuations == digest(11)
    && evidence.resources == digest(12)
    && evidence.native_scope == digest(13)
    && evidence.covered_keys == digest(14)
    && evidence.services == digest(15)
    && evidence.journals == digest(16)
    && evidence.host == digest(17)
  {
    True -> Ok(Nil)
    False -> Error(r.Conflict)
  }
}

fn stop(server: e.Server) {
  let monitor = process.monitor(e.pid(server))
  e.stop(server)
  assert process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down.reason })
    |> process.selector_receive(1000)
    == Ok(process.Normal)
}

fn clean(n: NativeRow) {
  let config = service.configuration(n.native)
  assert service.exchange(
      n.native,
      wire.Envelope(
        wire.Owner,
        "owner",
        "executor",
        config.generation,
        config.scope,
        wire.CloseScope,
      ),
    )
    == Ok(wire.ScopeRetirement)
  assert service.shutdown(n.native) == Ok(Nil)
  assert journal.release(n.book) == Ok(Nil)
  assert simplifile.delete(n.path) == Ok(Nil)
}

fn await(root: String, name: String) {
  let assert poll.Answered(Nil) =
    poll.until(5000, 1, fn() {
      case simplifile.is_file(root <> "/" <> name) {
        Ok(True) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "fixed peer completion"
}
