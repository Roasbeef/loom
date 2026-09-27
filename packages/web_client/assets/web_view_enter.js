// The ticket exchange's hand-off script (protocol-change/051, the operator
// addendum). The exchange answers with a page whose body names the keyed
// page to move to and the tab's nonce as data attributes; this keeps the
// nonce in sessionStorage, which no page on another loopback port can read,
// and replaces the location with the keyed page, so the ticket's URL stays
// out of the history. A `next` that is not a keyed page path is not
// followed. The item name is `web_view/page.nonce_item`.
(function () {
  var body = document.body;
  var next = body.getAttribute("data-next") || "";
  var nonce = body.getAttribute("data-nonce") || "";
  if (next.indexOf("/ui/p/") !== 0 || nonce === "") { return; }
  try { sessionStorage.setItem("loom-page-nonce", nonce); } catch (e) { return; }
  location.replace(next);
})();
