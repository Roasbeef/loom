//// What the home offers for creating a session: nothing, or under each
//// workspace a "New session" button that opens one small form (protocol-change/
//// 065, the fourth pull request), and a control for a folder that holds no
//// session yet (protocol-change/074).
////
//// The home's centre draws the same list for every principal, and only the
//// owner's page that was minted to operate offers this, so the rule for what is
//// drawn is written here once. The offer is the page's half of "the daemon
//// refuses anyone else": a member's or an observer's page has no handler to
//// press, and the daemon refuses a forged event from one all the same
//// (`client/daemon/ui_socket.create_for`).
////
//// The form under a workspace is one name field, one checkbox and two buttons.
//// The name is optional and the box is off, so pressing Create at once makes a
//// private session named for its folder, as the terminal does. The form submits
//// the two fields and nothing else: `fields` accepts exactly one `name` and at
//// most one `shareable`, and refuses the event for any other field or a repeat,
//// as the composer's decoder does. The workspace is not a field there. It is the
//// text the catalogue wrote, carried by the message the server drew into the
//// tree, so the browser's event names only the path it fired at.
////
//// When the daemon's configuration defines model profiles (protocol-change/076),
//// each form also carries a select of them, with the default roles first. The
//// profile names are the daemon's text and are never an attribute: an option's
//// `value` is its position in the list the page was given, and its label is the
//// name as a text node. The decoder turns the submitted position back into the
//// name from that same list (`fields_with_roles`), so the browser can choose
//// among the names the page drew and name nothing else.
////
//// The same forms carry a second select, of the daemon's `[models.<key>]` keys
//// (protocol-change/080), which pins the session's main model. It is drawn the
//// same way and decoded the same way, from its own list, and it is independent
//// of the profile select: a form may draw either, both or neither. A model key
//// is the owner's text from the configuration and is a text node and a position
//// like a profile name; nothing else about a model is given to the page.
////
//// The one "New session" form is the place a workspace is a field. For this
//// machine it adds a path to the same name and box, and its decoder
//// (`typed_fields`) is as strict: exactly one `path`, one `name`, at most one
//// `shareable`, and nothing else. The text is the browser's and nothing else is:
//// the daemon decides whether it names a folder the owner may use, and the page
//// words only the refusal, in fixed words. The typed path is never an attribute
//// on the page. The field is uncontrolled and the server never writes it back, so
//// what the owner typed is not echoed even in a refusal. The folders the daemon
//// remembers are offered beside the field as a select, drawn as the profile
//// select is: an option's value is its position in the list the page drew, its
//// label is the path as a text node, and the decoder turns the position back
//// into the path. A path typed in the field wins over the select.
////
//// When the daemon has executors or pools (protocol-change/078, 085), the form
//// opens with a "Runs on" choice before the folder: this machine, named for the
//// daemon and chosen by default, then a card for each executor and each pool in
//// the order the configuration lists them. A card carries the state the daemon
//// found when the form opened (`ready`, `degraded`, `full` or `down`, in the
//// three pill tints the page already has), what the executor's operator declared
//// about it, how many scopes it has free, and a Choose button. A state is advice:
//// the daemon found it a moment ago and decides again when the session opens, so
//// the form never refuses a card because of it and a `down` executor can be
//// chosen. Before the daemon's read answers, or when it gives nothing, the cards
//// carry names alone and say so. One line under the cards says where work
//// happens for the choice. A daemon with neither executors nor pools draws no
//// choice at all, so a single machine never meets the vocabulary.
////
//// The card a person chooses is the page's own state (`Chosen`), not a field of
//// the form. For an executor or a pool the folder field gives way to a select of
//// the workspaces that place registered, drawn from its report and decoded from
//// positions like the profile select, so with a list the browser can name only a
//// workspace the page drew and the daemon's "serves no workspace" refusal is a
//// backstop the form cannot reach. A place whose workspaces are not known (it is
//// down, not heard, or the read has not answered) says so in a note and takes the
//// name as typed text instead, held to `creations.registered_name`; the daemon's
//// refusal of a name it does not serve returns on the form. There is no
//// Shareable box there, because the daemon makes a session on an executor or in
//// a pool session-only whatever the form says. The placement is not a field of
//// the form: a card's button sends the choice it was drawn for, built by the
//// server from the names it was given, so the browser names no executor or pool,
//// and the decoder (`remote_fields`) accepts exactly one `workspace`, one `name`
//// and the two optional selects, which makes a forged `executor` or `pool` field
//// an extra field and refuses the event.
////
//// While a creation is out the form is drawn disabled with "Creating" on its
//// button, and every other workspace's button has no handler. That is the
//// page's half of "a second press asks nothing", and the component's update
//// and the daemon each refuse a second one as well.
////
//// A name and a workspace are never attributes. The workspace's folder name is
//// said in the form's quiet line as a text node, the input's placeholder is
//// fixed words, and nothing here is a class, a key or an identifier taken from
//// the catalogue. The same holds on a card: an executor's or a pool's name, the
//// daemon's own name, a declared platform and a workspace name are text nodes,
//// and the only strings that become classes are the pill tints
//// `placements.pill_class` returns. The free scope count and the contradiction
//// an executor's report can add to its card are words in a paragraph, drawn the
//// same way.
////
//// ## Flow
////
//// `button` → `form` → `fields_with_roles`, and for the one form
//// `new_button` → `new_form` → `typed_fields_with_roles` or
//// `remote_fields_with_roles`
////
//// 1. `button` opens a workspace's form and `form` draws it while it is the
////    open one; its submit is read by `fields_with_roles`, which turns the
////    positions of the select back into the profile and model names the page
////    offered.
//// 2. `new_button` opens the form for a new session and `new_form` draws it:
////    the "Runs on" cards when the daemon has any place to offer, then the
////    folder form for this machine (`typed_fields_with_roles` reads its submit)
////    or the workspace form for the chosen place (`remote_fields_with_roles`).
//// 3. `open_for` names the workspace a form is open for, which the component
////    uses to refuse a submit for a form that is not the open one.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import web_view/creations.{type Roles, type Sharing, Private, Shareable}
import web_view/placements.{type Cards, type Choice}

/// Where the person is in making a session.
pub type State {
  /// No form is open.
  Idle

  /// The form under this workspace is open, waiting to be filled and sent.
  Composing(workspace: String)

  /// This workspace's creation is out. The form is drawn disabled until the
  /// answer arrives.
  Waiting(workspace: String)

  /// The form for a new session is open and runs on this machine, the default
  /// choice: a folder on the daemon serving the page.
  Elsewhere

  /// The creation for a folder on this machine is out. The form is drawn
  /// disabled until the answer arrives.
  Sending

  /// The form is open with an executor or a pool chosen (protocol-change/078,
  /// 085), so it asks for a workspace registered there.
  Chosen(choice: Choice)

  /// The creation for a registered workspace is out. The form is drawn
  /// disabled, with the chosen card marked, until the answer arrives.
  Dispatching(choice: Choice)
}

/// What a page offers for creating a session.
pub type Create(message) {
  /// The page may not create: it is not the owner's, or it was not minted to
  /// operate. Nothing is drawn.
  Never

  /// The page may ask the daemon to create a session. `choose` is the message a
  /// workspace's button sends, given the workspace the group was drawn for;
  /// `submit` is what the form sends, given that workspace, the typed name, the
  /// sharing and the chosen roles; `cancel` closes the form; `elsewhere` opens
  /// the form for a new session and `submit_elsewhere` is what it sends for this
  /// machine, given the path, the typed name, the sharing and the chosen roles;
  /// `state` is where the person is; `profiles` is the profile names the forms
  /// offer beside the default roles, which may be none, and `models` is the
  /// model keys they offer beside the default model, which may be none. A
  /// profile or a model a submit carries is always one of them. `here` is what
  /// the card for this machine sends, `choose_place` is what an executor's or a
  /// pool's card sends, given the choice the card was drawn for, and
  /// `submit_remote` is what the form sends for a chosen place, given the
  /// workspace, the typed session name and the chosen roles; the placement the
  /// creation asks for is the one the page recorded when the card was chosen, so
  /// the browser cannot name another. `machine` is the daemon's own name and
  /// `cards` is the executors and pools the daemon gave the page and what it
  /// reported about them; with none, the form draws no "Runs on" choice.
  Offered(
    choose: fn(String) -> message,
    submit: fn(String, String, Sharing, Roles) -> message,
    cancel: message,
    elsewhere: message,
    submit_elsewhere: fn(String, String, Sharing, Roles) -> message,
    state: State,
    profiles: List(String),
    models: List(String),
    here: message,
    choose_place: fn(Choice) -> message,
    submit_remote: fn(String, String, Roles) -> message,
    machine: String,
    cards: Cards,
  )
}

/// The state a memoized view includes in its key, so a group changes when its
/// form opens, closes or starts waiting.
///
/// ## Examples
///
/// ```gleam
/// assert create.state(create.Never) == create.Idle
/// ```
pub fn state(create: Create(message)) -> State {
  case create {
    Never -> Idle
    Offered(state:, ..) -> state
  }
}

/// The cards a memoized view includes in its key, or nothing for a page that
/// may not create: the daemon's read changes what a card says without changing
/// the state, and the view must be drawn again when it does.
///
/// ## Examples
///
/// ```gleam
/// assert create.cards(create.Never) == None
/// ```
pub fn cards(create: Create(message)) -> Option(Cards) {
  case create {
    Never -> None
    Offered(cards:, ..) -> Some(cards)
  }
}

/// The button at the head of a workspace's group, or nothing. It has a handler
/// only while no creation is out, so a press cannot start a second.
///
/// ## Examples
///
/// ```gleam
/// // create.button(create, group.workspace)
/// ```
pub fn button(create: Create(message), workspace: String) -> Element(message) {
  case create {
    Never -> element.none()
    Offered(choose:, state:, ..) ->
      opener("New session", state, fn() { choose(workspace) })
  }
}

/// The button that opens the form for a new session, or nothing. It has a
/// handler only while no creation is out, as a workspace's button does.
///
/// ## Examples
///
/// ```gleam
/// // create.new_button(create)
/// ```
pub fn new_button(create: Create(message)) -> Element(message) {
  case create {
    Never -> element.none()
    Offered(elsewhere:, state:, ..) ->
      opener("New session", state, fn() { elsewhere })
  }
}

/// One "New session" button: disabled while a creation is out, otherwise it
/// sends the message the page chose.
fn opener(
  words: String,
  state: State,
  press: fn() -> message,
) -> Element(message) {
  let attributes = [
    attribute.type_("button"),
    attribute.class("home-new"),
  ]
  html.button(
    case state {
      Waiting(_) | Sending | Dispatching(_) -> [
        attribute.disabled(True),
        ..attributes
      ]
      Idle | Composing(_) | Elsewhere | Chosen(_) -> [
        event.on_click(press()),
        ..attributes
      ]
    },
    [html.text(words)],
  )
}

/// The form for a new session when it is open, and nothing otherwise. Where the
/// daemon has executors or pools it opens with the "Runs on" choice and a line
/// saying where work happens; below that is the folder form for this machine, or
/// the workspace form for the chosen place. `recent` is the remembered folders
/// the form offers beside the path field, as the page drew them.
///
/// ## Examples
///
/// ```gleam
/// // create.new_form(create, ["/home/me/app"])
/// ```
pub fn new_form(
  create: Create(message),
  recent: List(String),
) -> Element(message) {
  case create {
    Never -> element.none()
    Offered(state:, ..) ->
      case state {
        Elsewhere -> sheet(create, recent, None, Editable)
        Sending -> sheet(create, recent, None, Locked)
        Chosen(choice:) -> sheet(create, recent, Some(choice), Editable)
        Dispatching(choice:) -> sheet(create, recent, Some(choice), Locked)
        Idle | Composing(_) | Waiting(_) -> element.none()
      }
  }
}

/// The form under a workspace's heading when it is the one open, and nothing
/// otherwise. The form says in words the name a blank field gets.
///
/// ## Examples
///
/// ```gleam
/// // create.form(create, group.workspace)
/// ```
pub fn form(create: Create(message), workspace: String) -> Element(message) {
  case create {
    Never -> element.none()
    Offered(submit:, cancel:, state:, profiles:, models:, ..) ->
      case state {
        Composing(open) if open == workspace ->
          drawn(workspace, submit, cancel, Editable, profiles, models)
        Waiting(open) if open == workspace ->
          drawn(workspace, submit, cancel, Locked, profiles, models)
        Idle
        | Composing(_)
        | Waiting(_)
        | Elsewhere
        | Sending
        | Chosen(_)
        | Dispatching(_) -> element.none()
      }
  }
}

// Whether the fields take input: a form whose creation is out is locked.
type Fields {
  Editable
  Locked
}

fn locks(fields: Fields) -> List(attribute.Attribute(message)) {
  case fields {
    Editable -> []
    Locked -> [attribute.disabled(True)]
  }
}

/// Drawn helper.
fn drawn(
  workspace: String,
  submit: fn(String, String, Sharing, Roles) -> message,
  cancel: message,
  fields: Fields,
  profiles: List(String),
  models: List(String),
) -> Element(message) {
  html.form(
    [
      attribute.class("home-create"),
      attribute.aria_label("New session"),
      event.on("submit", submitted(workspace, submit, profiles, models))
        |> event.prevent_default,
    ],
    [
      name_field(fields),
      share_field(fields),
      ..list.append(role_fields(fields, profiles, models), [
        // The hint names what a blank field gets, so the stylesheet hides it
        // once the field holds a name (`:placeholder-shown`): the field is
        // uncontrolled, and the server never sees what is typed until it is
        // submitted.
        html.p([attribute.class("home-create-hint")], [
          html.text("Left blank, the session is named "),
          html.b([], [html.text(creations.folder(workspace))]),
          html.text("."),
        ]),
        actions(fields, cancel),
      ])
    ],
  )
}

/// The whole new-session form: the "Runs on" choice when the daemon has a place
/// to offer, then the fields for the choice. The choice is the page's own state,
/// so switching it redraws the fields below and the person's typed name is not
/// carried across.
fn sheet(
  create: Create(message),
  recent: List(String),
  chosen: Option(Choice),
  fields: Fields,
) -> Element(message) {
  case create {
    Never -> element.none()
    Offered(
      submit_elsewhere:,
      cancel:,
      profiles:,
      models:,
      here:,
      choose_place:,
      submit_remote:,
      machine:,
      cards:,
      ..,
    ) ->
      html.div([attribute.class("home-new-session")], [
        case placements.any(cards) {
          True -> places(machine, cards, chosen, here, choose_place, fields)
          False -> element.none()
        },
        case chosen {
          None ->
            typed(submit_elsewhere, cancel, fields, profiles, models, recent)
          Some(choice) ->
            registered(
              cards,
              choice,
              submit_remote,
              cancel,
              fields,
              profiles,
              models,
            )
        },
      ])
  }
}

/// The form for a folder on this machine: the remembered folders, the path, then
/// the same name and box. The name's hint follows the name input, as the
/// stylesheet's sibling rule needs.
fn typed(
  submit: fn(String, String, Sharing, Roles) -> message,
  cancel: message,
  fields: Fields,
  profiles: List(String),
  models: List(String),
  recent: List(String),
) -> Element(message) {
  html.form(
    [
      attribute.class("home-create"),
      attribute.aria_label("New session"),
      event.on("submit", typed_submitted(submit, profiles, models, recent))
        |> event.prevent_default,
    ],
    [
      remembered_field(fields, recent),
      html.input([
        attribute.type_("text"),
        attribute.name("path"),
        attribute.class("home-create-path"),
        attribute.placeholder("Folder path, for example ~/code/app"),
        attribute.aria_label("Folder path"),
        attribute.attribute("maxlength", "4096"),
        attribute.autocomplete("off"),
        attribute.autofocus(True),
        ..locks(fields)
      ]),
      html.p([attribute.class("home-create-hint")], [
        html.text(
          "The folder must already exist inside your home directory. A new session starts there.",
        ),
      ]),
      name_field(fields),
      share_field(fields),
      ..list.append(role_fields(fields, profiles, models), [
        html.p([attribute.class("home-create-hint")], [
          html.text("Left blank, the session is named for the folder."),
        ]),
        actions(fields, cancel),
      ])
    ],
  )
}

/// The "Runs on" choice: one card for this machine, then one for each executor
/// and each pool, and the line that says where work happens for the choice.
/// Nothing is chosen on the page's behalf except this machine, which is the
/// default: the cards are drawn in the order the configuration lists them,
/// executors first, and the person presses one.
///
/// The chosen placement is the page's own state and not a field of the form. A
/// card's button sends the choice it was drawn for, which the server built from
/// the names it was given, so no executor or pool name is ever an attribute, and
/// the form's submit carries only what a person types or picks from a list.
fn places(
  machine: String,
  cards: Cards,
  chosen: Option(Choice),
  here: message,
  choose: fn(Choice) -> message,
  fields: Fields,
) -> Element(message) {
  let placed = cards.placements
  html.section(
    [
      attribute.class("home-place"),
      attribute.aria_label("Where to run the session"),
    ],
    [
      html.p([attribute.class("home-create-profile-name")], [
        html.text("Runs on"),
      ]),

      // Every card carries a handler, so the list is keyed. The keys are
      // positions with the kind of place as a prefix, never a name: the lists
      // are the daemon's startup capture and cannot change while the page is
      // open, so a position names the same card for the page's life, and no
      // text the daemon gave is ever part of a key.
      keyed.div([attribute.class("home-cards")], [
        #("h", here_card(machine, chosen, here, fields)),
        ..list.append(
          list.index_map(placed.executors, fn(executor, position) {
            #(
              "e" <> int.to_string(position),
              executor_card(executor, cards.readiness, chosen, choose, fields),
            )
          }),
          list.index_map(placed.pools, fn(pool, position) {
            #(
              "p" <> int.to_string(position),
              pool_card(pool, cards.readiness, chosen, choose, fields),
            )
          }),
        )
      ]),
      html.p([attribute.class("home-create-hint")], [
        html.text(readiness_words(cards.readiness)),
      ]),
      html.p([attribute.class("home-create-hint")], [
        html.text(where_words(machine, cards, chosen)),
      ]),
    ],
  )
}

/// What the cards say of how they were made. The state of each card is advice,
/// and the line says so before the person reads one.
fn readiness_words(readiness: placements.Readiness) -> String {
  case readiness {
    placements.Checking ->
      "Checking which are reachable from the daemon. You can choose one now."
    placements.Checked ->
      "This is what the daemon found just now. A state is advice: you can still choose one that is down, and the daemon decides again when the session opens."
  }
}

/// Where the work of a session happens for the choice. The conversation always
/// stays on the daemon serving the page; the commands run where the choice says.
fn where_words(
  machine: String,
  cards: Cards,
  chosen: Option(Choice),
) -> String {
  case chosen {
    None -> "Commands and the conversation stay on " <> machine <> "."
    Some(placements.OnExecutor(name:)) ->
      "Commands run on "
      <> name
      <> platform_words(cards, name)
      <> "; the conversation stays on "
      <> machine
      <> "."
    Some(placements.InPool(name:)) ->
      "The daemon picks the executor from pool "
      <> name
      <> " when the session opens. Commands run there; the conversation stays on "
      <> machine
      <> "."
  }
}

/// The executor's declared platform in parentheses, or nothing when its operator
/// declared none or the daemon has not reported.
fn platform_words(cards: Cards, name: String) -> String {
  let found =
    list.find(cards.placements.executors, fn(each) { each.name == name })

  // Dispatch on platform_words state.
  case found {
    Ok(placements.Executor(
      report: Some(placements.Report(platform: Some(os), ..)),
      ..,
    )) -> " (" <> os <> ")"
    Ok(_) | Error(Nil) -> ""
  }
}

// Whether a card is the chosen one, so the card can mark itself.
type Mark {
  Marked
  Unmarked
}

/// Here card helper.
fn here_card(
  machine: String,
  chosen: Option(Choice),
  here: message,
  fields: Fields,
) -> Element(message) {
  card(
    "",
    machine <> " (this machine)",
    element.none(),
    [],
    case chosen {
      None -> Marked
      Some(_) -> Unmarked
    },
    here,
    fields,
  )
}

/// Executor card helper.
fn executor_card(
  executor: placements.Executor,
  readiness: placements.Readiness,
  chosen: Option(Choice),
  choose: fn(Choice) -> message,
  fields: Fields,
) -> Element(message) {
  let choice = placements.OnExecutor(executor.name)
  card(
    "executor",
    executor.name,
    case executor.report {
      Some(report) if readiness == placements.Checked ->
        pill(
          placements.pill_class(report.state),
          placements.state_words(report.state),
        )
      Some(_) | None -> pill("pending", "not checked")
    },
    case executor.report {
      Some(report) if readiness == placements.Checked -> executor_facts(report)
      Some(_) | None -> []
    },
    marked(chosen, choice),
    choose(choice),
    fields,
  )
}

fn marked(chosen: Option(Choice), choice: Choice) -> Mark {
  case chosen == Some(choice) {
    True -> Marked
    False -> Unmarked
  }
}

/// What an executor's card says beyond its name and state: what its operator
/// declared about the machine, which is the operator's claim and is worded as
/// one, then how many scopes the executor says are free and any way its census
/// contradicts the claim. The last two are the executor's own report, drawn as
/// text like the rest.
fn executor_facts(report: placements.Report) -> List(Element(message)) {
  list.flatten([
    [fact(declared_words(report))],
    case report.free_scopes {
      Some(free) -> [fact(scopes_free_words(free))]
      None -> []
    },
    case report.contradiction {
      Some(words) -> [fact(words <> ".")]
      None -> []
    },
  ])
}

fn scopes_free_words(free: Int) -> String {
  case free {
    1 -> "1 scope free."
    _ -> int.to_string(free) <> " scopes free."
  }
}

/// Declared words helper.
fn declared_words(report: placements.Report) -> String {
  let stated =
    list.flatten([
      stated_word(report.platform),
      stated_word(report.enforcement),
      report.toolchains,
    ])

  // Dispatch on declared_words state.
  case stated {
    [] -> "Declares nothing about its machine."
    words -> "Declared: " <> string.join(words, ", ") <> "."
  }
}

fn stated_word(word: Option(String)) -> List(String) {
  case word {
    Some(text) -> [text]
    None -> []
  }
}

/// Pool card helper.
fn pool_card(
  pool: placements.Pool,
  readiness: placements.Readiness,
  chosen: Option(Choice),
  choose: fn(Choice) -> message,
  fields: Fields,
) -> Element(message) {
  let choice = placements.InPool(pool.name)
  card(
    "pool",
    pool.name,
    case pool.report {
      Some(report) if readiness == placements.Checked ->
        case report.eligible {
          [_, ..] -> pill("online", "ready")
          [] -> pill("ended", "down")
        }
      Some(_) | None -> pill("pending", "not checked")
    },
    case pool.report {
      Some(report) if readiness == placements.Checked -> pool_facts(report)
      Some(_) | None -> []
    },
    marked(chosen, choice),
    choose(choice),
    fields,
  )
}

/// A pool's card says how many of its executors the daemon reached and in what
/// order a first open tries them. The order is the pool's own and is not changed
/// by health: an open moves to the next executor only for a failed connection or
/// a full one.
fn pool_facts(report: placements.PoolReport) -> List(Element(message)) {
  case report.executors {
    [] -> [fact("No executor satisfies the pool's requirements.")]
    tried -> [
      fact("The daemon picks the executor."),
      fact(
        int.to_string(list.length(report.eligible))
        <> " of "
        <> int.to_string(list.length(tried))
        <> " executors reachable."
        <> " Tried in order: "
        <> string.join(tried, ", ")
        <> ".",
      ),
    ]
  }
}

fn fact(words: String) -> Element(message) {
  html.p([attribute.class("home-card-fact")], [html.text(words)])
}

fn pill(tone: String, words: String) -> Element(message) {
  html.span([attribute.class("pill"), attribute.class(tone)], [
    html.text(words),
  ])
}

/// One card: the name, what kind of place it is (nothing for this machine), the
/// state pill, the facts, and the button that chooses it. The chosen card is
/// marked by its class and by a pressed button, and the buttons have no handler
/// while a creation is out.
fn card(
  kind: String,
  name: String,
  state: Element(message),
  facts: List(Element(message)),
  mark: Mark,
  press: message,
  fields: Fields,
) -> Element(message) {
  html.div(
    list.append([attribute.class("home-card")], case mark {
      Marked -> [attribute.class("chosen")]
      Unmarked -> []
    }),
    [
      html.div([attribute.class("home-card-head")], [
        html.span([attribute.class("home-card-name")], [html.text(name)]),
        case kind {
          "" -> element.none()
          _ -> html.span([attribute.class("home-card-kind")], [html.text(kind)])
        },
        state,
      ]),
      ..list.append(facts, [
        html.button(
          list.flatten([
            [
              attribute.type_("button"),
              attribute.class("home-new"),
              attribute.class("home-card-choose"),
              attribute.attribute("aria-pressed", case mark {
                Marked -> "true"
                Unmarked -> "false"
              }),
            ],
            case fields, mark {
              Editable, Unmarked -> [event.on_click(press)]
              Editable, Marked -> []
              Locked, _ -> [attribute.disabled(True)]
            },
          ]),
          [
            html.text(case mark {
              Marked -> "Chosen"
              Unmarked -> "Choose"
            }),
          ],
        ),
      ])
    ],
  )
}

/// The form for a workspace registered at the chosen place: a select of the
/// workspaces that place reported, and the optional session name. There is no
/// Shareable box, because the daemon makes a session on an executor or in a pool
/// session-only (its workspace aggregate is keyed by a path on the daemon's
/// host), which is what Shareable asks for. A place that has reported no
/// workspace (still being read, down, not heard, or none registered) offers a
/// text field for the name it serves instead, under a note saying so: the
/// daemon's refusal of a name the executor does not serve is the backstop.
fn registered(
  cards: Cards,
  choice: Choice,
  submit: fn(String, String, Roles) -> message,
  cancel: message,
  fields: Fields,
  profiles: List(String),
  models: List(String),
) -> Element(message) {
  let workspaces = placements.workspaces(cards, choice)
  html.form(
    [
      attribute.class("home-create"),
      attribute.aria_label("New session"),
      event.on("submit", remote_submitted(submit, workspaces, profiles, models))
        |> event.prevent_default,
    ],
    [
      case workspaces {
        [] -> typed_workspace_field(fields)
        _ -> workspace_field(fields, workspaces)
      },
      html.p([attribute.class("home-create-hint")], [
        html.text(case workspaces {
          [] -> unknown_words(choice)
          _ ->
            "The workspaces registered there. A workspace is a name, not a folder on this machine."
        }),
      ]),
      name_field(fields),
      ..list.append(role_fields(fields, profiles, models), [
        html.p([attribute.class("home-create-hint")], [
          html.text("Left blank, the session is named for the workspace."),
        ]),
        actions(fields, cancel),
      ])
    ],
  )
}

/// Why the form asks for a typed name: the place has not reported its
/// workspaces. The name of the executor or pool is a text node.
fn unknown_words(choice: Choice) -> String {
  case choice {
    placements.OnExecutor(name:) ->
      name <> " has not reported its workspaces; type the name it serves."
    placements.InPool(name:) ->
      "No workspace is known to be served by every executor in pool "
      <> name
      <> "; type the name they serve."
  }
}

/// The text field for a workspace name the page could not list. The name is the
/// browser's text, judged by `creations.registered_name` when the form is read
/// and again by the daemon.
fn typed_workspace_field(fields: Fields) -> Element(message) {
  html.input([
    attribute.type_("text"),
    attribute.name("workspace"),
    attribute.class("home-create-path"),
    attribute.placeholder("Workspace name, for example app"),
    attribute.aria_label("Workspace name"),
    attribute.attribute("maxlength", "128"),
    attribute.autocomplete("off"),
    attribute.autofocus(True),
    ..locks(fields)
  ])
}

fn workspace_field(
  fields: Fields,
  workspaces: List(String),
) -> Element(message) {
  chooser_of(fields, "workspace", "Workspace", None, workspaces)
}

/// The select of the remembered folders, or nothing when there are none. Its
/// first option is "no choice", so the path field below is the way to name a
/// folder that is not listed.
fn remembered_field(fields: Fields, recent: List(String)) -> Element(message) {
  case recent {
    [] -> element.none()
    _ ->
      chooser_of(
        fields,
        "folder",
        "Remembered folder",
        Some("Type a path below"),
        recent,
      )
  }
}

/// Name field helper.
fn name_field(fields: Fields) -> Element(message) {
  html.input([
    attribute.type_("text"),
    attribute.name("name"),
    attribute.class("home-create-name"),
    attribute.placeholder("Session name (optional)"),
    attribute.aria_label("Session name"),
    attribute.attribute("maxlength", "256"),
    attribute.autocomplete("off"),
    ..locks(fields)
  ])
}

/// Share field helper.
fn share_field(fields: Fields) -> Element(message) {
  html.label([attribute.class("home-create-share")], [
    html.input([
      attribute.type_("checkbox"),
      attribute.name("shareable"),
      ..locks(fields)
    ]),
    html.span([attribute.class("home-create-share-text")], [
      html.span([attribute.class("home-create-share-name")], [
        html.text("Shareable"),
      ]),
      html.span([attribute.class("home-create-share-hint")], [
        html.text(
          "Keeps its own notes and history, so you can invite people to it.",
        ),
      ]),
    ]),
  ])
}

/// The two optional selects and the line that says how they combine, or nothing
/// when the configuration defines neither.
fn role_fields(
  fields: Fields,
  profiles: List(String),
  models: List(String),
) -> List(Element(message)) {
  case profiles, models {
    [], [] -> []
    _, _ -> [
      profile_field(fields, profiles),
      model_field(fields, models),
      // A note and not a hint: the stylesheet hides the hints after the name
      // field once it holds a name, and this line explains the selects above it.
      html.p([attribute.class("home-create-note")], [
        html.text(
          "Default uses the configuration's roles. A profile sets the roles for this session, and a model you pick replaces the main model the profile gives.",
        ),
      ]),
    ]
  }
}

// The select of model profiles, or nothing when the configuration defines none.
fn profile_field(fields: Fields, profiles: List(String)) -> Element(message) {
  chooser(fields, "profile", "Model profile", profiles)
}

// The select of the daemon's model keys, or nothing when there are none. It
// pins the session's main model (protocol-change/080).
fn model_field(fields: Fields, models: List(String)) -> Element(message) {
  chooser(fields, "model", "Main model", models)
}

/// A labelled select of text the daemon supplied whose first option is the
/// default, or nothing when it supplied none.
fn chooser(
  fields: Fields,
  field_name: String,
  label: String,
  offered: List(String),
) -> Element(message) {
  case offered {
    [] -> element.none()
    _ -> chooser_of(fields, field_name, label, Some("Default"), offered)
  }
}

/// A labelled select of text the page drew. With `unchosen` the first option is
/// that words and has the empty value; without it the first offered text is the
/// one the browser selects. Each other option's value is its position in
/// `offered`, and its label is the text as a text node, so no name, key or path
/// is ever an attribute. The rows share the stylesheet's `home-create-profile`
/// classes, which style any labelled select in this form.
fn chooser_of(
  fields: Fields,
  field_name: String,
  label: String,
  unchosen: Option(String),
  offered: List(String),
) -> Element(message) {
  html.label([attribute.class("home-create-profile")], [
    html.span([attribute.class("home-create-profile-name")], [
      html.text(label),
    ]),
    html.select(
      [
        attribute.name(field_name),
        attribute.class("home-create-profile-select"),
        attribute.aria_label(label),
        ..locks(fields)
      ],
      list.append(
        case unchosen {
          Some(words) -> [html.option([attribute.value("")], words)]
          None -> []
        },
        list.index_map(offered, fn(text, position) {
          html.option([attribute.value(int.to_string(position))], text)
        }),
      ),
    ),
  ])
}

/// Actions helper.
fn actions(fields: Fields, cancel: message) -> Element(message) {
  html.div([attribute.class("home-create-actions")], [
    html.button(
      [
        attribute.type_("submit"),
        attribute.class("home-create-go"),
        ..locks(fields)
      ],
      [
        html.text(case fields {
          Editable -> "Create session"
          Locked -> "Creating"
        }),
      ],
    ),
    html.button(
      [
        attribute.type_("button"),
        attribute.class("home-create-cancel"),
        event.on_click(cancel),
        ..locks(fields)
      ],
      [html.text("Cancel")],
    ),
  ])
}

/// The event's decoder: the form's fields as the browser lists them, refused
/// unless `fields_with_roles` accepts them. A refused event is dropped by Lustre
/// with no message.
fn submitted(
  workspace: String,
  submit: fn(String, String, Sharing, Roles) -> message,
  profiles: List(String),
  models: List(String),
) -> decode.Decoder(message) {
  use listed <- decode.subfield(["detail", "formData"], decode.list(field()))

  // Dispatch on submitted state.
  case fields_with_roles(listed, profiles, models) {
    Ok(#(name, sharing, roles)) ->
      decode.success(submit(workspace, name, sharing, roles))
    Error(Nil) ->
      decode.failure(
        submit(workspace, "", Private, creations.default_roles),
        "creation form",
      )
  }
}

/// The folder form's decoder, refused unless `typed_fields_with_roles` accepts
/// the list.
fn typed_submitted(
  submit: fn(String, String, Sharing, Roles) -> message,
  profiles: List(String),
  models: List(String),
  recent: List(String),
) -> decode.Decoder(message) {
  use listed <- decode.subfield(["detail", "formData"], decode.list(field()))

  // Dispatch on typed_submitted state.
  case typed_fields_with_roles(listed, profiles, models, recent) {
    Ok(#(path, name, sharing, roles)) ->
      decode.success(submit(path, name, sharing, roles))
    Error(Nil) ->
      decode.failure(
        submit("", "", Private, creations.default_roles),
        "folder form",
      )
  }
}

/// The registered-workspace form's decoder, refused unless
/// `remote_fields_with_roles` accepts the list.
fn remote_submitted(
  submit: fn(String, String, Roles) -> message,
  workspaces: List(String),
  profiles: List(String),
  models: List(String),
) -> decode.Decoder(message) {
  use listed <- decode.subfield(["detail", "formData"], decode.list(field()))

  // Dispatch on remote_submitted state.
  case remote_fields_with_roles(listed, workspaces, profiles, models) {
    Ok(#(workspace, name, roles)) ->
      decode.success(submit(workspace, name, roles))
    Error(Nil) ->
      decode.failure(
        submit("", "", creations.default_roles),
        "registered workspace form",
      )
  }
}

fn field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}

/// The name and sharing a submitted form's fields stand for, or a refusal:
/// exactly one `name`, at most one `shareable` whose value is the browser's
/// `on`, and no other field. An unticked box is not sent, so its absence is
/// `Private`.
///
/// ## Examples
///
/// ```gleam
/// assert create.fields([#("name", "review")]) == Ok(#("review", creations.Private))
/// assert create.fields([#("name", ""), #("shareable", "on")])
///   == Ok(#("", creations.Shareable))
/// ```
pub fn fields(
  listed: List(#(String, String)),
) -> Result(#(String, Sharing), Nil) {
  let names = list.filter(listed, fn(field) { field.0 == "name" })
  let boxes = list.filter(listed, fn(field) { field.0 == "shareable" })

  // Dispatch on fields state.
  case names, boxes, list.length(listed) {
    [#(_, name)], [], 1 -> Ok(#(name, Private))
    [#(_, name)], [#(_, "on")], 2 -> Ok(#(name, Shareable))
    _, _, _ -> Error(Nil)
  }
}

/// The path, name and sharing a submitted folder form's fields stand for, or a
/// refusal: exactly one `path`, exactly one `name`, at most one `shareable`
/// whose value is the browser's `on`, and no other field. It is `fields` with
/// the path the form adds, and as strict, so the workspace becomes a field in
/// this one form and in no other.
///
/// ## Examples
///
/// ```gleam
/// assert create.typed_fields([#("path", "~/app"), #("name", "")])
///   == Ok(#("~/app", "", creations.Private))
/// assert create.typed_fields([#("path", "~/a"), #("path", "~/b"), #("name", "")])
///   == Error(Nil)
/// ```
pub fn typed_fields(
  listed: List(#(String, String)),
) -> Result(#(String, String, Sharing), Nil) {
  let paths = list.filter(listed, fn(field) { field.0 == "path" })
  let rest = list.filter(listed, fn(field) { field.0 != "path" })

  // Dispatch on typed_fields state.
  case paths, fields(rest) {
    [#(_, path)], Ok(#(name, sharing)) -> Ok(#(path, name, sharing))
    _, _ -> Error(Nil)
  }
}

/// The name, sharing and roles a submitted form's fields stand for, given the
/// profile names and model keys the form offered: `fields`, plus at most one
/// `profile` and at most one `model`, each of whose value is the empty string
/// (the default) or the position of one of the matching list, which is turned
/// back into the name or key here. A `profile` field when no profiles were
/// offered (likewise `model`), a position outside its list and any other text
/// refuse the event, so the browser can pick among the texts the page drew and
/// name no other.
///
/// ## Examples
///
/// ```gleam
/// assert create.fields_with_roles(
///     [#("name", "x"), #("profile", "1"), #("model", "0")],
///     ["a", "b"],
///     ["fast"],
///   )
///   == Ok(#("x", creations.Private, creations.Roles(Some("b"), Some("fast"))))
/// assert create.fields_with_roles([#("name", "x"), #("profile", "")], ["a"], [])
///   == Ok(#("x", creations.Private, creations.default_roles))
/// assert create.fields_with_roles([#("name", "x"), #("model", "2")], [], ["a"])
///   == Error(Nil)
/// ```
pub fn fields_with_roles(
  listed: List(#(String, String)),
  profiles: List(String),
  models: List(String),
) -> Result(#(String, Sharing, Roles), Nil) {
  use #(rest, roles) <- result.try(chosen_roles(listed, profiles, models))
  use #(name, sharing) <- result.map(fields(rest))
  #(name, sharing, roles)
}

/// The path, name, sharing and roles a submitted folder form's fields stand
/// for: `typed_fields` with the roles `fields_with_roles` reads, and at most one
/// `folder` whose value is the empty string or the position of one of the
/// remembered folders the form offered. A path typed in the field wins; when it
/// is empty the remembered folder is the path. A `folder` field when none was
/// offered, or a position outside the list, refuses the event.
///
/// ## Examples
///
/// ```gleam
/// assert create.typed_fields_with_roles(
///     [#("path", "~/app"), #("name", ""), #("profile", "0")],
///     ["a"],
///     [],
///     [],
///   )
///   == Ok(#("~/app", "", creations.Private, creations.Roles(Some("a"), None)))
/// assert create.typed_fields_with_roles(
///     [#("folder", "1"), #("path", ""), #("name", "")],
///     [],
///     [],
///     ["/h/a", "/h/b"],
///   )
///   == Ok(#("/h/b", "", creations.Private, creations.default_roles))
/// ```
pub fn typed_fields_with_roles(
  listed: List(#(String, String)),
  profiles: List(String),
  models: List(String),
  recent: List(String),
) -> Result(#(String, String, Sharing, Roles), Nil) {
  use #(rest, roles) <- result.try(chosen_roles(listed, profiles, models))
  use picked <- result.try(chosen(
    list.filter(rest, fn(field) { field.0 == "folder" }),
    recent,
  ))
  use #(path, name, sharing) <- result.map(
    typed_fields(list.filter(rest, fn(field) { field.0 != "folder" })),
  )

  // Dispatch on typed_fields_with_roles state.
  case picked, path {
    Some(folder), "" -> #(folder, name, sharing, roles)
    Some(_), _ | None, _ -> #(path, name, sharing, roles)
  }
}

/// Splits the `profile` and `model` entries from a form's fields and reads each
/// against its own offered list. What remains is the fields the older decoders
/// judge, so they stay as strict as they were.
fn chosen_roles(
  listed: List(#(String, String)),
  profiles: List(String),
  models: List(String),
) -> Result(#(List(#(String, String)), Roles), Nil) {
  let rest =
    list.filter(listed, fn(field) { field.0 != "profile" && field.0 != "model" })
  use profile <- result.try(chosen(
    list.filter(listed, fn(field) { field.0 == "profile" }),
    profiles,
  ))
  use model <- result.map(chosen(
    list.filter(listed, fn(field) { field.0 == "model" }),
    models,
  ))
  #(rest, creations.Roles(profile:, model:))
}

/// The text a form's entries for one select choose: none sent is the default, one
/// with an empty value is the default, and one whose value is the position of an
/// offered text is that text. Two entries, or any other value, is a refusal, and
/// so is any entry at all when nothing was offered.
fn chosen(
  entries: List(#(String, String)),
  offered: List(String),
) -> Result(Option(String), Nil) {
  case entries {
    [] -> Ok(None)
    [#(_, "")] if offered != [] -> Ok(None)
    [#(_, position)] -> at(position, offered) |> result.map(Some)
    [_, _, ..] -> Error(Nil)
  }
}

// The offered text a position names, or a refusal for anything that is not the
// position of one.
fn at(position: String, offered: List(String)) -> Result(String, Nil) {
  case int.parse(position) {
    Ok(index) if index >= 0 -> list.drop(offered, index) |> list.first
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

/// The workspace name and session name a submitted registered-workspace form's
/// fields stand for: exactly one `workspace`, exactly one `name`, and no other
/// field. When the form offered workspaces the value is the position of one of
/// them and is turned back into the name here. When it offered none the value is
/// the typed name, which must satisfy `creations.registered_name` (the grammar
/// the daemon applies) and is returned trimmed. The executor or pool is not a field:
/// it is the card the person chose, which the page recorded, so a forged
/// `executor` or `pool` field is refused with any other extra one. The browser
/// can name only a workspace the page drew, and the daemon judges it again.
///
/// ## Examples
///
/// ```gleam
/// assert create.remote_fields([#("workspace", "1"), #("name", "")], ["a", "app"])
///   == Ok(#("app", ""))
/// assert create.remote_fields(
///     [#("workspace", "0"), #("name", ""), #("executor", "0")],
///     ["app"],
///   )
///   == Error(Nil)
/// assert create.remote_fields([#("workspace", "3"), #("name", "")], ["app"])
///   == Error(Nil)
/// assert create.remote_fields([#("workspace", " app "), #("name", "")], [])
///   == Ok(#("app", ""))
/// assert create.remote_fields([#("workspace", "/w/app"), #("name", "")], [])
///   == Error(Nil)
/// ```
pub fn remote_fields(
  listed: List(#(String, String)),
  workspaces: List(String),
) -> Result(#(String, String), Nil) {
  let chosen = list.filter(listed, fn(field) { field.0 == "workspace" })
  let names = list.filter(listed, fn(field) { field.0 == "name" })

  // Dispatch on remote_fields state.
  case chosen, names, list.length(listed) {
    [#(_, text)], [#(_, name)], 2 -> {
      // Find workspace by registered name or from known list.
      let found = case workspaces {
        [] -> creations.registered_name(text)
        _ -> at(text, workspaces)
      }

      result.map(found, fn(workspace) { #(workspace, name) })
    }
    _, _, _ -> Error(Nil)
  }
}

/// The workspace, session name and roles a submitted registered-workspace
/// form's fields stand for: `remote_fields` with the roles `fields_with_roles`
/// reads from the profile and model lists the form offered.
///
/// ## Examples
///
/// ```gleam
/// assert create.remote_fields_with_roles(
///     [#("workspace", "0"), #("name", ""), #("model", "0")],
///     ["app"],
///     [],
///     ["fast"],
///   )
///   == Ok(#("app", "", creations.Roles(None, Some("fast"))))
/// ```
pub fn remote_fields_with_roles(
  listed: List(#(String, String)),
  workspaces: List(String),
  profiles: List(String),
  models: List(String),
) -> Result(#(String, String, Roles), Nil) {
  use #(rest, roles) <- result.try(chosen_roles(listed, profiles, models))
  use #(workspace, name) <- result.map(remote_fields(rest, workspaces))
  #(workspace, name, roles)
}

/// The workspace a form is open for, if one is, which the component's update
/// uses to refuse a submit for a form that is not the open one. The new-session
/// form is open for no workspace.
///
/// ## Examples
///
/// ```gleam
/// assert create.open_for(create.Composing("/w")) == Some("/w")
/// assert create.open_for(create.Elsewhere) == None
/// ```
pub fn open_for(state: State) -> Option(String) {
  case state {
    Idle | Elsewhere | Sending | Chosen(_) | Dispatching(_) -> None
    Composing(workspace:) | Waiting(workspace:) -> Some(workspace)
  }
}
