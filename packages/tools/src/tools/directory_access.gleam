//// Explicit directory access shared by native tools and jailed invocations.
////
//// This value records explicit additions to a session's readable and writable
//// roots. Native reads are judged against the base policy's `readable_roots`
//// widened by these additions (`widen`); native writes against the workspace
//// plus `writable`.
//// Session additions and call-bound approvals use the same representation,
//// but their owners retain their distinct lifetimes.

import broker/policy
import gleam/list

/// Additional canonical roots, separate from the jail's system read paths.
pub type Access {
  Access(
    /// Roots readable by this invocation.
    readable: List(String),
    /// Roots writable by this invocation, which are also readable.
    writable: List(String),
  )
}

/// No additions.
///
/// ## Examples
///
/// ```gleam
/// assert directory_access.none() == directory_access.Access([], [])
/// ```
pub fn none() -> Access {
  Access([], [])
}

/// Adds only filesystem grants consumed for the current invocation.
///
/// ## Examples
///
/// ```gleam
/// assert directory_access.approved(directory_access.none(), []).readable == []
/// ```
pub fn approved(access: Access, grants: List(policy.Grant)) -> Access {
  list.fold(grants, access, fn(access, grant) {
    case grant {
      policy.GrantReadableRoot(path) ->
        Access(..access, readable: list.unique([path, ..access.readable]))
      policy.GrantWritableRoot(path) ->
        Access(
          readable: list.unique([path, ..access.readable]),
          writable: list.unique([path, ..access.writable]),
        )
      policy.GrantNetwork(_)
      | policy.GrantEnv(_)
      | policy.GrantLimit(..)
      | policy.GrantScratch(_) -> access
    }
  })
}

/// Widens the jail's base with explicit session additions.
///
/// ## Examples
///
/// ```gleam
/// let base = policy.workspace_default("/work")
/// assert directory_access.widen(base, directory_access.none()) == base
/// ```
pub fn widen(
  base: policy.SandboxPolicy,
  access: Access,
) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..base,
    readable_roots: list.unique(
      list.flatten([
        base.readable_roots,
        access.readable,
        access.writable,
      ]),
    ),
    writable_roots: list.unique(list.append(
      base.writable_roots,
      access.writable,
    )),
  )
}
