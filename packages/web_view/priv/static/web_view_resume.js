// The resume page's script (protocol-change/065). A browser that visits its
// bookmark, `/ui/l/<login key>/home`, is served a fixed document with one
// form. This reads the login nonce the exchange left in localStorage under
// `loom.login.` and the key (`web_view/page.login_nonce_item`), puts it in the
// form and posts it to this same address, which is where the daemon verifies
// the login. The nonce is what a cookie alone cannot supply, so a cookie
// planted by another page, or copied from a cookie file, resumes nothing.
//
// A browser with no nonce under this key (a new profile, cleared storage, a
// private window) has nothing to post. It is told so, and how to sign in
// again, by the paragraph the document already holds.
(function () {
  var found = /^\/ui\/l\/([0-9a-f]{32})\/home$/.exec(location.pathname);
  var form = document.getElementById("login-form");
  var help = document.getElementById("login-help");
  var status = document.getElementById("login-status");
  var nonce = null;
  if (found) {
    try {
      nonce = localStorage.getItem("loom.login." + found[1]);
    } catch (e) { nonce = null; }
  }
  if (form && nonce && /^[0-9a-f]{64}$/.test(nonce)) {
    form.elements["nonce"].value = nonce;
    form.submit();
    return;
  }
  if (status) { status.textContent = "This browser is not signed in."; }
  if (help) { help.hidden = false; }
})();
