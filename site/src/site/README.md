# How the site is built

This directory holds the modules of the Loom website, a client-side [Lustre](https://hexdocs.pm/lustre/) application compiled to JavaScript. `site/README.md`, two levels up, covers building, testing and deploying. This file explains how the application works: the Lustre loop, the state it keeps, how pages and documents reach the screen, and how the step-through figures and the replay are put together.

## The Lustre loop

Lustre is the Elm architecture written in Gleam. There is one `Model`, one `Msg` type, an `update` function and a `view` function. `update` takes a model and a message and returns a new model plus an `Effect`. `view` turns the model into HTML; the runtime diffs each new view against the last one and patches the DOM. Nothing on the page changes except through a message passing through `update`.

`src/loom_site.gleam` holds all of it:

```
browser event ──► Msg ──► update(model, msg) ──► #(Model, Effect(Msg))
                               ▲                        │        │
                               │                        ▼        ▼
                               │                     view    effect runs
                               │                        │    (ffi.*)
                               │                        ▼        │
                               │                   DOM patch     │
                               └──────── dispatch(Msg) ◄─────────┘
```

`main` starts the app on the `#app` element of `index.html`. `init` parses the URL fragment into a route and returns a batch of effects. They fetch the page's Markdown if it's a docs page, set the document title, subscribe to hash changes, and start the scroll spies.

Effects are the only place the app touches the browser. Each one is an `effect.from(fn(dispatch) { ... })` that calls into `ffi.gleam`. When the browser answers (a fetch finishes, a timer fires, the hash changes), the callback dispatches a `Msg`, which goes back through `update`. Every asynchronous browser event therefore arrives as an ordinary message.

## State: `model.gleam` and `msg.gleam`

The whole page is one record:

| Field | What it holds |
|---|---|
| `route` | The parsed fragment: the landing page, the docs index, or a docs page and section. |
| `steps` | The current step of each figure, keyed by `msg.figure_key`. A missing key means step 0. |
| `playing`, `play_generation` | Which figure is playing on its own, if any, and a counter that discards stale timer ticks (see below). |
| `docs` | Each fetched Markdown page, as `Loading`, `Failed` or `Ready(blocks)`. |
| `section` | The landing section in view, which the sidebar highlights. |
| `menu_open`, `contents_open` | The phone menu and the "On this page" control. |
| `replay` | The replay's step, the visitor's approval answer, whether it's playing, and its own generation counter. |
| `copied` | Which copy button currently says "Copied". |

`msg.gleam` is a module of its own because every view module produces `Element(Msg)`. Putting the type in `loom_site.gleam` would make the imports cyclic. It also holds `FigureId` (`Crash`, `Approval`, `CodeMode`, `Migration`) and the replay's `Decision`.

### Timers and the generation counter

A playing figure advances on `FigureTick(id, generation)`, which `ffi.after` schedules. Gleam can't cancel a scheduled timer. Instead, every `FigurePlay` increments `play_generation`, and a tick acts only when its generation matches the model's and its figure is still the one playing. When the visitor presses Pause or Back, or plays another figure, the old timer still fires, and its tick is ignored. The replay does the same with `replay.generation`. This is the stale-timer check that `docs/weft.md` describes, kept as model state because a browser has no processes.

## Routing and documents

GitHub Pages serves files and can't send unknown paths to `index.html`, so every route lives in the fragment: `#/`, `#/docs`, `#/docs/code-mode`, `#/docs/code-mode/safety`. `route.gleam` parses it, and `RouteChanged` runs the same load, title and scroll effects that `init` does.

The docs text is plain Markdown under `public/content/`, so it can be edited without touching Gleam. `docs.gleam` knows the page order and lays out the sidebar, the outline and the previous and next links. `markdown.gleam` parses only the subset those pages use: headings, paragraphs, lists, tables, fenced code and `>` notes. It adds one extension: a line `::figure crash` embeds a step-through figure in the page. All prose (in the docs, the figures and the landing page) goes through `inline.gleam`, which handles backticks, `**bold**` and `[links](target)`.

`code.gleam` is the single component for code samples, so every sample has a copy button. For a shell sample whose lines start with `$ `, the button copies only the commands. `highlight.gleam` colours comments, strings and keywords in shell, TOML and Gleam. The colouring is only visual, and an unknown language is shown plain.

## The figures

The landing page tells four stories, each with a figure: a crash in the middle of a tool call (`fig_crash`), a command that needs more access than the session has (`fig_approval`), code mode from program to result (`fig_codemode`), and moving a session between orchestrators (`fig_migration`). A figure is a drawing plus a list of steps.

| Module | Role |
|---|---|
| `diagram.gleam` | The drawing as data. A `Diagram` is a set of boxes, each with a rectangle for the wide layout and one for the narrow layout. It also has links between box ids and one `Frame` per step, which gives every box's state and which links carry a message. Links have no coordinates of their own; `route` derives a straight or bent path from the two boxes' rectangles. |
| `diagram_view.gleam` | The renderer. It draws HTML boxes over an SVG of lines, so every label is real text at a fixed pixel size. Both layouts are rendered, and a container query in `public/figures.css` shows the one that fits. Under the drawing, a table states every box's state in words. Screen readers skip the drawing and read the table. |
| `figure.gleam` | The step-through component: a sticky panel with the drawing, the caption and the controls, beside a column of text blocks, one per `Step`. A step has a heading, a body, the facts that hold after it, an optional sample, and what fails at that point. |
| `fig_*.gleam` | One module per figure, holding its diagram (written with the short constructors in `dkit.gleam`) and the words of every step. The comment at the top of each names the repository documents it follows. |
| `figures.gleam` | Looks up a figure's `Spec` by `FigureId`. A new figure is a new `fig_*` module plus one line here. |

Because a drawing is data, the tests check it without a browser. `test/diagram_test.gleam` fails when a link or a state names a box that doesn't exist, or a frame leaves a box out. It also fails when two boxes overlap in either layout, or when a label's estimated wrapped height (`diagram.text_height`) doesn't fit its box.

### Scroll-driven steps

On a wide screen, the text blocks scroll past the sticky panel, and the block under a reading line picks the step. The figure scroll spy in `loom_site_ffi.mjs` does this and reports `FigureScrolled(id, step)`.

The buttons work the other way round. `FigureGo` sets the step in the model, then `ffi.reveal_step` scrolls the matching block under the reading line. The spy is suppressed during that scroll, so the blocks it passes don't each change the step. `ffi.note_step` then tells the spy the model's step, so the spy doesn't report the button's change back as a new one.

On a phone (760px or narrower), only the current step's text is shown, under the panel, and the reader moves with the buttons.

A second spy reports `SectionScrolled` for the landing sidebar. It picks the last section whose top has passed a line just under the header, or the last section when the page is scrolled to the end.

## The replay

The landing page opens with a terminal that plays back a recorded session. Nothing in it runs: `replay.gleam` is a script of eight steps, and each step adds lines to the transcript and has an explanation beside it.

Playback starts the first time at least 45% of the terminal is on screen (`ffi.observe_once` dispatches `ReplayVisible`), unless the visitor prefers reduced motion. It stops at the approval dialog until the visitor picks Allow once, Allow for session or Deny. That `Decision` changes the transcript and the explanations of the later steps. A step can link with `ShowFigure` to one step of a figure further down the page, which shows the mechanism behind what the terminal printed.

`replay_view.gleam` draws the terminal, the explanation and the controls. All of it works from the keyboard, and the explanation is an ARIA live region, so screen readers announce each step. `test/replay_test.gleam` checks the script.

## The FFI boundary

`ffi.gleam` binds `loom_site_ffi.mjs`, the only JavaScript in the project. It covers what Gleam's standard library has no bindings for:

- the URL hash, its change events and the document title;
- `setTimeout`, `fetch` and the clipboard;
- the reduced-motion preference and scrolling;
- the two scroll spies and the observer that starts the replay.

Every decision stays in Gleam. The JavaScript only calls the browser and dispatches the result back.

## Releases

`release.gleam` records publication separately from the existing example tag. With `SourceOnly`, install actions go to the source-build guide and show no version badge. Once assets are published and verified, `Published` enables the download action. The tag still fills conditional archive examples in the docs.
