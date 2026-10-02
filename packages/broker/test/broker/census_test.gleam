import broker/census.{Census}
import broker/framing
import broker/policy

pub fn local_reads_the_versions_it_does_not_own_test() {
  let here = census.local(["landlock", "seccomp"])
  assert here.service == census.service_version
  assert here.exec_proto == framing.exec_protocol_version
  assert here.policy_v == policy.version
  assert here.features == ["landlock", "seccomp"]
}

pub fn identical_censuses_do_not_skew_test() {
  let here = census.local([])
  assert census.skew(here, here) == Ok(Nil)
}

pub fn features_are_reported_not_refused_test() {
  let ours = census.local(["landlock"])
  let theirs = Census(..ours, features: [])
  assert census.skew(ours, theirs) == Ok(Nil)
  assert census.skew(theirs, ours) == Ok(Nil)
}

pub fn each_version_names_its_own_skew_test() {
  let ours = census.local([])
  assert census.skew(ours, Census(..ours, service: 7))
    == Error([census.ServiceSkew(ours: ours.service, theirs: 7)])
  assert census.skew(ours, Census(..ours, exec_proto: 7))
    == Error([census.ExecProtoSkew(ours: ours.exec_proto, theirs: 7)])
  assert census.skew(ours, Census(..ours, policy_v: 7))
    == Error([census.PolicySkew(ours: ours.policy_v, theirs: 7)])
}

pub fn every_mismatch_is_reported_in_field_order_test() {
  let ours = census.local([])
  let theirs = Census(service: 0, exec_proto: 0, policy_v: 0, features: [])
  assert census.skew(ours, theirs)
    == Error([
      census.ServiceSkew(ours: ours.service, theirs: 0),
      census.ExecProtoSkew(ours: ours.exec_proto, theirs: 0),
      census.PolicySkew(ours: ours.policy_v, theirs: 0),
    ])
}
