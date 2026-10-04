//// Bounded exact command proposals beneath a retained physical service.
////
//// An offer is data, never clearance, resource admission or execution authority.
//// Its complete CommandRef names the original service; ordered mappings, argv,
//// environment and every SandboxPolicy field retain the offered spelling.
//// Owner code must independently construct its closed compile or launch template
//// from retained input and trusted enrollment before accepting these facts.
//// No path here is resolved on disk, and no digest is computed or authenticated.
////
//// `offer` bounds native lists and their aggregate string bytes before policy
//// conversion. `check_value` then counts exact canonical encoded bytes and nodes
//// before encoding. `decode` preflights the complete raw frame with core's fixed
//// remote bounds before term decoding, validates through the same constructor,
//// and requires re-encoding to equal the original bytes. Policy is embedded as
//// a value, so its containers cannot hide behind an unchecked nested binary.
////
//// The identity header is canonical core/command JSON in one bounded 8-KiB
//// MessagePack string. Its inner JSON is separately parsed and re-encoded; the
//// closed core identity decoder owns scope and service/native-role relations.
//// The outer 2,048-node bound counts that header as one string, not JSON nodes.
//// Header parsing remains bounded by its bytes and core/json's depth limit.
//// The rest of the frame uses the fixed 256-KiB, depth-16 remote profile. These
//// are logical data bounds, not an equal BEAM resident-memory promise.
//// `within_count` inspects a fixed list prefix, and `check_paths` applies lexical
//// validation to bounded policy roots. `as_string` refuses non-string argv.
//// `container_header` and `charge` account for exact bytes and shared nodes.

import broker/policy
import core/bounded_msgpack
import core/command as identity
import core/json
import core/msgpack as mp
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

/// The closed region purposes used by compile and satellite templates.
pub type RegionUse {
  /// The enrolled workspace checkout.
  Workspace

  /// An enrolled immutable toolchain root.
  Toolchain

  /// This compile service's admitted allocation.
  Build

  /// The exact producing compile allocation used by launch.
  Artifact

  /// This launch service's admitted channel allocation.
  Channel

  /// The exact scratch region used by this command.
  Scratch
}

/// A purpose and exact canonical absolute root; arbitrary region labels do not
/// participate in this vocabulary. Association with enrollment belongs to the
/// owner's closed template, not this untrusted data constructor.
pub type RegionMapping {
  RegionMapping(
    /// The closed purpose of this access region.
    region: RegionUse,
    /// Exact component-canonical absolute path, without filesystem resolution.
    root: String,
  )
}

/// Exact native command facts, without grants, demand, token or lifetime.
pub type CommandData {
  CommandData(
    /// One to 128 arguments in their original order.
    argv: List(String),
    /// At most 64 distinct names, retaining pair order and literal values.
    env: List(#(String, String)),
    /// Exact component-canonical absolute working directory.
    cwd: String,
    /// The complete native sandbox requirement, including every policy field.
    requirements: policy.SandboxPolicy,
  )
}

/// A bounded canonical proposal. Opacity certifies shape, never authority.
pub opaque type CommandOffer {
  CommandOffer(
    /// The original complete service and closed native purpose.
    ref: identity.CommandRef,
    /// Ordered exact region evidence supplied by the proposer.
    mappings: List(RegionMapping),
    /// Ordered native bytes and full policy supplied by the proposer.
    data: CommandData,
  )
}

/// Refusals do not reflect unbounded peer input into diagnostics.
pub type Error {
  /// A count, string, node or encoded-byte limit was exceeded.
  BoundExceeded

  /// Native data has duplicate names/mappings, NULs or noncanonical paths.
  InvalidData

  /// The complete sandbox policy fails its existing semantic validation.
  InvalidPolicy

  /// The wire shape, version, identity or MessagePack value is malformed.
  InvalidEncoding

  /// Valid data used an encoding different from the canonical exact bytes.
  NoncanonicalEncoding
}

type Budget {
  Budget(bytes: Int, nodes: Int)
}

/// Constructs bounded data after short-circuiting oversized native lists.
/// Policy validation runs only after its lists and aggregate strings are bounded.
/// Region association and exact compile/launch semantics remain owner obligations.
///
/// ## Examples
///
/// ```gleam
/// // command.offer(ref, [command.RegionMapping(command.Build, root)], data)
/// ```
pub fn offer(
  ref: identity.CommandRef,
  mappings: List(RegionMapping),
  data: CommandData,
) -> Result(CommandOffer, Error) {
  use Nil <- result.try(check_lists(mappings, data))
  use header <- result.try(check_text(ref_text(ref)))
  use bytes <- result.try(check_texts(data.argv, header))
  use bytes <- result.try(check_environment(data.env, [], bytes))
  use bytes <- result.try(check_mappings(mappings, [], bytes))
  use bytes <- result.try(check_path(data.cwd, bytes))
  use _ <- result.try(check_policy_texts(data.requirements, bytes))

  // Semantic validation may flatten policy lists; only bounded lists reach it.
  use Nil <- result.try(
    policy.validate(data.requirements) |> result.replace_error(InvalidPolicy),
  )
  let candidate = CommandOffer(ref, mappings, data)
  use _ <- result.try(check_value(to_value(candidate), Budget(0, 0)))
  Ok(candidate)
}

/// Returns the exact original reference, without allocating a native UUID.
///
/// ## Examples
///
/// ```gleam
/// // command.reference(proposal) == original_ref
/// ```
pub fn reference(proposal: CommandOffer) -> identity.CommandRef {
  proposal.ref
}

/// Returns ordered mappings without interpreting their roots as local paths.
///
/// ## Examples
///
/// ```gleam
/// // command.mappings(proposal) == original_mappings
/// ```
pub fn mappings(proposal: CommandOffer) -> List(RegionMapping) {
  proposal.mappings
}

/// Returns the complete native facts, without permission to dispatch them.
///
/// ## Examples
///
/// ```gleam
/// // command.data(proposal) == original_data
/// ```
pub fn data(proposal: CommandOffer) -> CommandData {
  proposal.data
}

/// Encodes the canonical versioned value. Hashing belongs to existing owner or
/// executor SHA-256 boundaries, which must hash these returned exact bytes.
///
/// ## Examples
///
/// ```gleam
/// // command.encode(proposal) |> result.try(command.decode) == Ok(proposal)
/// ```
pub fn encode(proposal: CommandOffer) -> Result(BitArray, Error) {
  mp.encode(to_value(proposal)) |> result.replace_error(InvalidEncoding)
}

/// Totally decodes one canonical bounded frame before any owner acceptance.
/// Unsupported versions, trailing data, alternate encodings and invalid complete
/// policies are refused. No native reservation or execution occurs here.
///
/// ## Examples
///
/// ```gleam
/// assert command.decode(<<>>) == Error(command.InvalidEncoding)
/// ```
pub fn decode(bytes: BitArray) -> Result(CommandOffer, Error) {
  use value <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(InvalidEncoding),
  )
  use proposal <- result.try(from_value(value))
  use canonical <- result.try(encode(proposal))
  case canonical == bytes {
    True -> Ok(proposal)
    False -> Error(NoncanonicalEncoding)
  }
}

fn from_value(value: mp.MsgPackValue) -> Result(CommandOffer, Error) {
  case value {
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue(header),
      mp.ArrayValue(region_values),
      mp.ArrayValue([
        mp.ArrayValue(arguments),
        mp.ArrayValue(environment),
        mp.StringValue(cwd),
        requirements,
      ]),
    ]) -> {
      use ref <- result.try(decode_ref(header))
      use argv <- result.try(list.try_map(arguments, as_string))
      use env <- result.try(list.try_map(environment, decode_environment))
      use mappings <- result.try(list.try_map(region_values, decode_mapping))
      use requirements <- result.try(
        policy.from_msgpack(requirements) |> result.replace_error(InvalidPolicy),
      )
      offer(ref, mappings, CommandData(argv, env, cwd, requirements))
    }
    _ -> Error(InvalidEncoding)
  }
}

fn decode_ref(header: String) -> Result(identity.CommandRef, Error) {
  use _ <- result.try(check_text(header))
  use value <- result.try(
    json.parse(header) |> result.replace_error(InvalidEncoding),
  )
  use ref <- result.try(
    identity.decode_ref(value) |> result.replace_error(InvalidEncoding),
  )
  case ref_text(ref) == header {
    True -> Ok(ref)
    False -> Error(NoncanonicalEncoding)
  }
}

fn decode_environment(
  value: mp.MsgPackValue,
) -> Result(#(String, String), Error) {
  case value {
    mp.ArrayValue([mp.StringValue(name), mp.StringValue(value)]) ->
      Ok(#(name, value))
    _ -> Error(InvalidEncoding)
  }
}

fn decode_mapping(value: mp.MsgPackValue) -> Result(RegionMapping, Error) {
  case value {
    mp.ArrayValue([mp.IntValue(role), mp.StringValue(root)]) -> {
      use use_ <- result.try(case role {
        0 -> Ok(Workspace)
        1 -> Ok(Toolchain)
        2 -> Ok(Build)
        3 -> Ok(Artifact)
        4 -> Ok(Channel)
        5 -> Ok(Scratch)
        _ -> Error(InvalidEncoding)
      })
      Ok(RegionMapping(use_, root))
    }
    _ -> Error(InvalidEncoding)
  }
}

fn as_string(value: mp.MsgPackValue) -> Result(String, Error) {
  case value {
    mp.StringValue(text) -> Ok(text)
    mp.NilValue
    | mp.BoolValue(_)
    | mp.IntValue(_)
    | mp.FloatValue(_)
    | mp.BinaryValue(_)
    | mp.ArrayValue(_)
    | mp.MapValue(_) -> Error(InvalidEncoding)
  }
}

fn to_value(proposal: CommandOffer) -> mp.MsgPackValue {
  mp.ArrayValue([
    mp.IntValue(1),
    mp.StringValue(ref_text(proposal.ref)),
    mp.ArrayValue(
      list.map(proposal.mappings, fn(mapping) {
        mp.ArrayValue([
          mp.IntValue(region_number(mapping.region)),
          mp.StringValue(mapping.root),
        ])
      }),
    ),
    mp.ArrayValue([
      mp.ArrayValue(list.map(proposal.data.argv, mp.StringValue)),
      mp.ArrayValue(
        list.map(proposal.data.env, fn(pair) {
          mp.ArrayValue([mp.StringValue(pair.0), mp.StringValue(pair.1)])
        }),
      ),
      mp.StringValue(proposal.data.cwd),
      policy.to_msgpack(proposal.data.requirements),
    ]),
  ])
}

fn ref_text(ref: identity.CommandRef) -> String {
  identity.encode_ref(ref) |> json.to_string
}

fn region_number(use_: RegionUse) -> Int {
  case use_ {
    Workspace -> 0
    Toolchain -> 1
    Build -> 2
    Artifact -> 3
    Channel -> 4
    Scratch -> 5
  }
}

fn check_lists(
  mappings: List(RegionMapping),
  data: CommandData,
) -> Result(Nil, Error) {
  let requirements = data.requirements

  // drop inspects only the limit's prefix, never an attacker-sized whole list.
  use Nil <- result.try(within_count(data.argv, 128))
  use Nil <- result.try(case data.argv {
    [] -> Error(InvalidData)
    [_, ..] -> Ok(Nil)
  })
  use Nil <- result.try(within_count(data.env, 64))
  use Nil <- result.try(within_count(mappings, 128))
  use Nil <- result.try(within_count(requirements.writable_roots, 128))
  use Nil <- result.try(within_count(requirements.readable_roots, 128))
  use Nil <- result.try(within_count(requirements.protected, 128))
  use Nil <- result.try(within_count(requirements.env_allow, 128))
  use Nil <- result.try(within_count(requirements.mounts, 128))

  // Counting and conversion are now bounded even when one input list is huge.
  let scratch_count = case requirements.scratch {
    policy.ScratchTmpfs -> 0
    policy.ScratchPath(_) -> 1
  }
  use Nil <- result.try(
    case
      list.length(requirements.writable_roots)
      + list.length(requirements.readable_roots)
      + list.length(requirements.mounts)
      + scratch_count
      <= 128
    {
      True -> Ok(Nil)
      False -> Error(BoundExceeded)
    },
  )
  case requirements.network {
    policy.NetworkProxy(allow, _) -> within_count(allow, 128)
    policy.NetworkOff | policy.NetworkFull -> Ok(Nil)
  }
}

fn within_count(items: List(a), maximum: Int) -> Result(Nil, Error) {
  case list.drop(items, maximum) {
    [] -> Ok(Nil)
    [_, ..] -> Error(BoundExceeded)
  }
}

fn check_text(text: String) -> Result(Int, Error) {
  let bytes = string.byte_size(text)
  use Nil <- result.try(case bytes <= 8192 {
    True -> Ok(Nil)
    False -> Error(BoundExceeded)
  })

  // Inspect contents only after the constant-time byte bound admits the string.
  case string.contains(text, "\u{0000}") {
    True -> Error(InvalidData)
    False -> Ok(bytes)
  }
}

fn add_text(text: String, bytes: Int) -> Result(Int, Error) {
  use size <- result.try(check_text(text))
  case bytes + size <= 262_144 {
    True -> Ok(bytes + size)
    False -> Error(BoundExceeded)
  }
}

fn check_texts(texts: List(String), bytes: Int) -> Result(Int, Error) {
  list.try_fold(texts, bytes, fn(bytes, text) { add_text(text, bytes) })
}

fn check_path(path: String, bytes: Int) -> Result(Int, Error) {
  use bytes <- result.try(add_text(path, bytes))
  case path {
    "/" -> Ok(bytes)
    "/" <> rest -> {
      case
        list.any(string.split(rest, "/"), fn(component) {
          component == "" || component == "." || component == ".."
        })
      {
        True -> Error(InvalidData)
        False -> Ok(bytes)
      }
    }
    _ -> Error(InvalidData)
  }
}

fn check_paths(paths: List(String), bytes: Int) -> Result(Int, Error) {
  list.try_fold(paths, bytes, fn(bytes, path) { check_path(path, bytes) })
}

fn check_environment(
  env: List(#(String, String)),
  names: List(String),
  bytes: Int,
) -> Result(Int, Error) {
  case env {
    [] -> Ok(bytes)
    [#(name, value), ..rest] -> {
      use bytes <- result.try(add_text(name, bytes))
      use bytes <- result.try(add_text(value, bytes))
      use Nil <- result.try(
        case
          name == "" || string.contains(name, "=") || list.contains(names, name)
        {
          True -> Error(InvalidData)
          False -> Ok(Nil)
        },
      )
      check_environment(rest, [name, ..names], bytes)
    }
  }
}

fn check_mappings(
  mappings: List(RegionMapping),
  seen: List(RegionMapping),
  bytes: Int,
) -> Result(Int, Error) {
  case mappings {
    [] -> Ok(bytes)
    [mapping, ..rest] -> {
      use bytes <- result.try(check_path(mapping.root, bytes))
      use Nil <- result.try(case list.contains(seen, mapping) {
        True -> Error(InvalidData)
        False -> Ok(Nil)
      })
      check_mappings(rest, [mapping, ..seen], bytes)
    }
  }
}

fn check_policy_texts(
  requirements: policy.SandboxPolicy,
  bytes: Int,
) -> Result(Int, Error) {
  use bytes <- result.try(check_paths(requirements.writable_roots, bytes))
  use bytes <- result.try(check_paths(requirements.readable_roots, bytes))
  use bytes <- result.try(check_paths(requirements.protected, bytes))
  use bytes <- result.try(check_texts(requirements.env_allow, bytes))
  use bytes <- result.try(
    list.try_fold(requirements.mounts, bytes, fn(bytes, mount) {
      check_path(mount.path, bytes)
    }),
  )

  use bytes <- result.try(case requirements.scratch {
    policy.ScratchTmpfs -> Ok(bytes)
    policy.ScratchPath(path) -> check_path(path, bytes)
  })
  case requirements.network {
    policy.NetworkOff | policy.NetworkFull -> Ok(bytes)
    policy.NetworkProxy(allow, proxy) -> {
      use bytes <- result.try(check_texts(allow, bytes))
      add_text(proxy, bytes)
    }
  }
}

// This tree is built only from already bounded native lists and strings. Exact
// wire costs, including map keys and container headers, are checked before the
// encoder can allocate its byte tree. Its schema's deepest node is at depth 5.
fn check_value(
  value: mp.MsgPackValue,
  budget: Budget,
) -> Result(Budget, Error) {
  use budget <- result.try(charge(budget, 0, 1))
  case value {
    mp.StringValue(text) -> {
      let size = string.byte_size(text)
      let header = case size {
        _ if size < 32 -> 1
        _ if size < 256 -> 2
        _ -> 3
      }
      charge(budget, size + header, 0)
    }
    mp.IntValue(_) | mp.BoolValue(_) -> {
      use encoded <- result.try(
        mp.encode(value) |> result.replace_error(InvalidEncoding),
      )
      charge(budget, bit_array.byte_size(encoded), 0)
    }
    mp.ArrayValue(items) -> {
      use budget <- result.try(charge(
        budget,
        container_header(list.length(items)),
        0,
      ))
      list.try_fold(items, budget, fn(budget, item) {
        check_value(item, budget)
      })
    }
    mp.MapValue(entries) -> {
      use budget <- result.try(charge(
        budget,
        container_header(list.length(entries)),
        0,
      ))
      list.try_fold(entries, budget, fn(budget, entry) {
        use budget <- result.try(check_value(entry.0, budget))
        check_value(entry.1, budget)
      })
    }
    mp.NilValue | mp.FloatValue(_) | mp.BinaryValue(_) -> Error(InvalidEncoding)
  }
}

fn container_header(count: Int) -> Int {
  case count < 16 {
    True -> 1
    False -> 3
  }
}

fn charge(budget: Budget, bytes: Int, nodes: Int) -> Result(Budget, Error) {
  case budget.bytes + bytes <= 262_144 && budget.nodes + nodes <= 2048 {
    True -> Ok(Budget(budget.bytes + bytes, budget.nodes + nodes))
    False -> Error(BoundExceeded)
  }
}
