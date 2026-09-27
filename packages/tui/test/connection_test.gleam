//// The session socket's wake pacing is the frame pacing.
////
//// `tui/connection` cannot import `tui/pacing`, which sits above it in the
//// import graph, so the interval its sockets pace their wakes to is spelled
//// again there. Waking the loop more often than it may paint would only run
//// ticks whose frame is deferred, and less often would hold a frame back
//// from a paint it was allowed, so the two values must not drift apart.

import tui/connection
import tui/pacing

pub fn wakes_are_paced_at_the_frame_interval_test() {
  assert connection.wake_interval_ms == pacing.frame_interval_ms
}
