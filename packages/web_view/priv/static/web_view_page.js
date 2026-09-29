// The session page's script: hand the tab's nonce to the server component
// as its `csrf-token`, then give it its route, so Lustre's client runtime
// opens the socket with the nonce in its query. The runtime reads the token
// when `route` is set, so the order is load-bearing. A tab with no nonce
// opens nothing; the shell's own paragraph, which shows while the component
// has no session, says to run `loom ui` again (`web_view/page.waiting_notice`).
// The item name is `web_view/page.nonce_item`.
//
// It also applies the reader's saved theme, before the first paint. The
// shell reads the same item when it connects (`web_client/layout_rule`), but
// the page's first document holds only the server component, so the shell
// does not exist until the socket has opened and the first render has come
// back, and a reader who chose the other theme than the system's would see the
// system's for that whole time on every load. This script already runs before
// the shell and before paint, so the one read lives here. It sets `data-theme`
// to one of two fixed words and never to the stored text, and the shell owns
// every later change. The item name is `layout_rule.theme_key`, and
// `scripts/web_client_js_check.sh` fails if the two differ.
(function () {
  try {
    var theme = localStorage.getItem("loom.theme.v1");
    if (theme === "light" || theme === "dark") {
      document.documentElement.setAttribute("data-theme", theme);
    }
  } catch (e) { /* blocked storage: the page follows the system */ }
})();

(function () {
  var view = document.querySelector("lustre-server-component");
  if (!view) { return; }
  var nonce = null;
  try { nonce = sessionStorage.getItem("loom-page-nonce"); } catch (e) { nonce = null; }
  if (!nonce) { return; }
  view.setAttribute("csrf-token", nonce);
  view.setAttribute("route", location.pathname + "/ws");
})();
