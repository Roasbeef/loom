//// The JSON bodies of `projects.settings`, `projects.set_settings` and
//// `projects.propose` (protocol-change/106, "Settings held per project").
////
//// A page and the terminal draw the same body, so it carries what either
//// needs without a second request: the value in force for every key, where it
//// came from, who changed it and when, the revision a write must echo, and
//// the URL that publishing would send to. The decoders that read it are in
//// `session_view/project_settings_view`.

import client/project_overrides.{type Entry, type View}
import client/project_proposal.{type Proposal, type Proposals}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}

/// The reply body of a settings read or write.
///
/// ## Examples
///
/// ```gleam
/// // project_settings_wire.view_json("p1", view)
/// ```
pub fn view_json(project: String, view: View) -> JsonValue {
  json.Object([
    #("project", json.String(project)),
    #("revision", json.Int(view.revision)),
    #("publish_url", nullable_text(view.publish_url)),
    #("settings", json.Array(list.map(view.entries, entry_json))),
  ])
}

/// One key of the settings.
fn entry_json(entry: Entry) -> JsonValue {
  let #(by, at) = case entry.changed {
    Some(#(who, when)) -> #(json.String(who), json.Int(when))
    None -> #(json.Null, json.Null)
  }
  json.Object([
    #("key", json.String(project_overrides.key_word(entry.key))),
    #("value", json.Array(list.map(entry.values, json.String))),
    #("source", json.String(project_overrides.source_word(entry.source))),
    #("changed_by", by),
    #("changed_ms", at),
  ])
}

/// The reply body of a proposal. A key the table has no proposal for is null,
/// and the notes say what the table could not read.
///
/// ## Examples
///
/// ```gleam
/// // project_settings_wire.proposals_json("p1", proposals)
/// ```
pub fn proposals_json(project: String, proposals: Proposals) -> JsonValue {
  json.Object([
    #("project", json.String(project)),
    #("check", proposal_json(proposals.check)),
    #("setup", proposal_json(proposals.setup)),
    #("notes", json.Array(list.map(proposals.notes, json.String))),
  ])
}

/// One proposal or null.
fn proposal_json(proposal: Option(Proposal)) -> JsonValue {
  case proposal {
    None -> json.Null
    Some(found) ->
      json.Object([
        #("command", json.String(found.command)),
        #("because", json.String(found.because)),
      ])
  }
}

/// Text or null.
fn nullable_text(text: Option(String)) -> JsonValue {
  case text {
    Some(found) -> json.String(found)
    None -> json.Null
  }
}
