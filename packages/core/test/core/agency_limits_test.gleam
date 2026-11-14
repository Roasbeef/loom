import core/agency_limits.{BoundedDepth, UnlimitedDepth}
import core/json
import gleam/option.{None, Some}

pub fn agency_limits_roundtrip_test() {
  let limits =
    agency_limits.AgencyLimits(
      fan_out: Some(100),
      session_strands: Some(256),
      depth_cap: Some(BoundedDepth(3)),
    )
  let encoded = agency_limits.encode_json(limits)
  assert agency_limits.decode_json(encoded) == Ok(limits)

  let unlimited =
    agency_limits.AgencyLimits(
      fan_out: None,
      session_strands: None,
      depth_cap: Some(UnlimitedDepth),
    )
  assert agency_limits.decode_json(agency_limits.encode_json(unlimited))
    == Ok(unlimited)
}

pub fn agency_limits_validation_test() {
  assert agency_limits.decode_json(json.Object([]))
    == Ok(agency_limits.defaults())
  assert agency_limits.validate(agency_limits.AgencyLimits(
      fan_out: Some(100),
      session_strands: Some(50),
      depth_cap: None,
    ))
    == Error("agency.fan_out cannot exceed agency.session_strands")
  assert agency_limits.parse_depth_cap("") == Ok(None)
  assert agency_limits.parse_depth_cap("unlimited") == Ok(Some(UnlimitedDepth))
  assert agency_limits.parse_depth_cap("4") == Ok(Some(BoundedDepth(4)))
}
