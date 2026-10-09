# Sign in with ChatGPT

Loom's native subscription provider implements OpenAI's documented
[Sign in with ChatGPT flow for open-source apps](https://developers.openai.com/siwc/token-sharing-open-source/sign-in).
The browser grants an application permission to use ChatGPT plan allowance.
Loom then sends its own history and tool definitions to the public Responses
API at `https://api.openai.com/v1/responses`, with `store: false` and
`stream: true`. Loom owns the conversation, tool execution, policy, and agent
loop. Account model discovery uses authenticated `GET /v1/models` on the same
public API origin.
[Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference).

The catalogue keeps `dialect = "codex-subscription"`, `auth = "codex"`, and
the `loomd codex` command spelling for compatibility. The native path uses
Gleam modules in the server's BEAM application. It requires browser PKCE login;
the old Go helper and device grant are outside this authentication path.
Platform API-key inference remains a separately configured `openai-responses`
provider with usage-based Platform billing.

## Sign in

Run the command on the machine that will make subscription requests:

```sh
loomd codex login --profile personal
```

Open its printed `http://127.0.0.1:PORT/auth/start` URL in a browser on that
machine. The listener binds an ephemeral port on literal `127.0.0.1`; it
checks the exact bound Host authority before exposing the authorization
redirect or accepting a callback. The displayed URL contains no credential.
Only the browser receives the issuer redirect, including a returning
profile's signed identity hint. Login expires after ten minutes.
Loom has no device-code flow, so `--device` is refused like any unknown
argument.

Profile names contain 1-64 ASCII letters, digits, underscores, or hyphens,
and start with a letter or digit. Omitting `--profile` selects `default`.
Loom stores native profiles under
`$XDG_CONFIG_HOME/loom/chatgpt-subscription`, or
`$HOME/.config/loom/chatgpt-subscription` when `XDG_CONFIG_HOME` is unset.
Loom doesn't import an installed Codex CLI login or the old helper's grants.
Sign in again to create the native grant.

A new profile sends `client_id=dynamic_agent_client`, a stable
`ext_agent_host_id`, PKCE challenge, state, and nonce. It saves the issued
client ID together with the grant, only after the code exchange and ID token
verification succeed; a callback whose exchange fails leaves the profile
without a registration. Gose validates the ID token's
RS256 signature against the fixed issuer JWKS, its issuer, issued-client
audience, expiry, nonce, and nonempty subject. Multiple audiences also
require the matching authorized party. A returning login reuses the saved
client and host binding; a different account cannot silently replace that
registration.
[Profiles and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions).

Identity permission and permission to spend plan allowance are distinct.
An identity-only grant is saved, including when no refresh token was issued.
Inference and model discovery require both `resource.invoke` and
`chatgpt.tokens.use.direct`; otherwise Loom reports
`plan_permission_required`. Sign in again and grant plan usage to enable
those operations. A signed-in status describes the saved grant, and does
not prove that a live request is entitled or that its access token is fresh.

## A browser on another machine

For a headless remote host, start login there and leave it waiting. Read
`PORT` from the printed URL. In a second terminal on your browser machine,
forward that exact port to the remote machine:

```sh
ssh -N -L 127.0.0.1:PORT:127.0.0.1:PORT user@remote
```

Replace both `PORT` occurrences with the printed number, then open the
unchanged printed URL in your local browser. Keep the SSH tunnel open through
the callback. The local and remote ports must match because the selected
callback URI and Host authority belong to that attempt. If the local port
is occupied, free it or start a fresh login attempt. The SSH tunnel carries
the callback to the remote listener; credentials stay with the remote
profile. Copying a token file is unnecessary. This forwarding procedure
has not been tested against a live account.

## Configure Loom

Inspect the account's visible model IDs:

```sh
loomd codex status --profile personal
loomd codex models --profile personal
```

The subscription response contains `models` entries identified by `slug`.
Loom lists only entries with `visibility = "list"`, preserves the server's
order, and emits bounded JSON containing model IDs only. Account
visibility does not establish context windows, output limits, reasoning
capabilities, or successful inference. Configure those properties using the
model's documented capabilities and Loom's local limits.

Create `~/.loom/loom.toml` with a subscription entry and role route. Replace
`MODEL_ID_FROM_MODELS` with an exact visible ID. The numeric limits below
are configuration examples, not metadata returned by model discovery.

```toml
[models.codex-personal]
dialect = "codex-subscription"
auth = "codex"
profile = "personal"
model_id = "MODEL_ID_FROM_MODELS"
context_window = 128000
max_output_tokens = 8192
thinking = "off"

[roles]
main = ["codex-personal"]
subagent = ["codex-personal"]
```

A session reads the configuration when it is created, opened, or resumed.
Stop and reopen an existing session after changing its configuration. The
`[daemon]` and `[peers]` tables require a daemon restart. Several model entries
can use the same credential profile. Keep an existing entry name stable:
that name is Loom's durable provider identity.

### Keep Baseten as the default and select a Codex role profile

There are two separate profiles. `loomd codex login --profile personal`
creates a credential record. `[profiles.codex.roles]` creates a named set of
role routes, selected with `loom --model-profile codex`. A role profile contains
model entry names; each subscription entry points to its credential profile.

Keep your existing Baseten model entry and settings. In the following example
it is called `baseten-oss`; substitute its actual name in each role chain.
Add three subscription entries to the same configuration. Model IDs vary by
account; confirm them with `codex models` before using them. The output ceilings are local choices.

```toml
[models.codex-sol-6-1]
dialect = "codex-subscription"
auth = "codex"
profile = "personal"
model_id = "gpt-6.1-sol"
context_window = 272000
max_output_tokens = 32768
thinking = "low"

[models.codex-worker]
dialect = "codex-subscription"
auth = "codex"
profile = "personal"
model_id = "gpt-6-luna"
context_window = 272000
max_output_tokens = 8192
thinking = "medium"

[models.codex-astra]
dialect = "codex-subscription"
auth = "codex"
profile = "personal"
model_id = "gpt-6-astra"
context_window = 272000
max_output_tokens = 8192
thinking = "medium"

# These are the default routes when no role profile is selected.
[roles]
main = ["baseten-oss"]
subagent = ["baseten-oss"]
summarize = ["baseten-oss"]
advisor = ["baseten-oss"]

# Sol main, Luna children and summaries, Astra advisor.
[profiles.codex.roles]
main = ["codex-sol-6-1"]
subagent = ["codex-worker"]
advisor = ["codex-astra"]
summarize = ["codex-worker"]

# This optional split inherits Baseten main and advisor.
[profiles.codex-split.roles]
subagent = ["codex-worker"]
summarize = ["codex-worker"]
```

Merge these role keys into your existing `[roles]` table; do not define that
table twice. Other routes, such as `advisor` and `vision`, are inherited when a
profile omits them. A profile replaces each named chain whole. Its selection
is saved with the session, so resuming that session keeps the same profile.
`/model` changes one strand's selected entry; it does not select a role profile.
A sub-agent's explicit model argument can override the `subagent` default.

All three ChatGPT entries share `profile = "personal"`, so one login is sufficient.
Separate credential profiles have independent registration and grant records,
but do not create extra plan allowance for the same account.

The per-session `summarize` route serves structural block summaries and agent
activity descriptions. Shared workspace-domain memory maintenance uses the
configuration's default roles, because several sessions may share that domain.
Thus the split above keeps shared-domain distillation on Baseten. Current
compaction builds local notes and checkpoints; configuring `summarize` does not
add a model call to that compaction path.

Responses requests opt into `reasoning.summary = "auto"`. The readable thinking
blocks contain the provider's reasoning summary; encrypted reasoning remains
opaque replay data. Loom may condense a long provider summary into a short
collapsed-block headline through the `summarize` role. Expanding that block
shows the original provider summary. This headline does not replace encrypted
reasoning or the original summary in conversation replay.

Subscription entries reject `api_key_env`, `base_url`, and custom headers.
To configure Platform billing, use `openai-responses` with `auth = "api-key"`
and an `api_key_env` name. Configured subscription prices are API reference
estimates, not ChatGPT plan credits or account charges. Failed attempts retain
reported usage; missing usage or pricing remains unknown or partial.

## Select Daybreak on a specific model

Model selection and cybersecurity access are separate. An exact model entry can
select Daybreak Blue through the operator-owned `cyber_access` key:

```toml
[models.codex-sol-6-blue]
dialect = "codex-subscription"
auth = "codex"
profile = "personal"
model_id = "gpt-6-sol"
cyber_access = "daybreak_blue"
context_window = 272000
max_output_tokens = 32768
thinking = "medium"
```

After loading the updated configuration, use `/model codex-sol-6-blue` in the
terminal. The numeric limits are conservative local budgets. The entry sends
`model = "gpt-6-sol"` and `access_programs.cyber = "daybreak_blue"`; it uses the
saved ChatGPT login. The same key works with the API-key `openai-responses`
dialect, whose billing remains separate.

Omitting `cyber_access` leaves the server's default selection in place.
`standard` explicitly selects standard safeguards. Unsupported dialects and
invalid values refuse configuration; a remote permission denial stays a failed
request. A retryable service failure can still use an operator-configured
fallback, which sends its own entry's access selection.

The [Daybreak guide](https://developers.openai.com/api/docs/guides/daybreak)
documents eligible models and required approval. Sol 6.1 and Astra require
Daybreak Red approval even when the request selects `daybreak_blue`. A model's
self-description does not prove the selected model or program. Read provider
response metadata for that evidence.

An alias such as `gpt-daybreak-blue-latest` can echo the alias in response
metadata without naming the underlying model, so it is distinct from
explicitly selecting a model such as `gpt-6-sol`.

To run a whole session on Daybreak, give the entry its own role profile and
select it with `loom --model-profile codex-blue`. Roles the profile omits
inherit `[roles]`, so this one keeps the native child, advisor and summary
routes from the `codex` example above:

```toml
[profiles.codex-blue.roles]
main = ["codex-sol-6-blue"]
subagent = ["codex-worker"]
advisor = ["codex-astra"]
summarize = ["codex-worker"]
```

## Test end to end

Build both the server and terminal from your checkout. Use a fresh state
directory and a trial workspace outside `/tmp`, which the jail replaces with
scratch storage. The following commands keep the installed daemon's state
separate. `LOOM_ROOT` names this checkout; `TRIAL_CONFIG` is a copy of your
configuration with the entries and profiles above.

```sh
LOOM_ROOT=<path to your Loom checkout>
TRIAL_CONFIG="$HOME/.loom-codex-e2e.toml"
TRIAL_STATE="$HOME/.loom-codex-e2e"
TRIAL_WORKSPACE="$HOME/loom-codex-e2e-workspace"

cd "$LOOM_ROOT"
make codemode-seed
make release
make tui-shipment
mkdir -p "$TRIAL_WORKSPACE"

LOOMD="$LOOM_ROOT/build/release/loom/bin/loomd"
"$LOOMD" codex login --profile personal
"$LOOMD" codex status --profile personal
"$LOOMD" codex models --profile personal

# Fill TRIAL_CONFIG with your existing Baseten entry and the profile example.
"$LOOM_ROOT/bin/loom" \
  --server "$LOOMD" --state-dir "$TRIAL_STATE" \
  --config "$TRIAL_CONFIG" --workspace "$TRIAL_WORKSPACE" \
  --model-profile codex
```

1. **Native main inference.** Ask for a short explanation. Confirm the main
   strand uses Sol 6.1 and returns an answer. A successful models listing
   alone does not prove inference entitlement.
2. **A real tool round trip.** Ask it to create `hello.txt` containing one line,
   read it back through a tool, and quote the contents. Check the file yourself
   in the trial workspace. This exercises request encoding, tool-call streaming,
   local execution, and the next Responses request with the tool result.
3. **Worker routing.** Ask it to delegate a short, read-only inspection of that
   file to a child without a model override. Inspect the child strand and confirm
   Luna. Check that it returns the result to main. Ask main to use `code_mode`
   to read the same file, so the satellite and capability broker are exercised.
   The automatic advisor should complete its review on Astra; a quiet verdict
   is a successful review and need not produce a visible nudge.
4. **Summaries.** Run enough child activity for an activity description or a
   structural block summary. The `codex` profile routes `summarize` only to
   `codex-worker`, so a summary requested under it can use no other entry.
   Loom does not display which entry served a request; judge the step by the
   summary appearing and by the absence of authentication errors. Normal
   compaction and shared-domain maintenance do not exercise this per-session
   route.
5. **Split profile.** Create another new session with `--model-profile codex-split`.
   Confirm main uses Baseten and an unoverridden child uses `codex-worker`.
   Create a new session without `--model-profile` to confirm the default worker
   and summarizer routes remain Baseten. Existing sessions retain their original
   profile; give each trial its own workspace or choose New session explicitly.
6. **Resume and stop.** Close and resume the trial session. Its saved profile and
   transcript should remain intact. Stop a long native response and check that
   the session accepts another prompt. The local native fixture tests cover
   cancellation custody; this step checks the real account transport.

If status shows an identity-only grant, sign in again and grant plan usage.
`plan_permission_required` is an authorization refusal, not a model-name error.
If discovery works but inference fails, record the exact model ID and the
in-band error; do not infer model support from visibility. API reference costs
in the UI are estimates and do not show actual plan allowance remaining.

## Refresh and logout

Each operation acquires a bounded cross-process lock for its profile, rereads
its protected record, and atomically saves any rotated grant before releasing
the lock. No bearer cache survives across operations. The lock is released
before inference HTTP begins, so status, model discovery, login, and logout
can run while a stream is active. Login holds the lock through its browser
attempt; another operation reports `profile_busy` after a five-second wait.

```sh
loomd codex logout --profile personal
```

Logout attempts revocation of the saved refresh token, clears the local grant,
and retains the host, issued client, and verified subject for returning login.
If revocation cannot be confirmed, Loom still clears the local grant and asks
the operator to review the grant in ChatGPT settings. Logout does not retract
an already-admitted network request. Terminal refresh failures clear the grant
while preserving its registration; temporary endpoint failures preserve the
last durable grant. Tokens belong only in the protected profile and native
HTTP authorization boundary, never in catalogue entries or terminal output.

The prepared operation's surviving Weft scope adopts HTTP and callback
listener owners before admission. Cancellation or consumer loss closes those
owners, and a normal operation-owner exit proves their original drain
witnesses have completed.

## What the fixtures cover

Account model discovery returns `models[].slug` with a `visibility` field,
not the Platform API's `data[].id`. Regressions cover listed-model projection,
metadata omission, malformed entries, and bounds checked before visibility
filtering. Three stream properties of the subscription endpoint are also
covered: the native creator stays alive until its HTTP owner drains, a terminal
response may carry `output: []` after every streamed item has closed, and an
added message may already carry `status: completed` before its content
streams. Content closure, the tool namespace and populated terminal
consistency remain checked.

Native fixtures cover signed identity, PKCE callback binding, actual loopback
Host validation, concurrent refresh, logout, bounded HTTP, CLI rendering, and
cancellation custody. The role-profile regression checks that selected worker
and summary roles reach the shared native credential profile while default
Baseten routes remain unchanged.

Fixtures and release smokes do not establish that an account is entitled to a
model, or that a live login, inference request, or subscription tool turn
succeeds. The operator trial above is the check for those. The
[architecture note](architecture/codex-subscription.md) describes the design
and its custody rules.
