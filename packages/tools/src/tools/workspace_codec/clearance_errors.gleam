//// Closed clearance errors within workspace completion evidence.
////
//// Each exact array retains the original error fields and discriminant.
//// Diagnostics remain bounded data; no runtime terms gain a wire encoding.

import broker/budget
import broker/escalation
import broker/policy
import broker/token
import core/msgpack
import gleam/result
import tools/workspace_codec/value as v

/// Converts the closed policy.LimitField shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn limit_value(value: policy.LimitField) -> msgpack.MsgPackValue {
  case value {
    policy.CpuSeconds -> msgpack.ArrayValue([msgpack.IntValue(0)])
    policy.WallSeconds -> msgpack.ArrayValue([msgpack.IntValue(1)])
    policy.MemBytes -> msgpack.ArrayValue([msgpack.IntValue(2)])
    policy.Pids -> msgpack.ArrayValue([msgpack.IntValue(3)])
    policy.FsizeBytes -> msgpack.ArrayValue([msgpack.IntValue(4)])
    policy.OutputBytes -> msgpack.ArrayValue([msgpack.IntValue(5)])
  }
}

/// Converts the closed policy.LimitField shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_limit(
  value: msgpack.MsgPackValue,
) -> Result(policy.LimitField, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(policy.CpuSeconds)
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(policy.WallSeconds)
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(policy.MemBytes)
    }
    msgpack.ArrayValue([msgpack.IntValue(3)]) -> {
      Ok(policy.Pids)
    }
    msgpack.ArrayValue([msgpack.IntValue(4)]) -> {
      Ok(policy.FsizeBytes)
    }
    msgpack.ArrayValue([msgpack.IntValue(5)]) -> {
      Ok(policy.OutputBytes)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed policy.NetworkPolicy shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn network_value(value: policy.NetworkPolicy) -> msgpack.MsgPackValue {
  case value {
    policy.NetworkOff -> msgpack.ArrayValue([msgpack.IntValue(0)])
    policy.NetworkProxy(allow, proxy) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        fn(xs) { v.array(xs, msgpack.StringValue) }(allow),
        msgpack.StringValue(proxy),
      ])
    policy.NetworkFull -> msgpack.ArrayValue([msgpack.IntValue(2)])
  }
}

/// Converts the closed policy.NetworkPolicy shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_network(
  value: msgpack.MsgPackValue,
) -> Result(policy.NetworkPolicy, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(policy.NetworkOff)
    }
    msgpack.ArrayValue([msgpack.IntValue(1), allow, proxy]) -> {
      use allow <- result.try(fn(x) { v.inventory(x, 8192, v.text) }(allow))
      use proxy <- result.try(v.text(proxy))
      Ok(policy.NetworkProxy(allow, proxy))
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(policy.NetworkFull)
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed policy.Scratch shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn scratch_value(value: policy.Scratch) -> msgpack.MsgPackValue {
  case value {
    policy.ScratchTmpfs -> msgpack.ArrayValue([msgpack.IntValue(0)])
    policy.ScratchPath(path) ->
      msgpack.ArrayValue([msgpack.IntValue(1), msgpack.StringValue(path)])
  }
}

/// Converts the closed policy.Scratch shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_scratch(
  value: msgpack.MsgPackValue,
) -> Result(policy.Scratch, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(policy.ScratchTmpfs)
    }
    msgpack.ArrayValue([msgpack.IntValue(1), path]) -> {
      use path <- result.try(v.text(path))
      Ok(policy.ScratchPath(path))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed policy.Grant shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn grant_value(value: policy.Grant) -> msgpack.MsgPackValue {
  case value {
    policy.GrantWritableRoot(path) ->
      msgpack.ArrayValue([msgpack.IntValue(0), msgpack.StringValue(path)])
    policy.GrantReadableRoot(path) ->
      msgpack.ArrayValue([msgpack.IntValue(1), msgpack.StringValue(path)])
    policy.GrantNetwork(network) ->
      msgpack.ArrayValue([msgpack.IntValue(2), network_value(network)])
    policy.GrantEnv(name) ->
      msgpack.ArrayValue([msgpack.IntValue(3), msgpack.StringValue(name)])
    policy.GrantLimit(field, value) ->
      msgpack.ArrayValue([
        msgpack.IntValue(4),
        limit_value(field),
        msgpack.IntValue(value),
      ])
    policy.GrantScratch(scratch) ->
      msgpack.ArrayValue([msgpack.IntValue(5), scratch_value(scratch)])
  }
}

/// Converts the closed policy.Grant shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_grant(value: msgpack.MsgPackValue) -> Result(policy.Grant, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), path]) -> {
      use path <- result.try(v.text(path))
      Ok(policy.GrantWritableRoot(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), path]) -> {
      use path <- result.try(v.text(path))
      Ok(policy.GrantReadableRoot(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), network]) -> {
      use network <- result.try(parse_network(network))
      Ok(policy.GrantNetwork(network))
    }
    msgpack.ArrayValue([msgpack.IntValue(3), name]) -> {
      use name <- result.try(v.text(name))
      Ok(policy.GrantEnv(name))
    }
    msgpack.ArrayValue([msgpack.IntValue(4), field, value]) -> {
      use field <- result.try(parse_limit(field))
      use value <- result.try(v.natural(value))
      Ok(policy.GrantLimit(field, value))
    }
    msgpack.ArrayValue([msgpack.IntValue(5), scratch]) -> {
      use scratch <- result.try(parse_scratch(scratch))
      Ok(policy.GrantScratch(scratch))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed policy.PolicyError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn policy_error_value(value: policy.PolicyError) -> msgpack.MsgPackValue {
  case value {
    policy.RelativePath(path) ->
      msgpack.ArrayValue([msgpack.IntValue(0), msgpack.StringValue(path)])
    policy.NegativeLimit(field, value) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        limit_value(field),
        msgpack.IntValue(value),
      ])
    policy.ScratchIsRoot -> msgpack.ArrayValue([msgpack.IntValue(2)])
    policy.MountOverlapsProtected(mount, protected) ->
      msgpack.ArrayValue([
        msgpack.IntValue(3),
        msgpack.StringValue(mount),
        msgpack.StringValue(protected),
      ])
    policy.DuplicateMount(path) ->
      msgpack.ArrayValue([msgpack.IntValue(4), msgpack.StringValue(path)])
    policy.MountPathTrailingSlash(path) ->
      msgpack.ArrayValue([msgpack.IntValue(5), msgpack.StringValue(path)])
    policy.MountPathParentSegment(path) ->
      msgpack.ArrayValue([msgpack.IntValue(6), msgpack.StringValue(path)])
    policy.MountShadowsWritableRoot(mount, writable_root) ->
      msgpack.ArrayValue([
        msgpack.IntValue(7),
        msgpack.StringValue(mount),
        msgpack.StringValue(writable_root),
      ])
  }
}

/// Converts the closed policy.PolicyError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_policy_error(
  value: msgpack.MsgPackValue,
) -> Result(policy.PolicyError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), path]) -> {
      use path <- result.try(v.text(path))
      Ok(policy.RelativePath(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), field, value]) -> {
      use field <- result.try(parse_limit(field))
      use value <- result.try(v.negative(value))
      Ok(policy.NegativeLimit(field, value))
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(policy.ScratchIsRoot)
    }
    msgpack.ArrayValue([msgpack.IntValue(3), mount, protected]) -> {
      use mount <- result.try(v.text(mount))
      use protected <- result.try(v.text(protected))
      Ok(policy.MountOverlapsProtected(mount, protected))
    }
    msgpack.ArrayValue([msgpack.IntValue(4), path]) -> {
      use path <- result.try(v.text(path))
      Ok(policy.DuplicateMount(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(5), path]) -> {
      use path <- result.try(v.text(path))
      Ok(policy.MountPathTrailingSlash(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(6), path]) -> {
      use path <- result.try(v.text(path))
      Ok(policy.MountPathParentSegment(path))
    }
    msgpack.ArrayValue([msgpack.IntValue(7), mount, writable_root]) -> {
      use mount <- result.try(v.text(mount))
      use writable_root <- result.try(v.text(writable_root))
      Ok(policy.MountShadowsWritableRoot(mount, writable_root))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed escalation.DenialSource shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn source_value(value: escalation.DenialSource) -> msgpack.MsgPackValue {
  case value {
    escalation.PolicyDenial -> msgpack.ArrayValue([msgpack.IntValue(0)])
    escalation.ExecutionDenial(enforcement) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        fn(xs) { v.array(xs, msgpack.StringValue) }(enforcement),
      ])
  }
}

/// Converts the closed escalation.DenialSource shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_source(
  value: msgpack.MsgPackValue,
) -> Result(escalation.DenialSource, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(escalation.PolicyDenial)
    }
    msgpack.ArrayValue([msgpack.IntValue(1), enforcement]) -> {
      use enforcement <- result.try(fn(x) { v.inventory(x, 8192, v.text) }(
        enforcement,
      ))
      Ok(escalation.ExecutionDenial(enforcement))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed escalation.Denial shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn denial_value(value: escalation.Denial) -> msgpack.MsgPackValue {
  case value {
    escalation.Denial(reason, source, wanted) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.StringValue(reason),
        source_value(source),
        fn(xs) { v.array(xs, grant_value) }(wanted),
      ])
  }
}

/// Converts the closed escalation.Denial shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_denial(
  value: msgpack.MsgPackValue,
) -> Result(escalation.Denial, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), reason, source, wanted]) -> {
      use reason <- result.try(v.diagnostic(reason))
      use source <- result.try(parse_source(source))
      use wanted <- result.try(fn(x) { v.inventory(x, 8192, parse_grant) }(
        wanted,
      ))
      Ok(escalation.Denial(reason, source, wanted))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed budget.Refusal shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn budget_error_value(value: budget.Refusal) -> msgpack.MsgPackValue {
  case value {
    budget.OutstandingCapReached(cap) ->
      msgpack.ArrayValue([msgpack.IntValue(0), msgpack.IntValue(cap)])
    budget.DeadlinePassed(deadline_ms) ->
      msgpack.ArrayValue([msgpack.IntValue(1), msgpack.IntValue(deadline_ms)])
  }
}

/// Converts the closed budget.Refusal shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_budget_error(
  value: msgpack.MsgPackValue,
) -> Result(budget.Refusal, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), cap]) -> {
      use cap <- result.try(v.natural(cap))
      Ok(budget.OutstandingCapReached(cap))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), deadline_ms]) -> {
      use deadline_ms <- result.try(v.integer(deadline_ms))
      Ok(budget.DeadlinePassed(deadline_ms))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed token.MintError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn mint_error_value(value: token.MintError) -> msgpack.MsgPackValue {
  case value {
    token.EntropyFailure(got_bytes) ->
      msgpack.ArrayValue([msgpack.IntValue(0), msgpack.IntValue(got_bytes)])
    token.DuplicateToken -> msgpack.ArrayValue([msgpack.IntValue(1)])
  }
}

/// Converts the closed token.MintError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_mint_error(
  value: msgpack.MsgPackValue,
) -> Result(token.MintError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), got_bytes]) -> {
      use got_bytes <- result.try(v.natural(got_bytes))
      Ok(token.EntropyFailure(got_bytes))
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(token.DuplicateToken)
    }
    _ -> Error(Nil)
  }
}
