//// A return request persists until the asynchronous live patch arrives.
//// Gap alone cannot hide the control while the server still shows history.

import web_client/follow_rule

pub fn an_explicit_return_waits_for_the_live_endpoint_test() {
  assert follow_rule.returning(follow_rule.Historical) == follow_rule.Returning
  assert follow_rule.returning(follow_rule.Returning) == follow_rule.Returning
  assert follow_rule.returning(follow_rule.Live) == follow_rule.Live
}
