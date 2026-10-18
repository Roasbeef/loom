//// The queue editor's custody of a draft, over generated host sessions.
////
//// A queued input is edited from a complete authoritative document, and the
//// editor holds one draft whose text must survive everything the lane can do
//// around it: a read that is answered, a read that is dropped, a save that is
//// refused, acknowledged or lost. Two modules share the work. `session_view/
//// queue_request` correlates the lane's replies with the one read this
//// client issued, and `tui/queue_editor` folds what the lane did into the
//// draft. The terminal drives them from `tui/interaction`, `session_view/
//// surfaces`, `session_view/outbound` and `session_view/event_fold`, each of
//// which writes the same few record updates and calls `receive` and `show`.
//// This test replays those updates as commands against the two real modules,
//// so a draft's custody is checked over the orderings the host can produce.
////
//// A command is one thing the host does: select an input (a read is wanted),
//// issue the read, receive a document, type, save, refetch, or the lane's
//// verdict on a save (acknowledged, refused, lost) or on a wanted read (dropped).
//// The queue holds three inputs and a reply can come from the attachment
//// that asked or from another attachment or namespace, so every reply meets
//// every read. Typing is allowed only for an editable draft, as the host
//// allows it, which is the rule "uncertainty forbids another mutation"
//// at its first line. The system under test is the two states together; the
//// abstract model is empty, because every command is meaningful in every
//// state and the rules compare the states before and after one command.
////
//// The rules, by tag:
////
//// - `admit`: a received document is admitted exactly when it answers the
////   outstanding read by owner, namespace, strand and identity
////   (`queue_request.receive`); admitting it settles that read, and a reply
////   that is not admitted changes neither state, so a document is taken once.
//// - `keep`: an admitted document for the draft's own input keeps the text
////   the operator typed, takes the new revision and returns the draft to
////   editable (`queue_editor.receive`: "An uncertain draft stays intact when
////   the authoritative value differs").
//// - `replace`: an admitted document for any other input becomes a fresh
////   draft with the document's text.
//// - `uncertain`: a draft whose save has an unknown outcome stays locked
////   through everything but an explicit authoritative read or an
////   acknowledged save (`Delivery`: "only an explicit authoritative read can
////   reconcile it").
//// - `text`: no refusal, dropped read, lost save, selection, issue, refetch
////   or save changes the draft's text, and none discards the draft.
//// - `refused`: a definite refusal returns a draft awaiting its
////   acknowledgement to editable and ends every request in flight
////   (`queue_editor.refused`).
//// - `lost`: a save whose reply is lost locks whatever draft the editor holds
////   (`queue_editor.unknown`).
//// - `saved`: an acknowledged save forgets the draft and closes the editor.
//// - `saving`: a save from an editable draft marks it awaiting its
////   acknowledgement, and a save from any other draft changes nothing.
////
//// Each command is a plain value, and a schedule shrinks by deleting
//// commands and by moving each toward its first form: the first input, a
//// reply from the attachment that asked, the first text.

import etui/widgets/textarea
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import session_view/queue_request
import session_view/queued_input
import statem
import tui/queue_editor

// The attachment and queue namespace of the host that is asking, and the
// strand every queued input here belongs to.
const owner = "attachment-1"

const namespace = "queue-1"

const strand = "main"

const inputs = ["input-a", "input-b", "input-c"]

const texts = ["alpha", "beta", "gamma\nline two"]

/// Runs of the schedule check and the seed they come from. A schedule is up
/// to sixty commands.
const schedules = 400

const seed = 20_261_017

const longest_schedule = 60

// Which attachment or namespace a reply claims to be from.
type Origin {
  Asked
  OtherOwner
  OtherNamespace
}

type Command {
  // The operator selects an input, so a read of it is wanted.
  Select(input: Int)

  // The lane is free and issues the wanted read under request `id`.
  Issue(id: Int)

  // A queued-input document arrives.
  Receive(input: Int, origin: Origin, text: Int, revision: Int)

  // A character is typed into the editor.
  Type(char: String)

  // The last character is deleted.
  Backspace

  // Ctrl+s sends the draft.
  Save

  // Ctrl+r asks for the draft's input again.
  Refetch

  // The lane acknowledged the save.
  Acknowledge

  // The lane refused a frame.
  Refuse(reason: String)

  // The save's reply was lost.
  Lose

  // A wanted read was dropped before it was sent.
  Drop
}

// The host's two states together.
type Pair {
  Pair(request: queue_request.State, editor: queue_editor.State)
}

fn at(pool: List(String), index: Int) -> String {
  case list.drop(pool, index) {
    [value, ..] -> value
    [] -> ""
  }
}

fn fetch_of(input: Int) -> queue_request.Fetch {
  queue_request.Fetch(owner, namespace, strand, at(inputs, input))
}

fn document_of(input: Int, text: Int, revision: Int) -> queued_input.Document {
  queued_input.Document(
    id: at(inputs, input),
    strand:,
    revision:,
    kind: queued_input.Queue,
    text: at(texts, text),
    attachment_count: 0,
  )
}

fn draft_text(editor: queue_editor.State) -> Option(String) {
  option.map(editor.draft, fn(draft) { textarea.value(draft.input) })
}

fn delivery(editor: queue_editor.State) -> Option(queue_editor.Delivery) {
  option.map(editor.draft, fn(draft) { draft.delivery })
}

// --- the host's updates -----------------------------------------------------

// Each arm is the record update the host writes for the same event, taken
// from `interaction.select_queue_input`, `surfaces.service_queue_read`,
// `outbound.record_sent`, `event_fold.apply_event` and
// `interaction.save_queue_draft`, so the modules are driven through the
// states the host reaches and no other.
fn apply(pair: Pair, command: Command) -> Pair {
  case command {
    Select(input) ->
      Pair(
        queue_request.State(
          fetch: Some(fetch_of(input)),
          awaiting: None,
          request_id: None,
        ),
        pair.editor,
      )
    Issue(id) ->
      case pair.request.fetch {
        Some(fetch) ->
          Pair(
            queue_request.State(
              fetch: None,
              awaiting: Some(fetch),
              request_id: Some(id),
            ),
            pair.editor,
          )
        None -> pair
      }
    Receive(input, origin, text, revision) -> {
      let #(claimed_owner, claimed_namespace) = case origin {
        Asked -> #(owner, namespace)
        OtherOwner -> #("attachment-2", namespace)
        OtherNamespace -> #(owner, "queue-2")
      }
      let document = document_of(input, text, revision)
      case
        queue_request.receive(
          pair.request,
          claimed_owner,
          claimed_namespace,
          document,
        )
      {
        Ok(request) ->
          Pair(
            request,
            queue_editor.show(
              pair.editor,
              queue_request.Received(
                owner: claimed_owner,
                namespace: claimed_namespace,
                document:,
              ),
            ),
          )
        Error(Nil) -> pair
      }
    }
    Type(char) ->
      edited(pair, fn(input) {
        textarea.insert_char(textarea.textarea_new(), input, char)
      })
    Backspace -> edited(pair, textarea.backspace)
    Save ->
      case pair.editor.draft {
        Some(draft) if draft.delivery == queue_editor.Editable ->
          Pair(
            pair.request,
            queue_editor.State(
              ..pair.editor,
              draft: Some(
                queue_editor.Draft(..draft, delivery: queue_editor.Saving),
              ),
              message: "Saving this revision…",
            ),
          )
        Some(_) | None -> pair
      }
    Refetch ->
      case pair.editor.draft {
        Some(draft) if draft.delivery != queue_editor.Saving ->
          Pair(
            queue_request.State(
              ..pair.request,
              fetch: Some(queue_request.Fetch(
                owner,
                namespace,
                draft.document.strand,
                draft.document.id,
              )),
            ),
            pair.editor,
          )
        Some(_) | None -> pair
      }
    Acknowledge ->
      Pair(
        queue_request.new(),
        queue_editor.show(pair.editor, queue_request.Saved),
      )
    Refuse(reason) ->
      Pair(
        queue_request.new(),
        queue_editor.show(pair.editor, queue_request.Refused(reason)),
      )
    Lose ->
      Pair(pair.request, queue_editor.show(pair.editor, queue_request.Unknown))
    Drop ->
      Pair(
        queue_request.State(..pair.request, fetch: None),
        queue_editor.show(
          pair.editor,
          queue_request.Dropped("Attachment changed; select the input again"),
        ),
      )
  }
}

// Typing changes the draft only while it is editable, as the host's
// `edit_queue_text` allows.
fn edited(
  pair: Pair,
  edit: fn(textarea.TextAreaState) -> textarea.TextAreaState,
) -> Pair {
  case pair.editor.draft {
    Some(draft) if draft.delivery == queue_editor.Editable ->
      Pair(
        pair.request,
        queue_editor.State(
          ..pair.editor,
          draft: Some(queue_editor.Draft(..draft, input: edit(draft.input))),
        ),
      )
    Some(_) | None -> pair
  }
}

// --- the rules --------------------------------------------------------------

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

fn same(
  actual: a,
  expected: a,
  tag: String,
  detail: String,
) -> Result(Nil, statem.Violation) {
  case actual == expected {
    True -> Ok(Nil)
    False ->
      Error(violation(
        tag,
        detail
          <> ": expected "
          <> string.inspect(expected)
          <> ", got "
          <> string.inspect(actual),
      ))
  }
}

// Whether the read this client issued is the one a reply names.
fn answers(
  awaiting: Option(queue_request.Fetch),
  claimed_owner: String,
  claimed_namespace: String,
  document: queued_input.Document,
) -> Bool {
  awaiting
  == Some(queue_request.Fetch(
    claimed_owner,
    claimed_namespace,
    document.strand,
    document.id,
  ))
}

fn receive_rules(
  before: Pair,
  after: Pair,
  claimed_owner: String,
  claimed_namespace: String,
  document: queued_input.Document,
) -> Result(Nil, statem.Violation) {
  case
    answers(before.request.awaiting, claimed_owner, claimed_namespace, document)
  {
    False ->
      same(
        after,
        before,
        "admit",
        "a document that answers no read changed state",
      )
    True -> {
      use _ <- result.try(same(
        after.request,
        queue_request.State(..before.request, awaiting: None, request_id: None),
        "admit",
        "an admitted document did not settle its read",
      ))
      use _ <- result.try(same(
        delivery(after.editor),
        Some(queue_editor.Editable),
        "keep",
        "an admitted document left the draft locked",
      ))
      case before.editor.draft {
        Some(draft) if draft.document.id == document.id ->
          same(
            draft_text(after.editor),
            draft_text(before.editor),
            "keep",
            "an admitted document overwrote the operator's text",
          )
        Some(_) | None ->
          same(
            draft_text(after.editor),
            Some(document.text),
            "replace",
            "an admitted document for another input did not fill the draft",
          )
      }
    }
  }
}

// Everything but a received document, a keystroke and an acknowledgement
// leaves the draft's text alone and never discards it, and a locked draft
// stays locked through everything but a received document and an
// acknowledgement.
fn custody(
  before: Pair,
  command: Command,
  after: Pair,
) -> Result(Nil, statem.Violation) {
  let keeps_text = case command {
    Receive(..) | Type(_) | Backspace | Acknowledge -> False
    Select(_) | Issue(_) | Save | Refetch | Refuse(_) | Lose | Drop -> True
  }
  let keeps_lock = case command {
    Receive(..) | Acknowledge -> False
    Select(_)
    | Issue(_)
    | Type(_)
    | Backspace
    | Save
    | Refetch
    | Refuse(_)
    | Lose
    | Drop -> True
  }
  use _ <- result.try(case keeps_text {
    True ->
      same(
        draft_text(after.editor),
        draft_text(before.editor),
        "text",
        "a command that edits nothing changed the draft's text",
      )
    False -> Ok(Nil)
  })
  case keeps_lock, delivery(before.editor) {
    True, Some(queue_editor.Unknown) ->
      same(
        delivery(after.editor),
        Some(queue_editor.Unknown),
        "uncertain",
        "a draft with an unknown save outcome was unlocked",
      )
    _, _ -> Ok(Nil)
  }
}

fn rules(
  before: Pair,
  command: Command,
  after: Pair,
) -> Result(Nil, statem.Violation) {
  use _ <- result.try(custody(before, command, after))
  case command {
    Receive(input, origin, text, revision) -> {
      let #(claimed_owner, claimed_namespace) = case origin {
        Asked -> #(owner, namespace)
        OtherOwner -> #("attachment-2", namespace)
        OtherNamespace -> #(owner, "queue-2")
      }
      receive_rules(
        before,
        after,
        claimed_owner,
        claimed_namespace,
        document_of(input, text, revision),
      )
    }
    Acknowledge ->
      same(
        after,
        Pair(queue_request.new(), queue_editor.new()),
        "saved",
        "an acknowledged save left a draft or a request behind",
      )
    Refuse(_) -> {
      use _ <- result.try(same(
        after.request,
        queue_request.new(),
        "refused",
        "a refusal left a request in flight",
      ))
      case delivery(before.editor) {
        Some(queue_editor.Saving) ->
          same(
            delivery(after.editor),
            Some(queue_editor.Editable),
            "refused",
            "a refused save did not return to editable",
          )
        Some(_) | None -> Ok(Nil)
      }
    }
    Save ->
      case delivery(before.editor) {
        Some(queue_editor.Editable) ->
          same(
            delivery(after.editor),
            Some(queue_editor.Saving),
            "saving",
            "a save left the draft editable",
          )
        Some(_) | None ->
          same(
            after.editor,
            before.editor,
            "saving",
            "a save from a draft that cannot be saved changed it",
          )
      }
    Lose ->
      case after.editor.draft {
        Some(draft) ->
          same(
            draft.delivery,
            queue_editor.Unknown,
            "lost",
            "a save whose reply was lost left the draft unlocked",
          )
        None -> Ok(Nil)
      }
    Select(_) | Issue(_) | Type(_) | Backspace | Refetch | Drop -> Ok(Nil)
  }
}

// --- the spec ---------------------------------------------------------------

fn command() -> qcheck.Generator(Command) {
  let input = qcheck.bounded_int(0, 2)
  let origin =
    qcheck.from_weighted_generators(#(8, qcheck.constant(Asked)), [
      #(1, qcheck.constant(OtherOwner)),
      #(1, qcheck.constant(OtherNamespace)),
    ])
  qcheck.from_weighted_generators(#(12, qcheck.map(input, Select)), [
    #(12, qcheck.map(qcheck.bounded_int(1, 9), Issue)),
    #(
      24,
      qcheck.map4(
        input,
        origin,
        qcheck.bounded_int(0, 2),
        qcheck.bounded_int(1, 3),
        Receive,
      ),
    ),
    #(
      14,
      qcheck.from_generators(qcheck.constant("x"), [
        qcheck.constant("y"),
        qcheck.constant("z"),
      ])
        |> qcheck.map(Type),
    ),
    #(4, qcheck.constant(Backspace)),
    #(9, qcheck.constant(Save)),
    #(5, qcheck.constant(Refetch)),
    #(4, qcheck.constant(Acknowledge)),
    #(
      6,
      qcheck.from_generators(qcheck.constant("revision changed"), [
        qcheck.constant("lane busy"),
      ])
        |> qcheck.map(Refuse),
    ),
    #(5, qcheck.constant(Lose)),
    #(5, qcheck.constant(Drop)),
  ])
}

fn spec() -> statem.Spec(Nil, Command, Pair) {
  statem.Spec(
    initial: Nil,
    command: fn(_) { command() },
    precondition: fn(_, _) { statem.Admit },
    next_model: fn(model, _) { model },
    new_sut: fn() { Pair(queue_request.new(), queue_editor.new()) },
    execute: fn(pair, _, command) {
      let after = apply(pair, command)
      use _ <- result.try(rules(pair, command, after))
      Ok(after)
    },
    finish: fn(_, _) { Ok(Nil) },
    teardown: fn(_) { Nil },
  )
}

pub fn a_draft_survives_whatever_the_lane_does_around_it_test() {
  let config =
    statem.default_config(seed:)
    |> statem.with_test_count(schedules)
    |> statem.with_max_commands(longest_schedule)
  case statem.check(spec(), config) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, string.inspect)
  }
}

// A property that never reaches a locked draft or an admitted reply checks
// nothing, so a scripted schedule takes the whole path: a read, an edit, a
// save that is lost, a refetch that is answered with a different revision,
// and an acknowledgement.
pub fn the_whole_custody_path_holds_test() {
  let script = [
    Select(0),
    Issue(1),
    Receive(0, Asked, 0, 1),
    Type("x"),
    Save,
    Lose,
    Type("y"),
    Refetch,
    Issue(2),
    Receive(0, Asked, 1, 2),
    Type("z"),
    Save,
    Acknowledge,
  ]
  assert statem.replay(spec(), script) == Ok(Nil)
}
