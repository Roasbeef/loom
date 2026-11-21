// The passkey sign-in page's script (protocol-change/127). The document holds one
// form whose data attributes carry the challenge the daemon issued and the
// relying party id it expects. A press on the button asks the browser for an
// assertion with user verification required, puts the four results in the form's
// hidden fields as base64url and submits it to the same origin, which is where
// the daemon verifies it. The script reads nothing from storage and keeps
// nothing: the sign-in is the daemon's answer to the form, and the page it opens
// is handed the login's key and nonce by the exchange page, as every sign-in is.
//
// A browser without WebAuthn, or a document whose attributes are not the shapes
// the daemon writes, is told so by the paragraph the document already holds.
(function () {
  var form = document.getElementById("signin-form");
  var button = document.getElementById("signin-button");
  var status = document.getElementById("signin-status");

  function say(words) {
    if (status) { status.textContent = words; }
  }

  // Base64url without padding, to and from bytes.
  function toBytes(text) {
    var padded = text.replace(/-/g, "+").replace(/_/g, "/");
    while (padded.length % 4 !== 0) { padded += "="; }
    var raw = atob(padded);
    var out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) { out[i] = raw.charCodeAt(i); }
    return out;
  }

  function toText(buffer) {
    var bytes = new Uint8Array(buffer);
    var raw = "";
    for (var i = 0; i < bytes.length; i++) { raw += String.fromCharCode(bytes[i]); }
    return btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  if (!form || !button) { return; }
  var challenge = form.getAttribute("data-challenge") || "";
  var rpId = form.getAttribute("data-rp-id") || "";
  if (!window.PublicKeyCredential || !navigator.credentials) {
    say("This browser cannot use passkeys on this address.");
    button.disabled = true;
    return;
  }
  if (!/^[A-Za-z0-9_-]{43}$/.test(challenge) || rpId === "") {
    say("This page could not be read. Reload it.");
    button.disabled = true;
    return;
  }

  button.addEventListener("click", function () {
    button.disabled = true;
    say("");
    navigator.credentials.get({
      publicKey: {
        challenge: toBytes(challenge),
        rpId: rpId,
        userVerification: "required",
        timeout: 300000
      }
    }).then(function (credential) {
      var response = credential.response;
      form.elements["id"].value = toText(credential.rawId);
      form.elements["cdj"].value = toText(response.clientDataJSON);
      form.elements["ad"].value = toText(response.authenticatorData);
      form.elements["sig"].value = toText(response.signature);
      form.submit();
    }, function () {
      say("No passkey was used. Press the button to try again, or reload this page.");
      button.disabled = false;
    });
  });
})();
