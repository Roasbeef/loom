//// The client components' decisions, run without a page. Each component's
//// rules are functions of plain values (`follow.after_scroll`,
//// `composer.matching`, `composer.intent` and the like), and these tests
//// pin those. What they cannot cover is the DOM the effects read and move,
//// which `dom.mjs` does one call at a time; `packages/web_client/CLAUDE.md`
//// lists what only a browser shows.
////
//// The package targets JavaScript, so `gleam test` here needs Node, Bun or
//// Deno (`scripts/web_client_test.sh`).

import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}
