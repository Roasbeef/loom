//// Pure workspace selection and relative-path vocabulary for protocol 067.
////
//// A selector names an administratively unique registration. A binding adds
//// its workspace and session authority epochs; a scope adds the durable
//// session. None of these values grants access or resolves a physical root.
//// The executor rechecks registration, symlinks and protected paths at use.
////
//// Remote paths use only forward slashes. No separator normalization occurs:
//// backslashes and colons are rejected, including Windows drives, UNC paths
//// and alternate streams. A lone '.' names the root; components '.' and '..'
//// are refused. Local directory selection keeps the existing host pathname
//// unchanged, and must not pass through this remote path grammar.
////
//// The executor already owns its remote identity types. `scope_from_fields`
//// validates their projected fields without importing that package or moving
//// its identities. `scope_fields` supplies the reverse adapter's input.

import core/ids
import gleam/list
import gleam/result
import gleam/string

/// The largest encoded remote pathname, measured in UTF-8 bytes.
pub const max_path_bytes = 4096

/// The largest externally supplied step, measured in UTF-8 bytes.
pub const max_step_bytes = 1024

/// A canonical relative pathname, with '.' representing the root explicitly.
pub opaque type RelativePath {
  /// Constructed only after byte and component validation.
  RelativePath(
    /// Exact supplied spelling, never normalized.
    value: String,
  )
}

/// A registration selected by two case-sensitive administrative labels.
pub opaque type Selector {
  /// Labels are 1..128 ASCII bytes; administration owns uniqueness.
  Selector(
    /// Executor label, never an endpoint or a hostname lookup.
    executor: String,
    /// Workspace label, never a host path.
    workspace: String,
  )
}

/// An exact registration with both positive signed-32-bit authority epochs.
pub opaque type RegisteredBinding {
  /// Constructing the value validates syntax, not current authority.
  RegisteredBinding(
    /// The registration selected by owner configuration.
    selector: Selector,
    /// Executor administration's workspace epoch.
    workspace_epoch: Int,
    /// The owner's session authority epoch.
    session_epoch: Int,
  )
}

/// The creation-time choice; remote selection cannot become a local fallback.
pub type Selection {
  /// An existing local API pathname, preserving its host semantics verbatim.
  LocalDirectory(
    /// The local path passed to existing session assembly.
    path: String,
  )

  /// A registration to resolve through owner-controlled configuration.
  RegisteredWorkspace(
    /// The administratively enrolled executor/workspace pair.
    selector: Selector,
  )
}

/// A resolved session choice, persisted before workspace consumers start.
pub type Binding {
  /// Existing local assembly retains its pathname contract.
  LocalBinding(
    /// The local directory, with no remote-path normalization.
    path: String,
  )

  /// An exact remote binding; unavailability is an error in the consumer.
  Registered(
    /// Registration plus both authority epochs.
    binding: RegisteredBinding,
  )
}

/// The stable remote session scope, independent of a transport generation.
pub opaque type Scope {
  /// Every field participates in equality.
  Scope(
    /// Existing core session identity, without a second UUID representation.
    session: ids.SessionId,
    /// Exact registration and authority epochs.
    binding: RegisteredBinding,
  )
}

/// A bounded external step. Internally generated names retain their spelling.
pub opaque type Step {
  /// Nonempty, at most 1024 bytes, and free of control characters.
  Step(
    /// The original name, including legitimate '/', ':' and UUID suffixes.
    value: String,
  )
}

/// Bounded construction errors; rejected input is never retained in them.
pub type InputError {
  /// A path was empty or larger than 4096 UTF-8 bytes.
  PathSize

  /// A path began with '/', including POSIX and slash-form UNC roots.
  AbsolutePath

  /// A path contained an empty component, '.' component or '..' component.
  PathComponent

  /// A path contained a backslash or colon with host-dependent meaning.
  PathSeparator

  /// A pathname or step contained C0, DEL or C1 control characters.
  ControlCharacter

  /// An administrative label was empty or larger than 128 bytes.
  LabelSize

  /// A label contained anything outside ASCII letters, digits, '.', '_' or '-'.
  LabelCharacter

  /// An epoch was outside 1..2147483647.
  EpochRange

  /// An external step was empty or larger than 1024 UTF-8 bytes.
  StepSize

  /// The projected session field was not a core UUIDv7.
  InvalidSession
}

/// Validates a wire pathname before any filesystem access. Checks run in
/// bounded linear time; oversize input is refused before splitting components.
///
/// ## Examples
///
/// ```gleam
/// assert workspace.relative_path("../secret") == Error(workspace.PathComponent)
/// assert workspace.relative_path("src/main.gleam") |> result.is_ok
/// ```
pub fn relative_path(text: String) -> Result(RelativePath, InputError) {
  let size = string.byte_size(text)
  use Nil <- result.try(case size > 0 && size <= max_path_bytes {
    True -> Ok(Nil)
    False -> Error(PathSize)
  })
  use Nil <- result.try(case string.starts_with(text, "/") {
    True -> Error(AbsolutePath)
    False -> Ok(Nil)
  })
  use Nil <- result.try(
    case string.contains(text, "\\") || string.contains(text, ":") {
      True -> Error(PathSeparator)
      False -> Ok(Nil)
    },
  )
  use Nil <- result.try(validate_controls(<<text:utf8>>))

  // Root is a whole-path choice, never a component to normalize away.
  use Nil <- result.try(case text {
    "." -> Ok(Nil)
    _ -> list.try_each(string.split(text, "/"), validate_component)
  })
  Ok(RelativePath(text))
}

/// Names the workspace root without an empty or absolute pathname.
///
/// ## Examples
///
/// ```gleam
/// assert workspace.path_string(workspace.root()) == "."
/// ```
pub fn root() -> RelativePath {
  RelativePath(".")
}

/// Returns the canonical spelling accepted by the remote path constructor.
///
/// ## Examples
///
/// ```gleam
/// assert workspace.path_string(workspace.root()) == "."
/// ```
pub fn path_string(path: RelativePath) -> String {
  path.value
}

/// Validates administrative labels without resolving or authorizing them.
///
/// ## Examples
///
/// ```gleam
/// assert workspace.selector("linux-build", "loom") |> result.is_ok
/// assert workspace.selector("", "loom") == Error(workspace.LabelSize)
/// ```
pub fn selector(
  executor: String,
  workspace: String,
) -> Result(Selector, InputError) {
  use Nil <- result.try(validate_label(executor))
  use Nil <- result.try(validate_label(workspace))
  Ok(Selector(executor:, workspace:))
}

/// Projects names for configuration lookup or validated executor conversion.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(selected) = workspace.selector("linux", "loom")
/// assert workspace.selector_fields(selected) == #("linux", "loom")
/// ```
pub fn selector_fields(selector: Selector) -> #(String, String) {
  #(selector.executor, selector.workspace)
}

/// Validates epochs allocated by the authorities, without advancing them.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(selected) = workspace.selector("linux", "loom")
/// assert workspace.registered_binding(selected, 0, 1) == Error(workspace.EpochRange)
/// ```
pub fn registered_binding(
  selector: Selector,
  workspace_epoch: Int,
  session_epoch: Int,
) -> Result(RegisteredBinding, InputError) {
  use Nil <- result.try(validate_epoch(workspace_epoch))
  use Nil <- result.try(validate_epoch(session_epoch))
  Ok(RegisteredBinding(selector:, workspace_epoch:, session_epoch:))
}

/// Projects registration, workspace epoch, then session epoch for an adapter.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(selected) = workspace.selector("linux", "loom")
/// let assert Ok(bound) = workspace.registered_binding(selected, 2, 3)
/// assert workspace.binding_fields(bound) == #(selected, 2, 3)
/// ```
pub fn binding_fields(binding: RegisteredBinding) -> #(Selector, Int, Int) {
  #(binding.selector, binding.workspace_epoch, binding.session_epoch)
}

/// Binds a durable session to an exact remote registration.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = ids.parse_session_id("00000000-0000-7000-8000-000000000001")
/// let assert Ok(selected) = workspace.selector("linux", "loom")
/// let assert Ok(bound) = workspace.registered_binding(selected, 2, 3)
/// assert workspace.scope_fields(workspace.scope(session, bound)) == #(session, bound)
/// ```
pub fn scope(session: ids.SessionId, binding: RegisteredBinding) -> Scope {
  Scope(session:, binding:)
}

/// Projects typed values without claiming that the registration is current.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = ids.parse_session_id("00000000-0000-7000-8000-000000000001")
/// let assert Ok(selected) = workspace.selector("linux", "loom")
/// let assert Ok(bound) = workspace.registered_binding(selected, 2, 3)
/// assert workspace.scope_fields(workspace.scope(session, bound)) == #(session, bound)
/// ```
pub fn scope_fields(scope: Scope) -> #(ids.SessionId, RegisteredBinding) {
  #(scope.session, scope.binding)
}

/// Validates projected executor identity fields. Its argument order matches
/// executor/remote/identity.scope_fields: session, workspace, executor, session
/// epoch, workspace epoch. The adapter must still compare current authority.
///
/// ## Examples
///
/// ```gleam
/// assert workspace.scope_from_fields("bad", "loom", "linux", 1, 1)
///   == Error(workspace.InvalidSession)
/// ```
pub fn scope_from_fields(
  session: String,
  workspace: String,
  executor: String,
  session_epoch: Int,
  workspace_epoch: Int,
) -> Result(Scope, InputError) {
  use Nil <- result.try(case string.byte_size(session) == 36 {
    True -> Ok(Nil)
    False -> Error(InvalidSession)
  })
  use session <- result.try(
    ids.parse_session_id(session)
    |> result.replace_error(InvalidSession),
  )
  use selected <- result.try(selector(executor, workspace))
  use bound <- result.try(registered_binding(
    selected,
    workspace_epoch,
    session_epoch,
  ))
  Ok(scope(session, bound))
}

/// Validates an external step without truncating or narrowing internal names.
/// Call this at external admission; the local broker copies its trusted string.
///
/// ## Examples
///
/// ```gleam
/// assert workspace.step("job/j1:build") |> result.is_ok
/// assert workspace.step("") == Error(workspace.StepSize)
/// ```
pub fn step(text: String) -> Result(Step, InputError) {
  let size = string.byte_size(text)
  use Nil <- result.try(case size > 0 && size <= max_step_bytes {
    True -> Ok(Nil)
    False -> Error(StepSize)
  })
  use Nil <- result.try(validate_controls(<<text:utf8>>))
  Ok(Step(text))
}

/// Returns the exact externally validated step name.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(step) = workspace.step("job/j1")
/// assert workspace.step_string(step) == "job/j1"
/// ```
pub fn step_string(step: Step) -> String {
  step.value
}

fn validate_component(component: String) -> Result(Nil, InputError) {
  case component {
    "" | "." | ".." -> Error(PathComponent)
    _ -> Ok(Nil)
  }
}

fn validate_controls(bytes: BitArray) -> Result(Nil, InputError) {
  // UTF-8 encodes C1 as C2 80..9F. Other continuation bytes are not controls.
  case bytes {
    <<>> -> Ok(Nil)
    <<byte, _:bits>> if byte < 32 || byte == 127 -> Error(ControlCharacter)
    <<194, byte, _:bits>> if byte >= 128 && byte <= 159 ->
      Error(ControlCharacter)
    <<_, rest:bits>> -> validate_controls(rest)
    _ -> Error(ControlCharacter)
  }
}

fn validate_label(text: String) -> Result(Nil, InputError) {
  let size = string.byte_size(text)
  use Nil <- result.try(case size > 0 && size <= 128 {
    True -> Ok(Nil)
    False -> Error(LabelSize)
  })
  validate_label_loop(<<text:utf8>>)
}

fn validate_label_loop(bytes: BitArray) -> Result(Nil, InputError) {
  case bytes {
    <<>> -> Ok(Nil)
    <<byte, rest:bits>>
      if byte >= 65
      && byte <= 90
      || byte >= 97
      && byte <= 122
      || byte >= 48
      && byte <= 57
      || byte == 46
      || byte == 95
      || byte == 45
    -> validate_label_loop(rest)
    _ -> Error(LabelCharacter)
  }
}

fn validate_epoch(epoch: Int) -> Result(Nil, InputError) {
  case epoch >= 1 && epoch <= 2_147_483_647 {
    True -> Ok(Nil)
    False -> Error(EpochRange)
  }
}
