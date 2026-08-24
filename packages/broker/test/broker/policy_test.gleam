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
  )
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
    )
  let assert Ok(bytes) = policy.encode(empty)
  assert policy.decode(bytes) == Ok(empty)
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
    #("wrong version", with_entry("v", msgpack.IntValue(2))),
    #("v as string", with_entry("v", msgpack.StringValue("1"))),
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
