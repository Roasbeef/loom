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
//// and enters it again. The element therefore counts the elements it is
//// inside, as a depth, and shows its drop state while that depth is above
//// zero. A `drop` resets the depth, since no `dragleave` follows it.
////
//// What a dropped file may be is not decided here. The drop goes through
//// `attach_rule.choose`, the same vetting a paste and the file picker take,
//// so the limits and the refusal words are one set.
////
//// This module imports neither Lustre nor the DOM, so its decisions run
//// under Node in `drop_test`. `web_client/attach` is the element that
//// listens, and `web_client/drop_guard` is the page-wide listener.

import gleam/int
import gleam/list
import web_client/attach_rule

/// The entry `dataTransfer.types` holds for a drag that carries files.
pub const files_type = "Files"

/// How many of the composer's elements the pointer is inside while it drags
/// files, as `dragenter` and `dragleave` report it. It is never below zero.
pub type Depth {
  Depth(inside: Int)
}

/// A pointer that is not dragging over the composer.
pub const outside = Depth(inside: 0)

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

/// The depth after a `dragenter` from a drag with these types. A drag
/// without files changes nothing.
///
/// ## Examples
///
/// ```gleam
/// assert drop_rule.entered(drop_rule.outside, ["Files"]) == drop_rule.Depth(1)
/// ```
pub fn entered(depth: Depth, types: List(String)) -> Depth {
  case carries_files(types) {
    True -> Depth(inside: depth.inside + 1)
    False -> depth
  }
}

/// The depth after a `dragleave` from a drag with these types. A drag without
/// files changes nothing, and the depth stops at zero, so a `dragleave`
/// whose `dragenter` was missed cannot leave it negative.
///
/// ## Examples
///
/// ```gleam
/// assert drop_rule.left(drop_rule.outside, ["Files"]) == drop_rule.outside
/// ```
pub fn left(depth: Depth, types: List(String)) -> Depth {
  case carries_files(types) {
    True -> Depth(inside: int.max(depth.inside - 1, 0))
    False -> depth
  }
}

/// The depth after a drop, which no `dragleave` follows.
///
/// ## Examples
///
/// ```gleam
/// assert drop_rule.dropped(drop_rule.Depth(2)) == drop_rule.outside
/// ```
pub fn dropped(_depth: Depth) -> Depth {
  outside
}

/// What the composer draws while files are dragged over it, as the element's
/// state decides it.
pub type Surface {
  /// The drop state: a tint and a hint that images can be dropped.
  Inviting

  /// Nothing: no drag is over the composer, or nothing more can be attached.
  Plain
}

/// The surface for a depth and whether the composer has a place left for an
/// image.
///
/// ## Examples
///
/// ```gleam
/// assert drop_rule.surface(drop_rule.Depth(1), drop_rule.Room) == drop_rule.Inviting
/// assert drop_rule.surface(drop_rule.Depth(1), drop_rule.Full) == drop_rule.Plain
/// ```
pub fn surface(depth: Depth, places: Places) -> Surface {
  case depth.inside > 0, places {
    True, Room -> Inviting
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
