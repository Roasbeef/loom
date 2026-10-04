//// Reads another process's ownership label, the way the inspector does.
////
//// The label is `proc_lib:set_label({pickglass_owner, 1, Path, Role})`
//// (`protocol-change/065`). A test that starts a labelled service asks for
//// the label of the service's pid, which is the same `process_info(Pid,
//// label)` an attached inspector issues.

import gleam/erlang/process.{type Pid}
import gleam/option.{type Option}

/// The `#(path, role)` the process carries, or `None` if it has no label
/// of the frozen shape.
///
/// ## Examples
///
/// ```gleam
/// // owner_probe.label_of(service.pid)
/// // -> Some(#([#("session", "01a1...")], "async_runs"))
/// ```
@external(erlang, "client_test_ffi", "owner_label_of")
pub fn label_of(pid: Pid) -> Option(#(List(#(String, String)), String))
