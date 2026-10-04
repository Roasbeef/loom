//// Counterexamples for exact enrollment, bounded framing and UUID locations.

import broker/enrollment
import broker/exec
import broker/policy
import core/command
import core/ids
import core/msgpack as mp
import core/remote_tool
import core/workspace
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string

fn scope(epoch: Int) -> workspace.Scope {
  let assert Ok(value) =
    workspace.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "linux",
      epoch,
      7,
    )
    as "Scope retains the original session and both epochs."
  value
}

fn host_mounts() -> List(policy.Mount) {
  [
    policy.Mount("/tc", policy.MountReadOnly, policy.MountRequired),
    policy.Mount("/seed", policy.MountReadOnly, policy.MountOptional),
  ]
}

fn native() -> enrollment.NativeFacts {
  enrollment.NativeFacts(
    scope(2),
    ["/"],
    policy.SandboxPolicy(
      writable_roots: ["/work", "/alloc"],
      readable_roots: ["/tc", "/seed", "/work"],
      protected: ["/work/.git"],
      network: policy.NetworkProxy(["*.example.org"], "127.0.0.1:443"),
      limits: policy.Limits(11, 12, 13, 14, 15, 16),
      env_allow: ["PATH", "HOME"],
      scratch: policy.ScratchTmpfs,
      mounts: host_mounts(),
    ),
    exec.PlatformEnforcement,
  )
}

fn code() -> enrollment.CodeModeFacts {
  enrollment.CodeModeFacts(
    "/work",
    "/alloc/build",
    "/alloc/channel",
    "/tc/bin/gleam",
    "/tc/bin/erl",
    "/seed",
    ["/tc"],
    host_mounts(),
    "/tc/bin",
  )
}

fn make(
  native: enrollment.NativeFacts,
  code: enrollment.CodeModeFacts,
) -> Result(enrollment.SessionEnrollment, enrollment.Error) {
  enrollment.new(native, code, string.repeat("b", 64), string.repeat("c", 64))
}

fn enrolled() -> enrollment.SessionEnrollment {
  let assert Ok(value) = make(native(), code())
    as "The exact isolated configuration validates."
  value
}

fn service(
  role: command.ServiceRole,
  scope: workspace.Scope,
  registration: String,
  contract: String,
) -> command.ServiceKey {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Valid session."
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Valid operation."
  let assert Ok(id) = ids.parse_entry_id("00000000-0000-7000-8000-000000000003")
    as "Valid service UUID."
  let assert Ok(entry) =
    ids.parse_entry_id("00000000-0000-7000-8000-000000000004")
    as "Valid parent result UUID."
  let assert Ok(parent) =
    remote_tool.key(
      session,
      operation,
      "parent",
      3,
      string.repeat("a", 64),
      entry,
    )
    as "Complete provenance."
  let assert Ok(step) = workspace.step("physical:build")
    as "Valid physical step."
  let assert Ok(key) =
    command.service_key(
      parent,
      role,
      scope,
      operation,
      step,
      id,
      string.repeat("a", 64),
      registration,
      contract,
    )
    as "Full service key."
  key
}

fn key(role: command.ServiceRole) -> command.ServiceKey {
  service(role, scope(2), string.repeat("b", 64), string.repeat("c", 64))
}

pub fn full_policy_and_every_configured_field_roundtrip_test() {
  let original = enrolled()
  let assert Ok(bytes) = enrollment.encode(original)
    as "Bounded canonical encoding."
  let assert Ok(decoded) = enrollment.decode(bytes) as "Canonical full decode."
  assert decoded == original
  assert enrollment.native_facts(decoded) == native()
  assert enrollment.code_mode_facts(decoded) == code()
  assert enrollment.digests(decoded)
    == #(string.repeat("b", 64), string.repeat("c", 64))
  assert enrollment.matches(original, decoded) == Ok(Nil)
  assert bit_array.byte_size(bytes) < 262_144
}

pub fn same_scope_and_digest_claims_do_not_hide_configuration_drift_test() {
  let before = enrolled()
  let n = native()
  let c = code()
  let changes = [
    #(enrollment.NativeFacts(..n, working_roots: ["/alloc", "/work"]), c),
    #(enrollment.NativeFacts(..n, demand: exec.FullEnforcement), c),
    #(
      enrollment.NativeFacts(
        ..n,
        ceiling: policy.SandboxPolicy(
          ..n.ceiling,
          limits: policy.Limits(..n.ceiling.limits, pids: 99),
        ),
      ),
      c,
    ),
    #(n, enrollment.CodeModeFacts(..c, build_area: "/alloc/other")),
    #(n, enrollment.CodeModeFacts(..c, channel_area: "/alloc/other")),
    #(n, enrollment.CodeModeFacts(..c, gleam_path: "/tc/bin/other")),
    #(n, enrollment.CodeModeFacts(..c, erl_path: "/tc/bin/other")),
    #(n, enrollment.CodeModeFacts(..c, seed_root: "/seed/other")),
    #(n, enrollment.CodeModeFacts(..c, toolchain_roots: ["/tc/bin"])),
    #(n, enrollment.CodeModeFacts(..c, host_mounts: [])),
    #(n, enrollment.CodeModeFacts(..c, build_path: "/tc")),
  ]
  list.each(changes, fn(change) {
    let assert Ok(after) = make(change.0, change.1)
      as "Changed exact facts are individually valid."
    assert enrollment.matches(before, after) == Error(enrollment.Mismatch)
  })
}

pub fn allocation_uses_original_uuid_and_fixed_internal_basenames_test() {
  let original = enrolled()
  assert enrollment.compile_path(original, key(command.CompileService))
    == Ok("/alloc/build/00000000-0000-7000-8000-000000000003")
  let directory = "/alloc/channel/00000000-0000-7000-8000-000000000003"
  assert enrollment.launch_paths(original, key(command.LaunchService))
    == Ok(#(directory, directory <> "/s", directory <> "/cap-token"))
}

pub fn allocation_refuses_wrong_role_scope_registration_or_contract_test() {
  let original = enrolled()
  assert enrollment.compile_path(original, key(command.LaunchService))
    == Error(enrollment.Mismatch)
  assert enrollment.launch_paths(original, key(command.CompileService))
    == Error(enrollment.Mismatch)
  list.each(
    [
      service(
        command.CompileService,
        scope(3),
        string.repeat("b", 64),
        string.repeat("c", 64),
      ),
      service(
        command.CompileService,
        scope(2),
        string.repeat("d", 64),
        string.repeat("c", 64),
      ),
      service(
        command.CompileService,
        scope(2),
        string.repeat("b", 64),
        string.repeat("d", 64),
      ),
    ],
    fn(changed) {
      assert enrollment.compile_path(original, changed)
        == Error(enrollment.Mismatch)
    },
  )
  list.each(
    [
      service(
        command.LaunchService,
        scope(3),
        string.repeat("b", 64),
        string.repeat("c", 64),
      ),
      service(
        command.LaunchService,
        scope(2),
        string.repeat("d", 64),
        string.repeat("c", 64),
      ),
      service(
        command.LaunchService,
        scope(2),
        string.repeat("b", 64),
        string.repeat("d", 64),
      ),
    ],
    fn(changed) {
      assert enrollment.launch_paths(original, changed)
        == Error(enrollment.Mismatch)
    },
  )
}

pub fn aliases_and_traversal_are_refused_in_all_path_roles_test() {
  let c = code()
  list.each(
    [
      "/.",
      "/tc/../work",
      "/tc//bin",
      "/tc/./bin",
      "/tc/bin/",
      "/tc\\bin",
      "/tc/bin:alias",
      "/tc/\u{0000}",
    ],
    fn(path) {
      assert make(native(), enrollment.CodeModeFacts(..c, seed_root: path))
        == Error(enrollment.Invalid)
      assert make(native(), enrollment.CodeModeFacts(..c, gleam_path: path))
        == Error(enrollment.Invalid)
      assert make(enrollment.NativeFacts(..native(), working_roots: [path]), c)
        == Error(enrollment.Invalid)
    },
  )
}

pub fn ordinary_workspace_and_allocation_regions_are_disjoint_test() {
  let c = code()
  list.each(
    [
      enrollment.CodeModeFacts(..c, build_area: "/work/build"),
      enrollment.CodeModeFacts(..c, build_area: "/work"),
      enrollment.CodeModeFacts(..c, workspace_root: "/alloc"),
      enrollment.CodeModeFacts(..c, channel_area: "/alloc/build/channel"),
      enrollment.CodeModeFacts(..c, channel_area: "/alloc/build"),
    ],
    fn(changed) {
      assert make(native(), changed) == Error(enrollment.Invalid)
    },
  )
}

pub fn broad_working_roots_do_not_grant_workspace_jobs_the_allocations_test() {
  assert enrollment.native_facts(enrolled()).working_roots == ["/"]
  assert enrollment.code_mode_facts(enrolled()).workspace_root == "/work"
  let n = native()
  assert make(enrollment.NativeFacts(..n, working_roots: ["/work"]), code())
    == Error(enrollment.Invalid)
  assert make(
      enrollment.NativeFacts(
        ..n,
        ceiling: policy.SandboxPolicy(..n.ceiling, writable_roots: ["/work"]),
      ),
      code(),
    )
    == Error(enrollment.Invalid)
}

pub fn seed_toolchain_path_and_host_mounts_preserve_readonly_authority_test() {
  let n = native()
  let c = code()
  list.each(
    [
      policy.SandboxPolicy(..n.ceiling, writable_roots: [
        "/work",
        "/alloc",
        "/seed",
      ]),
      policy.SandboxPolicy(..n.ceiling, writable_roots: [
        "/work",
        "/alloc",
        "/tc/bin",
      ]),
      policy.SandboxPolicy(..n.ceiling, scratch: policy.ScratchPath("/seed")),
      policy.SandboxPolicy(..n.ceiling, mounts: [
        policy.Mount("/tc", policy.MountReadWrite, policy.MountRequired),
      ]),
    ],
    fn(ceiling) {
      assert make(enrollment.NativeFacts(..n, ceiling:), c)
        == Error(enrollment.Invalid)
    },
  )
  assert make(n, enrollment.CodeModeFacts(..c, seed_root: "/work/seed"))
    == Error(enrollment.Invalid)
  assert make(n, enrollment.CodeModeFacts(..c, toolchain_roots: ["/alloc"]))
    == Error(enrollment.Invalid)
  assert make(n, enrollment.CodeModeFacts(..c, build_path: "/work"))
    == Error(enrollment.Invalid)
  assert make(
      n,
      enrollment.CodeModeFacts(..c, host_mounts: [
        policy.Mount("/tc", policy.MountReadWrite, policy.MountRequired),
      ]),
    )
    == Error(enrollment.Invalid)
}

pub fn duplicate_lists_mounts_environment_and_path_are_refused_test() {
  let n = native()
  let c = code()
  assert make(enrollment.NativeFacts(..n, working_roots: ["/", "/"]), c)
    == Error(enrollment.Invalid)
  assert make(
      enrollment.NativeFacts(
        ..n,
        ceiling: policy.SandboxPolicy(..n.ceiling, env_allow: ["PATH", "PATH"]),
      ),
      c,
    )
    == Error(enrollment.Invalid)
  assert make(
      enrollment.NativeFacts(
        ..n,
        ceiling: policy.SandboxPolicy(..n.ceiling, env_allow: ["1INVALID"]),
      ),
      c,
    )
    == Error(enrollment.Invalid)
  assert make(n, enrollment.CodeModeFacts(..c, toolchain_roots: ["/tc", "/tc"]))
    == Error(enrollment.Invalid)
  assert make(
      n,
      enrollment.CodeModeFacts(
        ..c,
        host_mounts: list.append(host_mounts(), host_mounts()),
      ),
    )
    == Error(enrollment.Invalid)
  assert make(n, enrollment.CodeModeFacts(..c, build_path: "/tc/bin:/tc/bin"))
    == Error(enrollment.Invalid)
}

pub fn full_policy_validity_and_protected_allocations_are_checked_test() {
  let n = native()
  assert make(
      enrollment.NativeFacts(
        ..n,
        ceiling: policy.SandboxPolicy(
          ..n.ceiling,
          limits: policy.Limits(..n.ceiling.limits, wall_s: -1),
        ),
      ),
      code(),
    )
    == Error(enrollment.Invalid)
  assert make(
      enrollment.NativeFacts(
        ..n,
        ceiling: policy.SandboxPolicy(..n.ceiling, protected: [
          "/alloc/build/private",
        ]),
      ),
      code(),
    )
    == Error(enrollment.Invalid)
}

pub fn socket_limit_includes_canonical_uuid_and_s_basename_test() {
  let root = "/" <> string.repeat("c", 60)
  let n = native()
  let c = code()
  let n =
    enrollment.NativeFacts(
      ..n,
      ceiling: policy.SandboxPolicy(..n.ceiling, writable_roots: [
        root,
        ..n.ceiling.writable_roots
      ]),
    )
  let assert Ok(value) =
    make(n, enrollment.CodeModeFacts(..c, channel_area: root))
    as "Exactly 100 bytes fits."
  let assert Ok(#(_, socket, _)) =
    enrollment.launch_paths(value, key(command.LaunchService))
    as "The full UUID socket fits."
  assert string.byte_size(socket) == 100
  assert make(n, enrollment.CodeModeFacts(..c, channel_area: root <> "c"))
    == Error(enrollment.Invalid)
}

pub fn early_oversized_plain_values_are_refused_test() {
  let n = native()
  let c = code()
  assert make(
      enrollment.NativeFacts(..n, working_roots: list.repeat("/work", 100_000)),
      c,
    )
    == Error(enrollment.Invalid)
  assert make(
      n,
      enrollment.CodeModeFacts(
        ..c,
        seed_root: "/" <> string.repeat("a", 100_000),
      ),
    )
    == Error(enrollment.Invalid)
  assert make(
      n,
      enrollment.CodeModeFacts(..c, build_path: string.repeat("a", 100_000)),
    )
    == Error(enrollment.Invalid)
  assert enrollment.new(
      n,
      c,
      string.repeat("b", 100_000),
      string.repeat("c", 64),
    )
    == Error(enrollment.Invalid)
}

pub fn hostile_raw_framing_and_noncanonical_encoding_are_refused_test() {
  list.each(
    [
      <<>>,
      <<0xdd, 0xff, 0xff, 0xff, 0xff>>,
      <<0xdb, 0xff, 0xff, 0xff, 0xff>>,
      <<0xdc, 129:size(16)>>,
      <<0x91, 0xc0>>,
      <<1:size(1)>>,
    ],
    fn(bytes) {
      assert enrollment.decode(bytes) == Error(enrollment.Invalid)
    },
  )
  let assert Ok(bytes) = enrollment.encode(enrolled()) as "Canonical frame."
  assert enrollment.decode(<<bytes:bits, 0>>) == Error(enrollment.Invalid)

  // Array16 is legal MessagePack but differs from the pinned short array tag.
  let assert <<0x98, rest:bits>> = bytes
    as "The versioned enrollment has eight fields."
  assert enrollment.decode(<<0xdc, 8:size(16), rest:bits>>)
    == Error(enrollment.Invalid)
  let assert Ok(mp.ArrayValue(fields)) = mp.decode(bytes)
    as "The canonical frame is an array."
  let assert Ok(extra) =
    mp.encode(mp.ArrayValue(list.append(fields, [mp.NilValue])))
    as "An extra field is encodable."
  assert enrollment.decode(extra) == Error(enrollment.Invalid)
}

fn long_paths(prefix: String) -> List(String) {
  list.index_map(list.repeat(Nil, 30), fn(_, index) {
    "/" <> prefix <> int.to_string(index) <> string.repeat("a", 4000)
  })
}

pub fn aggregate_plain_text_budget_precedes_encoding_test() {
  let n = native()
  let ceiling =
    policy.SandboxPolicy(
      ..n.ceiling,
      writable_roots: ["/work", "/alloc", ..long_paths("w")],
      readable_roots: ["/tc", "/seed", ..long_paths("r")],
    )
  assert make(enrollment.NativeFacts(..n, ceiling:), code())
    == Error(enrollment.Invalid)
}
