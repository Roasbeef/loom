// The ticket exchange's hand-off script (protocol-change/051, the operator
// addendum). The exchange answers with a page whose body names the keyed
// page to move to and the tab's nonce as data attributes; this keeps the
// nonce in sessionStorage, which no page on another loopback port can read,
// and replaces the location with the keyed page, so the ticket's URL stays
// out of the history. A `next` that is not a keyed page path is not
// followed. The item name is `web_view/page.nonce_item`.
//
// An exchange that also set a browser login (protocol-change/065) names the
// login's key and nonce as well. The nonce is kept in localStorage, under
// `loom.login.` and the key (`web_view/page.login_nonce_item`), which is
// scoped to this scheme, host and port like sessionStorage but outlives the
// tab, so the bookmark works in a new one. The daemon keeps only the nonce's
// digest and will never send it again. Values that are not exactly a 32-digit
// key and a 64-digit nonce are not stored.
(function () {
  var body = document.body;
  var next = body.getAttribute("data-next") || "";
  var nonce = body.getAttribute("data-nonce") || "";
  var loginKey = body.getAttribute("data-login-key") || "";
  var loginNonce = body.getAttribute("data-login-nonce") || "";
  if (next.indexOf("/ui/p/") !== 0 || nonce === "") { return; }
  try { sessionStorage.setItem("loom-page-nonce", nonce); } catch (e) { return; }
  if (/^[0-9a-f]{32}$/.test(loginKey) && /^[0-9a-f]{64}$/.test(loginNonce)) {
    try {
      localStorage.setItem("loom.login." + loginKey, loginNonce);
    } catch (e) { /* the page still opens; the bookmark cannot resume here */ }
  }
  location.replace(next);
})();
