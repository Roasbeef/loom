//// The commands an operator runs for a machine, written for the Admin page's
//// machine pages to show (protocol-change/085, the addendum of 2026-10-16).
////
//// A machine page runs nothing. Enrolling, renewing and revoking a member sign
//// ledger entries with a key that stays on the operator's machine, and releasing
//// a scope opens the executor's ledger with its daemon stopped, so none of them
//// can be a button on a page served by a daemon. The page instead states the
//// exact command, filled in with the names it drew, in a box that copies it, and
//// the operator runs it in a terminal on the right machine.
////
//// ## A name cannot change the command
////
//// The names come from the daemon's configuration, the ledger and the executors'
//// own reports, so a name is not trusted. Each name becomes exactly one shell
//// word. A name made of the characters a node or plan name has is written as it
//// is. Any other name is wrapped in single quotes, and a quote inside it is
//// closed, escaped and reopened, so a space, a semicolon, a substitution, a
//// redirection or a quote in a name is data inside the word and not shell syntax.
//// A name that cannot be made safe at all gets no command: an empty one, one over
//// `word_limit` bytes, one with a character outside printable ASCII, and one
//// that begins with a dash, which the program would read as an option whatever
//// the shell did with its quotes. The page then says the command cannot be drawn
//// and shows the name as text.
////
//// The rule is written a second time in the browser, where the copy box refuses
//// any text of another shape (`web_client/copy_rule`, subject `operate`). The
//// two are held together by the examples in both packages' tests, because a
//// package that targets JavaScript cannot import this one.
////
//// ## Flow
////
//// `enroll` | `renew` | `revoke` | `release` → `quote`
////
//// 1. Each command writes its fixed words and flags, with each name passed
////    through `quote`.
//// 2. `quote` returns the name as one shell word, or an error for a name that
////    cannot be one.

import gleam/list
import gleam/result
import gleam/string
import web_view/machines.{type Role, Executor, Member, Orchestrator}

/// The most bytes one name may have.
pub const word_limit = 256

/// The most bytes a whole command may have.
pub const command_limit = 1024

// The characters a word may carry unquoted. They are the browser rule's, and
// they exclude every character a shell treats as syntax, and neither equals nor
// comma: zsh expands a word that begins with an equals sign, and `--links` splits
// on commas, so a name with either is quoted.
const bare_characters =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@.:/_+-"

/// A name as one shell word, or an error for a name that cannot be one.
///
/// ## Examples
///
/// ```gleam
/// assert operator_commands.quote("loom@box.example.net") == Ok("loom@box.example.net")
/// assert operator_commands.quote("it's") == Ok("'it'\\''s'")
/// assert operator_commands.quote("--force") == Error(Nil)
/// ```
pub fn quote(name: String) -> Result(String, Nil) {
  case
    name != ""
    && string.byte_size(name) <= word_limit
    && printable(name)
    && !string.starts_with(name, "-")
  {
    False -> Error(Nil)
    True ->
      case bare(name) {
        True -> Ok(name)
        False -> Ok("'" <> string.replace(name, "'", "'\\''") <> "'")
      }
  }
}

// Whether every character is printable ASCII.
fn printable(name: String) -> Bool {
  list.all(string.to_utf_codepoints(name), fn(codepoint) {
    let number = string.utf_codepoint_to_int(codepoint)
    number >= 32 && number <= 126
  })
}

// Whether every character may stand unquoted.
fn bare(name: String) -> Bool {
  list.all(string.to_graphemes(name), string.contains(bare_characters, _))
}

/// The command that renews a member's certificate.
///
/// A member installed under a custom directory also needs `--bundle-dir` with
/// that directory, which the page says in words and does not guess.
///
/// ## Examples
///
/// ```gleam
/// assert operator_commands.renew("box") == Ok("loom distribution renew box")
/// ```
pub fn renew(name: String) -> Result(String, Nil) {
  use name <- result.try(quote(name))
  within("loom distribution renew " <> name)
}

/// The command that revokes a member, ending with a reason for the operator to
/// write in place of `REASON`.
///
/// ## Examples
///
/// ```gleam
/// assert operator_commands.revoke("box")
///   == Ok("loom distribution revoke box --reason 'REASON'")
/// ```
pub fn revoke(name: String) -> Result(String, Nil) {
  use name <- result.try(quote(name))
  within("loom distribution revoke " <> name <> " --reason 'REASON'")
}

/// The command that enrolls a node, linked to the orchestrator that is drawing
/// the page. A node that is only a directory member has no role to enroll as.
///
/// ## Examples
///
/// ```gleam
/// assert operator_commands.enroll("box", "loom@box", machines.Executor, "hub")
///   == Ok("loom distribution enroll box --node loom@box --role executor --links hub")
/// ```
pub fn enroll(
  name: String,
  node: String,
  role: Role,
  links: String,
) -> Result(String, Nil) {
  use word <- result.try(case role {
    Executor -> Ok("executor")
    Orchestrator -> Ok("orchestrator")
    Member -> Error(Nil)
  })
  use name <- result.try(quote(name))
  use node <- result.try(quote(node))
  use links <- result.try(quote(links))
  within(
    "loom distribution enroll "
    <> name
    <> " --node "
    <> node
    <> " --role "
    <> word
    <> " --links "
    <> links,
  )
}

/// The command that releases an executor's stuck scope, run on that executor
/// with its daemon stopped.
///
/// ## Examples
///
/// ```gleam
/// assert operator_commands.release("0198c1aa-0000-7000-8000-000000000002")
///   == Ok("loomd executor release 0198c1aa-0000-7000-8000-000000000002")
/// ```
pub fn release(session: String) -> Result(String, Nil) {
  use session <- result.try(quote(session))
  within("loomd executor release " <> session)
}

// The command, when it is within the bound the browser's rule holds it to.
fn within(command: String) -> Result(String, Nil) {
  case string.byte_size(command) <= command_limit {
    True -> Ok(command)
    False -> Error(Nil)
  }
}
