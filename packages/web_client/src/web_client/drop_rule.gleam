//// The rules of dragging image files onto the operator composer, as
//// functions of what a drag carries and how many of the composer's elements
//// the pointer is inside (protocol-change/051, the addendum on images).
////
//// A drag is only the operator's business here when it carries files. A
//// text drag into the editor, a link, a selection moved between fields: each
//// is the browser's own and is never cancelled, or the textarea would stop
//// accepting them. A drag that does carry files is cancelled wherever it
//// lands, because the browser's default for a dropped file is to navigate
//// the tab to it and lose the page; that holds for a composer that cannot
//// attach too, which cancels the drop and attaches nothing.
////
//// The browser raises `dragenter` and `dragleave` for every element the
//// pointer crosses, so moving over the composer's own children leaves it
//// and enters it again. A leave therefore ends the drag only when the
//// element the pointer moved to is outside the composer, or there is none
//// (`Destination`). A count of enters and leaves would be wrong whenever the
//// server replaces the element under the pointer mid-drag, since that
//// element never fires its leave; deciding from where the pointer went
//// needs no count, and the next enter, or a drop or drag end anywhere on the
//// page, sets the state right again.
////
//// What a dropped file may be is not decided here. The drop goes through
//// `attach_rule.choose`, the same vetting a paste and the file picker take,
//// so the limits and the refusal words are one set.
////
//// This module imports neither Lustre nor the DOM, so its decisions run
//// under Node in `drop_test`. `web_client/attach` is the element that
//// listens, and `web_client/drop_guard` is the page-wide listener.

import gleam/list
import web_client/attach_rule

/// The entry `dataTransfer.types` holds for a drag that carries files.
pub const files_type = "Files"

/// Whether a file drag is over the composer.
pub type Drag {
  /// A file drag is over the composer.
  Over

  /// No file drag is over the composer.
  Away
}

/// The state of a pointer that is not dragging files over the composer.
pub const away = Away

/// Where the pointer went when a drag left an element of the composer.
pub type Destination {
  /// To another element of the composer, so the drag is still over it.
  Within

  /// To an element outside the composer, or to nothing (the pointer left the
  /// window, or the browser reports no target).
  Beyond
}

/// Whether a drag carries files, from the types its data transfer lists.
///
/// ## Examples
///
/// ```gleam
/// assert drop_rule.carries_files(["text/plain", "Files"])
/// assert !drop_rule.carries_files(["text/plain"])
/// ```
pub fn carries_files(types: List(String)) -> Bool {
  list.contains(types, files_type)
}

/// The state after a `dragenter` from a drag with these types. A drag
/// without files changes nothing.
///
/// ## Examples
///
/// ```gleam
/// assert drop_rule.entered(drop_rule.away, ["Files"]) == drop_rule.Over
/// ```
pub fn entered(drag: Drag, types: List(String)) -> Drag {
  case carries_files(types) {
    True -> Over
    False -> drag
  }
}

/// The state after a `dragleave` from a drag with these types, towards
/// `towards`. Only a file drag that went beyond the composer is away; one
/// that went to another element of it, and any drag without files, changes
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// assert drop_rule.left(drop_rule.Over, ["Files"], drop_rule.Beyond) == drop_rule.Away
/// ```
pub fn left(drag: Drag, types: List(String), towards: Destination) -> Drag {
  case carries_files(types), towards {
    True, Beyond -> Away
    _, _ -> drag
  }
}

/// The state after a drop or a drag's end, which no `dragleave` need follow.
///
/// ## Examples
///
/// ```gleam
/// assert drop_rule.dropped(drop_rule.Over) == drop_rule.away
/// ```
pub fn dropped(_drag: Drag) -> Drag {
  Away
}

/// What the composer draws while files are dragged over it, as the element's
/// state decides it.
pub type Surface {
  /// The drop state: a tint and a hint that images can be dropped.
  Inviting

  /// Nothing: no drag is over the composer, or nothing more can be attached.
  Plain
}

/// The surface for a drag state and whether the composer has a place left for an
/// image.
///
/// ## Examples
///
/// ```gleam
/// assert drop_rule.surface(drop_rule.Over, drop_rule.Room) == drop_rule.Inviting
/// assert drop_rule.surface(drop_rule.Over, drop_rule.Full) == drop_rule.Plain
/// ```
pub fn surface(drag: Drag, places: Places) -> Surface {
  case drag, places {
    Over, Room -> Inviting
    _, _ -> Plain
  }
}

/// Whether the composer has a place for another image.
pub type Places {
  /// At least one place is free.
  Room

  /// Every place is taken, or the page was told no limits.
  Full
}

/// Whether the element has a place for another image, as the attach rules'
/// own `full` decides it. An element told no limits has none.
///
/// ## Examples
///
/// ```gleam
/// assert drop_rule.places(attach_rule.start()) == drop_rule.Full
/// ```
pub fn places(state: attach_rule.State) -> Places {
  case attach_rule.full(state) {
    True -> Full
    False -> Room
  }
}
