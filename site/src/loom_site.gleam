//// The Loom website.
////
//// A client-side Lustre application. The URL fragment picks the page
//// (`site/route`), the landing page and the documentation are views of one
//// model (`site/landing`, `site/docs`), and the explainer figures are state
//// in that model: a step number each, plus at most one that is playing.
////
//// ## Flow
////
//// - `main` starts the application on `#app`.
//// - `init` reads the fragment, loads the page's Markdown if it is a
////   documentation page, and subscribes to hash changes and to the scroll spy.
//// - `update` handles route changes, loaded documents, and the figure
////   messages (`FigureGo`, `FigureScrolled`, `FigurePlay`, `FigureTick`).
//// - `view` renders the landing page or a documentation page.

import gleam/dict
import gleam/int
import gleam/option.{None, Some}
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import site/docs
import site/ffi
import site/figure
import site/figures
import site/landing
import site/markdown
import site/model.{type Model, Model} as m
import site/msg.{type Msg}
import site/route.{type Route}

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  let current = route.parse(ffi.get_hash())
  let model =
    Model(
      route: current,
      steps: dict.new(),
      playing: None,
      play_generation: 0,
      docs: dict.new(),
      menu_open: False,
    )
  #(
    model,
    effect.batch([
      subscribe(),
      load(model, current),
      title(current),
    ]),
  )
}

/// Hash changes and the scroll spy report through these two callbacks.
fn subscribe() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.on_hash_change(fn(hash) { dispatch(msg.RouteChanged(hash)) })
    ffi.start_scroll_spy(fn(key, step) {
      case msg.figure_from_key(key) {
        Ok(id) -> dispatch(msg.FigureScrolled(id, step))
        Error(Nil) -> Nil
      }
    })
  })
}

/// Fetches the Markdown for a documentation route that has not been asked for.
fn load(model: Model, current: Route) -> Effect(Msg) {
  case current {
    route.Doc(slug, _) ->
      case dict.has_key(model.docs, slug) {
        True -> effect.none()
        False ->
          effect.from(fn(dispatch) {
            ffi.fetch_text("./content/" <> slug <> ".md", fn(result) {
              dispatch(msg.DocLoaded(slug, result))
            })
          })
      }
    _ -> effect.none()
  }
}

fn title(current: Route) -> Effect(Msg) {
  effect.from(fn(_dispatch) {
    ffi.set_title(case current {
      route.Landing -> "Loom: a coding agent harness on the BEAM"
      route.DocsHome -> "Documentation | Loom"
      route.Doc(slug, _) -> docs.title_of(slug) <> " | Loom"
    })
  })
}

fn scroll_for(current: Route) -> Effect(Msg) {
  effect.from(fn(_dispatch) {
    case current {
      route.Doc(_, section) if section != "" -> ffi.scroll_to_id(section)
      _ -> ffi.scroll_to_top()
    }
  })
}

fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    msg.RouteChanged(hash) -> {
      let current = route.parse(hash)
      let next =
        Model(
          ..m.stopped(model),
          route: current,
          menu_open: False,
          docs: case current {
            route.Doc(slug, _) ->
              case dict.has_key(model.docs, slug) {
                True -> model.docs
                False -> dict.insert(model.docs, slug, m.Loading)
              }
            _ -> model.docs
          },
        )
      #(
        next,
        effect.batch([load(model, current), title(current), scroll_for(current)]),
      )
    }

    msg.DocLoaded(slug, result) -> {
      let loaded = case result {
        Ok(text) -> m.Ready(markdown.parse(text))
        Error(Nil) -> m.Failed
      }
      let next = Model(..model, docs: dict.insert(model.docs, slug, loaded))
      #(next, scroll_for(model.route))
    }

    msg.FigureGo(id, step) -> {
      let step = clamp(step, figure.count(figures.spec(id)))
      #(
        set_step(m.stopped(model), id, step),
        effect.from(fn(_dispatch) {
          ffi.note_step(msg.figure_key(id), step)
          ffi.reveal_step(msg.figure_key(id), step)
        }),
      )
    }

    msg.FigureScrolled(id, step) ->
      case m.is_playing(model, id) {
        True -> #(model, effect.none())
        False -> #(set_step(model, id, step), effect.none())
      }

    msg.FigurePlay(id) -> {
      let last = figure.count(figures.spec(id)) - 1
      let start = case m.step(model, id) >= last {
        True -> 0
        False -> m.step(model, id)
      }
      let generation = model.play_generation + 1
      let next =
        Model(
          ..set_step(model, id, start),
          playing: Some(id),
          play_generation: generation,
        )
      #(
        next,
        effect.batch([
          effect.from(fn(_dispatch) {
            ffi.note_step(msg.figure_key(id), start)
            ffi.reveal_step(msg.figure_key(id), start)
          }),
          tick(id, generation),
        ]),
      )
    }

    msg.FigureStop -> #(m.stopped(model), effect.none())

    msg.FigureTick(id, generation) ->
      case m.is_playing(model, id), generation == model.play_generation {
        True, True -> {
          let last = figure.count(figures.spec(id)) - 1
          let step = int.min(m.step(model, id) + 1, last)
          let next = set_step(model, id, step)
          let finished = step >= last
          #(
            case finished {
              True -> m.stopped(next)
              False -> next
            },
            effect.batch([
              effect.from(fn(_dispatch) {
                ffi.note_step(msg.figure_key(id), step)
                ffi.reveal_step(msg.figure_key(id), step)
              }),
              case finished {
                True -> effect.none()
                False -> tick(id, generation)
              },
            ]),
          )
        }
        _, _ -> #(model, effect.none())
      }

    msg.ToggleMenu -> #(
      Model(..model, menu_open: !model.menu_open),
      effect.none(),
    )

    msg.JumpTo(id) -> #(
      model,
      effect.from(fn(_dispatch) { ffi.scroll_to_id(id) }),
    )

    msg.Ignore -> #(model, effect.none())
  }
}

fn tick(id: msg.FigureId, generation: Int) -> Effect(Msg) {
  let delay = case ffi.prefers_reduced_motion() {
    True -> 4200
    False -> 3400
  }
  effect.from(fn(dispatch) {
    ffi.after(delay, fn() { dispatch(msg.FigureTick(id, generation)) })
  })
}

fn set_step(model: Model, id: msg.FigureId, step: Int) -> Model {
  Model(..model, steps: dict.insert(model.steps, msg.figure_key(id), step))
}

fn clamp(step: Int, count: Int) -> Int {
  int.max(0, int.min(step, count - 1))
}

fn view(model: Model) -> Element(Msg) {
  case model.route {
    route.Landing -> landing.view(model)
    route.DocsHome -> docs.home(model)
    route.Doc(slug, _) -> docs.view(model, slug)
  }
}
