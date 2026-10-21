// The root page's script (protocol-change/052, the addendum on the root page).
// A browser that opens the daemon's bare address is served a fixed document
// with no credential. This looks in localStorage for the logins
// `web_view_enter.js` keeps under `loom.login.` and a 32-digit key
// (`web_view/page.login_nonce_item`), and moves the tab to the resume page of
// the one it finds, `/ui/l/<key>/home`, which posts the nonce and lets the
// daemon verify the login. localStorage is scoped to this scheme, host and
// port, so every entry belongs to this origin.
//
// An entry counts only when it has a 32-digit key and a 64-digit nonce, the
// shapes `web_view_enter.js` stores. Several remembered logins are listed as
// links in key order rather than guessed between, because the page cannot tell
// which of them the daemon still honours. With none, or with storage that
// cannot be read, the document's own words say to run `loom ui`.
(function () {
  var status = document.getElementById("root-status");
  var list = document.getElementById("root-logins");
  var help = document.getElementById("root-help");
  var keys = [];
  try {
    for (var i = 0; i < localStorage.length; i++) {
      var name = localStorage.key(i) || "";
      var found = /^loom\.login\.([0-9a-f]{32})$/.exec(name);
      var nonce = found ? localStorage.getItem(name) : null;
      if (found && nonce && /^[0-9a-f]{64}$/.test(nonce)) {
        keys.push(found[1]);
      }
    }
  } catch (e) { keys = []; }
  keys.sort();
  if (keys.length === 1) {
    location.replace("/ui/l/" + keys[0] + "/home");
    return;
  }
  if (keys.length > 1 && list) {
    if (status) { status.textContent = "Choose a sign-in."; }
    keys.forEach(function (key) {
      var item = document.createElement("li");
      var link = document.createElement("a");
      link.className = "ended-link";
      link.href = "/ui/l/" + key + "/home";
      link.textContent = "Sign-in " + key.slice(0, 8);
      item.appendChild(link);
      list.appendChild(item);
    });
    list.hidden = false;
    return;
  }
  if (status) { status.textContent = "This browser is not signed in."; }
  if (help) { help.hidden = false; }
})();
