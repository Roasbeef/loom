// The passkey registration page's script (protocol-change/127). The owner's fresh
// home links to this page, whose document holds one form: the data attributes
// carry the challenge the daemon issued, the relying party id it expects, the
// principal's opaque handle and name, and the page's key. A press on the button
// asks the browser to create an ES256 passkey that is discoverable and needs user
// verification, puts the credential id, the client data, the authenticator data
// and the public key (SubjectPublicKeyInfo DER) in the form's hidden fields as
// base64url, adds the page's nonce, which this tab kept in sessionStorage under
// `loom-page-nonce.` and the page's key (`web_view/page.nonce_item`), and submits
// the form to the same origin, which answers by moving the tab back to the home.
//
// A browser that does not offer `getPublicKey` or `getAuthenticatorData` on the
// attestation response cannot register here, because the daemon reads no CBOR,
// and is told so. A tab with no nonce for this page's key is told to open the
// page from the home.
(function () {
  var form = document.getElementById("passkey-form");
  var button = document.getElementById("passkey-button");
  var status = document.getElementById("passkey-status");

  function say(words) {
    if (status) { status.textContent = words; }
  }

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
  var user = form.getAttribute("data-user") || "";
  var name = form.getAttribute("data-name") || "";
  var key = form.getAttribute("data-key") || "";
  var nonce = null;
  try {
    nonce = sessionStorage.getItem("loom-page-nonce." + key);
  } catch (e) { nonce = null; }

  if (!window.PublicKeyCredential || !navigator.credentials) {
    say("This browser cannot use passkeys on this address.");
    button.disabled = true;
    return;
  }
  if (!/^[A-Za-z0-9_-]{43}$/.test(challenge) || !/^[A-Za-z0-9_-]{43}$/.test(user) || rpId === "") {
    say("This page could not be read. Open it again from the home.");
    button.disabled = true;
    return;
  }
  if (!nonce || !/^[0-9a-f]{64}$/.test(nonce)) {
    say("This tab did not open the page from the home. Go back to the home and press Add a passkey.");
    button.disabled = true;
    return;
  }

  button.addEventListener("click", function () {
    button.disabled = true;
    say("");
    navigator.credentials.create({
      publicKey: {
        challenge: toBytes(challenge),
        rp: { id: rpId, name: "Loom" },
        user: { id: toBytes(user), name: name, displayName: name },
        pubKeyCredParams: [{ type: "public-key", alg: -7 }],
        authenticatorSelection: {
          residentKey: "required",
          requireResidentKey: true,
          userVerification: "required"
        },
        attestation: "none",
        timeout: 300000
      }
    }).then(function (credential) {
      var response = credential.response;
      if (typeof response.getPublicKey !== "function" ||
          typeof response.getAuthenticatorData !== "function") {
        say("This browser does not hand over the passkey's public key, so it cannot add one here.");
        button.disabled = false;
        return;
      }
      var publicKey = response.getPublicKey();
      if (!publicKey) {
        say("This passkey does not use ES256, which is the only kind Loom accepts.");
        button.disabled = false;
        return;
      }
      form.elements["nonce"].value = nonce;
      form.elements["id"].value = toText(credential.rawId);
      form.elements["cdj"].value = toText(response.clientDataJSON);
      form.elements["ad"].value = toText(response.getAuthenticatorData());
      form.elements["pk"].value = toText(publicKey);
      form.submit();
    }, function () {
      say("No passkey was added. Press the button to try again, or reload this page.");
      button.disabled = false;
    });
  });
})();
