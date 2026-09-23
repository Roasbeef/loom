# Experimental Codex subscription bridge

This binary is an isolated credential and HTTP transport owner for Loom's
experimental ChatGPT subscription dialect. It does not read Codex CLI's
`~/.codex/auth.json`, accept a caller-supplied URL, or accept a bearer token
through its protocol. OpenAI has not documented the ChatGPT backend route as a
public third-party inference API. Its behavior can change independently of the
public Responses API, so this is an experimental compatibility implementation.

The browser and device OAuth flow, token exchange, account claims, model
discovery, and transport headers were checked against
[oh-my-pi at `da58b16f`](https://github.com/can1357/oh-my-pi/tree/da58b16f424273605795435a6753778f422baff3).
The helper pins the Codex client version to `0.155.1`. It uses the fixed
`auth.openai.com` OAuth host and the fixed
`chatgpt.com/backend-api/codex/responses` and `/codex/models` routes. The
`/models` fallback is also fixed. It refuses redirects.

## Ownership and protocol

Run `codex-bridge --profile NAME`, with `NAME` matching
`[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}`. Only one process may own a profile; an
advisory lock is held until exit. Credentials live at the OS user config
directory under `loom/codex-subscription/NAME.json`. The helper requires a
private directory and writes the credential file with mode `0600` through an
atomic rename. Refresh is serialized, and a token refresh cannot change the
bound ChatGPT account. Login cannot switch an existing profile to another
account without an explicit logout.

Stdin and stdout carry a 4-byte big-endian length followed by JSON, at most
4 MiB per frame. All frames use `v: 1` and an `id` chosen by Loom. Input
commands are `status`, `logout`, `login_browser`, `login_device`, `models`,
`request`, and `cancel`. Every command includes the profile name, which must
match the process's `--profile` argument. A request also includes `body_b64`,
the base64-encoded Responses JSON body. The helper requires a model, `stream:
true`, and `store: false`. It checks the model against fresh account-scoped
discovery before submitting inference.

Output events are `status` (`code: logged_in` or `logged_out`, optional plan),
`login_instructions` (`url` for browser login or `url` and `user_code` for
device login), `login_complete` (optional plan), `logout_complete`, `models`
(validated IDs, context windows and reasoning levels), `http_status`, `chunk`
(`data_b64` raw SSE bytes), `end`, `cancel_ack`, and `error` (sanitized code).
Account IDs, email addresses, access tokens, refresh tokens, HTTP response
headers and raw authentication errors never enter stdout frames. The helper
uses the account ID privately for backend routing.
An unreadable or unsafe credential file reports `credential_unavailable`
rather than appearing as a logged-out profile.

`cancel_ack` follows cancellation of the active HTTP request and closure of
its response body or browser callback server. Every command's `end` follows
its completion, including when an `error` frame reports a sanitized failure.
For asynchronous commands, it follows worker cleanup. The caller keeps the
stream open through `end` or `cancel_ack`.
A 401 permits one token refresh and one replay before any response bytes are
emitted. Other failures are reported without replay.

## Validation

Run `go test ./...` inside this module. Tests use dummy JWTs and mock HTTP
servers; they cover browser PKCE and state, cross-process lock exclusion,
permission checks, account-switch rejection, serialized refresh, model
admission, 401 replay, redirect refusal and protocol bounds. No test spends
subscription usage or uses an operator credential.
