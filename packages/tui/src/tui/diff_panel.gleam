//// Diff navigation uses one geometry for painting, paging, and mouse hits.
//// The file list stays above the existing full-width patch renderer, while a
//// sticky selected-file row separates navigation labels from patch bytes.

import etui/geometry
import gleam/int

/// The exact rectangles and visible-list offset for one diff panel.
@internal
pub type Layout {
  Layout(
    /// Observation and focus controls at the top of the panel.
    heading: geometry.Rect,
    /// Bounded file navigation rows.
    navigation: geometry.Rect,
    /// Sticky selected-file identity and extent.
    selected: geometry.Rect,
    /// Existing unified-patch projection viewport.
    patch: geometry.Rect,
    /// First navigation index painted in the bounded list.
    navigation_offset: Int,
  )
}

/// Divides available content while preserving at least one patch row.
///
/// ## Examples
///
/// ```gleam
/// // diff_panel.layout(area, 4, 0)
/// ```
@internal
pub fn layout(area: geometry.Rect, labels: Int, selected: Int) -> Layout {
  let heading_height = case area.size.height < 8 {
    True -> int.min(1, area.size.height)
    False -> int.min(2, area.size.height)
  }
  let remaining = int.max(0, area.size.height - heading_height)
  let navigation_limit = case area.size.height {
    height if height < 8 -> 1
    height if height < 10 -> 2
    _ -> 6
  }
  let navigation_height =
    int.min(int.min(navigation_limit, labels), int.max(0, remaining - 2))
  let selected_height = case remaining - navigation_height > 0 {
    True -> 1
    False -> 0
  }
  let patch_height = int.max(0, remaining - navigation_height - selected_height)
  let navigation_offset =
    int.min(
      int.max(0, selected - navigation_height + 1),
      int.max(0, labels - navigation_height),
    )
  let heading =
    geometry.rect_new(
      area.position.x,
      area.position.y,
      area.size.width,
      heading_height,
    )
  let navigation =
    geometry.rect_new(
      area.position.x,
      area.position.y + heading_height,
      area.size.width,
      navigation_height,
    )
  let selected_area =
    geometry.rect_new(
      area.position.x,
      area.position.y + heading_height + navigation_height,
      area.size.width,
      selected_height,
    )
  let patch =
    geometry.rect_new(
      area.position.x,
      selected_area.position.y + selected_height,
      area.size.width,
      patch_height,
    )
  Layout(heading, navigation, selected_area, patch, navigation_offset)
}

/// Maps a mouse cell to a navigation index and excludes every header row.
///
/// ## Examples
///
/// ```gleam
/// // diff_panel.navigation_hit(layout, position, 4)
/// ```
@internal
pub fn navigation_hit(
  panel: Layout,
  at: geometry.Position,
  labels: Int,
) -> Result(Int, Nil) {
  case geometry.contains(panel.navigation, at) {
    False -> Error(Nil)
    True -> {
      let index = panel.navigation_offset + at.y - panel.navigation.position.y
      case index < labels {
        True -> Ok(index)
        False -> Error(Nil)
      }
    }
  }
}
