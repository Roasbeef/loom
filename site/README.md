# The Loom website

This directory is a separate Gleam project. It compiles to JavaScript and runs in the browser as a single-page [Lustre](https://hexdocs.pm/lustre/) application. It is not part of Loom's daemon, and nothing in `packages/` depends on it.

The landing page opens with what Loom is, then a recorded session in a terminal panel, then four stories. Each story has a few paragraphs and a step-through figure that advances with the scroll position. A sticky sidebar lists the sections and marks the one in view. The documentation pages are Markdown files that the app fetches and renders.

License: TBD. The project has not chosen a license yet, and the site's footer says so.

## Build, test and preview

You need Gleam (1.18 or later; the repository uses 1.19.0), Erlang/OTP to run the Gleam compiler, Node.js for the tests, and `rsync`.

```sh
make -C site build      # compile and assemble site/dist
make -C site test       # gleeunit, on the JavaScript target
make -C site fmt        # format the Gleam sources
make -C site check      # format check, test, copy-check and build
make -C site serve      # build, then serve site/dist on PORT (default 8702)
```

`build.sh` runs `gleam build --target javascript`, then writes `dist/`:

| In `dist/` | From |
|---|---|
| `index.html` | `index.html` |
| `site.css`, `figures.css`, `replay.css`, `content/*.md`, `img/*` | `public/` |
| `js/<package>/*.mjs` | the compiled modules under `build/dev/javascript` |
| `.nojekyll` | created, so GitHub Pages serves the files as they are |

There is no bundler. `index.html` loads `js/loom_site/loom_site.mjs` as an ES module, and the browser follows the relative imports. The page cannot be opened from `file://`, because browsers refuse ES modules there. Any static file server works.

## Releasing

Everything the site says about a release comes from `src/site/release.gleam`. To point the site at a new release, change `tag` there and rebuild. The Download button, its version label, the archive names on the install page and the `{{tag}}` and `{{version}}` placeholders in the Markdown pages all follow it. The site assumes that the tagged release exists when it is published. The existing `v0.2.0` tag predates the release workflow, `loom update` and the distributed runtime, so the first release that the install page describes is the next one. The Download button links to GitHub's `releases/latest` redirect, so it keeps working if a newer release appears before the site is rebuilt.

## Routes

Routes live in the URL fragment, so a deep link loads the single file that GitHub Pages serves.

| Fragment | Page |
|---|---|
| `#/` | The landing page. |
| `#/docs` | The documentation index. |
| `#/docs/<page>` | One documentation page, for example `#/docs/code-mode`. |
| `#/docs/<page>/<section>` | The same page, scrolled to a heading. Every heading has a link to its own address. |
| `#/install` | Alias for `#/docs/getting-started`. |

## Layout of the source

`src/site/README.md` explains how the application works: the Lustre loop, the model, routing, the figures and the replay.

| Path | What it holds |
|---|---|
| `src/loom_site.gleam` | The application: model, update, view. |
| `src/loom_site_ffi.mjs` | The only JavaScript: hash, timers, `fetch`, scrolling, the clipboard and the two scroll spies. |
| `src/site/release.gleam` | The release tag, the URLs and the archive names. |
| `src/site/landing.gleam`, `docs.gleam`, `ui.gleam` | Pages and shared chrome. |
| `src/site/replay.gleam`, `replay_view.gleam` | The recorded session: the script, and the terminal that plays it. |
| `src/site/diagram.gleam`, `diagram_view.gleam`, `dkit.gleam` | A figure's drawing as data (boxes, links, one frame per step), the renderer, and short constructors. |
| `src/site/figure.gleam`, `figures.gleam`, `fig_*.gleam` | The step-through figure, and one module per figure with its drawing and the words of every step. |
| `src/site/code.gleam`, `highlight.gleam` | Code samples with a copy button and colouring. |
| `src/site/markdown.gleam`, `inline.gleam`, `route.gleam` | The Markdown subset the docs use, inline marks, and fragment parsing. |
| `public/site.css`, `figures.css`, `replay.css` | All styling, with a light theme and a dark theme from `prefers-color-scheme`. |
| `public/content/*.md` | The documentation pages. |
| `test/` | The gleeunit tests. |
| `scripts/copy-check.sh` | Fails on banned words, the em dash and source links to any branch but `main`. |

To add a documentation page, write `public/content/<slug>.md` and add a `Page` to `pages()` in `src/site/docs.gleam`. A line `::figure crash` embeds a figure (`crash`, `approval`, `code-mode` or `migration`). Pages may use `{{tag}}` and `{{version}}`.

## How the figures work

A figure is a `Diagram`: boxes laid out twice, once for a wide panel and once for a narrow one, links between boxes, and one `Frame` per step that gives the state of every box and the messages in flight. The renderer draws HTML boxes over an SVG of lines, so every label is real text at 12 or 13 pixels, and a container query in `figures.css` picks the layout that fits the panel. Under each drawing a table lists every box and its state at that step.

Because the drawings are data, `test/diagram_test.gleam` checks them: every link, pulse and state names a real box, every step states every box, no two boxes overlap in either layout, every box fits its layout, and an estimate of each label's wrapped height has to fit its box. A new figure is a new `fig_*.gleam` and one line in `figures.gleam`.

## The replay

`src/site/replay.gleam` is a script: eight steps, each adding lines to a transcript and explaining itself. Playback stops at the approval step until the visitor answers, and the answer changes the later steps. `test/replay_test.gleam` holds the script to that. The project, the files and the counts in it are examples, and the page says so.

## Screenshots

`screenshots/` holds captures of the landing page (the hero, the sidebar part-way down the page and the replay at its approval dialog), one figure part-way through a step, and the install page, at 1440 by 900 and 375 by 812 pixels, in the light and dark themes. They were taken from `dist/` with a headless Chrome for Testing and are not regenerated by the build.

## Accuracy

Every figure names the repository documents it follows in the comment at the top of its module, and the replay does the same. The wording of a step uses the names those documents use. Source links name `main`. The site makes no claim about pull requests that have not merged.

## Deploy to GitHub Pages

All asset URLs are relative, so the site works from a project path such as `https://roasbeef.github.io/loom/` as well as from a custom domain. No server rewrite is needed.

`.github/workflows/pages.yml` publishes it. On a pull request that touches `site/`, it runs `make -C site check` and stops. On a push to `main`, it runs the same check, uploads `site/dist` with `actions/upload-pages-artifact` and publishes it with `actions/deploy-pages`. It installs stock Gleam 1.19.0 and Erlang/OTP 29 with `erlef/setup-beam`, because the site builds no Loom package and so does not need the patched toolchain the main CI uses.

Set the repository's Pages source to GitHub Actions. To publish by hand instead, copy the contents of `site/dist` to the `gh-pages` branch.

## Dependencies

The project depends on `gleam_stdlib` and `lustre` (pinned to 5.7.1, the version of the daemon's web view), and on `gleeunit` for the tests. Lustre brings `gleam_json`, `gleam_otp`, `gleam_erlang`, `exception` and `houdini` in `manifest.toml`, and the browser loads a few of their modules because `lustre.mjs` imports them. There is no JavaScript dependency.

The page loads about 100 small module files, 1.3 MB unminified, from `dist/js`. That is fine over HTTP/2, which GitHub Pages uses. If it ever matters, bundle `js/loom_site/loom_site.mjs` with a tool such as esbuild as a last build step and point `index.html` at the result.
