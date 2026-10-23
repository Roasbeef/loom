//// Capture ceilings leave the jail's own restrict-and-exec stage room to start.

import client/evolution/candidate

/// The jail's pids cap counts threads, and the helper's Go stage runs inside
/// it before `tar` starts. At 8 the stage exhausted the cap about one run in
/// ten on Linux (measured 31 of 300 in a cgroup v2 container), and 16 or more
/// never did. The floor below is that measurement with headroom, so a later
/// tightening of the capture limits fails here and not in a hosted CI shard.
///
/// ## Examples
///
/// `capture_limits().pids` is at least 32.
pub fn capture_pids_cap_leaves_the_helper_stage_room_to_start_test() {
  assert candidate.capture_limits().pids >= 32
}
