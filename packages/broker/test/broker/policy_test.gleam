import broker/policy
import core/msgpack
import gleam/list
import simplifile

fn base() -> policy.SandboxPolicy {
  policy.workspace_default("/work")
}

fn proxy_policy() -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    writable_roots: ["/work", "/work/.cache"],
    readable_roots: ["/work", "/usr/lib"],
    protected: ["/work/.git", "/work/.env"],
    network: policy.NetworkProxy(
      allow: ["registry.npmjs.org", "*.github.com"],
      proxy: "127.0.0.1:3128",
    ),
    limits: policy.Limits(
      cpu_s: 60,
      wall_s: 120,
      mem_bytes: 536_870_912,
      pids: 128,
      fsize_bytes: 1_048_576,
      output_bytes: 65_536,
    ),
    env_allow: ["PATH", "HOME"],
    scratch: policy.ScratchPath(path: "/work/.scratch"),
    mounts: [],
  )
}

fn mounted_policy() -> policy.SandboxPolicy {
  policy.SandboxPolicy(..base(), mounts: [
    policy.Mount(
      path: "/run/loom/cap.sock",
      access: policy.MountReadOnly,
      requirement: policy.MountRequired,
    ),
    policy.Mount(
      path: "/work/.blobs",
      access: policy.MountReadWrite,
      requirement: policy.MountOptional,
    ),
  ])
}

fn mount_entry(
  path: String,
  access: String,
  required: Bool,
) -> msgpack.MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("access"), msgpack.StringValue(access)),
    #(msgpack.StringValue("path"), msgpack.StringValue(path)),
    #(msgpack.StringValue("required"), msgpack.BoolValue(required)),
  ])
}

// --- wire codec ---------------------------------------------------------

pub fn roundtrip_default_test() {
  let assert Ok(bytes) = policy.encode(base())
  assert policy.decode(bytes) == Ok(base())
}

pub fn roundtrip_proxy_test() {
  let assert Ok(bytes) = policy.encode(proxy_policy())
  assert policy.decode(bytes) == Ok(proxy_policy())
}

pub fn roundtrip_empty_lists_test() {
  let empty =
    policy.SandboxPolicy(
      writable_roots: [],
      readable_roots: [],
      protected: [],
      network: policy.NetworkFull,
      limits: policy.Limits(
        cpu_s: 0,
        wall_s: 0,
        mem_bytes: 0,
        pids: 0,
        fsize_bytes: 0,
        output_bytes: 0,
      ),
      env_allow: [],
      scratch: policy.ScratchTmpfs,
      mounts: [],
    )
  let assert Ok(bytes) = policy.encode(empty)
  assert policy.decode(bytes) == Ok(empty)
}

pub fn roundtrip_mounts_test() {
  let assert Ok(bytes) = policy.encode(mounted_policy())
  assert policy.decode(bytes) == Ok(mounted_policy())
}

// The cross-language golden fixture (ADR-003 convention): first run
// writes the canonical bytes; later runs must reproduce them exactly.
// The Go helper's suite auto-decodes every `sandbox_policy*` file in
// the fixture directory with its strict decoder.
pub fn golden_sandbox_policy_fixture_test() {
  let path = "../../protocol/msgpack-fixtures/sandbox_policy_1.bin"
  let assert Ok(bytes) = policy.encode(proxy_policy())
  case simplifile.read_bits(path) {
    Ok(stored) -> {
      assert stored == bytes
      assert policy.decode(stored) == Ok(proxy_policy())
    }
    Error(simplifile.Enoent) -> {
      let assert Ok(Nil) = simplifile.write_bits(path, bytes)
      Nil
    }
    Error(_) -> panic as "fixture directory unreadable"
  }
}

pub fn golden_sandbox_policy_off_fixture_test() {
  let path = "../../protocol/msgpack-fixtures/sandbox_policy_2_network_off.bin"
  let assert Ok(bytes) = policy.encode(base())
  case simplifile.read_bits(path) {
    Ok(stored) -> {
      assert stored == bytes
      assert policy.decode(stored) == Ok(base())
    }
    Error(simplifile.Enoent) -> {
      let assert Ok(Nil) = simplifile.write_bits(path, bytes)
      Nil
    }
    Error(_) -> panic as "fixture directory unreadable"
  }
}

pub fn golden_sandbox_policy_mounts_fixture_test() {
  let path = "../../protocol/msgpack-fixtures/sandbox_policy_3_mounts.bin"
  let assert Ok(bytes) = policy.encode(mounted_policy())
  case simplifile.read_bits(path) {
    Ok(stored) -> {
      assert stored == bytes
      assert policy.decode(stored) == Ok(mounted_policy())
    }
    Error(simplifile.Enoent) -> {
      let assert Ok(Nil) = simplifile.write_bits(path, bytes)
      Nil
    }
    Error(_) -> panic as "fixture directory unreadable"
  }
}

// --- adversarial decoding (total, never crashes) ------------------------

fn encode_value(value: msgpack.MsgPackValue) -> BitArray {
  let assert Ok(bytes) = msgpack.encode(value)
  bytes
}

fn valid_entries() -> List(#(msgpack.MsgPackValue, msgpack.MsgPackValue)) {
  let assert Ok(bytes) = policy.encode(base())
  let assert Ok(msgpack.MapValue(entries)) = msgpack.decode(bytes)
  entries
}

fn without_key(key: String) -> BitArray {
  valid_entries()
  |> list.filter(fn(entry) { entry.0 != msgpack.StringValue(key) })
  |> msgpack.MapValue
  |> encode_value
}

fn with_entry(key: String, value: msgpack.MsgPackValue) -> BitArray {
  let replaced =
    valid_entries()
    |> list.map(fn(entry) {
      case entry.0 == msgpack.StringValue(key) {
        True -> #(entry.0, value)
        False -> entry
      }
    })
  let present =
    list.any(valid_entries(), fn(entry) { entry.0 == msgpack.StringValue(key) })
  case present {
    True -> encode_value(msgpack.MapValue(replaced))
    False ->
      encode_value(
        msgpack.MapValue(
          list.append(replaced, [#(msgpack.StringValue(key), value)]),
        ),
      )
  }
}

pub fn decode_rejects_adversarial_test() {
  let corpus = [
    #("random junk", <<0xde, 0xad, 0xbe, 0xef>>),
    #("truncated", <<0x81>>),
    #("not a map", encode_value(msgpack.IntValue(1))),
    #("missing v", without_key("v")),
    #("missing network", without_key("network")),
    #("missing limits", without_key("limits")),
    #("missing scratch", without_key("scratch")),
    #("v1, the version before mounts", with_entry("v", msgpack.IntValue(1))),
    #("wrong version", with_entry("v", msgpack.IntValue(3))),
    #("v as string", with_entry("v", msgpack.StringValue("2"))),
    #("missing mounts", without_key("mounts")),
    #(
      "mount with a relative path",
      with_entry("mounts", msgpack.ArrayValue([mount_entry("s", "ro", True)])),
    ),
    #(
      "mount with an empty path",
      with_entry("mounts", msgpack.ArrayValue([mount_entry("", "ro", True)])),
    ),
    #(
      "mount with an unknown access",
      with_entry("mounts", msgpack.ArrayValue([mount_entry("/s", "wr", True)])),
    ),
    #(
      "mount with an unknown key",
      with_entry(
        "mounts",
        msgpack.ArrayValue([
          msgpack.MapValue([
            #(msgpack.StringValue("access"), msgpack.StringValue("ro")),
            #(msgpack.StringValue("kind"), msgpack.StringValue("socket")),
            #(msgpack.StringValue("path"), msgpack.StringValue("/s")),
            #(msgpack.StringValue("required"), msgpack.BoolValue(True)),
          ]),
        ]),
      ),
    ),
    #(
      "mount missing required",
      with_entry(
        "mounts",
        msgpack.ArrayValue([
          msgpack.MapValue([
            #(msgpack.StringValue("access"), msgpack.StringValue("ro")),
            #(msgpack.StringValue("path"), msgpack.StringValue("/s")),
          ]),
        ]),
      ),
    ),
    #(
      "mount required as a string",
      with_entry(
        "mounts",
        msgpack.ArrayValue([
          msgpack.MapValue([
            #(msgpack.StringValue("access"), msgpack.StringValue("ro")),
            #(msgpack.StringValue("path"), msgpack.StringValue("/s")),
            #(msgpack.StringValue("required"), msgpack.StringValue("yes")),
          ]),
        ]),
      ),
    ),
    #("mounts as a map", with_entry("mounts", msgpack.MapValue([]))),
    #("unknown key", with_entry("sneaky", msgpack.BoolValue(True))),
    #(
      "relative writable root",
      with_entry(
        "writable_roots",
        msgpack.ArrayValue([msgpack.StringValue("work")]),
      ),
    ),
    #(
      "non-string root",
      with_entry("writable_roots", msgpack.ArrayValue([msgpack.IntValue(1)])),
    ),
    #(
      "unknown network mode",
      with_entry(
        "network",
        msgpack.MapValue([
          #(msgpack.StringValue("mode"), msgpack.StringValue("wat")),
        ]),
      ),
    ),
    #(
      "off mode with proxy key",
      with_entry(
        "network",
        msgpack.MapValue([
          #(msgpack.StringValue("mode"), msgpack.StringValue("off")),
          #(msgpack.StringValue("proxy"), msgpack.StringValue("x")),
        ]),
      ),
    ),
    #(
      "proxy mode missing allow",
      with_entry(
        "network",
        msgpack.MapValue([
          #(msgpack.StringValue("mode"), msgpack.StringValue("proxy")),
          #(msgpack.StringValue("proxy"), msgpack.StringValue("x")),
        ]),
      ),
    ),
    #(
      "negative limit",
      with_entry(
        "limits",
        msgpack.MapValue([
          #(msgpack.StringValue("cpu_s"), msgpack.IntValue(-1)),
          #(msgpack.StringValue("wall_s"), msgpack.IntValue(0)),
          #(msgpack.StringValue("mem_bytes"), msgpack.IntValue(0)),
          #(msgpack.StringValue("pids"), msgpack.IntValue(0)),
          #(msgpack.StringValue("fsize_bytes"), msgpack.IntValue(0)),
          #(msgpack.StringValue("output_bytes"), msgpack.IntValue(0)),
        ]),
      ),
    ),
    #(
      "limit as float",
      with_entry(
        "limits",
        msgpack.MapValue([
          #(msgpack.StringValue("cpu_s"), msgpack.FloatValue(1.5)),
          #(msgpack.StringValue("wall_s"), msgpack.IntValue(0)),
          #(msgpack.StringValue("mem_bytes"), msgpack.IntValue(0)),
          #(msgpack.StringValue("pids"), msgpack.IntValue(0)),
          #(msgpack.StringValue("fsize_bytes"), msgpack.IntValue(0)),
          #(msgpack.StringValue("output_bytes"), msgpack.IntValue(0)),
        ]),
      ),
    ),
    #("scratch relative", with_entry("scratch", msgpack.StringValue("scratch"))),
    #("scratch empty", with_entry("scratch", msgpack.StringValue(""))),
  ]
  list.each(corpus, fn(item) {
    let #(name, bytes) = item
    case policy.decode(bytes) {
      Error(_report) -> Nil
      Ok(_) -> panic as { "adversarial input accepted: " <> name }
    }
  })
}

pub fn decode_accepts_nil_mounts_test() {
  let bytes = with_entry("mounts", msgpack.NilValue)
  let assert Ok(decoded) = policy.decode(bytes)
  assert decoded.mounts == []
}

pub fn decode_accepts_nil_arrays_test() {
  // The Go encoder writes nil slices as msgpack nil; our decoder maps
  // them to empty lists.
  let bytes = with_entry("env_allow", msgpack.NilValue)
  let assert Ok(decoded) = policy.decode(bytes)
  assert decoded.env_allow == []
}

// --- validate -----------------------------------------------------------

pub fn validate_accepts_default_test() {
  assert policy.validate(base()) == Ok(Nil)
}

pub fn validate_rejects_relative_path_test() {
  let bad = policy.SandboxPolicy(..base(), writable_roots: ["work"])
  assert policy.validate(bad) == Error(policy.RelativePath(path: "work"))
}

pub fn validate_rejects_relative_scratch_test() {
  let bad = policy.SandboxPolicy(..base(), scratch: policy.ScratchPath("x"))
  assert policy.validate(bad) == Error(policy.RelativePath(path: "x"))
}

pub fn validate_rejects_negative_limit_test() {
  let limits = policy.Limits(..base().limits, pids: -1)
  let bad = policy.SandboxPolicy(..base(), limits:)
  assert policy.validate(bad)
    == Error(policy.NegativeLimit(field: policy.Pids, value: -1))
}

// #59: a scratch of the literal host root grants Landlock read-write
// over the whole filesystem (Landlock has no deny rules to carve a hole
// back out of "/"), so it is refused here rather than reaching the
// mount layer at all.
pub fn validate_rejects_scratch_of_root_test() {
  let bad = policy.SandboxPolicy(..base(), scratch: policy.ScratchPath("/"))
  assert policy.validate(bad) == Error(policy.ScratchIsRoot)
}

// A scratch nested under root, however shallow, is an ordinary absolute
// path and stays accepted — only the literal root is refused.
pub fn validate_accepts_scratch_under_root_test() {
  let ok = policy.SandboxPolicy(..base(), scratch: policy.ScratchPath("/x"))
  assert policy.validate(ok) == Ok(Nil)
}

// A mount under a protected entry cannot be carried out at all: on Linux
// the mask installs a read-only tmpfs over the region and the bind onto
// it makes bubblewrap exit 1 saying only "Read-only file system", the
// anonymous failure of issue #60. Refusing the pair here means neither
// emitter has to decide what to do with it.
pub fn validate_rejects_a_mount_under_a_protected_entry_test() {
  let bad =
    policy.SandboxPolicy(..base(), protected: ["/work/.git"], mounts: [
      policy.Mount(
        path: "/work/.git/cap/s",
        access: policy.MountReadOnly,
        requirement: policy.MountRequired,
      ),
    ])
  assert policy.validate(bad)
    == Error(policy.MountOverlapsProtected(
      mount: "/work/.git/cap/s",
      protected: "/work/.git",
    ))
}

// The other direction is where the two platforms disagreed. A mount
// covering a protected file is emitted after the mask on Linux and
// re-exposes it, while Darwin's trailing deny keeps it shut, so the same
// document enforced two different policies. Refusing it is what makes the
// argv order safe to state as a property.
pub fn validate_rejects_a_mount_covering_a_protected_entry_test() {
  let bad =
    policy.SandboxPolicy(
      ..base(),
      protected: ["/home/o/.loom/owner.token"],
      mounts: [
        policy.Mount(
          path: "/home/o/.loom",
          access: policy.MountReadWrite,
          requirement: policy.MountRequired,
        ),
      ],
    )
  assert policy.validate(bad)
    == Error(policy.MountOverlapsProtected(
      mount: "/home/o/.loom",
      protected: "/home/o/.loom/owner.token",
    ))
}

// One region, one entry. `meet_mounts` reads a path's access out of the
// entry it finds for that path, so a repeated path is a policy with two
// answers; refusing it is what makes the single lookup exact.
pub fn validate_rejects_a_duplicate_mount_path_test() {
  let bad =
    policy.SandboxPolicy(..base(), mounts: [
      policy.Mount(
        path: "/srv/a",
        access: policy.MountReadWrite,
        requirement: policy.MountRequired,
      ),
      policy.Mount(
        path: "/srv/a",
        access: policy.MountReadOnly,
        requirement: policy.MountRequired,
      ),
    ])
  assert policy.validate(bad) == Error(policy.DuplicateMount(path: "/srv/a"))
}

// The duplicate wearing a different spelling. Nothing on either side of
// the wire canonicalizes a mount path, so "/srv/a/" and "/srv/a" would
// compose as two entries here and bind one region in the helper.
pub fn validate_rejects_a_trailing_slash_in_a_mount_path_test() {
  let bad =
    policy.SandboxPolicy(..base(), mounts: [
      policy.Mount(
        path: "/srv/a/",
        access: policy.MountReadOnly,
        requirement: policy.MountRequired,
      ),
    ])
  assert policy.validate(bad)
    == Error(policy.MountPathTrailingSlash(path: "/srv/a/"))
}

// A ".." segment is the same hazard against the protected check rather
// than against another mount: the comparison is by component and nothing
// resolves the path first, so the entry would claim one region and bind
// another.
pub fn validate_rejects_a_parent_segment_in_a_mount_path_test() {
  let bad =
    policy.SandboxPolicy(..base(), mounts: [
      policy.Mount(
        path: "/srv/a/../b",
        access: policy.MountReadOnly,
        requirement: policy.MountRequired,
      ),
    ])
  assert policy.validate(bad)
    == Error(policy.MountPathParentSegment(path: "/srv/a/../b"))
}

// A mount beside a protected entry, sharing only a textual prefix, is
// not an overlap. The check asks the same component-wise question
// `policy.covers` asks everywhere else.
pub fn validate_accepts_a_mount_beside_a_protected_entry_test() {
  let ok =
    policy.SandboxPolicy(..base(), protected: ["/work/.git"], mounts: [
      policy.Mount(
        path: "/work/.gitx",
        access: policy.MountReadOnly,
        requirement: policy.MountRequired,
      ),
    ])
  assert policy.validate(ok) == Ok(Nil)
}

// --- phase-1 unenforceable narrowing ------------------------------------

pub fn narrow_unenforceable_downgrades_proxy_test() {
  // No egress sidecar exists in phase 1: proxy mode fails closed to
  // off, and the downgrade is reported as an ordinary narrowing
  // carrying the wanted proxy policy.
  let wanted =
    policy.NetworkProxy(allow: ["registry.npmjs.org"], proxy: "127.0.0.1:3128")
  let asking = policy.SandboxPolicy(..base(), network: wanted)
  let #(narrowed, narrowings) = policy.narrow_unenforceable(asking)
  assert narrowed == policy.SandboxPolicy(..base(), network: policy.NetworkOff)
  assert narrowings
    == [policy.NarrowedNetwork(wanted:, granted: policy.NetworkOff)]
}

pub fn narrow_unenforceable_leaves_off_alone_test() {
  assert policy.narrow_unenforceable(base()) == #(base(), [])
}

pub fn narrow_unenforceable_leaves_full_alone_test() {
  let full = policy.SandboxPolicy(..base(), network: policy.NetworkFull)
  assert policy.narrow_unenforceable(full) == #(full, [])
}

// --- composition tables -------------------------------------------------

pub fn compose_identical_no_narrowing_test() {
  assert policy.compose(base: base(), requirements: base(), grants: [])
    == #(base(), [])
}

pub fn compose_narrower_requirements_win_test() {
  let requirements =
    policy.SandboxPolicy(
      ..base(),
      writable_roots: ["/work/sub"],
      network: policy.NetworkOff,
    )
  let #(composed, narrowings) =
    policy.compose(base: base(), requirements:, grants: [])
  // Prefix-aware coverage: /work covers /work/sub, and the narrower
  // request is exactly what runs.
  assert composed.writable_roots == ["/work/sub"]
  assert narrowings == []
}

pub fn compose_uncovered_root_narrowed_test() {
  let requirements = policy.SandboxPolicy(..base(), writable_roots: ["/etc"])
  let #(composed, narrowings) =
    policy.compose(base: base(), requirements:, grants: [])
  assert composed.writable_roots == []
  assert narrowings == [policy.NarrowedWritableRoot(path: "/etc")]
  // The wanted grants are exactly the diff an approval would apply.
  assert policy.wanted_grants(narrowings)
    == [policy.GrantWritableRoot(path: "/etc")]
}

pub fn compose_grant_restores_root_test() {
  let requirements = policy.SandboxPolicy(..base(), writable_roots: ["/etc"])
  let #(composed, narrowings) =
    policy.compose(base: base(), requirements:, grants: [
      policy.GrantWritableRoot(path: "/etc"),
    ])
  assert list.contains(composed.writable_roots, "/etc")
  assert narrowings == []
}

pub fn compose_network_meet_test() {
  // Off wins over everything.
  let wants_full = policy.SandboxPolicy(..base(), network: policy.NetworkFull)
  let #(composed, narrowings) =
    policy.compose(base: base(), requirements: wants_full, grants: [])
  assert composed.network == policy.NetworkOff
  assert narrowings
    == [
      policy.NarrowedNetwork(
        wanted: policy.NetworkFull,
        granted: policy.NetworkOff,
      ),
    ]
}

pub fn compose_proxy_intersection_test() {
  let proxy_base =
    policy.SandboxPolicy(
      ..base(),
      network: policy.NetworkProxy(
        allow: ["a.example", "b.example"],
        proxy: "p",
      ),
    )
  let requirements =
    policy.SandboxPolicy(
      ..base(),
      network: policy.NetworkProxy(
        allow: ["b.example", "c.example"],
        proxy: "rogue",
      ),
    )
  let #(composed, narrowings) =
    policy.compose(base: proxy_base, requirements:, grants: [])
  // Intersection of allowlists; the harness-owned proxy address wins.
  assert composed.network
    == policy.NetworkProxy(allow: ["b.example"], proxy: "p")
  // c.example was wanted and not granted.
  assert narrowings
    == [
      policy.NarrowedNetwork(
        wanted: requirements.network,
        granted: composed.network,
      ),
    ]
}

pub fn compose_grant_widens_network_test() {
  let wants_proxy =
    policy.SandboxPolicy(
      ..base(),
      network: policy.NetworkProxy(allow: ["r.example"], proxy: "p"),
    )
  let grant =
    policy.GrantNetwork(policy.NetworkProxy(allow: ["r.example"], proxy: "p"))
  let #(composed, narrowings) =
    policy.compose(base: base(), requirements: wants_proxy, grants: [grant])
  assert composed.network
    == policy.NetworkProxy(allow: ["r.example"], proxy: "p")
  assert narrowings == []
}

pub fn compose_limits_meet_and_join_test() {
  let requirements =
    policy.SandboxPolicy(
      ..base(),
      limits: policy.Limits(
        ..base().limits,
        // Wants more CPU than the base allows...
        cpu_s: 900,
        // ...and unlimited wall time.
        wall_s: 0,
      ),
    )
  let #(composed, narrowings) =
    policy.compose(base: base(), requirements:, grants: [])
  // Most restrictive wins: base's 300s CPU and 600s wall.
  assert composed.limits.cpu_s == 300
  assert composed.limits.wall_s == 600
  assert list.contains(
    narrowings,
    policy.NarrowedLimit(field: policy.CpuSeconds, wanted: 900, granted: 300),
  )
  assert list.contains(
    narrowings,
    policy.NarrowedLimit(field: policy.WallSeconds, wanted: 0, granted: 600),
  )
  // A grant raises exactly the granted field.
  let #(widened, remaining) =
    policy.compose(base: base(), requirements:, grants: [
      policy.GrantLimit(field: policy.CpuSeconds, value: 900),
    ])
  assert widened.limits.cpu_s == 900
  assert remaining
    == [
      policy.NarrowedLimit(field: policy.WallSeconds, wanted: 0, granted: 600),
    ]
}

pub fn compose_protected_union_test() {
  let requirements = policy.SandboxPolicy(..base(), protected: ["/work/.git"])
  let with_protected = policy.SandboxPolicy(..base(), protected: ["/work/.env"])
  let #(composed, narrowings) =
    policy.compose(base: with_protected, requirements:, grants: [])
  // Protections accumulate from both sides and are never a narrowing.
  assert composed.protected == ["/work/.env", "/work/.git"]
  assert narrowings == []
}

pub fn compose_env_intersection_test() {
  let requirements =
    policy.SandboxPolicy(..base(), env_allow: ["PATH", "SECRET"])
  let #(composed, narrowings) =
    policy.compose(base: base(), requirements:, grants: [])
  assert composed.env_allow == ["PATH"]
  assert narrowings == [policy.NarrowedEnv(name: "SECRET")]
  // Granted explicitly, the variable appears.
  let #(widened, remaining) =
    policy.compose(base: base(), requirements:, grants: [
      policy.GrantEnv("SECRET"),
    ])
  assert list.contains(widened.env_allow, "SECRET")
  assert remaining == []
}

pub fn compose_scratch_conflict_collapses_to_tmpfs_test() {
  let requirements =
    policy.SandboxPolicy(..base(), scratch: policy.ScratchPath("/work/.s"))
  let #(composed, narrowings) =
    policy.compose(base: base(), requirements:, grants: [])
  assert composed.scratch == policy.ScratchTmpfs
  assert narrowings
    == [policy.NarrowedScratch(wanted: policy.ScratchPath("/work/.s"))]
  let #(widened, remaining) =
    policy.compose(base: base(), requirements:, grants: [
      policy.GrantScratch(policy.ScratchPath("/work/.s")),
    ])
  assert widened.scratch == policy.ScratchPath("/work/.s")
  assert remaining == []
}

pub fn compose_without_grants_never_widens_test() {
  // Whatever a tool asks for, absent grants the result allows no more
  // than the base: a coarse property over a few hostile requirements.
  let hostile = [
    policy.SandboxPolicy(
      ..base(),
      writable_roots: ["/", "/etc", "/home"],
      network: policy.NetworkFull,
      env_allow: ["AWS_SECRET_ACCESS_KEY"],
    ),
    policy.SandboxPolicy(
      ..base(),
      readable_roots: ["/etc/shadow"],
      limits: policy.Limits(
        cpu_s: 0,
        wall_s: 0,
        mem_bytes: 0,
        pids: 0,
        fsize_bytes: 0,
        output_bytes: 0,
      ),
    ),
  ]
  list.each(hostile, fn(requirements) {
    let #(composed, _) = policy.compose(base: base(), requirements:, grants: [])
    list.each(composed.writable_roots, fn(root) {
      assert root == "/work" || starts_with_work(root)
    })
    assert composed.network == policy.NetworkOff
    assert composed.limits.cpu_s <= 300
    assert composed.limits.wall_s <= 600
    assert !list.contains(composed.env_allow, "AWS_SECRET_ACCESS_KEY")
  })
}

fn starts_with_work(path: String) -> Bool {
  case path {
    "/work/" <> _ -> True
    _ -> False
  }
}

// --- the shared coverage predicate ------------------------------------------
//
// `covers` is one function with three call sites in three packages —
// composition here, the jail's reachability checks in `codemode/launch`,
// and the harness-side protected-path refusal in `tools/fs`. It used to
// be three textual copies, which is three places a fix could land in
// two of. Pinned at its own home so the property is asserted about the
// predicate rather than inferred from whichever caller happens to have a
// test.

pub fn covers_matches_a_path_by_component_never_by_prefix_test() {
  // The whole point of the predicate. `/workspace` merely shares a
  // textual prefix with `/work`; a plain `starts_with` would put it
  // inside a root that does not contain it, and — read through
  // `tools/fs` — would refuse a write to `.gitx/notes` as though it were
  // under `.git`.
  assert policy.covers(root: "/work", path: "/work")
  assert policy.covers(root: "/work", path: "/work/sub")
  assert policy.covers(root: "/work", path: "/work/sub/deeper.txt")
  assert !policy.covers(root: "/work", path: "/workspace")
  assert !policy.covers(root: "/work", path: "/workspace/sub")
  assert !policy.covers(root: "/work", path: "/other")
  assert !policy.covers(root: "/work/.git", path: "/work/.gitx/notes")
}

pub fn covers_treats_the_filesystem_root_as_covering_everything_test() {
  assert policy.covers(root: "/", path: "/")
  assert policy.covers(root: "/", path: "/anything/at/all")
}

pub fn covers_is_not_symmetric_test() {
  // A root covers what is under it and not the other way round: a
  // reversed argument order is a real bug and this is what catches it.
  assert policy.covers(root: "/work", path: "/work/sub")
  assert !policy.covers(root: "/work/sub", path: "/work")
}

pub fn covers_is_byte_exact_test() {
  // Stated rather than assumed: the enforced target is Linux, where the
  // kernel that applies the same boundary is byte-exact too. A case fold
  // here would make this predicate and the jail disagree.
  assert !policy.covers(root: "/work", path: "/WORK/x")
}

pub fn limit_field_name_is_the_wire_spelling_test() {
  assert policy.limit_field_name(policy.CpuSeconds) == "cpu_s"
  assert policy.limit_field_name(policy.WallSeconds) == "wall_s"
  assert policy.limit_field_name(policy.MemBytes) == "mem_bytes"
  assert policy.limit_field_name(policy.Pids) == "pids"
  assert policy.limit_field_name(policy.FsizeBytes) == "fsize_bytes"
  assert policy.limit_field_name(policy.OutputBytes) == "output_bytes"
}

// --- the mount lattice ------------------------------------------------------
//
// Composition over `mounts` is a meet on access and a join on requirement,
// intersected by path. The three algebraic laws below are what make
// "most-restrictive-wins" a claim about the value rather than about the
// order the broker happened to compose in, so they are checked
// exhaustively over a small alphabet rather than on a couple of examples.

// Every mount over two paths, both accesses and both requirements: the
// alphabet the exhaustive laws below range over.
fn mount_alphabet() -> List(policy.Mount) {
  let paths = ["/a", "/b"]
  let accesses = [policy.MountReadOnly, policy.MountReadWrite]
  let requirements = [policy.MountRequired, policy.MountOptional]
  list.flat_map(paths, fn(path) {
    list.flat_map(accesses, fn(access) {
      list.map(requirements, fn(requirement) {
        policy.Mount(path:, access:, requirement:)
      })
    })
  })
}

// Every mount list of length zero or one over that alphabet, plus the two
// two-element lists that name both paths. Longer lists add no case: the
// meet works one path at a time, so two paths already exercise every
// interaction between entries.
//
// A pair naming one path twice is excluded because `validate` refuses it
// (`validate_rejects_a_duplicate_mount_path_test`), so it is not a list
// the composition laws are claimed about. The exclusion is a validity
// condition rather than a gap in the alphabet.
fn mount_lists() -> List(List(policy.Mount)) {
  let singles = list.map(mount_alphabet(), fn(mount) { [mount] })
  let pairs =
    list.flat_map(mount_alphabet(), fn(left) {
      mount_alphabet()
      |> list.filter(fn(right) { right.path != left.path })
      |> list.map(fn(right) { [left, right] })
    })
  list.flatten([[[]], singles, pairs])
}

fn with_mounts(mounts: List(policy.Mount)) -> policy.SandboxPolicy {
  policy.SandboxPolicy(..base(), mounts:)
}

// Composition sorts nothing, so two runs that agree as sets can disagree
// as lists. The laws are about which mounts survive and at what access, so
// they compare by membership.
fn same_mounts(left: List(policy.Mount), right: List(policy.Mount)) -> Bool {
  list.length(left) == list.length(right)
  && list.all(left, fn(mount) { list.contains(right, mount) })
}

fn composed_mounts(
  base_mounts: List(policy.Mount),
  requested: List(policy.Mount),
) -> List(policy.Mount) {
  let #(composed, _) =
    policy.compose(
      base: with_mounts(base_mounts),
      requirements: with_mounts(requested),
      grants: [],
    )
  composed.mounts
}

pub fn mount_composition_is_commutative_test() {
  list.each(mount_lists(), fn(left) {
    list.each(mount_lists(), fn(right) {
      assert same_mounts(
        composed_mounts(left, right),
        composed_mounts(right, left),
      )
    })
  })
}

pub fn mount_composition_is_associative_test() {
  list.each(mount_lists(), fn(a) {
    list.each(mount_lists(), fn(b) {
      list.each(mount_lists(), fn(c) {
        let left = composed_mounts(composed_mounts(a, b), c)
        let right = composed_mounts(a, composed_mounts(b, c))
        assert same_mounts(left, right)
      })
    })
  })
}

pub fn mount_composition_is_idempotent_test() {
  list.each(mount_lists(), fn(mounts) {
    assert same_mounts(composed_mounts(mounts, mounts), mounts)
  })
}

// Absorption in the form that matters here: the workspace default carries
// no mounts, so composing against it can only ever produce none. A tool
// cannot introduce a bind the session base never granted, which is the
// property that lets `protocol-change/004` do without a `GrantMount`.
pub fn workspace_default_absorbs_every_requested_mount_test() {
  assert policy.workspace_default("/work").mounts == []
  list.each(mount_lists(), fn(mounts) {
    assert composed_mounts([], mounts) == []
    assert composed_mounts(mounts, []) == []
  })
}

pub fn a_mount_the_base_lacks_is_a_narrowing_with_no_grant_test() {
  let wanted =
    policy.Mount(
      path: "/run/loom/cap.sock",
      access: policy.MountReadOnly,
      requirement: policy.MountRequired,
    )
  let #(composed, narrowings) =
    policy.compose(
      base: base(),
      requirements: with_mounts([wanted]),
      grants: [],
    )
  assert composed.mounts == []
  assert narrowings == [policy.NarrowedMount(wanted:)]

  // No `GrantMount` exists, so the escalation carries nothing that would
  // widen this. The refusal is in-band and final for the session.
  assert policy.wanted_grants(narrowings) == []
}

pub fn a_read_write_request_is_not_satisfied_by_a_read_only_base_test() {
  let base_mount =
    policy.Mount(
      path: "/work/.blobs",
      access: policy.MountReadOnly,
      requirement: policy.MountOptional,
    )
  let wanted = policy.Mount(..base_mount, access: policy.MountReadWrite)
  let #(composed, narrowings) =
    policy.compose(
      base: with_mounts([base_mount]),
      requirements: with_mounts([wanted]),
      grants: [],
    )
  assert composed.mounts == [base_mount]
  assert narrowings == [policy.NarrowedMount(wanted:)]
}

// A required mount survives composition with an optional one, because
// `MountRequired` asks the helper to fail closed on a missing source and
// that is not a privilege composition may drop.
pub fn a_required_mount_survives_an_optional_one_test() {
  let path = "/run/loom/cap.sock"
  let required =
    policy.Mount(
      path:,
      access: policy.MountReadWrite,
      requirement: policy.MountRequired,
    )
  let optional = policy.Mount(..required, requirement: policy.MountOptional)
  assert composed_mounts([required], [optional])
    == [policy.Mount(..optional, requirement: policy.MountRequired)]
}

pub fn validate_rejects_a_relative_mount_test() {
  let bad =
    with_mounts([
      policy.Mount(
        path: "work/.blobs",
        access: policy.MountReadOnly,
        requirement: policy.MountOptional,
      ),
    ])
  assert policy.validate(bad) == Error(policy.RelativePath("work/.blobs"))
}

pub fn validate_rejects_an_empty_mount_path_test() {
  let bad =
    with_mounts([
      policy.Mount(
        path: "",
        access: policy.MountReadOnly,
        requirement: policy.MountOptional,
      ),
    ])
  assert policy.validate(bad) == Error(policy.RelativePath(""))
}
