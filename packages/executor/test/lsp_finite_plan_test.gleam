//// Actual descriptor and registration freeze the finite recipe; no native effect is run.

import broker/enrollment
import broker/exec
import broker/policy
import codemode/lsp_host/jail
import codemode/lsp_host/manager
import codemode/lsp_host/profile
import core/clock
import core/generation as g
import core/ids
import core/lsp_command as id
import core/msgpack as mp
import core/remote_tool
import core/workspace
import executor/remote/deployment
import executor/remote/identity
import executor/remote/internal/lsp_finite_plan as p
import executor/remote/lsp_journal as executor_lsp_journal
import executor/remote/lsp_wire
import executor/remote/registration
import executor/remote/wire
import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lsp/query
import simplifile
import tools/fs

type Rig {
  Rig(
    root: String,
    descriptor: deployment.Descriptor,
    registered: registration.Registration,
    placement: jail.Placement,
    base: policy.SandboxPolicy,
    profiles: id.EnrolledProfiles,
    scope: workspace.Scope,
    enrollment: g.Digest,
    contract: g.Digest,
  )
}

pub fn actual_search_ceiling_fixed_wall_and_changed_original_refusal_test() {
  with_plan(fn(text) { text }, fn(rig) {
    let #(ref, request, control, key) = search_identity(rig, 60_000)
    let assert Ok(plan) =
      p.checked_search(
        rig.descriptor,
        rig.registered,
        rig.placement,
        rig.base,
        ref,
        request,
        None,
        fn(_) { Error(Nil) },
        control,
      )
      as "Actual descriptor and registration freeze one complete Search."
    let prepared = from_offer(plan, rig.registered, control)
    assert prepared.request.argv
      == manager.search_argv(manager.Search(
        rig.placement.server,
        rig.placement.root,
        "name",
      ))
    assert prepared.request.argv
      == [
        "rg",
        "--json",
        "--word-regexp",
        "--fixed-strings",
        "--max-count",
        "4",
        "--glob",
        "*.gleam",
        "--glob",
        "*.hrl",
        "--",
        "name",
        rig.placement.root,
      ]
    assert manager.search_argv(manager.Search(
        profile.LspServer(..rig.placement.server, extensions: []),
        rig.placement.root,
        "--literal",
      ))
      == [
        "rg",
        "--json",
        "--word-regexp",
        "--fixed-strings",
        "--max-count",
        "4",
        "--",
        "--literal",
        rig.placement.root,
      ]
    assert prepared.lifetime == wire.Finite(60_000)
    let assert Some(policy) = prepared.request.policy
      as "The fixed finite policy is retained."
    assert policy.limits.wall_s == 10
    assert policy.limits.output_bytes == 4_194_304
    assert p.verify(plan, ref, request, None, key, prepared, control) == Ok(Nil)
    assert p.verify(
        plan,
        ref,
        request,
        None,
        key,
        wire.Prepared(..prepared, lifetime: wire.Finite(10_000)),
        control,
      )
      == Error(p.InvalidFinitePlan)
    let #(_, _, changed_control, _) = search_identity(rig, 70_000)
    assert p.verify(plan, ref, request, None, key, prepared, changed_control)
      == Error(p.InvalidFinitePlan)
    assert p.verify(
        plan,
        ref,
        request,
        None,
        key,
        wire.Prepared(..prepared, lifetime: wire.Finite(70_000)),
        changed_control,
      )
      == Error(p.InvalidFinitePlan)
    assert p.checked_search(
        rig.descriptor,
        rig.registered,
        rig.placement,
        rig.base,
        ref,
        request,
        None,
        fn(_) { Error(Nil) },
        changed_control,
      )
      == Error(p.InvalidFinitePlan)
    assert p.verify(
        plan,
        ref,
        lsp_wire.Diagnostics(None),
        None,
        key,
        prepared,
        control,
      )
      == Error(p.InvalidFinitePlan)
    assert p.checked_search(
        rig.descriptor,
        rig.registered,
        jail.Placement(..rig.placement, root: rig.root),
        rig.base,
        ref,
        request,
        None,
        fn(_) { Error(Nil) },
        control,
      )
      == Error(p.InvalidFinitePlan)
    assert p.checked_search(
        rig.descriptor,
        rig.registered,
        rig.placement,
        policy.SandboxPolicy(
          ..rig.base,
          limits: policy.Limits(..rig.base.limits, cpu_s: 0),
        ),
        ref,
        request,
        None,
        fn(_) { Error(Nil) },
        control,
      )
      == Error(p.InvalidFinitePlan)

    // A ten-second admitted ceiling is valid data, but leaves no room for the
    // ten-second helper wall after any admission elapsed. Service must clamp D.
    let #(short_ref, short_request, short_control, short_key) =
      search_identity(rig, 10_000)
    let assert Ok(short_plan) =
      p.checked_search(
        rig.descriptor,
        rig.registered,
        rig.placement,
        rig.base,
        short_ref,
        short_request,
        None,
        fn(_) { Error(Nil) },
        short_control,
      )
      as "Plan validity does not assert elapsed-window sufficiency."
    assert p.verify(
        short_plan,
        short_ref,
        short_request,
        None,
        short_key,
        from_offer(short_plan, rig.registered, short_control),
        short_control,
      )
      == Ok(Nil)
  })
}

pub fn probe_retains_real_startup_parent_and_prepare_recipe_is_closed_test() {
  with_plan(fn(text) { text }, fn(rig) {
    let #(ref, request) = startup_identity(rig, id.Probe)
    let #(_, _, control, _) = search_identity(rig, 70_000)
    let assert Ok(plan) =
      p.checked_probe(
        rig.descriptor,
        rig.registered,
        rig.placement,
        rig.base,
        ref,
        request,
        fn(_) { Error(Nil) },
        control,
      )
      as "Probe retains its exact original lease header."
    let assert Ok(bytes) = p.offer(plan)
      as "The fixed offer is bounded and canonical."
    let assert Ok(mp.ArrayValue([_, _, _, _, mp.ArrayValue(argv), _, _, _])) =
      wire.decode_value(bytes)
      as "Offer contains the fixed physical recipe."
    assert argv == list.map(manager.probe_argv, mp.StringValue)
    let #(prepare_ref, _) = startup_identity(rig, id.Prepare)
    assert p.checked_prepare(
        rig.descriptor,
        rig.registered,
        rig.placement,
        rig.base,
        prepare_ref,
        request,
        fn(_) { Error(Nil) },
        control,
      )
      == Error(p.InvalidFinitePlan)
    assert p.checked_probe(
        rig.descriptor,
        rig.registered,
        rig.placement,
        rig.base,
        prepare_ref,
        request,
        fn(_) { Error(Nil) },
        control,
      )
      == Error(p.InvalidFinitePlan)
  })
}

pub fn actual_declared_prepare_recipe_remains_full_network_finite_test() {
  with_plan(
    fn(text) {
      text
      |> string.replace(
        "project=\"read-only\"",
        "project=\"writable\"\nprepare=\"gleam-dependencies\"\ncache_env.XDG_CACHE_HOME=\"dependencies\"",
      )
      |> string.replace("\"mode\":\"off\"", "\"mode\":\"full\"")
      |> string.replace("\"@/c\"]", "\"@/c\",\"@/cache\"]")
    },
    fn(rig) {
      let #(ref, request) = startup_identity(rig, id.Prepare)
      let #(_, _, control, _) = search_identity(rig, 70_000)
      let assert Ok(plan) =
        p.checked_prepare(
          rig.descriptor,
          rig.registered,
          rig.placement,
          rig.base,
          ref,
          request,
          fn(_) { Error(Nil) },
          control,
        )
        as "The approved declared recipe constructs under its actual ceiling."
      let assert Ok(bytes) = p.offer(plan)
        as "Only the immutable finite recipe is retained."
      let assert Ok(mp.ArrayValue([
        _,
        _,
        _,
        _,
        mp.ArrayValue(argv),
        _,
        mp.BinaryValue(policy_bytes),
        _,
      ])) = wire.decode_value(bytes)
        as "Offer exposes checked immutable recipe evidence."
      assert argv
        == [
          mp.StringValue(rig.root <> "/t/gleam"),
          mp.StringValue("deps"),
          mp.StringValue("download"),
        ]
      let assert Ok(policy) = policy.decode(policy_bytes)
        as "The actual compose result is canonical."
      assert policy.limits.cpu_s == 60
      assert policy.limits.wall_s == 60
      assert policy.limits.output_bytes == 1_048_576
      assert policy.network == policy.NetworkFull

      // This plan proves neither installed dependency readiness nor an owner grant.
      assert p.recipe(ref) == Ok(p.Prepare)
    },
  )
}

fn with_plan(transform: fn(String) -> String, run: fn(Rig) -> Nil) {
  let #(root, text) = fixture()
  let #(binding, digest, text) = seal(transform(text))
  let assert Ok(table) = load_document(root, text)
    as "Actual sealed deployment loads its physical files."
  let assert Ok(descriptor) = deployment.select(table, binding, digest)
    as "The exact descriptor is selected."
  let assert Ok(enrolled) = deployment.describe(descriptor, session("2"))
    as "Original enrollment is session-specific."
  let facts = enrollment.native_facts(enrolled)
  let assert Ok(registered) =
    registration.new(
      native_scope(facts.scope),
      facts.working_roots,
      facts.ceiling,
      facts.demand,
      fn(path) {
        fs.resolve_real(fs.real_filesystem(), "/", path)
        |> result.replace_error(Nil)
      },
    )
    as "Existing physical canonicalization freezes original registration."
  let assert [server] = deployment.lsp_profiles(descriptor)
    as "Exactly one declared fixture profile is enrolled."
  let assert Ok(executable) =
    jail.locate(server, jail.Executables(None, fn(_) { Error(Nil) }))
    as "The actual enrolled executable is resolved."
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
      limits: policy.Limits(..facts.ceiling.limits, cpu_s: 10),
    )
  let assert Ok(encoded) = enrollment.encode(enrolled)
    as "Canonical enrollment binds the exact descriptor."
  let enrolled_digest = digest_of(encoded)
  let assert Ok(profiles) =
    id.enrolled_profiles(facts.scope, enrolled_digest, [
      id.Profile(server.name, placement.workspace),
    ])
    as "The exact original inventory is retained."
  let assert Ok(contract_bytes) =
    string.repeat("3", 64) |> bit_array.base16_decode
    as "The frozen contract digest is valid."
  let assert Ok(contract) = g.digest(contract_bytes)
    as "The original contract is exact."
  let assert Ok(built) =
    jail.policy_for(placement, base, reading: fn(_) { Error(Nil) })
    as "The existing jail itself admits the fixture placement."
  assert simplifile.create_directory_all(built.scratch <> "/tmp") == Ok(Nil)
  list.each(built.caches, fn(path) {
    assert simplifile.create_directory_all(path) == Ok(Nil)
  })
  let #(bounded, shortfall) =
    policy.compose(facts.ceiling, built.requirements, [])
  assert bounded == built.requirements
  assert shortfall == []
  run(Rig(
    root,
    descriptor,
    registered,
    placement,
    base,
    profiles,
    facts.scope,
    enrolled_digest,
    contract,
  ))
  assert simplifile.delete(root) == Ok(Nil)
}

fn search_identity(rig: Rig, remaining: Int) {
  let request =
    lsp_wire.Definition(query.SymbolQuery("module.name", None, None))
  let generator = ids.generator(clock.fixed(1000), 12)
  let #(operation, generator) = ids.mint_op(generator)
  let #(request_id, _) = ids.mint_entry(generator)
  let assert Ok(step) = workspace.step("lsp.query")
    as "Original step is retained."
  let assert Ok(input) = lsp_wire.semantic_input(request)
    as "The exact semantic request is canonical."
  let assert Ok(tool) =
    remote_tool.key(
      workspace.scope_fields(rig.scope).0,
      operation,
      "lsp.query",
      0,
      string.repeat("0", 64),
      request_id,
    )
    as "The original parent is complete."
  let assert Ok(origin) =
    remote_tool.tool_child(
      tool,
      remote_tool.AdmittedCapability(
        "lsp.query",
        0,
        remote_tool.SemanticWorkspace,
      ),
    )
    as "Fixture trusted admitted parent supplies provenance."
  let assert Ok(child) =
    id.original_child_ref(
      origin,
      rig.scope,
      operation,
      step,
      request_id,
      id.input_fields(input).1,
    )
    as "The exact original child is retained."
  let assert Ok(parent) = id.parent_control(child)
    as "The original timing parent is complete."
  let assert Ok(capture) =
    id.lsp_capture(
      origin,
      rig.scope,
      operation,
      step,
      request_id,
      input,
      parent,
      rig.enrollment,
      rig.contract,
    )
    as "Search never fabricates a startup lease."
  let assert Ok(parent_digest) = lsp_wire.parent_digest(parent)
    as "Canonical parent digest is exact."
  let anchor =
    id.finite_anchor(era(), digest_of(<<0:size(256)>>), parent_digest)
  let assert Ok(verified) =
    id.verify_parent_control(capture, parent, remaining, 0, None)
    as "The original finite remaining ceiling is retained."
  let assert Ok(proposal) =
    id.finite_timing_proposal(anchor, verified, parent_digest)
    as "The one original timing proposal retains anchor and remaining."
  let assert Ok(invocation) =
    id.lsp_invocation(capture, proposal, parent_digest)
    as "The full finite invocation is exact."
  let assert Ok(timing_digest) = lsp_wire.timing_digest(proposal)
    as "Original timing digest is canonical."
  let assert Ok(control) =
    id.admitted_control(anchor, proposal, -1000, -1000, era(), timing_digest)
    as "Only original first admission establishes D."
  let assert Ok(profile) = id.checked_profile(rig.profiles, 0)
    as "The declared profile ordinal is checked."
  let assert Ok(ref) =
    id.lsp_search_command(invocation, profile, id.cold_search_root(profile))
    as "The exact root belongs to this checked profile."
  let assert Ok(request_id) =
    identity.request_id(ids.entry_id_to_string(request_id))
    as "Native logical request identity is exact data."
  #(
    ref,
    request,
    control,
    identity.request_key(
      registration.scope(rig.registered),
      operation,
      request_id,
    ),
  )
}

fn startup_identity(rig: Rig, role: id.LspStartupRole) {
  let generator = ids.generator(clock.fixed(1000), 31)
  let #(operation, generator) = ids.mint_op(generator)
  let #(request, _) = ids.mint_entry(generator)
  let assert Ok(system) =
    remote_tool.system_child(workspace.scope_fields(rig.scope).0, "lsp", 0)
    as "The original system child owns startup."
  let assert Ok(input) = executor_lsp_input(rig, request)
    as "The complete lease input is canonical."
  let assert Ok(step) =
    workspace.step(jail.step_id(rig.placement.server.name, rig.placement.root))
    as "Actual jail step names the original lease."
  let assert Ok(lease) =
    id.lsp_service_key(
      system,
      rig.scope,
      operation,
      step,
      request,
      digest_of(input),
      rig.enrollment,
      rig.contract,
    )
    as "The original complete lease owns startup."
  let assert Ok(ref) = id.lsp_startup_command(lease, role)
    as "Closed startup role retains its actual lease."
  #(ref, lsp_wire.Diagnostics(None))
}

fn executor_lsp_input(rig: Rig, request: ids.EntryId) {
  executor_lsp_journal.lease_input(
    rig.placement.server.name,
    rig.placement.root,
    request,
  )
}

fn from_offer(
  plan: p.CheckedFinitePlan,
  registered: registration.Registration,
  control: id.AdmittedFiniteControl,
) -> wire.Prepared {
  let assert Ok(bytes) = p.offer(plan)
    as "The immutable checked offer encodes once."
  let assert Ok(mp.ArrayValue([
    _,
    _,
    mp.StringValue(step),
    mp.StringValue(cwd),
    mp.ArrayValue(argv),
    mp.ArrayValue(env),
    mp.BinaryValue(policy_bytes),
    _,
  ])) = wire.decode_value(bytes)
    as "The canonical offer has fixed fields."
  let argv =
    list.map(argv, fn(value) {
      let assert mp.StringValue(text) = value as "Every argv entry is text."
      text
    })
  let env =
    list.map(env, fn(value) {
      let assert mp.ArrayValue([mp.StringValue(name), mp.StringValue(text)]) =
        value
        as "Every environment entry is exact text."
      #(name, text)
    })
  let assert Ok(policy) = policy.decode(policy_bytes) as "Policy is canonical."
  wire.Prepared(
    step,
    registration.digest(registered),
    wire.Finite(id.control_fields(control).2),
    exec.ExecRequest(
      argv,
      env,
      cwd,
      Some(policy),
      <<0:size(256)>>,
      exec.FullEnforcement,
    ),
    wire.ProtocolStream,
  )
}

fn era() {
  let assert Ok(value) = id.clock_era("00000000-0000-4000-8000-000000000001")
    as "The trusted fixture retains one era."
  value
}

fn digest_of(bytes: BitArray) -> g.Digest {
  let assert Ok(digest) = g.digest(crypto.hash(crypto.Sha256, bytes))
    as "SHA-256 is exactly32 bytes."
  digest
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

fn fixture() -> #(String, String) {
  let suffix =
    crypto.strong_random_bytes(6) |> bit_array.base16_encode |> string.lowercase
  let root = "/private/tmp/ld-" <> suffix
  let directories = [
    root,
    root <> "/w",
    root <> "/b",
    root <> "/c",
    root <> "/t",
    root <> "/seed",
    root <> "/h",
    root <> "/cache",
    root <> "/a",
    root <> "/s",
  ]
  list.each(directories, fn(path) {
    let assert Ok(Nil) = simplifile.create_directory(path)
      as "fixture directory"
    let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o700)
      as "private directory"
  })
  list.each(["ca", "cert", "key", "cookie", "options", "helper"], fn(name) {
    let path = root <> "/a/" <> name
    let assert Ok(Nil) = simplifile.write(path, "fixture\n")
      as "administrative file"
    let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o700)
      as "private executable"
  })
  list.each(["gleam", "erl"], fn(name) {
    let path = root <> "/t/" <> name
    let assert Ok(Nil) = simplifile.write(path, "fixture\n")
      as "toolchain executable"
    let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o700)
      as "executable file"
  })
  #(root, document(root))
}

fn document(root: String) -> String {
  "schema = 1
endpoint_lifetime = \"retired_slots_v1\"
owner = \"owner-a\"
local_node = \"exec@executor.example.invalid\"
[membership]
ca = \"@/a/ca\"
certificate = \"@/a/cert\"
key = \"@/a/key\"
cookie = \"@/a/cookie\"
options = \"@/a/options\"
[[peers]]
node = \"owner@owner.example.invalid\"
leaf_sha256 = \"1111111111111111111111111111111111111111111111111111111111111111\"
[executor]
helper = \"@/a/helper\"
pool_size = 2
state_root = \"@/s\"
[[workspaces]]
executor = \"exec-a\"
workspace = \"project-a\"
owner = \"owner-a\"
owner_peer = \"owner@owner.example.invalid\"
workspace_epoch = 1
session_epoch = 1
first_generation = 1
generation_policy = \"clean_successor\"
descriptor_sha256 = \"0000000000000000000000000000000000000000000000000000000000000000\"
compilation_contract_sha256 = \"3333333333333333333333333333333333333333333333333333333333333333\"
native_demand = \"full\"
native_working_roots = [\"@\"]
native_ceiling = '{\"v\":2,\"writable_roots\":[\"@/w\",\"@/b\",\"@/c\",\"@/cache\"],\"readable_roots\":[\"@/w\",\"@/b\",\"@/c\",\"@/cache\",\"@/seed\",\"@/t\"],\"protected\":[\"@/a/ca\",\"@/a/cert\",\"@/a/key\",\"@/a/cookie\",\"@/a/options\",\"@/a/helper\",\"@/s\"],\"network\":{\"mode\":\"off\"},\"limits\":{\"cpu_s\":0,\"wall_s\":0,\"mem_bytes\":100000000,\"pids\":32,\"fsize_bytes\":10000000,\"output_bytes\":67108864},\"env_allow\":[\"PATH\",\"HOME\",\"TMPDIR\",\"XDG_CACHE_HOME\"],\"scratch\":\"tmpfs\",\"mounts\":[{\"path\":\"@/t\",\"access\":\"ro\",\"required\":true}]}'
[workspaces.code_mode]
workspace_root = \"@/w\"
build_area = \"@/b\"
channel_area = \"@/c\"
gleam_path = \"@/t/gleam\"
erl_path = \"@/t/erl\"
seed_root = \"@/seed\"
toolchain_roots = [\"@/t\"]
build_path = \"@/t\"
host_mounts = []
[workspaces.lsp.gleam]
command=[\"@/t/gleam\",\"lsp\"]
extensions=[\".gleam\",\".hrl\"]
root_markers=[\"gleam.toml\"]
project=\"read-only\"
readable=[]
writable=[]
env=[]
"
  |> string.replace("@/", root <> "/")
  |> string.replace("[\"@\"]", "[\"" <> root <> "\"]")
}

fn seal(text: String) -> #(workspace.RegisteredBinding, String, String) {
  let assert Ok([#(binding, digest)]) = deployment.fingerprints(text)
    as "canonical provisioning commitment"
  #(binding, digest, string.replace(text, string.repeat("0", 64), digest))
}

fn load_document(
  root: String,
  text: String,
) -> Result(deployment.Table, deployment.DeploymentError) {
  let path = root <> "/deployment.toml"
  let assert Ok(Nil) = simplifile.write(path, text) as "deployment source"
  deployment.load(path)
}

fn session(last: String) -> ids.SessionId {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-00000000000" <> last)
    as "session identity"
  session
}
