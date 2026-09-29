// The session page's script: hand the tab's nonce to the server component
// as its `csrf-token`, then give it its route, so Lustre's client runtime
// opens the socket with the nonce in its query. The runtime reads the token
// when `route` is set, so the order is load-bearing. A tab with no nonce
// opens nothing; the shell's own paragraph, which shows while the component
// has no session, says to run `loom ui` again (`web_view/page.waiting_notice`).
// The item name is `web_view/page.nonce_item`.
(function () {
  var view = document.querySelector("lustre-server-component");
  if (!view) { return; }
  var nonce = null;
  try { nonce = sessionStorage.getItem("loom-page-nonce"); } catch (e) { nonce = null; }
  if (!nonce) { return; }
  view.setAttribute("csrf-token", nonce);
  view.setAttribute("route", location.pathname + "/ws");
})();
