//// Boundary tests for generated MCP codecs: a typed projection must either
//// satisfy the schema shape or retain a precise failure and original result.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/mcp as mcp_internal
import cap/internal/mcp_codec as codec
import cap/mcp
import cap/report
import core/msgpack
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string

fn optional_cursor() -> codec.Decoder(Option(Option(String))) {
  codec.object(["cursor"], codec.RejectAdditional, {
    use cursor <- codec.optional_field("cursor", codec.nullable(codec.string()))
    codec.success(cursor)
  })
}

pub fn optional_nullable_retains_three_distinct_states_test() {
  assert codec.decode(report.object([]), optional_cursor()) == Ok(None)
  assert codec.decode(
      report.object([#("cursor", report.null())]),
      optional_cursor(),
    )
    == Ok(Some(None))
  assert codec.decode(
      report.object([#("cursor", report.string("next"))]),
      optional_cursor(),
    )
    == Ok(Some(Some("next")))
}

pub fn optional_present_invalid_value_is_not_absence_test() {
  assert codec.decode(
      report.object([#("cursor", report.int(3))]),
      optional_cursor(),
    )
    == Error(mcp.DecodeError(["cursor"], "expected a string"))
}

pub fn optional_non_nullable_rejects_null_test() {
  let decoder = {
    use cursor <- codec.optional_field("cursor", codec.string())
    codec.success(cursor)
  }
  assert codec.decode(report.object([#("cursor", report.null())]), decoder)
    == Error(mcp.DecodeError(["cursor"], "expected a string"))
}

pub fn optional_and_nullable_encoders_retain_absence_null_and_false_test() {
  let encode = fn(value) { codec.nullable_value(value, report.bool) }
  assert codec.optional("flag", None, encode) == []
  assert codec.optional("flag", Some(None), encode)
    == [#("flag", report.null())]
  assert codec.optional("flag", Some(Some(False)), encode)
    == [#("flag", report.bool(False))]
}

pub fn json_number_accepts_both_numeric_representations_test() {
  assert codec.decode(report.int(7), codec.number()) == Ok(7.0)
  assert codec.decode(report.float(7.5), codec.number()) == Ok(7.5)
  assert report.as_float(report.int(7)) == Error(Nil)
  assert codec.decode(report.string("7"), codec.number())
    == Error(mcp.DecodeError([], "expected a number"))
}

pub fn integer_accepts_integral_floats_without_rounding_test() {
  assert codec.decode(report.float(7.0), codec.int()) == Ok(7)
  assert codec.decode(report.float(7.1), codec.int())
    == Error(mcp.DecodeError([], "expected an integer"))
  assert codec.decode(report.bool(True), codec.int())
    == Error(mcp.DecodeError([], "expected an integer"))
  assert report.as_int(report.float(7.0)) == Error(Nil)
}

pub fn literal_compares_numbers_without_losing_integer_precision_test() {
  assert codec.decode(report.float(1.0), codec.literal(report.int(1), "one"))
    == Ok("one")
  assert codec.decode(
      report.int(9_007_199_254_740_993),
      codec.literal(report.float(9_007_199_254_740_992.0), "rounded"),
    )
    == Error(mcp.DecodeError([], "expected the declared literal"))
}

pub fn empty_record_and_optional_fields_still_require_object_test() {
  let empty = codec.object([], codec.AllowAdditional, codec.success(Nil))
  assert codec.decode(report.null(), empty)
    == Error(mcp.DecodeError([], "expected an object"))
  assert codec.decode(report.list([]), optional_cursor())
    == Error(mcp.DecodeError([], "expected an object"))
}

pub fn additional_properties_policy_is_enforced_test() {
  let value = report.object([#("unexpected.key", report.int(1))])
  assert codec.decode(value, optional_cursor())
    == Error(mcp.DecodeError(["unexpected.key"], "unexpected property"))
  assert codec.decode(
      value,
      codec.object([], codec.AllowAdditional, codec.success(Nil)),
    )
    == Ok(Nil)
}

fn results_decoder() -> codec.Decoder(List(String)) {
  let item =
    codec.object(["id"], codec.RejectAdditional, {
      use id <- codec.field("id", codec.string())
      codec.success(id)
    })
  codec.object(["results"], codec.RejectAdditional, {
    use results <- codec.field("results", codec.list(item))
    codec.success(results)
  })
}

pub fn nested_error_path_includes_list_index_and_missing_field_test() {
  let value = report.object([#("results", report.list([report.object([])]))])
  assert codec.decode(value, results_decoder())
    == Error(mcp.DecodeError(["results", "0", "id"], "missing required field"))
}

pub fn nested_error_path_reports_actual_bad_index_test() {
  let good = report.object([#("id", report.string("a"))])
  let bad = report.object([#("id", report.bool(False))])
  let value = report.object([#("results", report.list([good, bad]))])
  assert codec.decode(value, results_decoder())
    == Error(mcp.DecodeError(["results", "1", "id"], "expected a string"))
}

pub fn field_chain_continues_on_parent_without_inheriting_sibling_path_test() {
  let decoder = {
    use first <- codec.field("first", codec.string())
    use second <- codec.field("second", codec.int())
    codec.success(#(first, second))
  }
  assert codec.decode(report.object([#("first", report.string("ok"))]), decoder)
    == Error(mcp.DecodeError(["second"], "missing required field"))
}

pub fn one_of_requires_exactly_one_match_test() {
  let decoder =
    codec.one_of([
      codec.literal(report.string("a"), 1),
      codec.literal(report.string("b"), 2),
    ])
  assert codec.decode(report.string("b"), decoder) == Ok(2)
  assert codec.decode(report.string("c"), decoder)
    == Error(mcp.DecodeError([], "expected the declared literal"))
  let ambiguous = codec.one_of([codec.int(), codec.success(2)])
  assert codec.decode(report.int(1), ambiguous)
    == Error(mcp.DecodeError([], "multiple oneOf branches matched"))
}

pub fn boolean_mapping_and_raw_union_branches_are_disjoint_test() {
  let decoder =
    codec.one_of([
      codec.map(codec.string(), report.string),
      codec.raw_object(),
      codec.raw_array(),
      codec.map(codec.null(), fn(_) { report.null() }),
    ])
  assert codec.decode(report.object([]), decoder) == Ok(report.object([]))
  assert codec.decode(report.null(), decoder) == Ok(report.null())
  assert codec.decode(report.list([]), decoder) == Ok(report.list([]))
  assert codec.decode(
      report.bool(True),
      codec.map(codec.boolean(), fn(value) {
        case value {
          True -> "enabled"
          False -> "disabled"
        }
      }),
    )
    == Ok("enabled")
}

pub fn dictionary_decodes_values_and_retains_dynamic_key_paths_test() {
  let decoder = codec.dictionary(codec.number())
  assert codec.decode(report.object([#("choice", report.int(1))]), decoder)
    == Ok([#("choice", 1.0)])
  assert codec.decode(report.object([#("a.b[0]", report.null())]), decoder)
    == Error(mcp.DecodeError(["a.b[0]"], "expected a number"))
}

pub fn dictionary_rejects_duplicate_and_non_string_keys_test() {
  let duplicate = report.object([#("a", report.int(1)), #("a", report.int(2))])
  assert codec.decode(duplicate, codec.dictionary(codec.int()))
    == Error(mcp.DecodeError(["a"], "duplicate property"))
  assert codec.decode(
      msgpack.MapValue([#(report.int(1), report.int(2))]),
      codec.raw_object(),
    )
    == Error(mcp.DecodeError([], "expected a string"))
}

fn install_result(structured: Option(report.Value)) -> Nil {
  let fields = [
    #(
      "content",
      report.list([
        report.object([
          #("type", report.string("text")),
          #("text", report.string("keep this explanation")),
        ]),
        report.object([#("type", report.string("image"))]),
      ]),
    ),
    #("is_error", report.bool(False)),
  ]
  let fields = case structured {
    None -> fields
    Some(value) -> [#("structured", value), ..fields]
  }
  dispatch.install(channel.Channel(fn(_, _, _) { Ok(report.object(fields)) }))
}

pub fn typed_invoke_retains_original_result_on_schema_mismatch_test() {
  let value = report.object([#("results", report.list([report.object([])]))])
  install_result(Some(value))
  assert mcp_internal.invoke_typed(
      "fixture",
      "lookup",
      report.object([]),
      results_decoder(),
    )
    == Error(mcp.ResultSchemaMismatch(
      mcp.DecodeError(["results", "0", "id"], "missing required field"),
      mcp.ToolResult(
        [mcp.Text("keep this explanation"), mcp.Other("image")],
        Some(value),
      ),
    ))
}

pub fn typed_invoke_requires_structured_content_even_for_nullable_schema_test() {
  install_result(None)
  assert mcp_internal.invoke_typed(
      "fixture",
      "lookup",
      report.object([]),
      codec.nullable(codec.string()),
    )
    == Error(mcp.ResultSchemaMismatch(
      mcp.DecodeError([], "missing structured content"),
      mcp.ToolResult(
        [mcp.Text("keep this explanation"), mcp.Other("image")],
        None,
      ),
    ))
}

pub fn typed_invoke_returns_generated_projection_test() {
  let value =
    report.object([
      #(
        "results",
        report.list([
          report.object([#("id", report.string("found"))]),
        ]),
      ),
    ])
  install_result(Some(value))
  assert mcp_internal.invoke_typed(
      "fixture",
      "lookup",
      report.object([]),
      results_decoder(),
    )
    == Ok(["found"])
}

pub fn typed_invoke_preserves_broker_failures_test() {
  dispatch.install(
    channel.Channel(fn(_, _, _) {
      Error(channel.Denied("mcp_timeout", "deadline"))
    }),
  )
  assert mcp_internal.invoke_typed(
      "fixture",
      "lookup",
      report.object([]),
      codec.int(),
    )
    == Error(mcp.McpDenied("mcp_timeout", "deadline"))
}

pub fn number_decoder_is_total_for_hand_built_oversized_integer_test() {
  let assert Ok(huge) = int.parse("1" <> string.repeat("0", 400))
    as "Decimal integer is valid."
  assert codec.decode(report.int(huge), codec.number())
    == Error(mcp.DecodeError([], "number exceeds Float range"))
}

pub fn typed_invoke_preserves_present_structured_null_test() {
  install_result(Some(report.null()))
  assert mcp_internal.invoke_typed(
      "fixture",
      "lookup",
      report.object([]),
      codec.nullable(codec.string()),
    )
    == Ok(None)
}
