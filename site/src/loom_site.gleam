//// The Loom website.
////
//// A client-side Lustre application. The URL fragment picks the page
//// (`site/route`), the landing page and the documentation are views of one
//// model (`site/landing`, `site/docs`), and the explainer figures are state
//// in that model: a step number each, plus at most one that is playing. The
//// landing page's scripted replay is state there too (`site/replay`).
////
//// ## Flow
////
//// - `main` starts the application on `#app`.
//// - `init` reads the fragment, loads the page's Markdown if it is a
////   documentation page, and subscribes to hash changes and to the scroll
////   spies.
//// - `update` handles route changes, loaded documents, the figure messages
////   (`FigureGo`, `FigureScrolled`, `FigurePlay`, `FigureTick`), the replay
////   messages (`ReplayGo`, `ReplayPlay`, `ReplayTick`, `ReplayDecide`), the
////   sidebar (`SectionScrolled`, `JumpTo`) and the copy buttons.
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
import site/model.{type Model, Model, Replay} as m
import site/msg.{type Msg}
import site/replay
import site/route.{type Route}

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  let current = route.parse(ffi.get_hash())
  let model = m.new(current)
  #(
    model,
    effect.batch([
      subscribe(),
      load(model, current),
      title(current),
      watch_replay(current),
    ]),
  )
}

/// Hash changes and the scroll spies report through these callbacks.
fn subscribe() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.on_hash_change(fn(hash) { dispatch(msg.RouteChanged(hash)) })
    ffi.start_scroll_spy(
      landing.section_ids(),
      fn(key, step) {
        case msg.figure_from_key(key) {
          Ok(id) -> dispatch(msg.FigureScrolled(id, step))
          Error(Nil) -> Nil
        }
      },
      fn(id) { dispatch(msg.SectionScrolled(id)) },
    )
  })
}

/// Starts the replay by itself the first time it is on screen, unless the
/// reader asked the system for less motion. It only watches while the landing
/// page is showing.
fn watch_replay(current: Route) -> Effect(Msg) {
  case current {
    route.Landing ->
      effect.from(fn(dispatch) {
        ffi.observe_once("replay", 0.45, fn() { dispatch(msg.ReplayVisible) })
      })
    _ -> effect.none()
  }
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
          contents_open: False,
          section: "",
          docs: case current {
            route.Doc(slug, _) ->
              case dict.has_key(model.docs, slug) {
                True -> model.docs
                False -> dict.insert(model.docs, slug, m.Loading)
              }
            _ -> model.docs
          },
          replay: Replay(..model.replay, playing: False),
        )
      #(
        next,
        effect.batch([
          load(model, current),
          title(current),
          scroll_for(current),
          case model.replay.autostarted {
            True -> effect.none()
            False -> watch_replay(current)
          },
        ]),
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
      #(set_step(m.stopped(model), id, step), reveal(id, step))
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
      #(next, effect.batch([reveal(id, start), tick(id, generation)]))
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
              reveal(id, step),
              case finished {
                True -> effect.none()
                False -> tick(id, generation)
              },
            ]),
          )
        }
        _, _ -> #(model, effect.none())
      }

    msg.ShowFigure(id, step) -> {
      let step = clamp(step, figure.count(figures.spec(id)))
      #(
        set_step(m.stopped(model), id, step),
        effect.from(fn(_dispatch) { ffi.show_step(msg.figure_key(id), step) }),
      )
    }

    msg.ToggleMenu -> #(
      Model(..model, menu_open: !model.menu_open),
      effect.none(),
    )

    msg.ToggleContents -> #(
      Model(..model, contents_open: !model.contents_open),
      effect.none(),
    )

    msg.JumpTo(id) -> #(
      Model(..model, contents_open: False, section: id),
      effect.from(fn(_dispatch) { ffi.jump_to_id(id) }),
    )

    msg.SectionScrolled(id) -> #(Model(..model, section: id), effect.none())

    msg.ReplayVisible ->
      case model.replay.autostarted || ffi.prefers_reduced_motion() {
        True -> #(
          Model(..model, replay: Replay(..model.replay, autostarted: True)),
          effect.none(),
        )
        False -> start_replay(model, Replay(..model.replay, autostarted: True))
      }

    msg.ReplayGo(index) -> {
      let last = replay.furthest(model.replay.decision)
      let index = int.max(0, int.min(index, last))
      #(
        Model(
          ..model,
          replay: Replay(
            ..model.replay,
            index: index,
            playing: False,
            generation: model.replay.generation + 1,
          ),
        ),
        effect.none(),
      )
    }

    msg.ReplayPlay -> {
      let current = model.replay
      case replay.waiting(current.index, current.decision) {
        True -> #(model, effect.none())
        False ->
          case current.index >= replay.last() {
            True -> start_replay(model, restarted(current))
            False -> start_replay(model, current)
          }
      }
    }

    msg.ReplayPause -> #(
      Model(
        ..model,
        replay: Replay(
          ..model.replay,
          playing: False,
          generation: model.replay.generation + 1,
        ),
      ),
      effect.none(),
    )

    msg.ReplayRestart -> start_replay(model, restarted(model.replay))

    msg.ReplayTick(generation) -> {
      let current = model.replay
      case current.playing && generation == current.generation {
        False -> #(model, effect.none())
        True -> {
          let index = replay.next_index(current.index, current.decision)
          let moving = index != current.index
          let stops =
            !moving
            || replay.waiting(index, current.decision)
            || index >= replay.last()
          let next = Replay(..current, index: index, playing: !stops)
          #(Model(..model, replay: next), case stops {
            True -> effect.none()
            False -> replay_tick(next)
          })
        }
      }
    }

    msg.ReplayDecide(decision) -> {
      let current = model.replay
      case replay.waiting(current.index, current.decision) {
        False -> #(model, effect.none())
        True -> {
          let next =
            Replay(
              ..current,
              decision: Some(decision),
              playing: True,
              generation: current.generation + 1,
            )
          #(Model(..model, replay: next), after_answer(next))
        }
      }
    }

    msg.CopyText(id, text) -> #(
      model,
      effect.from(fn(dispatch) {
        ffi.copy_text(text, fn() { dispatch(msg.CopyDone(id)) })
      }),
    )

    msg.CopyDone(id) -> #(
      Model(..model, copied: Some(id)),
      effect.from(fn(dispatch) {
        ffi.after(1800, fn() { dispatch(msg.CopyReset(id)) })
      }),
    )

    msg.CopyReset(id) ->
      case model.copied == Some(id) {
        True -> #(Model(..model, copied: None), effect.none())
        False -> #(model, effect.none())
      }

    msg.Ignore -> #(model, effect.none())
  }
}

/// A replay back at its first step, with no answer and still counting the
/// first autostart as used.
fn restarted(current: m.Replay) -> m.Replay {
  Replay(
    ..m.new_replay(),
    autostarted: current.autostarted,
    generation: current.generation,
  )
}

/// Begins stepping the replay from the state given, and schedules its first
/// step.
fn start_replay(model: Model, from: m.Replay) -> #(Model, Effect(Msg)) {
  let next = Replay(..from, playing: True, generation: from.generation + 1)
  #(Model(..model, replay: next), replay_tick(next))
}

/// The timer for the replay's next step. A tick that comes back after the
/// reader moved by hand carries an old generation and is ignored.
fn replay_tick(current: m.Replay) -> Effect(Msg) {
  timer(replay.dwell_ms(current.index), msg.ReplayTick(current.generation))
}

/// The pause that lets the reader see the result of an answer before the
/// replay moves on.
fn after_answer(current: m.Replay) -> Effect(Msg) {
  timer(2600, msg.ReplayTick(current.generation))
}

/// A message after a delay, stretched when the reader wants less motion.
fn timer(milliseconds: Int, message: Msg) -> Effect(Msg) {
  let delay = case ffi.prefers_reduced_motion() {
    True -> milliseconds * 3 / 2
    False -> milliseconds
  }
  effect.from(fn(dispatch) { ffi.after(delay, fn() { dispatch(message) }) })
}

fn tick(id: msg.FigureId, generation: Int) -> Effect(Msg) {
  timer(3400, msg.FigureTick(id, generation))
}

fn reveal(id: msg.FigureId, step: Int) -> Effect(Msg) {
  effect.from(fn(_dispatch) {
    ffi.note_step(msg.figure_key(id), step)
    ffi.reveal_step(msg.figure_key(id), step)
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
