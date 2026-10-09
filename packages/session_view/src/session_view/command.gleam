//// Slash-command parsing for the terminal client.
////
//// Commands stay separate from protocol encoding: this module decides what
//// the operator meant, while the connection layer later decides which frozen
//// ClientGateway envelope carries it.
////
//// A parse also decides who acts on the command. A `Surface` command is the
//// host's own: a panel it draws, its daemon control connection, its exit.
//// A `Session` command is the session's, and the shared step dispatches it
//// the same way in every host. The host routes on the outer variant, so the
//// shared dispatch never sees a command it can only refuse.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// One action entered at the prompt: a command the host acts on itself, or
/// one it hands to the session.
///
/// The parse decides which, so a host routes on this outer variant and the
/// shared step's dispatch is exhaustive over `Session` alone
/// (`docs/design-notes/step-extraction.md`, question 7).
pub type Command {
  /// A command the host carries out with its own machinery: it opens a
  /// surface the host draws, reaches the daemon's control connection, or
  /// ends the host. The session state may change as a consequence, but the
  /// host decides how.
  Surface(surface: Surface)

  /// A command the session carries out: it sends a frame, writes the
  /// session state, or refuses with a line in the transcript. The shared
  /// step dispatches it.
  Session(session: Session)
}

/// A command the host acts on itself.
pub type Surface {
  /// Show the command reference.
  Help

  /// Show the model catalogue.
  Models

  /// Show the strand list.
  Strands

  /// Inspect the session's agents and sub-agents.
  Agents

  /// Inspect and administer owner-granted peer links.
  PeerLinks

  /// Inspect and reduce who has access to this daemon. Owner-only.
  Access

  /// Choose another locally managed session.
  Sessions

  /// Change the current session's saved display name.
  Rename(name: String)

  /// Browse the active strand's injected agent-note digest.
  Notes

  /// Browse successful edit diffs retained in this client.
  Diff

  /// Inspect held inputs without creating another submission.
  QueueInspect

  /// Inspect the latest completed operation and separately observed live jobs.
  Summary

  /// Show the strand's latest code-mode program, its result and its calls.
  Trace

  /// Inspect current context totals.
  Context

  /// Inspect current context totals and individual items.
  ContextAll

  /// Toggle expanded reasoning and tool detail.
  Details

  /// Switch the active strand by name.
  Strand(
    /// The stable strand name to make active.
    name: String,
  )

  /// Show the session goal's status panel.
  GoalStatus

  /// Leave the client.
  Quit
}

/// A command the shared step dispatches.
pub type Session {
  /// Add read access to a directory, or write access with an explicit flag.
  AddDirectory(path: String, access: String)

  /// Switch the active strand to one catalogue model by name.
  Model(
    /// The stable catalogue name selected by the operator.
    name: String,
  )

  /// Show the session's model role profile and the profiles the daemon's
  /// configuration defines. Answered by the daemon, not read from local state:
  /// the names are whatever the file defines now.
  ProfileShow

  /// Switch the session's saved model profile, so every role routes through
  /// that profile's chains from the next open, and restart the session to
  /// apply it (protocol-change/082).
  ProfileSelect(
    /// The profile to switch to, or `None` for the configuration's default
    /// roles, which the operator spells `default`.
    profile: Option(String),
  )

  /// List every schedule the session holds — the operator's own tables
  /// and the ones its strands created.
  Schedules

  /// Retire one schedule a strand created.
  Unschedule(
    /// The schedule's name, as the listing prints it.
    name: String,
    /// The strand it fires onto; `None` means the active strand, which
    /// is the row an operator is usually looking at.
    target: Option(String),
  )

  /// Show captured decisions, or explicitly load one exact historical decision.
  Approvals(id: Option(String))

  /// Approve the exact displayed action and requested grants at its captured seq.
  Approve(id: String)

  /// Reject the displayed pending action at its captured seq.
  Deny(id: String)

  /// Fork the active strand.
  Fork(
    /// The operator-facing name for the new branch strand.
    name: String,
  )

  /// Set the active strand's reasoning level for its next turns.
  Effort(
    /// The level word the server accepts: `off`, `minimal`, `low`,
    /// `medium`, `high`, `xhigh` or `max`. Validated server-side, so an
    /// unknown word comes back as a worded error rather than a guess.
    level: String,
  )

  /// Pin or replace the session goal.
  GoalSet(
    /// The operator's objective, verbatim, including any trailing number.
    objective: String,
    /// The primary tokens the goal may spend. The wire requires a positive
    /// number, so a `/goal` without `--budget` carries
    /// `default_goal_budget` rather than nothing.
    token_budget: Int,
  )

  /// Set or clear the check the harness runs before each goal feed.
  ///
  /// `None` clears it. The command is not validated here beyond its length:
  /// whether a shell command is one the operator meant is not a question a
  /// terminal can answer, and the server's own bound is what refuses a
  /// pasted script.
  GoalCheck(command: Option(String))

  /// Delete the session goal whatever its status.
  GoalClear

  /// Hold the session goal.
  GoalPause

  /// Continue a held or tripped session goal.
  GoalResume

  /// A `/goal --budget` whose token count is not a positive number.
  ///
  /// Its own variant rather than `MissingArgument` because the argument is
  /// present and wrong, and the operator needs to be shown the word that
  /// was rejected — a budget quietly defaulted here would pin a goal to a
  /// spend nobody chose.
  GoalBudgetInvalid(
    /// The rejected word, as the operator typed it.
    word: String,
  )

  /// A `/goal check` whose command is longer than the wire accepts.
  ///
  /// Its own variant rather than `GoalObjectiveTooLong` because the two
  /// bounds are different numbers on different fields, and an operator told
  /// the objective's limit while the command was refused would cut the wrong
  /// text.
  GoalCheckTooLong(
    /// How many characters the command actually carried.
    count: Int,
  )

  /// A `/goal` whose objective is longer than the wire accepts.
  ///
  /// Refused here rather than sent and refused there, because the operator
  /// who pasted a document into the composer wants to know before the
  /// round trip, and the count is what tells them how much to cut.
  GoalObjectiveTooLong(
    /// How many characters the objective actually carried.
    count: Int,
  )

  /// Compact the active strand.
  Compact

  /// Abort the active strand's live operation.
  Abort

  /// Inject text into the active strand's live operation.
  Steer(
    /// The instruction that must affect the in-flight turn.
    text: String,
  )

  /// Queue text to run after the active strand's live operation.
  Queue(
    /// The instruction that must wait for the in-flight turn to settle.
    text: String,
  )

  /// Clear only this client's rendered transcript.
  Clear

  /// Send ordinary text as a prompt.
  Prompt(
    /// The user-authored prompt text.
    text: String,
  )

  /// A slash command the client does not know.
  Unknown(
    /// The first slash-prefixed word that was not recognized.
    name: String,
  )

  /// A known command whose required argument is absent.
  MissingArgument(
    /// The command name whose argument is missing.
    name: String,
  )

  /// Ignore an empty submission.
  Empty
}

/// One slash-command row shown while the operator is composing.
pub type Suggestion {
  Suggestion(
    /// The slash-prefixed command inserted into the editor.
    command: String,
    /// A short operator-facing description.
    description: String,
    /// Whether choosing the row should leave room for an argument.
    takes_argument: Bool,
  )
}

/// The word that returns a session to the configuration's default roles. The
/// catalogue refuses a profile of this name (`client/catalog.default_profile`),
/// so the word cannot also name one.
pub const default_profile = "default"

/// Returns prefix-matched slash commands for an incomplete command word.
pub fn suggestions(input: String) -> List(Suggestion) {
  let input = string.trim_start(input)
  case input {
    // A command with a closed argument vocabulary keeps the palette open
    // past the space and offers the words themselves, so the operator
    // never has to remember them; Tab completes one and Enter submits.
    "/effort " <> partial -> level_suggestions(string.trim(partial))

    // `/goal`'s argument is free text, so the palette can only offer the
    // words that are subcommands when they stand alone. An objective that
    // happens to begin with one of them is still an objective; the rows
    // stop matching at the first character that differs, and an operator
    // who wanted the subcommand would have submitted it by then.
    "/goal " <> partial -> goal_suggestions(string.trim(partial))

    // The profile names are the daemon's and are not known here, so the palette
    // can offer only the word that is always valid. `/profile` alone lists the
    // names the configuration defines.
    "/profile " <> partial -> profile_suggestions("/profile", partial)
    "/model-profile " <> partial ->
      profile_suggestions("/model-profile", partial)

    _ -> word_suggestions(string.trim(input))
  }
}

fn word_suggestions(input: String) -> List(Suggestion) {
  case string.starts_with(input, "/"), string.contains(input, " ") {
    True, False ->
      all_suggestions()
      |> list.filter(fn(suggestion) {
        string.starts_with(suggestion.command, input)
      })
    _, _ -> []
  }
}

/// The reasoning levels `/effort` completes, with what each one means.
/// The vocabulary is the server's (`set_config` validates it); the
/// adapters fold its seven steps onto whatever their dialect offers.
pub const effort_levels = [
  #("off", "no reasoning requested"),
  #("minimal", "the smallest budget the model offers"),
  #("low", "a small reasoning budget"),
  #("medium", "a medium reasoning budget"),
  #("high", "a large reasoning budget"),
  #("xhigh", "beyond high where the model offers it"),
  #("max", "the largest budget the model offers"),
]

fn level_suggestions(partial: String) -> List(Suggestion) {
  effort_levels
  |> list.filter(fn(level) { string.starts_with(level.0, partial) })
  |> list.map(fn(level) { Suggestion("/effort " <> level.0, level.1, False) })
}

/// The tokens `/goal` completes past its own space: the three subcommands,
/// and the flag that sets the budget.
///
/// Each subcommand is a subcommand only as the whole argument, so these
/// rows are a reminder of the vocabulary rather than a claim about what the
/// operator is typing. `--budget` takes an argument; the other three do not.
pub const goal_words = [
  #("check", "run a command before each review: /goal check make check"),
  #("clear", "unpin the session goal"),
  #("pause", "hold the goal without unpinning it"),
  #("resume", "continue a held or tripped goal"),
  #("--budget", "set the token budget: /goal --budget 200000 <objective>"),
]

fn goal_suggestions(partial: String) -> List(Suggestion) {
  goal_words
  |> list.filter(fn(word) { string.starts_with(word.0, partial) })
  |> list.map(fn(word) {
    // Two of the words take an argument the operator keeps typing: the
    // budget's number, and the check's command. The other three are whole
    // commands, so the palette submits them rather than leaving the line open.
    Suggestion(
      "/goal " <> word.0,
      word.1,
      word.0 == "--budget" || word.0 == "check",
    )
  })
}

fn profile_suggestions(command: String, partial: String) -> List(Suggestion) {
  case string.starts_with(default_profile, string.trim(partial)) {
    True -> [
      Suggestion(
        command <> " " <> default_profile,
        "use the configuration's default roles",
        False,
      ),
    ]
    False -> []
  }
}

/// Moves a slash palette selection and wraps at either edge.
pub fn move_selection(selected: Int, count: Int, down: Bool) -> Int {
  case count <= 0, down, selected {
    True, _, _ -> 0
    False, True, selected if selected >= count - 1 -> 0
    False, True, selected -> selected + 1
    False, False, selected if selected <= 0 -> count - 1
    False, False, selected -> selected - 1
  }
}

/// Returns the command text selected in a filtered palette.
pub fn selected(
  suggestions: List(Suggestion),
  selected: Int,
) -> Option(String) {
  suggestions
  |> list.drop(selected)
  |> list.first
  |> option_from_result
  |> option_map(fn(suggestion) {
    case suggestion.takes_argument {
      True -> suggestion.command <> " "
      False -> suggestion.command
    }
  })
}

fn all_suggestions() -> List(Suggestion) {
  [
    Suggestion("/help", "show the command reference", False),
    Suggestion("/model", "choose a model", False),
    Suggestion("/agents", "inspect agents and sub-agents", False),
    Suggestion("/peers", "manage directional agent links", False),
    Suggestion("/sessions", "switch local sessions", False),
    Suggestion("/rename", "rename the current session", True),
    Suggestion("/notes", "browse agent notes", False),
    Suggestion("/diff", "observe current worktree changes", False),
    Suggestion("/context", "inspect current context usage", False),
    Suggestion("/contextall", "inspect context items", False),
    Suggestion("/summary", "inspect the latest completed operation", False),
    Suggestion(
      "/trace",
      "show the latest code-mode program and its calls",
      False,
    ),
    Suggestion("/details", "toggle reasoning and tool detail", False),
    Suggestion("/effort", "set the active strand's reasoning level", True),
    Suggestion("/goal", "show status; add a space for goal actions", False),
    Suggestion("/strands", "list session strands", False),
    Suggestion("/strand", "switch the active strand", True),
    Suggestion("/schedules", "list session schedules", False),
    Suggestion("/unschedule", "retire one schedule", True),
    Suggestion("/fork", "fork the active strand", True),
    Suggestion("/compact", "compact the active strand", False),
    Suggestion("/abort", "abort the live operation", False),
    Suggestion("/approvals", "show captured approval decisions", False),
    Suggestion(
      "/add-dir",
      "add session directory access (--write for writes)",
      True,
    ),
    Suggestion("/add-write-dir", "add read/write directory access", True),
    Suggestion("/approve", "approve an exact displayed request", True),
    Suggestion("/deny", "reject an exact displayed request", True),
    Suggestion("/steer", "inject into the live operation", True),
    Suggestion("/queue", "inspect queued inputs; /queue text adds one", False),
    Suggestion("/access", "owner: see and reduce who has access", False),
    Suggestion("/profile", "show or switch the model profile", True),
    Suggestion("/model-profile", "alias of /profile", True),
    Suggestion("/clear", "clear this local transcript", False),
    Suggestion("/quit", "leave the client", False),
  ]
}

fn option_from_result(value: Result(a, Nil)) -> Option(a) {
  case value {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

fn option_map(value: Option(a), map: fn(a) -> b) -> Option(b) {
  case value {
    Some(value) -> Some(map(value))
    None -> None
  }
}

/// Parses prompt text into a slash command or ordinary prompt.
///
/// The command name is case-sensitive and the first run of whitespace
/// separates it from its argument. The argument keeps its internal spaces.
///
/// ## Examples
///
/// ```gleam
/// assert command.parse("/models") == command.Surface(command.Models)
/// ```
///
/// ```gleam
/// assert command.parse("hello") == command.Session(command.Prompt("hello"))
/// ```
///
pub fn parse(input: String) -> Command {
  let input = string.trim(input)
  case input {
    "" -> Session(Empty)
    "/help" -> Surface(Help)
    "/models" -> Surface(Models)
    "/model" -> Surface(Models)
    "/strands" -> Surface(Strands)
    "/schedules" -> Session(Schedules)
    "/unschedule" -> Session(MissingArgument("unschedule"))
    "/agents" -> Surface(Agents)
    "/peers" -> Surface(PeerLinks)
    "/access" -> Surface(Access)
    "/sessions" -> Surface(Sessions)
    "/rename" -> Session(MissingArgument("rename"))
    "/rename " <> rest ->
      required_argument("rename", rest, fn(value) { Surface(Rename(value)) })
    "/approvals" -> Session(Approvals(None))
    "/add-dir" -> Session(MissingArgument("add-dir"))
    "/add-write-dir" -> Session(MissingArgument("add-write-dir"))
    "/approve" -> Session(MissingArgument("approve"))
    "/deny" -> Session(MissingArgument("deny"))
    "/notes" -> Surface(Notes)
    "/diff" -> Surface(Diff)
    "/summary" -> Surface(Summary)
    "/trace" -> Surface(Trace)
    "/context" -> Surface(Context)
    "/context all" | "/contextall" -> Surface(ContextAll)
    "/details" -> Surface(Details)
    "/effort" -> Session(MissingArgument("effort"))
    "/goal" -> Surface(GoalStatus)
    "/compact" -> Session(Compact)
    "/abort" -> Session(Abort)
    "/steer" -> Session(MissingArgument("steer"))
    "/queue" -> Surface(QueueInspect)
    "/clear" -> Session(Clear)
    "/quit" -> Surface(Quit)
    "/strand" -> Session(MissingArgument("strand"))
    "/fork" -> Session(MissingArgument("fork"))
    "/model " <> rest ->
      required_argument("model", rest, fn(value) { Session(Model(value)) })
    "/profile" | "/model-profile" -> Session(ProfileShow)
    "/profile " <> rest | "/model-profile " <> rest -> profile(rest)
    "/approvals " <> rest ->
      required_argument("approvals", rest, fn(id) {
        Session(Approvals(Some(id)))
      })
    "/add-write-dir " <> rest ->
      required_argument("add-write-dir", rest, fn(path) {
        Session(AddDirectory(path, "write"))
      })
    "/add-dir --write " <> rest ->
      required_argument("add-dir", rest, fn(path) {
        Session(AddDirectory(path, "write"))
      })
    "/add-dir --write" -> Session(MissingArgument("add-dir"))
    "/add-dir " <> rest ->
      required_argument("add-dir", rest, fn(path) {
        Session(AddDirectory(path, "read"))
      })
    "/approve " <> rest ->
      required_argument("approve", rest, fn(value) { Session(Approve(value)) })
    "/deny " <> rest ->
      required_argument("deny", rest, fn(value) { Session(Deny(value)) })
    "/strand " <> rest ->
      required_argument("strand", rest, fn(value) { Surface(Strand(value)) })
    "/fork " <> rest ->
      required_argument("fork", rest, fn(value) { Session(Fork(value)) })
    "/effort " <> rest ->
      required_argument("effort", rest, fn(value) { Session(Effort(value)) })
    "/goal " <> rest -> goal(rest)
    "/steer " <> rest ->
      required_argument("steer", rest, fn(value) { Session(Steer(value)) })
    "/queue " <> rest ->
      required_argument("queue", rest, fn(value) { Session(Queue(value)) })
    "/unschedule " <> rest -> unschedule(rest)
    "/" <> rest -> Session(Unknown(command_name(rest)))
    text -> Session(Prompt(text))
  }
}

// `/profile [name]`, spelled `/model-profile` as well. No argument reads the
// profile; `default` is the default roles, and any other word is sent as a
// profile name for the daemon to judge, since only the daemon knows which names
// the configuration defines now.
fn profile(raw: String) -> Command {
  case string.trim(raw) {
    "" -> Session(ProfileShow)
    word if word == default_profile -> Session(ProfileSelect(None))
    word -> Session(ProfileSelect(Some(word)))
  }
}

// `/unschedule <name> [target]`. The target is optional because the
// common case is a schedule on the strand the operator is already
// watching; a second word names another one, which is how a heartbeat a
// parent set onto a subagent is reached.
fn unschedule(raw: String) -> Command {
  case words(raw) {
    [] -> Session(MissingArgument("unschedule"))
    [name] -> Session(Unschedule(name:, target: None))
    [name, target, ..] -> Session(Unschedule(name:, target: Some(target)))
  }
}

/// The token budget a `/goal` without `--budget` pins.
///
/// The wire requires a positive budget — protocol 044 has no unbounded
/// goals — so the terminal either refuses every `/goal` that omits one or
/// supplies a number. It supplies this one, and says so in the row that
/// confirms the goal, for two reasons. The loop has two harness bounds
/// besides the budget (a cap of eight consecutive turns, and suppression
/// after two turns that produce nothing), so a defaulted budget cannot run
/// away unobserved; and the panel prints spend against budget from the
/// first read, so an operator who wanted a different number sees this one
/// immediately and re-pins with `--budget`.
pub const default_goal_budget = 200_000

/// The longest check command `/goal check` will send, in characters.
///
/// The server's own bound (`client/protocol.check_limit`, protocol 044 §8),
/// mirrored for the reason the objective's bound is mirrored: the terminal
/// can say so without a round trip, and a client that guessed a larger
/// number would send a command the server refuses, which is the honest
/// failure rather than a silent one.
pub const check_limit = 1000

/// The longest objective `/goal` will send, in characters.
///
/// The server's own bound (`client/protocol.objective_limit`, protocol 044
/// §1), mirrored because the terminal can say so without a round trip.
/// Mirrored rather than shared: the two packages do not depend on one
/// another, and a client that guessed a *larger* number would send a
/// command the server refuses — which is the honest failure and not a
/// silent one.
pub const objective_limit = 4000

// `/goal [--budget <tokens>] <objective>`, or one of three subcommands.
//
// The subcommands are subcommands only as the *whole* argument, because the
// objective is free text and `/goal clear the failing test` is work to do,
// not a request to unpin. That leaves the budget, which must not be guessed
// out of the objective: a trailing integer is a word of the objective — "fix
// issue 468" pins that objective and not a 468-token budget — so the budget
// is carried by an explicit flag in the first position and nowhere else.
// One rule, no escape hatch needed, and an objective may end in any number.
fn goal(raw: String) -> Command {
  case string.trim(raw) {
    "" -> Surface(GoalStatus)
    "clear" -> Session(GoalClear)
    "pause" -> Session(GoalPause)
    "resume" -> Session(GoalResume)

    // `check` is the one subcommand that takes an argument of its own, so it
    // is matched as a whole-argument *prefix* rather than as the whole
    // argument: bare `/goal check` clears the check, and `/goal check make
    // check` pins that command.
    //
    // The cost is an objective that begins with the word "check" — `/goal
    // check the logs` pins no goal, it sets a check. That is a real
    // ambiguity and it already has an escape that needs no new syntax:
    // `--budget` puts the objective past the first position, so `/goal
    // --budget 200000 check the logs` pins the objective. One rule, and the
    // escape is a flag the operator is already being offered.
    "check" -> Session(GoalCheck(command: None))
    "check " <> command -> checking(string.trim(command))

    "--budget" -> Session(MissingArgument("goal --budget"))
    "--budget " <> rest -> budgeted(rest)

    // `--budget=200000` is the same statement as `--budget 200000`, and it is
    // accepted rather than refused because an operator who writes the equals
    // sign has said exactly what they meant. Reading it as objective text was
    // the silent failure: the goal was pinned to the flag itself, under the
    // default budget, and nothing said so.
    "--budget=" <> rest -> budgeted(rest)

    objective -> pinning(objective, default_goal_budget)
  }
}

// The check command, bounded here so the operator is told the count without
// a round trip. An argument of nothing but whitespace is the bare form: the
// server reads an empty command as a clear, and so does this.
fn checking(command: String) -> Command {
  case command, string.length(command) > check_limit {
    "", _empty -> Session(GoalCheck(command: None))
    _text, True -> Session(GoalCheckTooLong(count: string.length(command)))
    text, False -> Session(GoalCheck(command: Some(text)))
  }
}

// One place decides whether an objective may be sent, so the flagged form
// and the bare form cannot disagree about the bound.
fn pinning(objective: String, token_budget: Int) -> Command {
  case string.length(objective) > objective_limit {
    True -> Session(GoalObjectiveTooLong(count: string.length(objective)))
    False -> Session(GoalSet(objective:, token_budget:))
  }
}

// The flag's own argument is the next whitespace-separated word, and
// everything after it is the objective verbatim.
fn budgeted(raw: String) -> Command {
  case string.split_once(string.trim_start(raw), " ") {
    // A budget with no objective pins nothing, and the word is still
    // checked: `/goal --budget abc` is a rejected budget whether or not an
    // objective followed it, and reporting only the missing objective sent
    // the operator looking for the wrong mistake.
    Error(Nil) -> objective_for(string.trim(raw), "")

    Ok(#(word, rest)) -> objective_for(word, string.trim(rest))
  }
}

fn objective_for(word: String, objective: String) -> Command {
  case token_count(word), objective {
    Error(Nil), _ -> Session(GoalBudgetInvalid(word))
    Ok(_), "" -> Session(MissingArgument("goal"))
    Ok(budget), objective -> pinning(objective, budget)
  }
}

// A positive token count, written in digits with optional `_` separators so
// `200_000` reads the way the operator would write it. No `k` or `m`
// suffix: the abbreviation would have to be documented in two places and
// argued about in one, and an explicit number in a command that pins a
// spend is worth the keystrokes.
fn token_count(word: String) -> Result(Int, Nil) {
  use count <- result.try(int.parse(string.replace(word, "_", "")))
  case count > 0 {
    True -> Ok(count)
    False -> Error(Nil)
  }
}

fn words(raw: String) -> List(String) {
  raw
  |> string.trim
  |> string.split(" ")
  |> list.filter(fn(word) { word != "" })
}

fn required_argument(
  name: String,
  raw: String,
  build: fn(String) -> Command,
) -> Command {
  case string.trim(raw) {
    "" -> Session(MissingArgument(name))
    value -> build(value)
  }
}

fn command_name(raw: String) -> String {
  raw
  |> string.split(" ")
  |> list.first
  |> result_or(raw)
}

fn result_or(value: Result(a, Nil), fallback: a) -> a {
  case value {
    Ok(found) -> found
    Error(Nil) -> fallback
  }
}

/// The command reference rendered by `/help`.
///
/// ## Examples
///
/// ```gleam
/// assert command.help_text() |> string.contains("/model")
/// ```
pub fn help_text() -> String {
  "/help             show this command reference\n"
  <> "/model            open the model selector\n"
  <> "/model <name>     switch the active strand model\n"
  <> "/profile          show the model profile and the names it can switch to\n"
  <> "/profile <name>   switch the session's model profile (default: the default roles)\n"
  <> "/model-profile    alias of /profile\n"
  <> "/agents           inspect agents and sub-agents\n"
  <> "/peers            manage directional agent links\n"
  <> "/access           owner: see and reduce who has access\n"
  <> "/sessions         switch locally managed sessions (← on an empty prompt)\n"
  <> "/rename <name>    rename the current session\n"
  <> "/notes            refresh current agent notes\n"
  <> "/context          inspect current context usage\n"
  <> "/context all      expand context item estimates\n"
  <> "/diff             observe current worktree changes\n"
  <> "/details          toggle reasoning and tool detail\n"
  <> "/effort <level>   set reasoning: off, minimal, low, medium, high, xhigh, max\n"
  <> "/goal             show the session goal's status\n"
  <> "/goal [--budget N] <objective>  pin a session goal (default 200000 tokens)\n"
  <> "/goal clear|pause|resume  unpin, hold or continue the goal\n"
  <> "/goal check [command]  run a command before each review, or clear it\n"
  <> "/strands          list session strands\n"
  <> "/schedules        list session schedules\n"
  <> "/add-dir [--write] <path>  add directory access for this session\n"
  <> "/add-write-dir <path>  add read/write directory access\n"
  <> "/unschedule <name> [target]  retire one schedule\n"
  <> "/strand <name>    switch the active strand\n"
  <> "/fork <name>      fork the active strand\n"
  <> "/compact          compact the active strand\n"
  <> "/abort            abort the live operation\n"
  <> "/steer <text>     inject into the live operation\n"
  <> "/summary          inspect latest completion and live jobs\n"
  <> "/trace            show the latest code-mode program and its calls\n"
  <> "/queue            inspect and edit queued inputs\n"
  <> "/queue <text>     run after the live operation\n"
  <> "/clear            clear this local transcript\n"
  <> "/quit             leave the client"
}

/// Completes built-ins and the attached daemon's loaded skills.
///
/// Built-ins retain their names when a skill claims the same command.
///
/// ## Examples
///
/// ```gleam
/// assert command.suggestions_with_skills("hello", []) == []
/// ```
pub fn suggestions_with_skills(
  input: String,
  skills: List(Suggestion),
) -> List(Suggestion) {
  let built_in = suggestions(input)
  let word = string.trim_start(input)
  case string.starts_with(word, "/") && !string.contains(word, " ") {
    True ->
      list.append(
        built_in,
        list.filter(skills, fn(skill) {
          string.starts_with(skill.command, word)
          && case parse(skill.command) {
            Session(Unknown(_)) -> True
            Session(_) | Surface(_) -> False
          }
        }),
      )
    False -> built_in
  }
}

/// Recognizes loaded skill commands as ordinary prompt submissions.
///
/// This classification happens before mutation admission, so observers and
/// occupied command slots retain the same draft as any other prompt.
///
/// ## Examples
///
/// ```gleam
/// assert command.parse_with_skills("/missing", [])
///   == command.Session(command.Unknown("missing"))
/// ```
pub fn parse_with_skills(input: String, skills: List(Suggestion)) -> Command {
  case parse(input) {
    Session(Unknown(name)) as unknown ->
      case list.any(skills, fn(skill) { skill.command == "/" <> name }) {
        True -> Session(Prompt(input))
        False -> unknown
      }
    other -> other
  }
}
