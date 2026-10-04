//// What version of the executor service this is, as one comparable value.
////
//// An executor that runs on another machine will be started, upgraded and
//// restarted independently of the harness that uses it, so the two ends
//// can disagree about vocabulary in ways neither build notices. This
//// module is the notice: a `Census` names the three numbers an executor's
//// meaning rests on, `skew` compares two of them, and a mismatch is a
//// reason to refuse before any execution is dispatched rather than an
//// anonymous decoder error on some later frame.
////
//// It is pure on purpose. Reading a version constant is not an effect, and
//// keeping the comparison free of processes lets a future transport call
//// it from either side of a connection, and lets tests enumerate it.
//// How a census travels is not decided here: this package defines no wire
//// and no trust, only what is compared.
////
//// ## Versions refuse, features report
////
//// `service`, `exec_proto` and `policy_v` are versions of vocabularies
//// that both ends must read identically, so a difference in any of them is
//// `Skew`. `features` is different in kind. It is the hello a helper
//// announced, the list of enforcement layers its kernel could build, and
//// it varies by host (a runner without a cgroup base lacks one layer)
//// without making the vocabulary any less shared. The broker already
//// weighs features against each request's demand at dispatch time, so
//// refusing a whole executor for lacking one would duplicate that check
//// at the wrong granularity. Features are capability, reported for the
//// caller to read, never refused here.

import broker/framing
import broker/policy
import gleam/list

/// The executor service's own interface version: the meaning of the
/// `Dispatcher` contract in `broker/dispatch` and of the service behind
/// it. Bumped when that contract changes meaning, for example when the
/// order in which `deliver` and `settle` are called changes, or a
/// `StartRefusal` is given a new reading. It does not move for a change
/// inside the service that no caller can observe, and it is independent
/// of `exec_proto`, which versions the helper's wire, and of `policy_v`,
/// which versions the policy encoding.
pub const service_version = 1

/// One executor's versions and capability.
pub type Census {
  Census(
    /// The executor service's interface version, `service_version`.
    service: Int,
    /// The exec channel's body vocabulary the service speaks to its
    /// helpers, `framing.exec_protocol_version`.
    exec_proto: Int,
    /// The policy encoding the service sends with each execution,
    /// `policy.version`.
    policy_v: Int,
    /// The enforcement layers a live helper announced in its hello, or
    /// empty when no helper could be asked. Capability, not skew.
    features: List(String),
  )
}

/// A single mismatched field, with both sides' values. One variant per
/// version field; `features` has none because it is never refused.
pub type Skew {
  /// The executors' service interface versions differ.
  ServiceSkew(ours: Int, theirs: Int)

  /// The executors' exec-channel vocabularies differ.
  ExecProtoSkew(ours: Int, theirs: Int)

  /// The executors' policy encodings differ.
  PolicySkew(ours: Int, theirs: Int)
}

/// This build's census, carrying the features the caller observed.
///
/// ## Examples
///
/// ```gleam
/// let here = census.local(["landlock"])
/// assert here.service == census.service_version
/// assert here.features == ["landlock"]
/// ```
///
pub fn local(features: List(String)) -> Census {
  Census(
    service: service_version,
    exec_proto: framing.exec_protocol_version,
    policy_v: policy.version,
    features:,
  )
}

/// Compares two censuses and names every version on which they disagree,
/// in the order `service`, `exec_proto`, `policy_v`. `Ok` means the two
/// speak one vocabulary; features are not compared (see the module doc).
///
/// ## Examples
///
/// ```gleam
/// let ours = census.local([])
/// assert census.skew(ours, census.Census(..ours, features: ["x"])) == Ok(Nil)
/// assert census.skew(ours, census.Census(..ours, policy_v: 9))
///   == Error([census.PolicySkew(ours: ours.policy_v, theirs: 9)])
/// ```
///
pub fn skew(ours: Census, theirs: Census) -> Result(Nil, List(Skew)) {
  let found = [
    differing(ours.service, theirs.service, ServiceSkew),
    differing(ours.exec_proto, theirs.exec_proto, ExecProtoSkew),
    differing(ours.policy_v, theirs.policy_v, PolicySkew),
  ]
  case found {
    [[], [], []] -> Ok(Nil)
    _ -> Error(list.flatten(found))
  }
}

// One field's contribution: nothing when the sides agree, a single skew
// when they differ. A list so the three can be concatenated in order.
fn differing(ours: Int, theirs: Int, make: fn(Int, Int) -> Skew) -> List(Skew) {
  case ours == theirs {
    True -> []
    False -> [make(ours, theirs)]
  }
}
