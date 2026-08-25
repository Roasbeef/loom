//// Operating-system externals for the exec pool.
////
//// FFI confinement (spec §0.2): every `@external` the pool needs lives
//// under `broker/internal`, backed by `broker_ffi.erl`. This one exists
//// so `broker/exec` can answer "does `loom-exec` have a jail here?"
//// without the caller having to know how the BEAM spells an OS name.

/// The running system's OS name, as `os:type/0`'s second element:
/// `"linux"`, `"darwin"`, `"nt"`. Not normalized — deciding what a name
/// means for the jail is `broker/exec`'s job.
///
/// Uses `os:type/0`; the BEAM offers no pure alternative, and the answer
/// is fixed for the life of the node.
@external(erlang, "broker_ffi", "os_name")
pub fn os_name() -> String
