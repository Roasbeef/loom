//// Closed broker errors within workspace completion evidence.
////
//// Each exact array retains the original error fields and discriminant.
//// Diagnostics remain bounded data; no runtime terms gain a wire encoding.

import broker/broker
import core/msgpack
import gleam/result
import tools/workspace_codec/clearance_errors
import tools/workspace_codec/execution_errors

/// Converts the closed broker.Refusal shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn refusal_value(value: broker.Refusal) -> msgpack.MsgPackValue {
  case value {
    broker.PolicyRefused(denial) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        clearance_errors.denial_value(denial),
      ])
    broker.InvalidPolicy(error) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        clearance_errors.policy_error_value(error),
      ])
    broker.BudgetRefused(refusal) ->
      msgpack.ArrayValue([
        msgpack.IntValue(2),
        clearance_errors.budget_error_value(refusal),
      ])
    broker.MintRefused(error) ->
      msgpack.ArrayValue([
        msgpack.IntValue(3),
        clearance_errors.mint_error_value(error),
      ])
    broker.NoHelper(error) ->
      msgpack.ArrayValue([
        msgpack.IntValue(4),
        execution_errors.checkout_error_value(error),
      ])
    broker.OperationAborted -> msgpack.ArrayValue([msgpack.IntValue(5)])
    broker.BrokerUnavailable -> msgpack.ArrayValue([msgpack.IntValue(6)])
  }
}

/// Converts the closed broker.Refusal shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_refusal(
  value: msgpack.MsgPackValue,
) -> Result(broker.Refusal, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), denial]) -> {
      use denial <- result.try(clearance_errors.parse_denial(denial))
      Ok(broker.PolicyRefused(denial))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), error]) -> {
      use error <- result.try(clearance_errors.parse_policy_error(error))
      Ok(broker.InvalidPolicy(error))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), refusal]) -> {
      use refusal <- result.try(clearance_errors.parse_budget_error(refusal))
      Ok(broker.BudgetRefused(refusal))
    }
    msgpack.ArrayValue([msgpack.IntValue(3), error]) -> {
      use error <- result.try(clearance_errors.parse_mint_error(error))
      Ok(broker.MintRefused(error))
    }
    msgpack.ArrayValue([msgpack.IntValue(4), error]) -> {
      use error <- result.try(execution_errors.parse_checkout_error(error))
      Ok(broker.NoHelper(error))
    }
    msgpack.ArrayValue([msgpack.IntValue(5)]) -> {
      Ok(broker.OperationAborted)
    }
    msgpack.ArrayValue([msgpack.IntValue(6)]) -> {
      Ok(broker.BrokerUnavailable)
    }
    _ -> Error(Nil)
  }
}
