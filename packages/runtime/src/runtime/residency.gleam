//// How long a session's actors stay awake with nothing to do.
////
//// A resident session is mostly parked. Between two turns most of its
//// assembly has nothing to do, and each of those actors is holding a heap
//// sized by the last turn's work rather than by what it still needs: a
//// young generation that has not been swept, an old generation promoted
//// through it, and heap fragments waiting to be merged. Over six local
//// sessions that came to 28.7% of what an idle assembly held.
////
//// `weft/actor.hibernate_after` returns the part of it belonging to actors
//// whose *mailboxes* also fall quiet, which is a smaller set than the actors
//// with no work — measured at 3 to 5% of the same total.
//// `erlang:hibernate/3` sweeps and then shrinks the heap block to the live
//// data, rather than sizing a fresh one from a growth policy the way a
//// forced collection does, so what it gives back it gives back completely.
////
//// This module exists so that the interval is one value with one argument
//// behind it rather than a number repeated at eleven call sites.
//// `docs/design-notes/daemon-memory.md` has the measurement and the list of
//// which actors take it and which cannot.
////
//// One entry on that list is worth naming here, because it is the reason
//// this module recovers less than its argument suggests. A strand runtime
//// holds the largest `Effects` heap in an assembly and does no work between
//// turns, so it is the target worth having. It still cannot take the
//// interval: its `PollTick` arm re-arms the checkpoint poll every
//// `poll_interval_ms` — 200 ms in `api.default_options` — whether or not
//// there is work, so the mailbox is never quiet even when the strand is.
//// Reaching it means arming that poll conditionally, which changes the drive
//// loop's liveness argument rather than this constant.

/// The quiet interval after which a session assembly's actor hibernates.
///
/// Thirty seconds, and the bound is argued from both sides.
///
/// It has to be long enough that an active turn never hibernates between its
/// own steps. Within a turn the strand messages its assembly continuously,
/// in fractions of a second, so the only gaps that approach this are a slow
/// provider request or a long jailed tool run — and an actor that is genuinely
/// idle for half a minute in the middle of one *should* hibernate, because it
/// will pay a single wake against a request already measured in tens of
/// seconds. What must not happen is a threshold short enough to hibernate
/// between two steps of ordinary work, where the wake would be paid on every
/// step and recover nothing.
///
/// It has to be short enough that a session a human has stopped talking to
/// compacts promptly rather than holding a turn's working heap until the next
/// prompt, which may be hours away. Half a minute reaches that inside the
/// minute an operator would call parked.
///
/// A site with a stated reason to differ may differ. None does today.
pub const hibernate_after_ms = 30_000
