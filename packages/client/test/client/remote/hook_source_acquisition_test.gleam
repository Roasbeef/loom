//// Real fixed hook source acquisition over original SQLite, TLS and filesystem.
//// The shared physical fixtures retain exact independent owner/executor actors.

import broker/enrollment
import broker/exec
import broker/executor as native
import broker/policy
import client/daemon/deployment
import client/hookcompat
import client/hookserve
import client/remote/custodian
import client/remote/hook_source_acquisition as acquisition
import core/clock
import core/generation
import core/ids
import core/remote_tool
import core/workspace as cw
import distribution_fixture
import executor/remote/admission
import executor/remote/beam_endpoint as connection
import executor/remote/distribution
import executor/remote/identity
import executor/remote/internal/beam_protocol as transport
import executor/remote/journal as native_journal
import executor/remote/registration
import executor/remote/service as native_service
import executor/remote/workspace_journal as journal
import executor/remote/workspace_service as service
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import simplifile
import sqlight
import storage/owner_custody as custody
import support/hook_source_beam_fixture as beam_fixture
import support/internal/ffi_memory
import support/internal/ffi_soak
import telemetry/log
import tools/directory_access
import tools/fs
import tools/tool
import tools/workspace
import tools/workspace_codec as codec
import tools/workspace_local as local
import weft/poll
import weft/registry

type Fixture {
  FixtureState(
    root: String,
    owner: custodian.Handle,
    ready: custodian.RegisteredOwner,
    owner_config: custodian.Config,
    owner_pid: process.Pid,
    book: journal.Journal,
    connection: connection.Config,
  )
}

pub fn complete_batch_reads_real_sources_once_and_preserves_owner_baseline_test() {
  use peer <- beam_fixture.run(
    "complete_batch_reads_real_sources_once_and_preserves_owner_baseline_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  source_files(f, settings("project-original"), settings("local-original"))
  let home = owner_home(f)
  assert simplifile.write(
      home <> "/.claude/settings.json",
      settings("owner-original"),
    )
    == Ok(Nil)
  let c = acquisition_config(f, Some(home), 15_000)
  let assert Ok(baseline) = acquisition.capture_owner(c)
    as "Actual owner capture occurs once before observation."
  let plan = candidate(c, baseline, poll.monotonic().now() + 20_000)
  assert scalar(f, "SELECT COUNT(*) FROM owner_system_intent") == 0
  assert simplifile.write(
      home <> "/.claude/settings.json",
      settings("owner-changed"),
    )
    == Ok(Nil)
  start_executor(f)
  let assert Ok(sources) = acquisition.acquire(c, baseline, plan)
    as "Known full preparation submits both actual fixed reads."
  assert sources
    == expected(
      f,
      home,
      Some(settings("owner-original")),
      Some(settings("project-original")),
      Some(settings("local-original")),
    )
  assert read_count(f) == 2
  assert executor_rows(f) == 2
  assert scalar(f, "SELECT COUNT(*) FROM owner_system_intent") == 3
  assert scalar(f, "SELECT COUNT(*) FROM owner_custody_children") == 2
  assert scalar(f, "SELECT next_ordinal FROM owner_system_ordinal") == 2
  verify_receipts(f)
  assert simplifile.read(display_root() <> "/.claude/settings.json")
    == Ok("owner executor-label canary")
  assert simplifile.read(display_root() <> "/.claude/settings.local.json")
    == Ok("owner local-label canary")
  assert simplifile.write(
      f.root <> "/executor/.claude/settings.json",
      settings("project-changed"),
    )
    == Ok(Nil)
  assert acquisition.observe(c, baseline) == Ok(sources)
  assert acquisition.acquire(c, baseline, plan) == Ok(sources)
  assert read_count(f) == 2
  let assert Ok(changed) = acquisition.capture_owner(c)
    as "A new body cannot stand in for the original capture."
  assert acquisition.observe(c, changed)
    == Error(acquisition.OwnerBaselineUnavailable)
  finish(f)
}

pub fn partial_preparation_never_reads_or_fills_missing_slot_test() {
  use peer <- beam_fixture.run(
    "partial_preparation_never_reads_or_fills_missing_slot_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  source_files(f, settings("project"), settings("local"))
  let c = acquisition_config(f, None, 15_000)
  let assert Ok(baseline) = acquisition.capture_owner(c)
    as "No home omits exactly one owner position."
  let plan = candidate(c, baseline, poll.monotonic().now() + 20_000)
  mutate(
    f,
    "CREATE TRIGGER refuse_local BEFORE INSERT ON owner_system_intent WHEN NEW.step='registered-hooks:local' BEGIN SELECT RAISE(ABORT,'refuse final preparation slot'); END",
  )
  start_executor(f)
  let assert Error(acquisition.OwnerUnavailable(_)) =
    acquisition.acquire(c, baseline, plan)
    as "Actual final-slot refusal prevents both source admissions."
  assert scalar(f, "SELECT COUNT(*) FROM owner_system_intent") == 2
  assert scalar(f, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert read_count(f) == 0
  mutate(f, "DROP TRIGGER refuse_local")
  assert acquisition.acquire(c, baseline, plan)
    == Error(acquisition.PreparationUncertain)
  assert acquisition.observe(c, baseline)
    == Error(acquisition.PreparationUncertain)
  assert scalar(f, "SELECT COUNT(*) FROM owner_system_intent") == 2
  assert read_count(f) == 0
  finish(f)
}

pub fn changed_candidate_and_expired_original_refuse_without_preparation_test() {
  use peer <- beam_fixture.run(
    "changed_candidate_and_expired_original_refuse_without_preparation_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  source_files(f, settings("project"), settings("local"))
  let c = acquisition_config(f, None, 15_000)
  let assert Ok(baseline) = acquisition.capture_owner(c)
    as "Original omitted baseline."
  let expired = candidate(c, baseline, poll.monotonic().now() - 1)
  start_executor(f)
  assert acquisition.acquire(c, baseline, expired)
    == Error(acquisition.SourceFailure(0, acquisition.ObservationExpired))
  assert scalar(f, "SELECT COUNT(*) FROM owner_system_intent") == 0
  let plan = candidate(c, baseline, poll.monotonic().now() + 20_000)
  let assert Ok(_) = acquisition.acquire(c, baseline, plan)
    as "One original complete batch settles."
  let changed = candidate(c, baseline, poll.monotonic().now() + 20_000)
  assert acquisition.acquire(c, baseline, changed)
    == Error(acquisition.InvalidInventory)
  assert read_count(f) == 2
  finish(f)
}

pub fn actual_missing_and_parse_refusal_preserve_later_source_positions_test() {
  use peer <- beam_fixture.run(
    "actual_missing_and_parse_refusal_preserve_later_source_positions_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  source_files(f, "not valid settings JSON", settings("local"))
  let home = owner_home(f)
  let c = acquisition_config(f, Some(home), 15_000)
  let assert Ok(baseline) = acquisition.capture_owner(c)
    as "Genuine absent owner file keeps its source position."
  let plan = candidate(c, baseline, poll.monotonic().now() + 20_000)
  start_executor(f)
  let assert Ok(sources) = acquisition.acquire(c, baseline, plan)
    as "Parse refusal occurs only after honest acquisition."
  assert sources
    == expected(
      f,
      home,
      None,
      Some("not valid settings JSON"),
      Some(settings("local")),
    )
  assert read_count(f) == 2
  finish(f)
}

pub fn no_home_and_true_remote_missing_keep_two_original_positions_test() {
  use peer <- beam_fixture.run(
    "no_home_and_true_remote_missing_keep_two_original_positions_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  assert simplifile.create_directory_all(f.root <> "/executor/.claude")
    == Ok(Nil)
  assert simplifile.write(
      f.root <> "/executor/.claude/settings.local.json",
      settings("local"),
    )
    == Ok(Nil)
  let c = acquisition_config(f, None, 15_000)
  let assert Ok(baseline) = acquisition.capture_owner(c)
    as "Owner omission is distinct from a missing owner document."
  let plan = candidate(c, baseline, poll.monotonic().now() + 20_000)
  start_executor(f)
  let assert Ok(sources) = acquisition.acquire(c, baseline, plan)
    as "Only exact FsNotFound becomes absence."
  assert sources
    == hookserve.load_registered(
      [
        hookserve.AcquiredDocument(
          hookserve.Located(
            display_root() <> "/.claude/settings.json",
            hookserve.ClaudeSettings,
            hookcompat.ProjectSettings,
          ),
          None,
        ),
        hookserve.AcquiredDocument(
          hookserve.Located(
            display_root() <> "/.claude/settings.local.json",
            hookserve.ClaudeSettings,
            hookcompat.LocalSettings,
          ),
          Some(settings("local")),
        ),
      ],
      None,
    )
  assert read_count(f) == 1
  verify_receipts(f)
  finish(f)
}

pub fn owner_text_limit_and_invalid_utf8_are_explicit_failures_test() {
  use peer <- beam_fixture.run(
    "owner_text_limit_and_invalid_utf8_are_explicit_failures_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let home = owner_home(f)
  let c = acquisition_config(f, Some(home), 15_000)
  assert simplifile.write(
      home <> "/.claude/settings.json",
      string.repeat("x", fs.max_read_bytes + 1),
    )
    == Ok(Nil)
  assert acquisition.capture_owner(c)
    == Error(acquisition.SourceFailure(
      0,
      acquisition.FileRefused(
        workspace.FileReadFailed(fs.TooLarge(
          fs.max_read_bytes + 1,
          fs.max_read_bytes,
        )),
      ),
    ))
  assert simplifile.write_bits(home <> "/.claude/settings.json", <<255>>)
    == Ok(Nil)
  assert acquisition.capture_owner(c)
    == Error(acquisition.SourceFailure(
      0,
      acquisition.FileRefused(workspace.FileReadFailed(fs.NotText)),
    ))
  assert scalar(f, "SELECT COUNT(*) FROM owner_system_intent") == 0
  start_executor(f)
  finish(f)
}

pub fn large_bodies_stay_outside_metadata_and_copy_growth_is_measured_test() {
  use peer <- beam_fixture.run(
    "large_bodies_stay_outside_metadata_and_copy_growth_is_measured_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let home = owner_home(f)
  let c = acquisition_config(f, Some(home), 15_000)
  let large =
    "{\"padding\":\"" <> string.repeat("x", 1_048_577) <> "\",\"hooks\":{}}"
  source_files(f, large, large)
  assert simplifile.write(home <> "/.claude/settings.json", large) == Ok(Nil)
  let assert Ok(baseline) = acquisition.capture_owner(c)
    as "One actual large owner body remains outside observation."
  let plan = candidate(c, baseline, poll.monotonic().now() + 20_000)
  io.println(
    "COPY baseline-flat-words="
    <> int.to_string(ffi_memory.flat_words(baseline))
    <> " plan-flat-words="
    <> int.to_string(ffi_memory.flat_words(plan)),
  )
  start_executor(f)
  let replies = process.new_subject()
  let release = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      let answer = acquisition.acquire(c, baseline, plan)
      process.send(replies, answer)
      let assert Ok(Nil) = process.receive(release, 2000)
        as "Measurement samples the completed observer before releasing its result."
      Nil
    })
  let assert Ok(Ok(sources)) = process.receive(replies, 20_000)
    as "Actual accepted large remote and owner inputs settle."
  io.println(
    "COPY caller-process="
    <> int.to_string(process_memory(caller))
    <> " verified-flat-words="
    <> int.to_string(ffi_memory.flat_words(sources)),
  )
  process.send(release, Nil)
  assert scalar(f, "SELECT MAX(length(intent_bytes)) FROM owner_system_intent")
    <= 8192
  assert scalar(f, "SELECT MAX(length(terminal)) FROM owner_custody_children")
    > 1_048_576
  assert ffi_memory.flat_words(plan) < 1024
  assert read_count(f) == 2
  finish(f)
}

fn acquisition_config(
  f: Fixture,
  home: option.Option(String),
  within: Int,
) -> acquisition.Config {
  let assert Ok(config) =
    acquisition.new(
      f.ready,
      deployment_table(f.connection.peer),
      connection.Config(..f.connection, within_ms: 5000),
      limits(codec.max_completion_bytes),
      within,
      home,
    )
    as "Closed source configuration captures the original route and actor."
  config
}

fn candidate(
  config: acquisition.Config,
  baseline: acquisition.OwnerBaseline,
  deadline: Int,
) -> acquisition.FixedBatchPlan {
  let assert Ok(#(plan, _)) =
    acquisition.fixed_batch_plan(
      config,
      baseline,
      ids.generator(clock.fixed(2000), 44),
      deadline,
    )
    as "Pure candidate fixes IDs and deadline before any observer."
  plan
}

fn settings(command: String) -> String {
  "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\""
  <> command
  <> "\"}]}]}}"
}

fn source_files(f: Fixture, project: String, local: String) -> Nil {
  assert simplifile.create_directory_all(f.root <> "/executor/.claude")
    == Ok(Nil)
  assert simplifile.write(f.root <> "/executor/.claude/settings.json", project)
    == Ok(Nil)
  assert simplifile.write(
      f.root <> "/executor/.claude/settings.local.json",
      local,
    )
    == Ok(Nil)
  assert simplifile.create_directory_all(display_root() <> "/.claude")
    == Ok(Nil)
  assert simplifile.write(
      display_root() <> "/.claude/settings.json",
      "owner executor-label canary",
    )
    == Ok(Nil)
  assert simplifile.write(
      display_root() <> "/.claude/settings.local.json",
      "owner local-label canary",
    )
    == Ok(Nil)
  Nil
}

fn owner_home(f: Fixture) -> String {
  let home = f.root <> "/owner/home"
  assert simplifile.create_directory_all(home <> "/.claude") == Ok(Nil)
  home
}

fn expected(
  f: Fixture,
  home: String,
  owner: option.Option(String),
  project: option.Option(String),
  local: option.Option(String),
) -> hookserve.VerifiedSources {
  let _ = f
  hookserve.load_registered(
    [
      hookserve.AcquiredDocument(
        hookserve.Located(
          home <> "/.claude/settings.json",
          hookserve.ClaudeSettings,
          hookcompat.UserSettings,
        ),
        owner,
      ),
      hookserve.AcquiredDocument(
        hookserve.Located(
          display_root() <> "/.claude/settings.json",
          hookserve.ClaudeSettings,
          hookcompat.ProjectSettings,
        ),
        project,
      ),
      hookserve.AcquiredDocument(
        hookserve.Located(
          display_root() <> "/.claude/settings.local.json",
          hookserve.ClaudeSettings,
          hookcompat.LocalSettings,
        ),
        local,
      ),
    ],
    Some(home <> "/hooktrust"),
  )
}

fn verify_receipts(f: Fixture) -> Nil {
  list.each([0, 1], fn(ordinal) {
    let assert Ok(origin) =
      remote_tool.system_child(session(), "workspace-administration", ordinal)
      as "Inspection selects only the actual committed ordinal."
    let assert Ok(#(id, request, Some(receipt))) =
      custodian.child(f.owner, origin)
      as "Original full receipt is retained before source promotion."
    assert custodian.receipt_generation(f.owner, origin, id)
      == Ok(#(receipt, association()))
    assert connection.workspace_exchange(f.connection, transport.Query, request)
      == Ok(journal.Acknowledged(journal.digest(receipt)))
  })
}

fn process_memory(pid: process.Pid) -> Int {
  let assert Ok(value) =
    decode.run(
      ffi_soak.process_info(pid, atom.create("memory")),
      decode.at([1], decode.int),
    )
    as "Actual live caller process exposes its own allocation snapshot."
  value
}

fn limits(payload: Int) {
  let assert Ok(value) = custody.limits(4, 64, 268_435_456, payload)
    as "Finite original owner ceiling."
  value
}

fn fixture(peer: distribution.Peer, payload: Int) -> Fixture {
  let root = beam_fixture.root() <> "/data"
  assert simplifile.create_directory_all(root <> "/owner") == Ok(Nil)
  assert simplifile.create_directory_all(root <> "/executor") == Ok(Nil)
  assert simplifile.write(root <> "/executor/proof.txt", "original") == Ok(Nil)
  assert simplifile.write(root <> "/read-count", "0") == Ok(Nil)
  let assert Ok(names) = registry.start()
    as "Fixture owns an original registry."
  let assert Ok(owner_config) =
    custodian.config_with_reports(
      root <> "/owner/custody.db",
      session(),
      limits(payload),
      1,
      5000,
      fn(_, _, _) { panic as "System reads must never execute a parent tool." },
      bootstrap.sha256,
    )
    as "Original owner actor has finite custody."
  let assert Ok(owner_config) =
    custodian.with_registered(owner_config, pin(), association(), 1)
    as "Original registered immutable metadata."
  let owner = custodian.new(names, owner_config)
  let assert Ok(started) = custodian.start(owner, owner_config)
    as "Actual original SQLite writer starts."
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(owner)
    as "Only this original writer grants assembly readiness; this is not activation."
  let assert Ok(book_limits) = journal.limits(4, 268_435_456)
    as "Original executor journal ceiling."
  let assert Ok(book) =
    journal.fresh(root <> "/executor/custody.db", scope(), book_limits)
    as "Actual separate executor SQLite journal."
  FixtureState(
    root,
    owner,
    ready,
    owner_config,
    started.pid,
    book,
    connection.Config(peer, "owner", "executor", identity_scope(1), 1, 5000),
  )
}

fn pin() -> custody.EnrollmentPin {
  let roots = [display_root(), "/build", "/channel"]
  let base = policy.workspace_default(display_root())
  let ceiling =
    policy.SandboxPolicy(
      ..base,
      writable_roots: roots,
      readable_roots: ["/tools", "/seed"],
      protected: [],
      mounts: [],
    )
  let native =
    enrollment.NativeFacts(scope(), roots, ceiling, exec.FullEnforcement)
  let code =
    enrollment.CodeModeFacts(
      display_root(),
      "/build",
      "/channel",
      "/tools/gleam",
      "/tools/erl",
      "/seed",
      ["/tools"],
      [],
      "/tools",
    )
  let assert Ok(registered) =
    registration.new(
      identity_scope(1),
      roots,
      ceiling,
      exec.FullEnforcement,
      Ok,
    )
    as "Actual registration codec validates fixed native enrollment."
  let digest =
    identity.digest_bytes(registration.digest(registered))
    |> bit_array.base16_encode
    |> string.lowercase
  let assert Ok(enrolled) =
    enrollment.new(native, code, digest, string.repeat("4", 64))
    as "Complete immutable enrollment."
  let assert Ok(bytes) = enrollment.encode(enrolled)
    as "Canonical full enrollment bytes."
  let assert Ok(descriptor) = generation.digest(<<2:size(256)>>)
    as "Descriptor width."
  let assert Ok(hash) = generation.digest(bootstrap.sha256(bytes))
    as "Real SHA-256 of complete canonical enrollment."
  let #(_, binding) = cw.scope_fields(scope())
  let assert Ok(pin) =
    custody.enrollment_pin(session(), binding, descriptor, hash, bytes)
    as "Complete original pin."
  pin
}

fn association() {
  let #(_, _, descriptor, hash, _) = custody.enrollment_fields(pin())
  let assert Ok(key) = generation.key(scope(), descriptor, 1)
    as "Original generation."
  generation.association(key, hash, entry(1), generation.FirstGeneration)
}

fn deployment_table(peer: distribution.Peer) {
  let node = distribution.name(peer)
  let digest =
    generation.digest_bytes(custody.enrollment_fields(pin()).2)
    |> bit_array.base16_encode
    |> string.lowercase
  let document = "schema = 1
endpoint_lifetime = \"retired_slots_v1\"
owner = \"owner\"
local_node = \"owner@owner.example.invalid\"
[membership]
ca = \"/etc/loom-owner/ca.pem\"
certificate = \"/etc/loom-owner/cert.pem\"
key = \"/etc/loom-owner/key.pem\"
cookie = \"/etc/loom-owner/.erlang.cookie\"
options = \"/etc/loom-owner/tls.options\"
[[peers]]
node = \"" <> node <> "\"
leaf_sha256 = \"" <> string.repeat("1", 64) <> "\"
[[workspaces]]
executor = \"executor\"
workspace = \"checkout\"
peer = \"" <> node <> "\"
workspace_epoch = 1
session_epoch = 1
first_generation = 1
generation_policy = \"clean_successor\"
descriptor_sha256 = \"" <> digest <> "\"
"
  let assert Ok(table) = deployment.decode(document)
    as "Immutable selected deployment table."
  table
}

fn counted_filesystem(root: String) -> tool.FileSystem {
  let original = fs.real_filesystem()
  tool.FileSystem(..original, read: fn(path) {
    let directory = root <> "/.."
    let assert Ok(text) = simplifile.read(directory <> "/read-count")
      as "Finite read counter."
    let assert Ok(count) = int.parse(text) as "Exact read count."
    assert simplifile.write(
        directory <> "/read-count",
        int.to_string(count + 1),
      )
      == Ok(Nil)
    assert scalar_path(
        directory <> "/owner/custody.db",
        "SELECT COUNT(*) FROM owner_system_intent",
      )
      == 3
      as "All three actual intent slots precede every physical source read."
    let label = case string.ends_with(path, "settings.local.json") {
      True -> "local"
      False -> "project"
    }
    assert simplifile.write(directory <> "/read-" <> label, "read") == Ok(Nil)
    beam_fixture.mark(directory, "reading")
    case simplifile.is_file(directory <> "/hold-read") {
      Ok(True) -> beam_fixture.await(directory, "release-read")
      _ -> Nil
    }
    original.read(path)
  })
}

fn read_count(f: Fixture) -> Int {
  let assert Ok(text) = simplifile.read(f.root <> "/read-count")
    as "Original counter is readable."
  let assert Ok(value) = int.parse(text) as "Original counter is integer."
  value
}

fn mutate(f: Fixture, statement: String) -> Nil {
  let assert Ok(db) = sqlight.open(f.root <> "/owner/custody.db")
    as "Test SQL fault injector is not a custody Store."
  assert sqlight.exec(statement, db) == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
}

fn scalar(f: Fixture, statement: String) -> Int {
  let assert Ok(db) = sqlight.open(f.root <> "/owner/custody.db")
    as "Finite independent evidence inspector."
  let assert Ok([value]) =
    sqlight.query(statement, db, [], decode.at([0], decode.int))
    as "One exact scalar row."
  assert sqlight.close(db) == Ok(Nil)
  value
}

fn executor_rows(f: Fixture) -> Int {
  let assert Ok(db) = sqlight.open(f.root <> "/executor/custody.db")
    as "Read-only test inspection of actual executor journal rows."
  let assert Ok([value]) =
    sqlight.query(
      "SELECT COUNT(*) FROM workspace_call",
      db,
      [],
      decode.at([0], decode.int),
    )
    as "Exact journal row inventory."
  assert sqlight.close(db) == Ok(Nil)
  value
}

pub fn executor_main() -> Nil {
  let runtime_root = beam_fixture.root()
  let root = runtime_root <> "/data"
  let assert Ok(provisioned) =
    distribution_fixture.read_provisioned(runtime_root <> "/fixture.term")
    as "The executor receives only its original administrative fixture."
  let assert Ok(membership) = distribution.start(provisioned.executor_config)
    as "The independent executor enters real mutual TLS membership."
  let assert Ok(owner) = distribution.peer(membership, provisioned.owner_name)
    as "The registered owner has exact admitted boot provenance."
  let assert poll.Answered(Nil) =
    poll.until(10_000, 10, fn() {
      case simplifile.is_file(root <> "/start") {
        Ok(True) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "The owner commits and releases test setup before executor startup."

  // Executor reservations have a distinct actual SQLite journal and ceiling.
  let assert Ok(limits) = journal.limits(4, 268_435_456)
    as "The executor retains the original reservation ceiling."
  let assert Ok(book) =
    journal.recover(root <> "/executor/custody.db", scope(), limits)
    as "The original journal metadata and historical fences reopen unchanged."
  let host = local_host(scope(), context(root <> "/executor"), fn(_) { None })
  let assert Ok(config) = service.configure(host, book, 2, 10_000)
    as "Concrete semantic host and journal share the exact original scope."
  let assert Ok(semantic) = service.start(config)
    as "Real executor-local filesystem work owns its own effect custody."

  // Enrollment derives from concrete local service owners, never wire callbacks.
  let #(native_executor, native_remote) = concrete_native(root)
  let assert Ok(row) =
    connection.registration(
      owner,
      native_remote,
      Some(semantic),
      process.self(),
    )
    as "Enrollment binds the actual native and semantic actors locally."
  let assert Ok(server_config) = connection.configure_server([row], 10_000)
    as "Only this original scope enters the finite node-wide rendezvous."
  let assert Ok(endpoint) = connection.start(server_config)
    as "The actual fixed endpoint publishes after TLS bootstrap and local setup."
  beam_fixture.mark(root, "ready")

  // The original enclosing executor role owns physical service close and join.
  let assert poll.Answered(Nil) =
    poll.until(20_000, 10, fn() {
      case simplifile.is_file(root <> "/done") {
        Ok(True) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "Finite fixed role reaches original host shutdown."
  connection.quiesce(endpoint)
  assert service.close(semantic) == Ok(Nil)
  assert journal.mode(book) == Ok(journal.SealedScope)
  assert journal.release(book) == Ok(Nil)
  connection.stop(endpoint)
  assert native.close(native_executor, draining: 1000, helpers: 1000) == Ok(Nil)
  beam_fixture.mark(runtime_root, "executor-success")
}

fn concrete_native(root: String) {
  let assert Ok(executor) =
    native.start(native.ExecutorConfig(
      fn() { Error(exec.PoolUnavailable) },
      fn(_) { Nil },
      fn() { Error(exec.PoolUnavailable) },
      fn(_) { Ok(Nil) },
      4,
      log.discard(),
    ))
    as "A real native actor exists; semantic-only cases allocate no process pool."
  let assert Ok(capacity) = admission.capacity(4)
    as "Native admission remains finite even though these cases send no commands."
  let assert Ok(book) =
    native_journal.fresh(root <> "/native.sqlite", identity_scope(1), capacity)
    as "Actual native registration has separate SQLite custody."
  let assert Ok(remote) =
    native_service.start(native_service.Config(
      "owner",
      "executor",
      identity_scope(1),
      1,
      book,
      executor,
      fn(_, _) { Ok(Nil) },
      poll.monotonic().now,
    ))
    as "The endpoint enrollment derives from the real scoped native service."
  #(executor, remote)
}

// Seeding commits before the executor opens this same journal. Recovery retains
// its exact metadata, Accepted/Started fences and all original invocation bytes.
fn start_executor(f: Fixture) -> Nil {
  case simplifile.is_file(f.root <> "/start") {
    Ok(True) -> Nil
    _ -> {
      assert journal.release(f.book) == Ok(Nil)
      beam_fixture.mark(f.root, "start")
      beam_fixture.await(f.root, "ready")
    }
  }
}

fn context(root: String) -> tool.Ctx {
  tool.Ctx(
    workspace: tool.LocalWorkspace(root, counted_filesystem(root)),
    strand: "main",
    op_id: operation(),
    step_id: "workspace",
    source_index: 0,
    base_policy: policy.workspace_default(root),
    directory_access: directory_access.none(),
    grants: [],
    demand: exec.FullEnforcement,
    env: [],
    clock: clock.fixed(1000),
    owner_blobs: tool.OwnerBlobs(root <> "/.blobs", fs.real_filesystem()),
    clear_call: fn(_, _) {
      panic as "File-only fixture must not launch a process."
    },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

fn session() {
  ids.mint_session(ids.generator(clock.fixed(1000), 1)).0
}

fn operation() {
  ids.mint_op(ids.generator(clock.fixed(1000), 2)).0
}

fn entry(seed: Int) {
  ids.mint_entry(ids.generator(clock.fixed(1000), seed)).0
}

fn scope() {
  let assert Ok(value) =
    cw.scope_from_fields(
      ids.session_id_to_string(session()),
      "checkout",
      "executor",
      1,
      1,
    )
    as "Complete scope validates."
  value
}

fn identity_scope(epoch: Int) {
  let assert Ok(w) = identity.workspace_id("checkout")
    as "Workspace label validates."
  let assert Ok(e) = identity.executor_id("executor")
    as "Executor label validates."
  let assert Ok(owner_epoch) = identity.epoch(epoch) as "Owner epoch validates."
  let assert Ok(workspace_epoch) = identity.epoch(1)
    as "Workspace epoch validates."
  identity.scope(session(), w, e, owner_epoch, workspace_epoch)
}

fn stop_owner(f: Fixture) {
  let monitor = process.monitor(f.owner_pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "SQLite owner exits before reopen."
  Nil
}

fn finish(f: Fixture) {
  assert journal.release(f.book) == Ok(Nil)
  stop_owner(f)
  beam_fixture.mark(f.root, "done")
  beam_fixture.await(beam_fixture.root(), "executor-success")
}

// A registered context cannot construct the executor-local host.
fn local_host(
  scope: cw.Scope,
  ctx: tool.Ctx,
  observer: fn(String) -> option.Option(String),
) -> local.Host {
  let assert Ok(host) = local.new(scope, ctx, observer)
    as "fixture must have local authority"
  host
}

fn display_root() -> String {
  beam_fixture.root() <> "/data/owner/executor-display"
}

fn scalar_path(path: String, statement: String) -> Int {
  let assert Ok(db) = sqlight.open(path)
    as "Bounded independent evidence inspector."
  let assert Ok([value]) =
    sqlight.query(statement, db, [], decode.at([0], decode.int))
    as "Exact scalar evidence exists."
  assert sqlight.close(db) == Ok(Nil)
  value
}
