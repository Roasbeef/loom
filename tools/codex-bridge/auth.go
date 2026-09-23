package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
const deviceURL = "https://auth.openai.com/codex/device"
const deviceRedirect = "https://auth.openai.com/deviceauth/callback"
const browserRedirect = "http://localhost:1455/auth/callback"
const oauthScope = "openid profile email offline_access api.connectors.read api.connectors.invoke"

var errNotLoggedIn = errors.New("not logged in")
var errCredentialUnavailable = errors.New("credential unavailable")
var errRefreshFailed = errors.New("refresh failed")

type authClient struct {
	http  *http.Client
	base  string
	store *profileStore
}

func (a *authClient) postJSON(ctx context.Context, path string, value any, out any) (int, error) {
	buf, err := json.Marshal(value)
	if err != nil {
		return 0, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.base+path, strings.NewReader(string(buf)))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := a.http.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return resp.StatusCode, nil
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(out); err != nil {
		return resp.StatusCode, errors.New("invalid authentication response")
	}
	return resp.StatusCode, nil
}

func (a *authClient) exchange(ctx context.Context, values url.Values, old *credential) (credential, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.base+"/oauth/token", strings.NewReader(values.Encode()))
	if err != nil {
		return credential{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := a.http.Do(req)
	if err != nil {
		return credential{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return credential{}, errors.New("token exchange rejected")
	}
	var data struct {
		Access  string `json:"access_token"`
		Refresh string `json:"refresh_token"`
		Expires int    `json:"expires_in"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&data); err != nil || data.Access == "" || data.Expires <= 0 {
		return credential{}, errors.New("invalid token response")
	}
	account, email, plan, residency, err := tokenClaims(data.Access)
	if err != nil {
		return credential{}, err
	}
	if old != nil {
		if old.AccountID != account {
			return credential{}, errAccountMismatch
		}
		if data.Refresh == "" {
			data.Refresh = old.Refresh
		}
	} else if data.Refresh == "" {
		return credential{}, errors.New("refresh token missing")
	}
	return credential{Access: data.Access, Refresh: data.Refresh, Expires: time.Now().Add(time.Duration(data.Expires) * time.Second), AccountID: account, Email: email, Plan: plan, Residency: residency}, nil
}

// current serializes refresh with credential persistence. A failed refresh
// never overwrites the previous token pair.
func (a *authClient) current(ctx context.Context, force bool) (credential, error) {
	a.store.mu.Lock()
	defer a.store.mu.Unlock()
	c, err := a.store.loadLocked()
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return credential{}, errNotLoggedIn
		}
		return credential{}, errCredentialUnavailable
	}
	if !force && time.Until(c.Expires) > 60*time.Second {
		return c, nil
	}
	values := url.Values{"grant_type": {"refresh_token"}, "client_id": {codexClientID}, "refresh_token": {c.Refresh}}
	updated, err := a.exchange(ctx, values, &c)
	if err != nil {
		if errors.Is(err, errAccountMismatch) {
			return credential{}, err
		}
		return credential{}, errRefreshFailed
	}
	if err := a.store.saveLocked(updated); err != nil {
		return credential{}, errRefreshFailed
	}
	return updated, nil
}

func (a *authClient) loginDevice(ctx context.Context, send func(event)) error {
	var init struct {
		DeviceID string          `json:"device_auth_id"`
		UserCode string          `json:"user_code"`
		Interval json.RawMessage `json:"interval"`
	}
	status, err := a.postJSON(ctx, "/api/accounts/deviceauth/usercode", map[string]string{"client_id": codexClientID}, &init)
	if err != nil || status != 200 || init.DeviceID == "" || init.UserCode == "" {
		return errors.New("device authorization unavailable")
	}
	interval := 5
	if len(init.Interval) > 0 {
		if err := json.Unmarshal(init.Interval, &interval); err != nil {
			var asString string
			if json.Unmarshal(init.Interval, &asString) == nil {
				if parsed, err := strconv.Atoi(asString); err == nil {
					interval = parsed
				}
			}
		}
	}
	if interval < 5 {
		interval = 5
	}
	if interval > 30 {
		interval = 30
	}
	send(event{Event: "login_instructions", URL: deviceURL, UserCode: init.UserCode})
	for polls := 0; polls < 120; polls++ {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(interval+3) * time.Second):
		}
		var result struct {
			Code     string `json:"authorization_code"`
			Verifier string `json:"code_verifier"`
		}
		status, err := a.postJSON(ctx, "/api/accounts/deviceauth/token", map[string]string{"device_auth_id": init.DeviceID, "user_code": init.UserCode}, &result)
		if err != nil {
			return errors.New("device authorization failed")
		}
		if status == 403 || status == 404 {
			continue
		}
		if status != 200 || result.Code == "" || result.Verifier == "" {
			return errors.New("device authorization rejected")
		}
		values := url.Values{"grant_type": {"authorization_code"}, "client_id": {codexClientID}, "code": {result.Code}, "code_verifier": {result.Verifier}, "redirect_uri": {deviceRedirect}}
		c, err := a.exchange(ctx, values, nil)
		if err != nil {
			return err
		}
		if err := a.store.saveLogin(c); err != nil {
			if errors.Is(err, errAccountMismatch) {
				return err
			}
			return errors.New("credential persistence failed")
		}
		send(event{Event: "login_complete", Plan: c.Plan})
		return nil
	}
	return errors.New("device authorization timed out")
}

func randomURLToken() (string, error) {
	var bytes [32]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(bytes[:]), nil
}

// loginBrowser binds the exact allowlisted callback before exposing the
// authorization URL. State and PKCE bind the callback to this invocation.
func (a *authClient) loginBrowser(ctx context.Context, send func(event)) error {
	verifier, err := randomURLToken()
	if err != nil {
		return errors.New("browser login unavailable")
	}
	state, err := randomURLToken()
	if err != nil {
		return errors.New("browser login unavailable")
	}
	listener, err := net.Listen("tcp", "localhost:1455")
	if err != nil {
		return errors.New("browser callback port unavailable")
	}
	defer listener.Close()
	challenge := sha256.Sum256([]byte(verifier))
	params := url.Values{
		"response_type": {"code"}, "client_id": {codexClientID},
		"redirect_uri": {browserRedirect}, "scope": {oauthScope},
		"code_challenge":        {base64.RawURLEncoding.EncodeToString(challenge[:])},
		"code_challenge_method": {"S256"}, "state": {state},
		"id_token_add_organizations": {"true"},
		"codex_cli_simplified_flow":  {"true"}, "originator": {"loom"},
	}
	code := make(chan string, 1)
	handler := http.NewServeMux()
	handler.HandleFunc("/auth/callback", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Query().Get("state") != state || r.URL.Query().Get("code") == "" {
			http.Error(w, "Invalid login callback", http.StatusBadRequest)
			return
		}
		select {
		case code <- r.URL.Query().Get("code"):
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			_, _ = io.WriteString(w, "Login complete. You can return to Loom.")
		default:
			http.Error(w, "Login already completed", http.StatusConflict)
		}
	})
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = server.Serve(listener) }()
	defer server.Close()
	send(event{Event: "login_instructions", URL: a.base + "/oauth/authorize?" + params.Encode()})
	deadline, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	var authorizationCode string
	select {
	case <-deadline.Done():
		return deadline.Err()
	case authorizationCode = <-code:
	}
	values := url.Values{"grant_type": {"authorization_code"}, "client_id": {codexClientID}, "code": {authorizationCode}, "code_verifier": {verifier}, "redirect_uri": {browserRedirect}}
	c, err := a.exchange(deadline, values, nil)
	if err != nil {
		return err
	}
	if err := a.store.saveLogin(c); err != nil {
		if errors.Is(err, errAccountMismatch) {
			return err
		}
		return errors.New("credential persistence failed")
	}
	_ = server.Close()
	send(event{Event: "login_complete", Plan: c.Plan})
	return nil
}
