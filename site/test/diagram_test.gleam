//// The figures' drawings are data, and these tests are the reason that is
//// worth the trouble: a box id that names nothing, a link that points at a
//// box a layout leaves out, a step with no state for a box, two boxes drawn
//// over each other, and a label that cannot fit its box all fail here
//// instead of on a visitor's screen.

import gleam/list
import gleam/string
import site/diagram.{
  type Diagram, type Node, type Rect, Narrow, Point, Rect, Wide,
}
import site/figure
import site/figures

/// The width, as a fraction of the design width, that the wide layout is
/// shown at when the container query has just chosen it. The query switches
/// to the narrow layout under 440 units and the wide layout is designed at
/// 480, so a box is never narrower than this share of its design.
const narrowest_percent = 91

fn all_diagrams() -> List(#(String, Diagram)) {
  list.map(figures.all(), fn(id) {
    let spec = figures.spec(id)
    #(spec.title, spec.diagram)
  })
}

fn each_diagram(check: fn(String, Diagram) -> Nil) -> Nil {
  list.each(all_diagrams(), fn(pair) { check(pair.0, pair.1) })
}

pub fn every_step_has_exactly_one_frame_test() {
  list.each(figures.all(), fn(id) {
    let spec = figures.spec(id)
    assert list.length(spec.diagram.frames) == figure.count(spec)
  })
}

pub fn node_ids_are_unique_test() {
  each_diagram(fn(_, d) {
    let ids = list.map(d.nodes, fn(node) { node.id })
    assert list.unique(ids) == ids
  })
}

pub fn link_ids_are_unique_test() {
  each_diagram(fn(_, d) {
    let ids = list.map(d.links, fn(link) { link.id })
    assert list.unique(ids) == ids
  })
}

pub fn links_name_real_boxes_test() {
  each_diagram(fn(_, d) {
    list.each(d.links, fn(link) {
      assert is_ok(diagram.find_node(d, link.a))
      assert is_ok(diagram.find_node(d, link.b))
    })
  })
}

pub fn linked_boxes_are_drawn_in_the_layouts_that_draw_the_link_test() {
  // A link is drawn only when both of its ends are, so a link whose end is
  // missing from one layout is a link that silently disappears there.
  each_diagram(fn(_, d) {
    list.each(d.links, fn(link) {
      let assert Ok(a) = diagram.find_node(d, link.a)
      let assert Ok(b) = diagram.find_node(d, link.b)
      assert diagram.is_drawn(a.wide) && diagram.is_drawn(b.wide)
      assert diagram.is_drawn(a.narrow) && diagram.is_drawn(b.narrow)
    })
  })
}

pub fn pulses_travel_on_real_links_from_one_of_their_ends_test() {
  each_diagram(fn(_, d) {
    list.each(d.frames, fn(frame) {
      list.each(frame.pulses, fn(pulse) {
        let assert Ok(link) = diagram.find_link(d, pulse.link)
        assert pulse.from == link.a || pulse.from == link.b
      })
    })
  })
}

pub fn every_frame_states_every_box_test() {
  each_diagram(fn(_, d) {
    list.each(d.frames, fn(frame) {
      list.each(diagram.boxes(d), fn(node) {
        assert is_ok(diagram.state_of(frame, node.id))
      })
    })
  })
}

pub fn states_name_real_boxes_and_name_each_once_test() {
  each_diagram(fn(_, d) {
    let box_ids = list.map(diagram.boxes(d), fn(node) { node.id })
    list.each(d.frames, fn(frame) {
      let named = list.map(frame.states, fn(s) { s.node })
      assert list.length(named) == list.length(list.unique(named))
      list.each(named, fn(id) {
        assert list.contains(box_ids, id)
      })
    })
  })
}

pub fn every_step_changes_the_drawing_test() {
  // Two neighbouring frames that are identical would make a step that shows
  // nothing new, so the figure's Next button would appear to do nothing.
  each_diagram(fn(_, d) {
    let pairs = list.zip(d.frames, list.drop(d.frames, 1))
    list.each(pairs, fn(pair) {
      assert pair.0 != pair.1
    })
  })
}

pub fn boxes_fit_their_layouts_test() {
  each_diagram(fn(_, d) {
    list.each(d.nodes, fn(node) {
      assert within(node.wide, d.sizes.wide_w, d.sizes.wide_h)
      assert within(node.narrow, d.sizes.narrow_w, d.sizes.narrow_h)
    })
  })
}

pub fn no_two_boxes_overlap_in_either_layout_test() {
  each_diagram(fn(_, d) {
    let boxes = diagram.boxes(d)
    list.each(boxes, fn(a) {
      list.each(boxes, fn(b) {
        case a.id == b.id {
          True -> Nil
          False -> {
            assert !overlaps(a.wide, b.wide)
            assert !overlaps(a.narrow, b.narrow)
          }
        }
      })
    })
  })
}

pub fn every_box_sits_inside_a_container_or_none_in_each_layout_test() {
  // A box that straddles the edge of a container it does not belong to
  // draws as a box that half escapes it. Each box either lies wholly inside
  // a container or touches none.
  each_diagram(fn(_, d) {
    let containers = list.filter(d.nodes, diagram.is_container)
    list.each(diagram.boxes(d), fn(box) {
      list.each([Wide, Narrow], fn(layout) {
        let rect = diagram.rect_of(box, layout)
        list.each(containers, fn(zone) {
          let outer = diagram.rect_of(zone, layout)
          assert !overlaps(rect, outer) || inside(rect, outer)
        })
      })
    })
  })
}

pub fn every_label_fits_its_box_in_every_step_test() {
  // Collect every offender, so that one run lists all the boxes to resize.
  let offenders =
    list.flat_map(all_diagrams(), fn(pair) {
      let #(name, d) = pair
      list.flat_map(d.frames, fn(frame) {
        list.flat_map(diagram.boxes(d), fn(node) {
          let assert Ok(state) = diagram.state_of(frame, node.id)
          let lines = string.split(state.text, "\n")
          let wide = case fits(node, node.wide, lines, narrowest_percent) {
            True -> []
            False -> [name <> ": " <> node.id <> " (wide): " <> state.text]
          }
          let narrow = case fits(node, node.narrow, lines, 100) {
            True -> []
            False -> [name <> ": " <> node.id <> " (narrow): " <> state.text]
          }
          list.append(wide, narrow)
        })
      })
    })
  assert offenders == []
}

pub fn the_two_layouts_hold_the_same_boxes_test() {
  each_diagram(fn(_, d) {
    list.each(d.nodes, fn(node) {
      assert diagram.is_drawn(node.wide)
      assert diagram.is_drawn(node.narrow)
    })
  })
}

// GEOMETRY --------------------------------------------------------------------

pub fn route_between_side_by_side_boxes_is_one_horizontal_run_test() {
  assert diagram.route(Rect(0, 0, 100, 50), Rect(200, 0, 100, 50), 0)
    == [Point(100, 25), Point(200, 25)]
}

pub fn route_between_stacked_boxes_is_one_vertical_run_test() {
  assert diagram.route(Rect(0, 0, 100, 50), Rect(0, 100, 100, 50), 0)
    == [Point(50, 50), Point(50, 100)]
}

pub fn route_between_diagonal_boxes_bends_once_test() {
  assert diagram.route(Rect(0, 0, 100, 50), Rect(200, 100, 100, 50), 0)
    == [Point(100, 25), Point(250, 25), Point(250, 100)]
}

pub fn lanes_shift_a_route_off_the_centre_test() {
  assert diagram.route(Rect(0, 0, 100, 50), Rect(200, 0, 100, 50), 1)
    == [Point(100, 32), Point(200, 32)]
}

pub fn label_sits_on_the_longest_segment_test() {
  assert diagram.label_point([Point(0, 0), Point(10, 0), Point(10, 100)])
    == Point(10, 50)
}

pub fn text_height_grows_with_wrapping_test() {
  let short = diagram.text_height("Writer", "", ["running"], 200)
  let long =
    diagram.text_height(
      "Writer",
      "",
      ["a state that is long enough to wrap onto a second line"],
      120,
    )
  assert short == 49
  assert long > short
}

// HELPERS ---------------------------------------------------------------------

fn is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn within(r: Rect, width: Int, height: Int) -> Bool {
  r.x >= 0 && r.y >= 0 && r.x + r.w <= width && r.y + r.h <= height
}

fn overlaps(a: Rect, b: Rect) -> Bool {
  diagram.is_drawn(a)
  && diagram.is_drawn(b)
  && a.x < b.x + b.w
  && b.x < a.x + a.w
  && a.y < b.y + b.h
  && b.y < a.y + a.h
}

fn inside(inner: Rect, outer: Rect) -> Bool {
  inner.x >= outer.x
  && inner.y >= outer.y
  && inner.x + inner.w <= outer.x + outer.w
  && inner.y + inner.h <= outer.y + outer.h
}

fn fits(node: Node, rect: Rect, lines: List(String), percent: Int) -> Bool {
  let width = rect.w * percent / 100
  diagram.text_height(node.title, node.detail, lines, width) <= rect.h
}
