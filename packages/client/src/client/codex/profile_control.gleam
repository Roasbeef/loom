//// Operator commands for a native ChatGPT subscription profile, and the
//// events a command reports back.
////
//// A command runs inside a profile operation owned by `client/codex/transport`
//// and reports to the one process that started it, over an in-VM `Subject`.
//// No wire or web surface carries these values, so each event is a closed type
//// rather than a string the receiver would have to validate again. Events hold
//// no token, account subject, or upstream response text; the terminal command
//// renders them and never sees a credential. Plan permission is its own value
//// because a verified identity does not by itself allow spending plan
//// allowance.

/// An operator operation on one dedicated subscription profile.
pub type Command {
  /// Observes local identity and plan permission without refreshing a token.
  Status

  /// Authorizes through a literal loopback browser callback and PKCE.
  LoginBrowser

  /// Removes local tokens while preserving installation and registration.
  Logout

  /// Lists the models the authenticated public API makes available.
  Models
}

/// Whether a signed-in grant may invoke the public Responses API.
pub type Permission {
  /// The grant carries both `resource.invoke` and `chatgpt.tokens.use.direct`.
  PlanEnabled

  /// The identity is verified but the grant lacks plan permission.
  IdentityOnly
}

/// The local sign-in state of a profile.
pub type SignIn {
  /// The profile holds no grant: it is new or was signed out.
  SignedOut

  /// The profile holds a grant, whose scopes decide `permission`.
  SignedIn(permission: Permission)
}

/// An observation a running command reports to its caller.
pub type ControlEvent {
  /// The loopback port whose `/auth/start` route opens the browser attempt.
  LoginInstructions(port: Int)

  /// Identity was verified and saved; `permission` states what it may do.
  LoginComplete(permission: Permission)

  /// The answer to a `Status` command.
  LoginStatus(sign_in: SignIn)

  /// Local token removal completed.
  LogoutComplete

  /// Local tokens are cleared, but remote renewable-session revocation failed.
  LogoutRevocationUnconfirmed

  /// A bounded, validated public model catalogue without credential fields.
  ModelCatalogue(json: String)

  /// A stable error code which never includes upstream response text.
  ControlFailed(code: String)
}
