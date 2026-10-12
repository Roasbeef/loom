//// Hash routes.
////
//// The site is a static single-page app on GitHub Pages, which cannot
//// rewrite unknown paths to `index.html`. Every route therefore lives in
//// the URL fragment (`#/docs/code-mode/safety`), so a deep link always
//// loads the one file the host serves.

import gleam/list
import gleam/string

/// A page the site can show.
pub type Route {
  /// The landing page.
  Landing
  /// The documentation index.
  DocsHome
  /// One documentation page, optionally scrolled to a heading id.
  Doc(slug: String, section: String)
}

/// Parses a fragment such as `#/docs/code-mode/safety`. Anything that is
/// not a known shape is the landing page.
///
/// ## Examples
///
/// ```gleam
/// parse("#/docs/sessions") == Doc("sessions", "")
/// parse("") == Landing
/// ```
pub fn parse(hash: String) -> Route {
  let path =
    hash
    |> string.drop_start(1)
    |> string.split("/")
    |> list.filter(fn(part) { part != "" })
  case path {
    ["docs"] -> DocsHome
    ["docs", slug] -> Doc(slug, "")
    ["docs", slug, section] -> Doc(slug, section)
    ["install"] -> Doc("getting-started", "")
    _ -> Landing
  }
}

/// The fragment for a route.
pub fn to_hash(route: Route) -> String {
  case route {
    Landing -> "#/"
    DocsHome -> "#/docs"
    Doc(slug, "") -> "#/docs/" <> slug
    Doc(slug, section) -> "#/docs/" <> slug <> "/" <> section
  }
}

/// The link target for a documentation page.
pub fn doc(slug: String) -> String {
  to_hash(Doc(slug, ""))
}
