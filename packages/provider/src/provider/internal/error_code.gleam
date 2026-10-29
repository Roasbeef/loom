//// Recognized permanent provider codes own policy before diagnostic heuristics.
//// Adapters and retry classification share this vocabulary so adding context
//// cannot turn an identified denial into a transient failure.

import gleam/list

const permanent_codes = [
  "authentication_error", "invalid_api_key", "unauthorized", "permission_error",
  "permission_denied", "invalid_request_error", "invalid_request",
  "invalid_prompt", "model_not_found", "insufficient_quota",
  "credit_balance_exhausted", "organization_spend_limit_exceeded",
  "project_spend_limit_exceeded", "organization_usage_limit_exceeded",
  "usage_not_included", "usage_limit_reached", "flex_unavailable",
  "cyber_policy", "bio_policy", "misalignment_policy_violation",
  "context_length_exceeded",
]

/// Identified request, access, quota and context failures cannot be repaired by
/// replaying the same request. This fixed vocabulary contains no remote prose.
///
/// ## Examples
///
/// ```gleam
/// assert error_code.is_permanent("permission_denied")
/// assert !error_code.is_permanent("server_error")
/// ```
pub fn is_permanent(code: String) -> Bool {
  list.contains(permanent_codes, code)
}
