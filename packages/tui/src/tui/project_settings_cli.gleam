//// `loom project settings`, `set`, `unset` and the setting half of `init`
//// (protocol-change/106, "Settings held per project").
////
//// A person sets a project up without opening `loom.toml`. The daemon holds
//// the settings, so each verb here is a short conversation with it: read the
//// settings for their revision, send the change that names it, and print what
//// the daemon says is now in force. `init` adds the step that makes setting up
//// cheap: it asks the daemon to propose `setup` and `check` from the
//// repository, and either asks the person at a terminal to confirm each, or,
//// when no one can be asked, prints what it would use and the command that
//// sets it. Nothing a proposal says is applied until a person answers yes or
//// types their own command.
////
//// The daemon is reached through a function the caller passes, so this module
//// holds no connection and is tested against a stand-in.
////
//// ## Flow
////
//// `show` / `set` / `unset` / `init_settings` → `send`

import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/project_settings_view as view

/// One `projects.*` round trip: the command and its fields, and the reply body
/// or the daemon's own sentence.
pub type Request =
  fn(String, List(#(String, JsonValue))) -> Result(JsonValue, String)

/// Asks the person one question. It refuses when no one can answer, which is
/// how a pipeline is told from a terminal.
pub type Ask =
  fn(String) -> Result(String, String)

/// `loom project settings`: every key with its value and where it came from.
///
/// ## Examples
///
/// ```gleam
/// // project_settings_cli.show(request, "p-0123456789ab")
/// ```
pub fn show(request: Request, project: String) -> Result(String, String) {
  use settings <- result.map(read(request, project))
  string.join(view.lines(settings), "\n")
}

/// `loom project set <key> <value>...`: holds a value for the project. Turning
/// `publish` on takes `--publish-to <url>` naming the URL the settings show,
/// and without it the command says where publishing would go and changes
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// // project_settings_cli.set(request, "p-0123456789ab", "check", ["make check"], None)
/// ```
pub fn set(
  request: Request,
  project: String,
  key: String,
  values: List(String),
  publish_to: Option(String),
) -> Result(String, String) {
  use settings <- result.try(read(request, project))
  use Nil <- result.try(confirm_publish(settings, key, values, publish_to))
  send(request, settings, [#(key, Some(values))], publish_to)
}

/// `loom project unset <key>`: gives a key back to `loom.toml`'s value.
///
/// ## Examples
///
/// ```gleam
/// // project_settings_cli.unset(request, "p-0123456789ab", "check")
/// ```
pub fn unset(
  request: Request,
  project: String,
  key: String,
) -> Result(String, String) {
  use settings <- result.try(read(request, project))
  send(request, settings, [#(key, None)], None)
}

/// The setting half of `loom project init`. With `--check` or `--setup` it
/// holds those values and prints what is in force. With neither it asks the
/// daemon for a proposal, then asks the person to confirm each key or type
/// another command, and when the person cannot be asked it prints what it
/// would use and the command that sets it.
///
/// ## Examples
///
/// ```gleam
/// // project_settings_cli.init_settings(request, ask, "p-0123456789ab", None, None)
/// ```
pub fn init_settings(
  request: Request,
  ask: Ask,
  project: String,
  check: Option(String),
  setup: Option(String),
) -> Result(String, String) {
  // Neither flag means the person is to be asked, and any flag is the answer.
  case check, setup {
    None, None -> propose_and_confirm(request, ask, project)
    _, _ -> {
      use settings <- result.try(read(request, project))
      let changes =
        list.filter_map([#("check", check), #("setup", setup)], fn(each) {
          case each.1 {
            Some(command) -> Ok(#(each.0, Some([command])))
            None -> Error(Nil)
          }
        })
      send(request, settings, changes, None)
    }
  }
}

/// Reads the daemon's proposal and turns each key into a confirmed change, a
/// skip, or a line saying how to set it.
fn propose_and_confirm(
  request: Request,
  ask: Ask,
  project: String,
) -> Result(String, String) {
  use body <- result.try(request("projects.propose", named(project)))
  use proposed <- result.try(view.decode_proposed(body))
  let asked =
    list.map([#("check", proposed.check), #("setup", proposed.setup)], fn(each) {
      confirm_key(ask, each.0, each.1)
    })
  let chosen =
    list.filter_map(asked, fn(each) {
      case each.0 {
        Some(change) -> Ok(change)
        None -> Error(Nil)
      }
    })
  let words = list.flat_map(asked, fn(each) { each.1 })
  let notes = list.map(proposed.notes, fn(note) { "note: " <> note })

  // Nothing confirmed means nothing is sent, and the lines say why.
  case chosen {
    [] -> Ok(string.join(list.append(words, notes), "\n"))
    _ -> {
      use settings <- result.try(read(request, project))
      use applied <- result.map(send(request, settings, chosen, None))
      string.join(list.flatten([words, notes, [applied]]), "\n")
    }
  }
}

/// One key's confirmation. A person at a terminal answers yes to use the
/// proposal, no to leave the key, or types the command to hold instead. A
/// caller no one can answer gets the sentence that says what to run.
fn confirm_key(
  ask: Ask,
  key: String,
  found: Option(view.Suggestion),
) -> #(Option(#(String, Option(List(String)))), List(String)) {
  // A key with no proposal has nothing to confirm.
  case found {
    None -> #(None, [
      key
      <> ": nothing in this repository suggests one; set it with "
      <> set_command(key, "<command>"),
    ])
    Some(suggestion) -> ask_about(ask, key, suggestion)
  }
}

/// Asks about one proposal. A caller no one can answer gets the sentence that
/// says what the proposal was and what to run.
fn ask_about(
  ask: Ask,
  key: String,
  suggestion: view.Suggestion,
) -> #(Option(#(String, Option(List(String)))), List(String)) {
  let prompt =
    key
    <> " = `"
    <> suggestion.command
    <> "` ("
    <> suggestion.because
    <> "). Use it? [Y/n, or type another command] "

  // A refusal to ask is not an answer, so nothing is held.
  case ask(prompt) {
    Error(_) -> #(None, [
      key
      <> ": would use `"
      <> suggestion.command
      <> "` ("
      <> suggestion.because
      <> "); set it with "
      <> set_command(key, suggestion.command),
    ])
    Ok(reply) -> answered(key, suggestion, reply)
  }
}

/// What a person's reply to a proposal holds: yes (or nothing) the proposal, no
/// leaves the key, and anything else is the command they typed.
fn answered(
  key: String,
  suggestion: view.Suggestion,
  reply: String,
) -> #(Option(#(String, Option(List(String)))), List(String)) {
  // The words of a yes and a no are the only ones with a fixed meaning.
  case string.trim(reply) {
    "" | "y" | "Y" | "yes" -> #(Some(#(key, Some([suggestion.command]))), [])
    "n" | "N" | "no" -> #(None, [key <> ": left as it was"])
    own -> #(Some(#(key, Some([own]))), [])
  }
}

/// The command that holds a value for the project in the current directory.
fn set_command(key: String, value: String) -> String {
  "`loom project set " <> key <> " '" <> value <> "'`"
}

/// Refuses to turn `publish` on without the URL. The sentence says where the
/// host would publish and how to confirm it, so a person reads the URL before
/// anything leaves the machine.
fn confirm_publish(
  settings: view.Settings,
  key: String,
  values: List(String),
  publish_to: Option(String),
) -> Result(Nil, String) {
  let on = values == ["pull_request"]
  let off_now =
    list.any(settings.settings, fn(each) {
      each.key == "publish" && each.value == ["off"]
    })

  // Only the change from off to on needs the URL named; the daemon checks it
  // again, so this refusal is for the person, not the safety.
  case key == "publish" && on && off_now, settings.publish_url, publish_to {
    False, _, _ -> Ok(Nil)
    True, None, _ ->
      Error("this project has no remote, so there is nowhere to publish to")
    True, Some(_), Some(_) -> Ok(Nil)
    True, Some(url), None ->
      Error(
        "publish would push verified branches to "
        <> url
        <> " and open pull requests there. To turn it on, run the command again with --publish-to "
        <> url,
      )
  }
}

/// Reads and decodes the project's settings.
fn read(request: Request, project: String) -> Result(view.Settings, String) {
  request("projects.settings", named(project))
  |> result.try(view.decode_settings)
}

/// Sends changes naming the revision that was read, and prints the settings
/// the daemon says are in force.
fn send(
  request: Request,
  settings: view.Settings,
  changes: List(#(String, Option(List(String)))),
  publish_to: Option(String),
) -> Result(String, String) {
  let encoded =
    json.Array(
      list.map(changes, fn(each) {
        json.Object([
          #("key", json.String(each.0)),
          #("value", case each.1 {
            Some(words) -> json.Array(list.map(words, json.String))
            None -> json.Null
          }),
        ])
      }),
    )
  let fields = [
    #("project", json.String(settings.project)),
    #("revision", json.Int(settings.revision)),
    #("changes", encoded),
    ..case publish_to {
      Some(url) -> [#("publish_to", json.String(url))]
      None -> []
    }
  ]
  use body <- result.try(request("projects.set_settings", fields))
  use now <- result.map(view.decode_settings(body))
  string.join(view.lines(now), "\n")
}

fn named(project: String) -> List(#(String, JsonValue)) {
  [#("project", json.String(project))]
}
