package ghproxy

import (
	"crypto/subtle"
	"encoding/base64"
	"net/http"
	"strings"
)

// injector replaces the per-VM placeholder with the real token in the
// Authorization header and nowhere else. The three forms are the ones GitHub's
// clients send: git speaks Basic with the username x-access-token and the
// token as the password, and gh speaks "token X" or "Bearer X".
//
// Only an exact match counts. A header that merely contains the placeholder,
// or a placeholder in the URL, a body or any other header, is forwarded
// unchanged, so the token reaches GitHub only where a client was asked to put
// a credential.
type injector struct {
	placeholder string
	token       string
}

// apply rewrites every Authorization value of h that carries the placeholder
// and reports whether it replaced one.
func (i injector) apply(h http.Header) bool {
	values := h.Values("Authorization")
	replaced := false

	for n, v := range values {
		if out, ok := i.rewrite(v); ok {
			values[n] = out
			replaced = true
		}
	}

	if replaced {
		h["Authorization"] = values
	}

	return replaced
}

// rewrite substitutes in one header value. It returns false when the value is
// not a credential of a known scheme or does not carry the placeholder.
func (i injector) rewrite(value string) (string, bool) {
	scheme, credential, ok := strings.Cut(strings.TrimSpace(value), " ")
	if !ok {
		return "", false
	}

	credential = strings.TrimSpace(credential)

	switch strings.ToLower(scheme) {
	case "token", "bearer":
		if !i.isPlaceholder(credential) {
			return "", false
		}

		return scheme + " " + i.token, true

	case "basic":
		return i.rewriteBasic(scheme, credential)

	default:
		return "", false
	}
}

// rewriteBasic substitutes in a Basic credential. The decoded form is
// user:password; the placeholder may stand as either whole field, because a
// client configured with the token as its username (a common pattern for
// token-only HTTP auth) sends it that way.
func (i injector) rewriteBasic(scheme, encoded string) (string, bool) {
	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "", false
	}

	user, password, ok := strings.Cut(string(raw), ":")
	if !ok {
		return "", false
	}

	switch {
	case i.isPlaceholder(password):
		password = i.token

	case i.isPlaceholder(user):
		user = i.token

	default:
		return "", false
	}

	return scheme + " " + base64.StdEncoding.EncodeToString([]byte(user+":"+password)), true
}

// isPlaceholder compares in constant time. A comparison that stops at the first
// differing byte would let a guest recover the placeholder one byte at a time
// from the response timing, which would turn a value that is worthless outside
// this proxy into one that selects where the token is spent.
func (i injector) isPlaceholder(s string) bool {
	return subtle.ConstantTimeCompare([]byte(s), []byte(i.placeholder)) == 1
}
