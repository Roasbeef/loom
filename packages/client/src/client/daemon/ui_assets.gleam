//// The web view's static assets, read once when a daemon started with
//// `--ui` comes up, and served from memory for its life.
////
//// Every asset is a file some application ships in its `priv` directory:
//// Lustre's client runtime in `lustre`'s, and the page's stylesheet and
//// scripts in `web_view`'s (`web_view/page.static_file`), which a release
//// carries like any other application's `priv`. Reading them at startup
//// rather than per request means a request never touches the disk, and a
//// daemon whose release lost an asset says so when it starts instead of
//// answering a page with a 500 later. The set is closed: `ui_http.Asset`
//// names every asset, and a name outside it is a 404 before this module is
//// asked.

import client/daemon/ui_http
import gleam/result
import simplifile
import web_view/page

/// Every asset's body, by the route that serves it.
pub opaque type Assets {
  Assets(
    runtime: String,
    stylesheet: String,
    enter_script: String,
    page_script: String,
  )
}

/// Reads every asset from disk, or names the first one that could not be
/// read.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(assets) = ui_assets.load()
/// ```
pub fn load() -> Result(Assets, String) {
  use runtime <- result.try(read(page.runtime_asset, page.runtime_file()))
  use stylesheet <- result.try(owned(page.stylesheet_asset))
  use enter_script <- result.try(owned(page.enter_asset))
  use page_script <- result.try(owned(page.page_asset))
  Ok(Assets(runtime:, stylesheet:, enter_script:, page_script:))
}

// One of the assets `web_view` ships in its own `priv/static`.
fn owned(name: String) -> Result(String, String) {
  read(name, page.static_file(name))
}

fn read(name: String, path: Result(String, Nil)) -> Result(String, String) {
  path
  |> result.try(fn(path) { simplifile.read(path) |> result.replace_error(Nil) })
  |> result.replace_error("web view asset " <> name <> " is unreadable")
}

/// One asset's content type and body.
///
/// ## Examples
///
/// ```gleam
/// // ui_assets.body(assets, ui_http.Stylesheet)
/// //   == #("text/css; charset=utf-8", "...")
/// ```
pub fn body(assets: Assets, asset: ui_http.Asset) -> #(String, String) {
  case asset {
    ui_http.Runtime -> #("text/javascript; charset=utf-8", assets.runtime)
    ui_http.Stylesheet -> #("text/css; charset=utf-8", assets.stylesheet)
    ui_http.EnterScript -> #(
      "text/javascript; charset=utf-8",
      assets.enter_script,
    )
    ui_http.PageScript -> #(
      "text/javascript; charset=utf-8",
      assets.page_script,
    )
  }
}
