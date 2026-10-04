//// Boundary controls for exact command data, without semantic acceptance.

import broker/command
import broker/policy
import core/clock
import core/command as identity
import core/ids
import core/json
import core/msgpack as mp
import core/remote_tool
import core/workspace
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub fn complete_policy_ordered_data_and_closed_regions_roundtrip_test() {
  let original = make_offer(make_ref("a"), mappings(), data())
  let bytes = encoded(original)
  assert command.decode(bytes) == Ok(original)
  assert command.reference(original) == make_ref("a")
  assert command.mappings(original) == mappings()
  assert command.data(original) == data()

  // These independent values ensure decoding cannot lose policy fields while
  // a field-dropping encoder and decoder accidentally agree with one another.
  let assert Ok(mp.ArrayValue([_, _, _, mp.ArrayValue([_, _, _, full])])) =
    mp.decode(bytes)
    as "The policy remains an embedded value."
  assert full == policy.to_msgpack(data().requirements)
  assert policy.from_msgpack(full) == Ok(data().requirements)
  list.each([policy.NetworkOff, policy.NetworkFull], fn(network) {
    let requirements = policy.SandboxPolicy(..data().requirements, network:)
    let variant =
      make_offer(
        make_ref("a"),
        mappings(),
        command.CommandData(..data(), requirements:),
      )
    assert command.decode(encoded(variant)) == Ok(variant)
  })
}

pub fn changed_reference_mappings_argv_env_and_every_policy_field_are_observable_test() {
  let original = make_offer(make_ref("a"), mappings(), data())
  let bytes = encoded(original)
  let requirements = data().requirements
  let variants = [
    make_offer(make_ref("d"), mappings(), data()),
    make_offer(make_ref("a"), list.reverse(mappings()), data()),
    make_offer(
      make_ref("a"),
      [command.RegionMapping(command.Build, "/foreign"), ..mappings()],
      data(),
    ),
    make_offer(
      make_ref("a"),
      mappings(),
      command.CommandData(..data(), argv: list.reverse(data().argv)),
    ),
    make_offer(
      make_ref("a"),
      mappings(),
      command.CommandData(..data(), env: list.reverse(data().env)),
    ),
    make_offer(
      make_ref("a"),
      mappings(),
      command.CommandData(..data(), env: [#("PATH", "/changed")]),
    ),
    make_offer(
      make_ref("a"),
      mappings(),
      command.CommandData(..data(), cwd: "/different"),
    ),
  ]
  list.each(variants, fn(variant) {
    assert encoded(variant) != bytes
    assert command.decode(encoded(variant)) == Ok(variant)
  })
  let policies = [
    policy.SandboxPolicy(..requirements, writable_roots: ["/other"]),
    policy.SandboxPolicy(..requirements, readable_roots: ["/other"]),
    policy.SandboxPolicy(..requirements, protected: ["/other"]),
    policy.SandboxPolicy(..requirements, network: policy.NetworkOff),
    policy.SandboxPolicy(..requirements, env_allow: ["PATH"]),
    policy.SandboxPolicy(..requirements, scratch: policy.ScratchTmpfs),
    policy.SandboxPolicy(..requirements, mounts: []),
    policy.SandboxPolicy(..requirements, mounts: [
      policy.Mount("/tools", policy.MountReadWrite, policy.MountOptional),
    ]),
    policy.SandboxPolicy(
      ..requirements,
      limits: policy.Limits(..requirements.limits, cpu_s: 99),
    ),
    policy.SandboxPolicy(
      ..requirements,
      limits: policy.Limits(..requirements.limits, wall_s: 99),
    ),
    policy.SandboxPolicy(
      ..requirements,
      limits: policy.Limits(..requirements.limits, mem_bytes: 99),
    ),
    policy.SandboxPolicy(
      ..requirements,
      limits: policy.Limits(..requirements.limits, pids: 99),
    ),
    policy.SandboxPolicy(
      ..requirements,
      limits: policy.Limits(..requirements.limits, fsize_bytes: 99),
    ),
    policy.SandboxPolicy(
      ..requirements,
      limits: policy.Limits(..requirements.limits, output_bytes: 99),
    ),
  ]
  list.each(policies, fn(requirements) {
    let variant =
      make_offer(
        make_ref("a"),
        mappings(),
        command.CommandData(..data(), requirements:),
      )
    assert encoded(variant) != bytes
    assert command.decode(encoded(variant)) == Ok(variant)
    assert command.data(variant).requirements == requirements
  })
}

pub fn canonical_offer_and_identity_header_are_required_test() {
  let bytes = encoded(make_offer(make_ref("a"), mappings(), data()))
  let assert <<0x94, body:bits>> = bytes
    as "The canonical outer array uses fixarray."
  assert command.decode(<<0xdc, 4:size(16), body:bits>>)
    == Error(command.NoncanonicalEncoding)
  let assert mp.ArrayValue([version, mp.StringValue(header), regions, native]) =
    value()
    as "The reference occupies a bounded JSON string."
  assert decode_value(
      mp.ArrayValue([version, mp.StringValue(" " <> header), regions, native]),
    )
    == Error(command.NoncanonicalEncoding)
  assert decode_value(
      mp.ArrayValue([mp.IntValue(2), mp.StringValue(header), regions, native]),
    )
    == Error(command.InvalidEncoding)
  assert command.decode(<<bytes:bits, 0xc0>>) |> result.is_error
  assert command.decode(<<0x94, 1, 0xda, 8193:size(16)>>) |> result.is_error
}

pub fn malformed_reference_and_foreign_command_role_are_refused_test() {
  let assert mp.ArrayValue([version, _, regions, native]) = value()
    as "The reference field can be independently corrupted."
  list.each(["[]", "{", string.repeat("x", 8193)], fn(header) {
    assert decode_value(
        mp.ArrayValue([version, mp.StringValue(header), regions, native]),
      )
      |> result.is_error
  })
  let assert json.Array([ref_version, service, _]) =
    identity.encode_ref(make_ref("a"))
    as "The complete core reference has a closed role field."
  let foreign =
    json.Array([ref_version, service, json.String("satellite_command")])
    |> json.to_string
  assert decode_value(
      mp.ArrayValue([version, mp.StringValue(foreign), regions, native]),
    )
    == Error(command.InvalidEncoding)
}

pub fn every_original_service_coordinate_remains_in_the_offered_bytes_test() {
  let ref = make_ref("a")
  let original = make_offer(ref, mappings(), data()) |> encoded
  let assert json.Array([version, json.Array(fields), role]) =
    identity.encode_ref(ref)
    as "The complete service identity remains in the header."
  let assert Ok(json.Array(scope)) = list.first(list.drop(fields, 3))
    as "The original full scope occupies its closed field."
  let assert Ok(json.Array(parent)) = list.first(list.drop(fields, 1))
    as "The original managed parent occupies its closed field."
  let #(other_id, _) = ids.mint_entry(ids.generator(clock.fixed(9000), 99))
  let variants = [
    #(
      1,
      json.Array(
        list.index_map(parent, fn(value, index) {
          case index {
            3 -> json.Int(4)
            4 -> json.String(string.repeat("d", 64))
            _ -> value
          }
        }),
      ),
    ),
    #(
      3,
      json.Array(
        list.index_map(scope, fn(value, index) {
          case index {
            1 -> json.String("another_executor")
            2 -> json.String("another_workspace")
            3 -> json.Int(20)
            4 -> json.Int(30)
            _ -> value
          }
        }),
      ),
    ),
    #(5, json.String("another:physical")),
    #(6, json.String(ids.entry_id_to_string(other_id))),
    #(7, json.String(string.repeat("d", 64))),
    #(8, json.String(string.repeat("d", 64))),
    #(9, json.String(string.repeat("d", 64))),
  ]
  list.each(variants, fn(change) {
    let changed =
      json.Array(
        list.index_map(fields, fn(value, index) {
          case index == change.0 {
            True -> change.1
            False -> value
          }
        }),
      )
    let assert Ok(changed_ref) =
      identity.decode_ref(json.Array([version, changed, role]))
      as "Changed facts remain independently valid identity data."
    let offer = make_offer(changed_ref, mappings(), data())
    assert encoded(offer) != original
    assert command.decode(encoded(offer)) == Ok(offer)
    assert command.reference(offer) == changed_ref
  })
}

pub fn duplicate_environment_and_mapping_data_are_refused_test() {
  let duplicate_env =
    command.CommandData(..data(), env: [#("PATH", "a"), #("PATH", "b")])
  assert command.offer(make_ref("a"), mappings(), duplicate_env)
    == Error(command.InvalidData)
  assert command.offer(
      make_ref("a"),
      [
        command.RegionMapping(command.Build, "/build"),
        command.RegionMapping(command.Build, "/build"),
      ],
      data(),
    )
    == Error(command.InvalidData)
  list.each(["", "A=B"], fn(name) {
    assert command.offer(
        make_ref("a"),
        mappings(),
        command.CommandData(..data(), env: [#(name, "value")]),
      )
      == Error(command.InvalidData)
  })
  let assert mp.ArrayValue([
    version,
    header,
    regions,
    mp.ArrayValue([argv, _, cwd, requirements]),
  ]) = value()
    as "The environment can be corrupted without changing other fields."
  let pair = mp.ArrayValue([mp.StringValue("PATH"), mp.StringValue("a")])
  assert decode_value(
      mp.ArrayValue([
        version,
        header,
        regions,
        mp.ArrayValue([argv, mp.ArrayValue([pair, pair]), cwd, requirements]),
      ]),
    )
    == Error(command.InvalidData)
}

pub fn noncanonical_paths_and_nuls_are_refused_in_all_native_fields_test() {
  let ref = make_ref("a")
  list.each(
    ["work", "/work/", "/work//x", "/work/./x", "/work/../x", "/work\u{0000}"],
    fn(path) {
      assert command.offer(
          ref,
          mappings(),
          command.CommandData(..data(), cwd: path),
        )
        |> result.is_error
      assert command.offer(
          ref,
          [command.RegionMapping(command.Build, path)],
          data(),
        )
        |> result.is_error
      let base = data().requirements
      list.each(
        [
          policy.SandboxPolicy(..base, writable_roots: [path]),
          policy.SandboxPolicy(..base, readable_roots: [path]),
          policy.SandboxPolicy(..base, protected: [path]),
          policy.SandboxPolicy(..base, scratch: policy.ScratchPath(path)),
          policy.SandboxPolicy(..base, mounts: [
            policy.Mount(path, policy.MountReadOnly, policy.MountRequired),
          ]),
        ],
        fn(requirements) {
          assert command.offer(
              ref,
              mappings(),
              command.CommandData(..data(), requirements:),
            )
            |> result.is_error
        },
      )
    },
  )
  list.each(
    [
      command.CommandData(..data(), argv: ["x\u{0000}"]),
      command.CommandData(..data(), env: [#("x\u{0000}", "value")]),
      command.CommandData(..data(), env: [#("NAME", "x\u{0000}")]),
      command.CommandData(
        ..data(),
        requirements: policy.SandboxPolicy(..data().requirements, env_allow: [
          "x\u{0000}",
        ]),
      ),
      command.CommandData(
        ..data(),
        requirements: policy.SandboxPolicy(
          ..data().requirements,
          network: policy.NetworkProxy(["x\u{0000}"], "proxy"),
        ),
      ),
      command.CommandData(
        ..data(),
        requirements: policy.SandboxPolicy(
          ..data().requirements,
          network: policy.NetworkProxy([], "x\u{0000}"),
        ),
      ),
    ],
    fn(native) {
      assert command.offer(ref, mappings(), native)
        == Error(command.InvalidData)
    },
  )
}

pub fn constructor_counts_are_bounded_before_policy_conversion_test() {
  let ref = make_ref("a")
  let many = list.repeat("/read", 129)
  let base = data().requirements
  assert command.offer(ref, mappings(), command.CommandData(..data(), argv: []))
    == Error(command.InvalidData)
  assert command.offer(
      ref,
      mappings(),
      command.CommandData(..data(), argv: list.repeat("arg", 129)),
    )
    == Error(command.BoundExceeded)
  assert command.offer(
      ref,
      mappings(),
      command.CommandData(..data(), env: list.repeat(#("A", "B"), 65)),
    )
    == Error(command.BoundExceeded)
  assert command.offer(
      ref,
      list.repeat(command.RegionMapping(command.Build, "/build"), 129),
      data(),
    )
    == Error(command.BoundExceeded)
  list.each(
    [
      policy.SandboxPolicy(..base, writable_roots: many),
      policy.SandboxPolicy(..base, readable_roots: many),
      policy.SandboxPolicy(..base, protected: many),
      policy.SandboxPolicy(..base, env_allow: many),
      policy.SandboxPolicy(
        ..base,
        mounts: list.repeat(
          policy.Mount("/mount", policy.MountReadOnly, policy.MountRequired),
          129,
        ),
      ),
      policy.SandboxPolicy(..base, network: policy.NetworkProxy(many, "proxy")),
      policy.SandboxPolicy(
        ..base,
        writable_roots: list.repeat("/write", 64),
        readable_roots: list.repeat("/read", 64),
        mounts: [],
      ),
      policy.SandboxPolicy(..base, protected: list.repeat("/read", 100_000)),
    ],
    fn(requirements) {
      assert command.offer(
          ref,
          mappings(),
          command.CommandData(..data(), requirements:),
        )
        == Error(command.BoundExceeded)
    },
  )
}

pub fn constructor_maximum_legal_counts_still_fit_the_node_bound_test() {
  let regions =
    list.map(list.index_map(list.repeat(Nil, 128), fn(_, i) { i }), fn(index) {
      command.RegionMapping(command.Toolchain, "/tool" <> int.to_string(index))
    })
  let mounts =
    list.map(list.index_map(list.repeat(Nil, 128), fn(_, i) { i }), fn(index) {
      policy.Mount(
        "/mount" <> int.to_string(index),
        policy.MountReadOnly,
        policy.MountRequired,
      )
    })
  let env =
    list.map(list.index_map(list.repeat(Nil, 64), fn(_, i) { i }), fn(index) {
      #(int.to_string(index), "value")
    })
  let requirements =
    policy.SandboxPolicy(
      writable_roots: [],
      readable_roots: [],
      protected: list.repeat("/protected", 128),
      network: policy.NetworkProxy(list.repeat("host", 128), "proxy"),
      limits: policy.Limits(1, 2, 3, 4, 5, 6),
      env_allow: list.repeat("NAME", 128),
      scratch: policy.ScratchTmpfs,
      mounts:,
    )
  let native =
    command.CommandData(list.repeat("arg", 128), env, "/work", requirements)
  assert policy.validate(requirements) == Ok(Nil)
  let accepted = make_offer(make_ref("a"), regions, native)
  assert command.decode(encoded(accepted)) == Ok(accepted)

  // The closed schema's maximum legal counts total 2,029 nodes. Untrusted
  // alternative policy shapes still need the raw 2,048-node preflight below.
  let assert Ok(value) = mp.decode(encoded(accepted))
    as "The maximum legal data has a bounded canonical frame."
  assert node_count(value) == 2029
}

pub fn every_string_and_aggregate_byte_limit_is_enforced_test() {
  let ref = make_ref("a")
  let long = string.repeat("x", 8193)
  let base = data().requirements
  list.each(
    [
      command.CommandData(..data(), argv: [long]),
      command.CommandData(..data(), env: [#(long, "a")]),
      command.CommandData(..data(), env: [#("A", long)]),
      command.CommandData(..data(), cwd: "/" <> long),
      command.CommandData(
        ..data(),
        requirements: policy.SandboxPolicy(..base, env_allow: [long]),
      ),
      command.CommandData(
        ..data(),
        requirements: policy.SandboxPolicy(
          ..base,
          network: policy.NetworkProxy([long], "proxy"),
        ),
      ),
      command.CommandData(
        ..data(),
        requirements: policy.SandboxPolicy(
          ..base,
          network: policy.NetworkProxy([], long),
        ),
      ),
      command.CommandData(
        ..data(),
        argv: list.repeat(string.repeat("x", 8192), 33),
      ),
    ],
    fn(native) {
      assert command.offer(ref, mappings(), native)
        == Error(command.BoundExceeded)
    },
  )
  assert command.offer(
      ref,
      [command.RegionMapping(command.Build, "/" <> long)],
      data(),
    )
    == Error(command.BoundExceeded)

  // The exact encoded limit includes fixed policy keys and container headers;
  // raw string bytes alone cannot enforce it. Exercise both sides by one byte.
  let native =
    command.CommandData(
      ..data(),
      argv: list.repeat(string.repeat("x", 8192), 31),
    )
  let prefix = make_offer(ref, mappings(), native) |> encoded
  let gap = 262_144 - bit_array.byte_size(prefix) - 3
  let exact =
    command.CommandData(
      ..native,
      argv: list.append(native.argv, [string.repeat("x", gap)]),
    )
  let exact_offer = make_offer(ref, mappings(), exact)
  assert bit_array.byte_size(encoded(exact_offer)) == 262_144
  assert command.decode(encoded(exact_offer)) == Ok(exact_offer)
  let excessive =
    command.CommandData(
      ..native,
      argv: list.append(native.argv, [string.repeat("x", gap + 1)]),
    )
  assert command.offer(ref, mappings(), excessive)
    == Error(command.BoundExceeded)
}

pub fn invalid_complete_policy_is_refused_test() {
  let base = data().requirements
  list.each(
    [
      policy.SandboxPolicy(
        ..base,
        limits: policy.Limits(..base.limits, wall_s: -1),
      ),
      policy.SandboxPolicy(..base, scratch: policy.ScratchPath("/")),
      policy.SandboxPolicy(..base, mounts: [
        policy.Mount("/secret", policy.MountReadWrite, policy.MountRequired),
      ]),
      policy.SandboxPolicy(..base, mounts: [
        policy.Mount("/same", policy.MountReadOnly, policy.MountRequired),
        policy.Mount("/same", policy.MountReadOnly, policy.MountRequired),
      ]),
    ],
    fn(requirements) {
      let native = command.CommandData(..data(), requirements:)
      assert command.offer(make_ref("a"), mappings(), native)
        == Error(command.InvalidPolicy)
      assert decode_value(with_policy(policy.to_msgpack(requirements)))
        |> result.is_error
    },
  )
  let assert Ok(bytes) = policy.encode(base) as "The complete policy encodes."
  assert decode_value(with_policy(mp.BinaryValue(bytes)))
    == Error(command.InvalidPolicy)
}

pub fn raw_preflight_refuses_deep_oversized_and_aggregate_policy_trees_test() {
  let deep =
    list.fold(list.repeat(Nil, 18), mp.NilValue, fn(value, _) {
      mp.ArrayValue([value])
    })
  let broad = mp.ArrayValue(list.repeat(mp.NilValue, 129))
  let nodes =
    mp.ArrayValue(list.repeat(mp.ArrayValue(list.repeat(mp.NilValue, 128)), 16))
  let bytes =
    mp.ArrayValue(list.repeat(mp.StringValue(string.repeat("x", 8192)), 33))
  list.each(
    [deep, broad, nodes, bytes, mp.BinaryValue(<<0:size(131_073)-unit(8)>>)],
    fn(policy) {
      assert decode_value(with_policy(policy)) == Error(command.InvalidEncoding)
    },
  )
}

pub fn malformed_native_shapes_and_unknown_region_roles_are_refused_test() {
  let assert mp.ArrayValue([version, header, regions, native]) = value()
    as "The fixed frame exposes closed positional fields."
  list.each(
    [
      mp.NilValue,
      mp.ArrayValue([version, header, regions]),
      mp.ArrayValue([version, header, regions, native, mp.NilValue]),
      mp.ArrayValue([
        version,
        header,
        mp.ArrayValue([
          mp.ArrayValue([mp.IntValue(6), mp.StringValue("/build")]),
        ]),
        native,
      ]),
      mp.ArrayValue([
        version,
        header,
        mp.ArrayValue([
          mp.ArrayValue([mp.IntValue(2), mp.StringValue("/build"), mp.NilValue]),
        ]),
        native,
      ]),
      mp.ArrayValue([
        version,
        header,
        regions,
        mp.ArrayValue([
          mp.ArrayValue([mp.IntValue(1)]),
          mp.ArrayValue([]),
          mp.StringValue("/work"),
          policy.to_msgpack(data().requirements),
        ]),
      ]),
    ],
    fn(value) {
      assert decode_value(value) == Error(command.InvalidEncoding)
    },
  )
  assert command.decode(<<0x94, 1>>) == Error(command.InvalidEncoding)
  assert command.decode(<<0xc1>>) == Error(command.InvalidEncoding)
}

fn make_ref(input: String) -> identity.CommandRef {
  let generator = ids.generator(clock.fixed(1000), 77)
  let #(session, generator) = ids.mint_session(generator)
  let #(operation, generator) = ids.mint_op(generator)
  let #(entry, generator) = ids.mint_entry(generator)
  let #(service_id, _) = ids.mint_entry(generator)
  let assert Ok(parent) =
    remote_tool.key(
      session,
      operation,
      "parent",
      3,
      string.repeat("a", 64),
      entry,
    )
    as "The complete managed parent validates."
  let assert Ok(scope) =
    workspace.scope_from_fields(
      ids.session_id_to_string(session),
      "repo",
      "executor",
      2,
      3,
    )
    as "The original registered scope validates."
  let assert Ok(step) = workspace.step("physical:build")
    as "The physical step validates."
  let assert Ok(service) =
    identity.service_key(
      parent,
      identity.CompileService,
      scope,
      operation,
      step,
      service_id,
      string.repeat(input, 64),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "The complete physical service validates."
  let assert Ok(ref) = identity.command_ref(service, identity.CompileCommand)
    as "The native purpose belongs to the original service."
  ref
}

fn mappings() -> List(command.RegionMapping) {
  [
    command.RegionMapping(command.Workspace, "/work"),
    command.RegionMapping(command.Toolchain, "/tools"),
    command.RegionMapping(command.Build, "/build"),
    command.RegionMapping(command.Artifact, "/artifact"),
    command.RegionMapping(command.Channel, "/channel"),
    command.RegionMapping(command.Scratch, "/scratch"),
  ]
}

fn data() -> command.CommandData {
  command.CommandData(
    ["/tools/gleam", "build", "--warnings-as-errors", "é"],
    [#("PATH", "/tools"), #("TMPDIR", "/scratch")],
    "/build",
    policy.SandboxPolicy(
      writable_roots: ["/work"],
      readable_roots: ["/library"],
      protected: ["/secret"],
      network: policy.NetworkProxy(
        ["example.org", "*.example.net"],
        "localhost:9999",
      ),
      limits: policy.Limits(1, 2, 3, 4, 5, 6),
      env_allow: ["PATH", "TMPDIR"],
      scratch: policy.ScratchPath("/scratch"),
      mounts: [
        policy.Mount("/tools", policy.MountReadOnly, policy.MountRequired),
      ],
    ),
  )
}

fn make_offer(
  ref: identity.CommandRef,
  regions: List(command.RegionMapping),
  native: command.CommandData,
) -> command.CommandOffer {
  let assert Ok(offer) = command.offer(ref, regions, native)
    as "The fixture satisfies the bounded data contract."
  offer
}

fn encoded(offer: command.CommandOffer) -> BitArray {
  let assert Ok(bytes) = command.encode(offer)
    as "Validated data has a canonical encoding."
  bytes
}

fn value() -> mp.MsgPackValue {
  let assert Ok(value) =
    mp.decode(encoded(make_offer(make_ref("a"), mappings(), data())))
    as "The original canonical frame decodes."
  value
}

fn with_policy(requirements: mp.MsgPackValue) -> mp.MsgPackValue {
  let assert mp.ArrayValue([
    version,
    header,
    regions,
    mp.ArrayValue([argv, env, cwd, _]),
  ]) = value()
    as "The policy is a nested value in the native record."
  mp.ArrayValue([
    version,
    header,
    regions,
    mp.ArrayValue([argv, env, cwd, requirements]),
  ])
}

fn decode_value(
  value: mp.MsgPackValue,
) -> Result(command.CommandOffer, command.Error) {
  let assert Ok(bytes) = mp.encode(value)
    as "The malformed fixture is valid raw MessagePack."
  command.decode(bytes)
}

fn node_count(value: mp.MsgPackValue) -> Int {
  case value {
    mp.ArrayValue(items) ->
      list.fold(items, 1, fn(total, item) { total + node_count(item) })
    mp.MapValue(entries) ->
      list.fold(entries, 1, fn(total, entry) {
        total + node_count(entry.0) + node_count(entry.1)
      })
    _ -> 1
  }
}
