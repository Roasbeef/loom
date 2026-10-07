//// Original native LSP component fixtures retain actual SQL, Broker and pool custody.
//// Channel peers model only the physical wire ordering; the real-helper control
//// separately requires the checkout's helper and actual FullEnforcement policy.

import broker/broker
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/executor as local
import broker/framing
import broker/policy
import broker/token
import codemode/lsp_host/jail
import codemode/lsp_host/profile
import core/clock
import core/generation as g
import core/ids
import core/lsp_command as id
import core/remote_tool
import core/workspace
import envoy
import executor
import executor/remote/admission
import executor/remote/deployment
import executor/remote/identity
import executor/remote/journal
import executor/remote/lsp_journal as custody
import executor/remote/lsp_native
import executor/remote/registration
import executor/remote/service
import executor/remote/wire
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import telemetry/log
import tools/fs
import weft/actor
import weft/poll

pub type Kind {
  WirePeer
  RealHelper
}

pub type Peer {
  Peer(helper: exec.Helper, outbound: process.Subject(BitArray))
}

pub type Rig {
  Rig(
    path: String,
    enrolled: enrollment.SessionEnrollment,
    registered: registration.Registration,
    plan: lsp_native.CheckedServerPlan,
    jail: jail.Jail,
    variants: List(#(String, lsp_native.CheckedServerPlan, jail.Jail)),
    binding: custody.Binding,
    contract: g.Digest,
    era: id.ClockEra,
    store: custody.Store,
    book: journal.Journal,
    native: local.Executor,
    pool: exec.Pool,
    service: service.Service,
    peers: List(Peer),
  )
}

type Allocate {
  Take(process.Subject(Result(exec.Helper, exec.SpawnError)))
}

pub fn start(kind: Kind) -> Rig {
  start_with(kind, None)
}

pub fn competing(original: Rig) -> Rig {
  start_with(WirePeer, Some(original.registered))
}

fn start_with(kind: Kind, verifier: Option(registration.Registration)) -> Rig {
  let assert Ok(here) = simplifile.current_directory()
    as "The component package directory exists."
  let suffix =
    crypto.strong_random_bytes(6) |> bit_array.base16_encode |> string.lowercase
  let root = here <> "/build/lsp-native-" <> suffix
  let channel_parent =
    result.unwrap(envoy.get("LOOM_TEST_SCRATCH"), "/private/tmp/ln")
  let channel = canonical(channel_parent <> "/" <> string.drop_end(suffix, 6))
  assert simplifile.create_directory_all(channel) == Ok(Nil)
  assert simplifile.set_permissions_octal(channel, 0o700) == Ok(Nil)
  list.each(
    ["w", "b", "c", "t", "seed", "a", "s", "h", "cache", "pool/tmp"],
    fn(name) {
      let path = root <> "/" <> name
      assert simplifile.create_directory_all(path) == Ok(Nil)
      assert simplifile.set_permissions_octal(path, 0o700) == Ok(Nil)
    },
  )
  list.each(["ca", "cert", "key", "cookie", "options"], fn(name) {
    let path = root <> "/a/" <> name
    assert simplifile.write(path, "fixture\n") == Ok(Nil)
    assert simplifile.set_permissions_octal(path, 0o700) == Ok(Nil)
  })
  list.each(["gleam", "erl"], fn(name) {
    let path = root <> "/t/" <> name
    assert simplifile.write(path, "fixture\n") == Ok(Nil)
    assert simplifile.set_permissions_octal(path, 0o700) == Ok(Nil)
  })
  let shell = canonical("/bin/sh")
  let helper = case kind {
    RealHelper -> canonical(here <> "/../sandbox/loom-exec")
    WirePeer -> root <> "/a/helper"
  }
  case kind {
    WirePeer -> {
      assert simplifile.write(helper, "wire fixture\n") == Ok(Nil)
      assert simplifile.set_permissions_octal(helper, 0o700) == Ok(Nil)
    }
    RealHelper -> {
      assert simplifile.is_file(helper) == Ok(True)
    }
  }
  let python = executable("python3")
  let server = root <> "/t/server.py"
  assert simplifile.write(server, server_source()) == Ok(Nil)
  let ceiling = ceiling(root, channel, shell, python)
  let text = document(root, channel, helper, shell, python, server, ceiling)
  assert simplifile.write(root <> "/template.toml", text) == Ok(Nil)
  let assert Ok([#(binding, digest)]) = deployment.fingerprints(text)
    as "The descriptor commitment is derived by the production decoder."
  let text = string.replace(text, string.repeat("0", 64), digest)
  let path = root <> "/deployment.toml"
  assert simplifile.write(path, text) == Ok(Nil)
  let assert Ok(table) = deployment.load(path)
    as "Actual private canonical placement is loaded."
  let assert Ok(descriptor) = deployment.select(table, binding, digest)
    as "The exact sealed descriptor is selected."
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "The original session is valid."
  let assert Ok(enrolled) = deployment.describe(descriptor, session)
    as "Enrollment retains the descriptor's FullEnforcement demand."
  let facts = enrollment.native_facts(enrolled)
  let scope = native_scope(facts.scope)
  let assert Ok(registered) =
    registration.new(
      scope,
      facts.working_roots,
      facts.ceiling,
      facts.demand,
      fn(path) {
        fs.resolve_real(fs.real_filesystem(), "/", path)
        |> result.replace_error(Nil)
      },
    )
    as "Actual registration freezes the same physical facts."
  let profiles = deployment.lsp_profiles(descriptor)
  let assert Ok(server) =
    list.find(profiles, fn(server) { server.name == "server" })
    as "The fixture declares a bounded multi-profile inventory."
  let assert Ok(executable) =
    jail.locate(server, jail.Executables(None, fn(_) { Error(Nil) }))
    as "The actual configured interpreter is measured by the existing jail."
  let placement =
    jail.Placement(
      server,
      root <> "/w",
      root <> "/w",
      executable,
      profile.Places(Some(root <> "/h"), Some(root <> "/cache")),
    )
  let base =
    policy.SandboxPolicy(
      ..facts.ceiling,
      limits: policy.Limits(
        ..facts.ceiling.limits,
        cpu_s: 10,
        wall_s: 30,
        output_bytes: 262_144,
      ),
    )
  let assert Ok(built) = jail.policy_for(placement, base, reading: trusted_env)
    as "The existing jail derives the Session policy and executable mounts."
  assert simplifile.create_directory_all(built.scratch <> "/tmp") == Ok(Nil)
  list.each(built.caches, fn(path) {
    assert simplifile.create_directory_all(path) == Ok(Nil)
  })
  let assert Ok(plan) =
    lsp_native.checked_plan(
      descriptor,
      registered,
      placement,
      base,
      trusted_env,
    )
    as "The checked plan freezes actual profile, descriptor and enrollment."
  let variants =
    list.map(profiles, fn(server) {
      let placement = jail.Placement(..placement, server: server)
      let assert Ok(built) =
        jail.policy_for(placement, base, reading: trusted_env)
        as "Each declared profile uses the same existing placement constructor."
      let assert Ok(plan) =
        lsp_native.checked_plan(
          descriptor,
          registered,
          placement,
          base,
          trusted_env,
        )
        as "Each profile retains its exact descriptor and enrollment."
      assert simplifile.create_directory_all(built.scratch <> "/tmp") == Ok(Nil)
      #(server.name, plan, built)
    })
  let assert Ok(descriptor_digest) =
    bit_array.base16_decode(digest)
    |> result.try(fn(bytes) { g.digest(bytes) |> result.replace_error(Nil) })
    as "The exact descriptor digest is typed."
  let assert Ok(encoded) = enrollment.encode(enrolled)
    as "Enrollment is canonical."
  let assert Ok(enrollment_digest) =
    g.digest(crypto.hash(crypto.Sha256, encoded))
    as "The exact enrollment is committed."
  let assert Ok(contract) =
    bit_array.base16_decode(enrollment.digests(enrolled).1)
    |> result.try(fn(bytes) { g.digest(bytes) |> result.replace_error(Nil) })
    as "The frozen compilation contract is retained."
  let assert Ok(generation) = g.key(facts.scope, descriptor_digest, 1)
    as "No latest-generation lookup occurs."
  let binding = custody.binding(generation, enrollment_digest)
  let assert Ok(era) = id.clock_era("00000000-0000-4000-8000-000000000001")
    as "The trusted fixture shares one clock construction and era."
  let assert Ok(incarnation) =
    ids.parse_entry_id("00000000-0000-7000-8000-000000000099")
    as "The store's original incarnation is valid."
  let assert Ok(limits) = custody.limits(100, 100_000_000)
    as "Permanent custody is bounded."
  let assert Ok(profiles) =
    id.enrolled_profiles(
      facts.scope,
      enrollment_digest,
      list.map(profiles, fn(server) { id.Profile(server.name, root <> "/w") }),
    )
    as "The durable inventory is the original checked profile."
  let assert Ok(store) =
    custody.fresh(
      root <> "/s/lsp.sqlite",
      binding,
      contract,
      incarnation,
      limits,
      custody.Clock(era, poll.monotonic().now, fn() {
        crypto.strong_random_bytes(32)
      }),
      profiles,
    )
    as "Actual serialized SQLite custody is created."
  let assert Ok(capacity) = admission.capacity(100)
    as "Native admission is independently bounded."
  let assert Ok(book) =
    journal.fresh(root <> "/s/native.sqlite", scope, capacity)
    as "Actual original native custody is created."
  let peers = case kind {
    WirePeer -> list.map([1, 2, 3, 4, 5, 6], fn(_) { wire_peer() })
    RealHelper -> []
  }
  let pool = case kind {
    WirePeer -> {
      let helpers = list.map(peers, fn(peer) { peer.helper })
      let assert Ok(allocator) =
        actor.new(helpers)
        |> actor.on_message(fn(helpers, msg) {
          let Take(reply) = msg
          case helpers {
            [helper, ..rest] -> {
              process.send(reply, Ok(helper))
              case rest {
                [] -> actor.stop()
                _ -> actor.continue(rest)
              }
            }
            [] -> {
              process.send(reply, Error(exec.PortOpenFailed))
              actor.continue(helpers)
            }
          }
        })
        |> actor.start
        as "The bounded fixture allocator preserves six distinct helpers."
      let assert Ok(pool) =
        exec.start_pool(6, fn() {
          let reply = process.new_subject()
          process.send(allocator.data, Take(reply))
          process.receive(reply, 1000)
          |> result.unwrap(Error(exec.PortOpenFailed))
        })
        as "Actual pool custody reserves three helpers for other work."
      pool
    }
    RealHelper -> {
      let spawn =
        exec.SpawnConfig(
          helper,
          shell,
          executor.base_policy(root),
          [],
          root <> "/pool/tmp",
          3000,
          3000,
          0,
        )
      let assert Ok(pool) =
        exec.start_pool(6, fn() { exec.prepare_helper(spawn) })
        as "The current checkout's helper supplies the actual production pool."
      pool
    }
  }
  let assert Ok(native) =
    local.start_with_retirement(
      local.ExecutorConfig(
        fn() { exec.checkout(pool, waiting: 3000) },
        fn(helper) { exec.checkin(pool, helper) },
        fn() { exec.pool_custody(pool, waiting: 1000) },
        fn(ms) { exec.close_pool(pool, waiting: ms) },
        29,
        log.discard(),
      ),
      fn(helper, done) { exec.prepare_borrowed_retirement(pool, helper, done) },
    )
    as "The original executor installs exact pool retirement observers."
  let verifier = option.unwrap(verifier, registered)
  let assert Ok(remote) =
    service.start(service.Config(
      "owner-a",
      "exec-a",
      scope,
      1,
      book,
      native,
      fn(key, prepared) { registration.verify(verifier, key, prepared) },
      poll.monotonic().now,
    ))
    as "The sole Service owns original admission and credited attachment state."
  Rig(
    root,
    enrolled,
    registered,
    plan,
    built,
    variants,
    binding,
    contract,
    era,
    store,
    book,
    native,
    pool,
    remote,
    peers,
  )
}

pub fn lease(
  rig: Rig,
  number: Int,
) -> #(
  custody.LeaseStartupClaim,
  id.LspServiceKey,
  identity.RequestKey,
  ids.OpId,
) {
  lease_for(rig, number, "server")
}

pub fn lease_for(
  rig: Rig,
  number: Int,
  name: String,
) -> #(
  custody.LeaseStartupClaim,
  id.LspServiceKey,
  identity.RequestKey,
  ids.OpId,
) {
  let assert Ok(#(_, _, built)) =
    list.find(rig.variants, fn(item) { item.0 == name })
    as "The named profile is actually declared and checked."
  let generator = ids.generator(clock.fixed(1000), number)
  let #(operation, generator) = ids.mint_op(generator)
  let #(request, _) = ids.mint_entry(generator)
  let scope = enrollment.native_facts(rig.enrolled).scope
  let assert Ok(system) =
    remote_tool.system_child(workspace.scope_fields(scope).0, "lsp", number)
    as "The original system child is derived from the actual session."
  let assert Ok(step) = workspace.step(built.step_id)
    as "The physical step is valid."
  let assert Ok(input) = custody.lease_input(name, rig.path <> "/w", request)
    as "The original profile and root retain their input."
  let assert Ok(digest) = g.digest(crypto.hash(crypto.Sha256, input))
    as "The original input is hashed."
  let assert Ok(enrollment) =
    enrollment.encode(rig.enrolled)
    |> result.replace_error(Nil)
    |> result.map(crypto.hash(crypto.Sha256, _))
    |> result.try(fn(bytes) { g.digest(bytes) |> result.replace_error(Nil) })
    as "The full original enrollment is retained."
  let assert Ok(lease) =
    id.lsp_service_key(
      system,
      scope,
      operation,
      step,
      request,
      digest,
      enrollment,
      rig.contract,
    )
    as "The original lease uses only the checked constructor."
  let assert Ok(custody.FreshLease(claim)) =
    custody.reserve_lease_live(rig.store, lease, input, name, rig.path <> "/w")
    as "Only the first original COMMIT returns startup custody."
  let assert Ok(native_request) =
    identity.request_id(ids.entry_id_to_string(request))
    as "The same native request UUID is used."
  #(
    claim,
    lease,
    identity.request_key(
      registration.scope(rig.registered),
      operation,
      native_request,
    ),
    operation,
  )
}

pub fn cleared(
  rig: Rig,
  operation: ids.OpId,
) -> #(wire.Prepared, broker.Broker, dispatch.Dispatch) {
  cleared_for(rig, operation, "server")
}

pub fn cleared_for(
  rig: Rig,
  operation: ids.OpId,
  name: String,
) -> #(wire.Prepared, broker.Broker, dispatch.Dispatch) {
  let assert Ok(#(_, _, built)) =
    list.find(rig.variants, fn(item) { item.0 == name })
    as "The owner clears the actual named profile."
  let observed = process.new_subject()
  let dispatcher =
    dispatch.Dispatcher(fn(request) {
      process.send(observed, request)
      Ok(
        dispatch.Execution(
          dispatch.execution_id(19, request.seq),
          process.self(),
          fn() { Nil },
          fn(_, _) { Nil },
          fn() { Nil },
          fn() { Nil },
        ),
      )
    })
  let assert Ok(owner) =
    broker.start_dispatching(
      token.production_entropy(),
      clock.from_function(poll.monotonic().now),
      dispatcher,
    )
    as "The fixture's trusted owner boundary uses actual Broker composition, budget and token clearance."
  let events = process.new_subject()
  let assert Ok(_) =
    broker.clear_call(
      owner,
      jail.call_spec(
        built,
        operation,
        poll.monotonic().now(),
        exec.FullEnforcement,
      ),
      events: events,
      waiting: 2000,
    )
    as "The original owner clears the exact FullEnforcement Session plan."
  let assert Ok(request) = process.receive(observed, 2000)
    as "Actual cleared native bytes carry the original Broker token."
  #(
    wire.Prepared(
      built.step_id,
      registration.digest(rig.registered),
      wire.Session,
      request.request,
      wire.ProtocolStream,
    ),
    owner,
    request,
  )
}

pub fn wire_peer() -> Peer {
  let outbound = process.new_subject()
  let config =
    exec.default_config(
      exec.ChannelTransport(fn(bytes) { process.send(outbound, bytes) }, fn() {
        Nil
      }),
    )
  let assert Ok(helper) =
    exec.start(exec.HelperConfig(..config, heartbeat_interval_ms: 0))
    as "The deterministic original credited helper actor starts."
  inbound(
    Peer(helper, outbound),
    framing.Frame(
      1,
      framing.Hello(framing.exec_protocol_version, "exec-helper", [
        framing.protocol_credit_feature,
      ]),
    ),
  )
  let assert Ok(_) = exec.await_ready(helper, waiting: 1000)
    as "The actual Hello codec completes."
  let peer = Peer(helper, outbound)
  let _ = next(peer)
  peer
}

pub fn inbound(peer: Peer, frame: framing.Frame) -> Nil {
  let assert Ok(bytes) = framing.encode(frame)
    as "The original helper frame is canonical."
  process.send(exec.wire(peer.helper), exec.WireBytes(bytes))
}

pub fn next(peer: Peer) -> framing.Frame {
  let assert Ok(bytes) = process.receive(peer.outbound, 2000)
    as "The original outbound frame arrives."
  let parsed = framing.push(framing.deframer(), bytes)
  let assert [framing.Known(frame)] = parsed.inbound
    as "One exact frame is decoded."
  frame
}

pub fn canonical(path: String) -> String {
  let assert Ok(path) = fs.resolve_real(fs.real_filesystem(), "/", path)
    as "Trusted fixture placement resolves the physical canonical path."
  path
}

fn executable(name: String) -> String {
  let assert Ok(path) = envoy.get("PATH")
    as "The test environment supplies executable discovery."
  let assert Ok(directory) =
    list.find(string.split(path, ":"), fn(directory) {
      simplifile.is_file(directory <> "/" <> name) == Ok(True)
    })
    as "The actual required executable is installed."
  canonical(directory <> "/" <> name)
}

fn trusted_env(name: String) -> Result(String, Nil) {
  envoy.get(name) |> result.replace_error(Nil)
}

fn ceiling(
  root: String,
  channel: String,
  shell: String,
  python: String,
) -> policy.SandboxPolicy {
  let directory = fn(path) {
    string.join(
      list.reverse(list.drop(list.reverse(string.split(path, "/")), 1)),
      "/",
    )
  }
  let regions =
    list.unique([
      directory(shell),
      directory(python),
      directory(directory(python)),
    ])
  policy.SandboxPolicy(
    writable_roots: [root <> "/w", root <> "/b", channel],
    readable_roots: list.unique([
      root <> "/w",
      root <> "/b",
      channel,
      root <> "/t",
      root <> "/seed",
      canonical("/usr"),
      ..regions
    ]),
    protected: [
      root <> "/a/ca",
      root <> "/a/cert",
      root <> "/a/key",
      root <> "/a/cookie",
      root <> "/a/options",
      root <> "/s",
    ],
    network: policy.NetworkOff,
    limits: policy.Limits(0, 0, 1_073_741_824, 256, 67_108_864, 67_108_864),
    env_allow: ["PATH", "HOME", "TMPDIR"],
    scratch: policy.ScratchTmpfs,
    mounts: list.map(regions, fn(path) {
      policy.Mount(path, policy.MountReadOnly, policy.MountRequired)
    }),
  )
}

fn document(
  root: String,
  channel: String,
  helper: String,
  shell: String,
  python: String,
  server: String,
  ceiling: policy.SandboxPolicy,
) -> String {
  let text =
    "schema=1\nendpoint_lifetime=\"retired_slots_v1\"\nowner=\"owner-a\"\nlocal_node=\"exec@executor.example.invalid\"\n[membership]\nca=\"@/a/ca\"\ncertificate=\"@/a/cert\"\nkey=\"@/a/key\"\ncookie=\"@/a/cookie\"\noptions=\"@/a/options\"\n[[peers]]\nnode=\"owner@owner.example.invalid\"\nleaf_sha256=\"1111111111111111111111111111111111111111111111111111111111111111\"\n[executor]\nhelper=\""
    <> helper
    <> "\"\npool_size=6\nstate_root=\"@/s\"\n[[workspaces]]\nexecutor=\"exec-a\"\nworkspace=\"project-a\"\nowner=\"owner-a\"\nowner_peer=\"owner@owner.example.invalid\"\nworkspace_epoch=1\nsession_epoch=1\nfirst_generation=1\ngeneration_policy=\"clean_successor\"\ndescriptor_sha256=\"0000000000000000000000000000000000000000000000000000000000000000\"\ncompilation_contract_sha256=\"3333333333333333333333333333333333333333333333333333333333333333\"\nnative_demand=\"full\"\nnative_working_roots=[\"@\"]\nnative_ceiling='"
    <> policy_json(ceiling)
    <> "'\n[workspaces.code_mode]\nworkspace_root=\"@/w\"\nbuild_area=\"@/b\"\nchannel_area=\"@/c\"\ngleam_path=\"@/t/gleam\"\nerl_path=\"@/t/erl\"\nseed_root=\"@/seed\"\ntoolchain_roots=[\"@/t\"]\nbuild_path=\"@/t\"\nhost_mounts=[]\n[workspaces.lsp.server]\ncommand=[\""
    <> shell
    <> "\",\"-c\",\"exec "
    <> python
    <> " "
    <> server
    <> "\"]\nextensions=[\".fixture\"]\nroot_markers=[\"fixture.toml\"]\nproject=\"read-only\"\nreadable=[]\nwritable=[]\nenv=[]\n"
  let assert Ok(#(_, profile_text)) =
    string.split_once(text, "[workspaces.lsp.server]")
    as "The literal fixture profile is present."
  let text =
    text
    <> string.concat(
      list.map(["second", "third", "fourth"], fn(name) {
        "[workspaces.lsp."
        <> name
        <> "]"
        <> string.replace(profile_text, ".fixture", "." <> name)
      }),
    )
  let python_root =
    string.join(
      list.reverse(list.drop(list.reverse(string.split(python, "/")), 2)),
      "/",
    )
  text
  |> string.replace(
    "readable=[]",
    "readable=[\"@/t\",\"" <> python_root <> "\"]",
  )
  |> string.replace("@/c\"", channel <> "\"")
  |> string.replace(
    "native_working_roots=[\"@\"]",
    "native_working_roots=[\"" <> root <> "\",\"" <> channel <> "\"]",
  )
  |> string.replace("@/", root <> "/")
  |> string.replace("[\"@\"]", "[\"" <> root <> "\"]")
}

fn policy_json(p: policy.SandboxPolicy) -> String {
  let strings = fn(values) { json.array(values, json.string) }
  json.object([
    #("v", json.int(2)),
    #("writable_roots", strings(p.writable_roots)),
    #("readable_roots", strings(p.readable_roots)),
    #("protected", strings(p.protected)),
    #("network", json.object([#("mode", json.string("off"))])),
    #(
      "limits",
      json.object([
        #("cpu_s", json.int(0)),
        #("wall_s", json.int(0)),
        #("mem_bytes", json.int(p.limits.mem_bytes)),
        #("pids", json.int(p.limits.pids)),
        #("fsize_bytes", json.int(p.limits.fsize_bytes)),
        #("output_bytes", json.int(p.limits.output_bytes)),
      ]),
    ),
    #("env_allow", strings(p.env_allow)),
    #("scratch", json.string("tmpfs")),
    #(
      "mounts",
      json.array(p.mounts, fn(m) {
        json.object([
          #("path", json.string(m.path)),
          #("access", json.string("ro")),
          #("required", json.bool(True)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn server_source() -> String {
  "import sys,json\nwhile True:\n h={}\n while True:\n  l=sys.stdin.buffer.readline()\n  if not l: sys.exit(0)\n  if l in (b'\\r\\n',b'\\n'): break\n  k,v=l.decode().split(':',1);h[k.lower()]=v.strip()\n m=json.loads(sys.stdin.buffer.read(int(h['content-length'])))\n method=m.get('method')\n if 'id' in m:\n  r={'capabilities':{'hoverProvider':True,'textDocumentSync':2}} if method=='initialize' else None\n  b=json.dumps({'jsonrpc':'2.0','id':m['id'],'result':r},separators=(',',':')).encode()\n  sys.stdout.buffer.write(('Content-Length: %d\\r\\n\\r\\n'%len(b)).encode()+b);sys.stdout.buffer.flush()\n if method=='exit': sys.exit(0)\n"
}

fn native_scope(scope: workspace.Scope) -> identity.Scope {
  let #(session, binding) = workspace.scope_fields(scope)
  let #(selector, workspace_epoch, session_epoch) =
    workspace.binding_fields(binding)
  let #(executor, name) = workspace.selector_fields(selector)
  let assert Ok(executor) = identity.executor_id(executor)
    as "The original executor is valid."
  let assert Ok(name) = identity.workspace_id(name)
    as "The original workspace is valid."
  let assert Ok(session_epoch) = identity.epoch(session_epoch)
    as "The original session epoch is valid."
  let assert Ok(workspace_epoch) = identity.epoch(workspace_epoch)
    as "The original workspace epoch is valid."
  identity.scope(session, name, executor, session_epoch, workspace_epoch)
}
