//// Worktree observation ceilings leave the jail's own restrict-and-exec stage
//// room to start.

import client/worktree_diff

/// The jail's pids cap counts threads, and the helper's Go stage runs inside
/// it before the observed command starts. At 8 that stage exhausted the cap
/// about one run in ten on Linux, and 16 left little margin. The floor below
/// keeps headroom, so a later tightening of the observation limits fails here
/// and not in a hosted CI shard.
///
/// ## Examples
///
/// `observation_limits(..).pids` is at least 32.
pub fn observation_pids_cap_leaves_the_helper_stage_room_to_start_test() {
  assert worktree_diff.observation_limits(wall_s: 5, output_bytes: 1024).pids
    >= 32
}
