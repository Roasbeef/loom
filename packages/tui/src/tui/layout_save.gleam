//// Joining the terminal's layout to its memory file.
////
//// `layout_memory` is the file and its decoder, over plain values. This
//// module is the part that knows the model: it applies what the file
//// remembered when a terminal starts, and after each step it notices that the
//// layout the person chose has changed and asks the runtime to save it.
////
//// ## Flow
////
//// `remember_launch` → `apply` → `settle`
////
//// 1. `remember_launch` runs once, in the launcher, before the loop. It
////    names the file under the state root, reads it (total: an unreadable
////    file is the default layout), and applies the workspace's remembered
////    rail choice to the model through `apply`. A launch that keeps nothing, such as a replay
////    or the demo, never calls it, so its model has no target and neither
////    reads nor writes a file.
//// 2. `settle` runs at the end of every step. It compares the layout the
////    model has now with the one last saved and queues a `SaveLayout` effect
////    only when they differ, so a tick, a keystroke in the composer or a
////    scroll writes nothing. A toggle of the rail is one write.
////
//// The remembered layout is only the choices a person made. A workspace
//// whose rail was never toggled has no entry, and `settle` does not create
//// one: with no remembered choice and the default rail, the layout is still
//// the default.

import filepath
import gleam/option.{None, Some}
import gleam/result
import host/bootstrap as host_bootstrap
import tui/bootstrap
import tui/effect
import tui/layout_memory.{type Layout, Layout, Target}
import tui/model.{type Model, Model, View} as tui_model
import tui/view_set

/// Reads the layout memory under the state root and applies this
/// workspace's layout to the model.
///
/// `state_override` is the operator's `--state-dir`, empty for the default
/// `~/.loom`. If the state root cannot be resolved the model keeps no
/// target and the layout simply is not remembered.
///
/// ## Examples
///
/// ```gleam
/// let model = layout_save.remember_launch(model, "")
/// ```
pub fn remember_launch(model: Model, state_override: String) -> Model {
  case bootstrap.state_directory(state_override) {
    Error(_) -> model
    Ok(root) -> {
      let path = filepath.join(filepath.join(root, "tui"), "layout.json")
      let key = layout_memory.workspace_key(absolute(model.view.workspace.path))
      let saved = layout_memory.lookup(layout_memory.load(path), key)
      apply(model, Target(path:, key:, saved:))
    }
  }
}

// The workspace path made absolute, so `loom --workspace .` is keyed by the
// directory it names and not by the one-character string. A path that cannot
// be resolved is keyed as given.
fn absolute(path: String) -> String {
  host_bootstrap.absolute_path(path) |> result.unwrap(path)
}

/// The model with `target`'s remembered layout in force and `target` kept
/// to compare later changes with.
///
/// ## Examples
///
/// ```gleam
/// let model = layout_save.apply(model, target)
/// ```
pub fn apply(model: Model, target: layout_memory.Target) -> Model {
  Model(
    ..model,
    view: View(
      ..{
        model.view
        |> view_set.rail(target.saved.rail)
      },
      rail_tab: target.saved.tab,
      layout_target: Some(target),
    ),
  )
}

/// Queues a save when the layout is no longer the one last saved.
///
/// ## Examples
///
/// ```gleam
/// let model = layout_save.settle(model)
/// ```
pub fn settle(model: Model) -> Model {
  case model.view.layout_target {
    None -> model
    Some(target) -> {
      let current = current(model)
      case current == target.saved {
        True -> model
        False ->
          Model(
            ..model,
            view: View(
              ..model.view,
              layout_target: Some(Target(..target, saved: current)),
            ),
          )
          |> tui_model.emit(effect.SaveLayout(
            path: target.path,
            key: target.key,
            layout: current,
          ))
      }
    }
  }
}

// The layout the model has now: the operator's choices about the rail and
// its tab, each none until it is made, so a workspace nobody touched stays
// out of the file.
fn current(model: Model) -> Layout {
  Layout(rail: model.view.rail, tab: model.view.rail_tab)
}
