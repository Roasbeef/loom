# Account pool: rotating among several subscription seats

Status: **a proposal, not a decision**. Written against `main` at `47fb2c168`
on 2026-11-11. Only the pure ledger in `provider/pool.gleam` is implemented;
it is not yet called by anything, so no request routes differently. Every claim
about existing machinery names the module it comes from, and every claim about
a provider names the source it was read from or says that none was found.

## 1. The question

A consumer that runs many agent sessions on plan seats meets a plan's usage
limit as a hard stop: a five-hour window for some plans, a weekly window for
all of them. The request is for loom to hold several credentials for one
provider, use one, move to another when the first is refused for exhausted
allowance, come back when the first resets, and, where the provider says how,
report what is left on each.

Three of the questions are about loom's own shape (where it lives, what state
it keeps, what happens to a session in flight). Two are about what the
providers expose (the gauge) and permit (the terms). The terms decide whether
the feature should be built at all, so section 7 is written to be read first.

## 2. Where it lives

### What loom does today

- A `[models.<name>]` entry with `dialect = "codex-subscription"` names one
  credential `profile`. `gateway.CodexSubscriptionProvider(name, profile)`
  carries that name and nothing else; `gateway.subscription_attempt` hands it
  to `CodexTransport.prepare_streaming(profile, request, events)`, which is
  `client/codex/transport.gleam`. Authorization (`client/codex/profile.auth`)
  runs inside the bridge's parked worker after the begin permit, rereading the
  profile's protected record under a file lock and refreshing the grant if it
  is near expiry. No bearer survives the call.
- Several model entries may share one profile (`docs/codex-subscription.md`).
  A role route is an ordered chain of entries, and the gateway walks it only
  on a *retryable* failure (`retry.classify`, `gateway.continue_terminal`).
- A usage-limit refusal is not retryable. `usage_limit_reached` is in
  `provider/internal/error_code.gleam`'s permanent vocabulary, and a permanent
  429 classifies as `Terminal`, so the gateway delivers it in-band and does not
  walk to the next chain entry. The reset time is also gone by then: the
  adapter keeps the error type, a fixed phrase and `retry_after_ms`, and drops
  the body's `resets_at`.
- `harness/routing.gleam` states a ruling this design must respect: routing
  is a pure function of durable state and boot configuration, with "no
  per-request rerouting, no mutable role registry, no health tracking and no
  sticky chain position". A captured model identity that does not head a role
  chain dispatches `ForResolved` and never walks.
- The Claude route does not exist in loom. `provider/adapter/anthropic` speaks
  the Messages API with an API key from the secret store. There is no plan
  sign-in for Claude in loom.

### Two shapes, and the one proposed

*A pool as a role chain.* Give each seat its own model entry and list them in
a chain. This needs no new type, but it fails three ways. A usage-limit refusal
does not walk (above). Each entry is a distinct durable identity, so a
transcript and a cost ledger split by seat, and a strand whose captured
identity is not the chain head dispatches `ForResolved` and never rotates.
And the head is tried first on every request, so an exhausted head costs a
refused round trip each time unless something remembers it, which is the health
tracking the routing ruling excludes.

*A pool beneath one entry* (proposed). The entry names a pool where it names a
profile today. The durable identity stays the one logical entry, and the choice
of credential happens at dispatch, below the gateway, in the same place the
credential is already chosen. This does not conflict with the routing ruling:
the pool is credential custody, like the grant refresh the bridge already does,
not a decision about which model answers. A transcript records the entry, not
the seat, so rotation does not rewrite history.

The smallest shape is then:

- **Configuration.** A pool is a name and an ordered list of existing profile
  names, `[codex.pools.<name>] members = ["seat-a", "seat-b"]`, plus an
  optional hold for a refusal with no reset time. A `profile = "<name>"` that
  names a pool selects the pool; a pool name and a profile name share one
  namespace and a collision is refused at load. Nothing is discovered: a seat
  is in the pool only because the operator listed it.
- **The ledger.** `provider/pool.gleam`, pure and implemented here. Each member
  is `Available`, `Exhausted(until)` or `Unusable(cause)`. It is a `step` over
  an event with the time passed in, so it has no clock, no process and no
  credential. Its transition table is in the module doc and gated by lint R14.
- **The owner.** One `weft/actor` in `client` holds a `Pool` per configured
  pool and answers `Pick`, `Refused`, `Observed` and `Reinstated`. It is the
  only writer, which is what makes a concurrent pick and refusal ordered.
- **The call site.** The bridge worker asks the owner for a member before
  authorizing, passes the chosen profile name to `profile.auth`, and reports
  what happens. Section 3 says what it can see and what it needs added.

The gateway, the adapters and the frozen request and resolved-model types do
not change.

### What marks a member exhausted, and when it returns

- **A usage-limit refusal.** HTTP 429 with `error.type = "usage_limit_reached"`
  (section 3). The member rests until the reset time the provider named. A
  reset time at or before now is replaced by the configured hold, since the
  refusal just proved the member is not usable. A later refusal never moves the
  return earlier.
- **A full gauge window.** When a response carries a reading with a window at
  100 percent that has not reset, the member rests until the last such window
  resets. This only closes a member earlier than the refusal would; it never
  reopens one.
- **An authorization failure** (`not_logged_in`, `plan_permission_required`
  from `profile.auth`) makes the member `Unusable` until an operator signs in
  again and reinstates it. Waiting does not repair it.
- **Return** is by comparison, not by timer: `Pick` returns every member whose
  `until` has been reached before choosing. A gauge reading can never be what
  declares a member usable.

## 3. Gauging what is left

State of the evidence for each provider, with what is documented, what is
observable but undocumented, and what could not be established. No provider
API was called and no credential was read to produce this section.

### ChatGPT and Codex

Sources: the open-source Codex CLI, `github.com/openai/codex` at
`95dcd1e8378021080bf380e42587ef891f611897`, read from a shallow clone, and
OpenAI's public documentation.

**Observable, not documented.**

1. *Response headers.* `codex-rs/codex-api/src/rate_limits.rs` parses, for the
   default limit and for each named limit family,
   `x-codex-primary-used-percent`, `x-codex-primary-window-minutes`,
   `x-codex-primary-reset-at` and the three `secondary` counterparts, plus
   `x-codex-credits-has-credits`, `x-codex-credits-unlimited`,
   `x-codex-credits-balance`, `x-codex-promo-message` and
   `x-codex-rate-limit-reached-type`. `codex-rs/codex-api/src/sse/responses.rs`
   takes them from the HTTP response that opens the stream, and the same
   fields arrive as a `codex.rate_limits` stream event and in a websocket
   error event. Every successful response therefore carries the gauge of the
   seat that served it, for free.
2. *A usage endpoint.* `codex-rs/backend-client/src/client/rate_limit_resets.rs`
   issues `GET <base>/wham/usage` (or `/api/codex/usage`, depending on the base
   URL) with the account's bearer and a `chatgpt-account-id` header
   (`codex-rs/http-client/src/openai_headers.rs`). The payload
   (`codex-rs/codex-backend-openapi-models/src/models/rate_limit_status_payload.rs`
   and `rate_limit_status_details.rs`, `rate_limit_window_snapshot.rs`) has
   `plan_type`, `rate_limit.allowed`, `rate_limit.limit_reached`,
   `primary_window` and `secondary_window` each with `used_percent`,
   `limit_window_seconds`, `reset_after_seconds` and `reset_at`, plus
   `credits`, `spend_control`, `additional_rate_limits` and
   `rate_limit_reached_type`. The CLI's `/status` and `/usage` read this
   (`codex-rs/tui/src/chatwidget/rate_limits.rs`,
   `codex-rs/tui/src/status/rate_limits.rs`). The same client has endpoints to
   list and consume "rate-limit reset credits", which this design does not use.
3. *The refusal.* `codex-rs/codex-api/src/api_bridge.rs` maps HTTP 429 with
   body `error.type = "usage_limit_reached"` to a typed error built from the
   body's `plan_type`, `resets_at` (epoch seconds) and `limit_window_minutes`
   and the same headers. The websocket path wraps the same body in an error
   event with `status: 429` (`codex-rs/codex-api/src/endpoint/responses_websocket.rs`
   tests). No usage-limit failure inside a 200 stream was found in the SSE
   path; the only in-stream throttle it handles is `rate_limit_exceeded`.

**Documented.** OpenAI's Sign in with ChatGPT pages say only that
"the five-hour usage limit is shared across all apps where they use their ChatGPT plan"
and that an app should let a user choose "an existing ChatGPT account or add another"
(`https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions`).
Neither the headers nor `/wham/usage` appears in the public documentation read.

**Not established.** Whether the `https://api.openai.com/v1/responses`
route that loom's subscription provider posts to returns the `x-codex-*`
headers (Codex's own route is the ChatGPT backend, not that host). Whether the
grant loom obtains (`chatgpt.tokens.use.direct`, `dynamic_agent_client`) is
authorized against `/wham/usage`. Whether the `used_percent` reading is stable
across the ChatGPT backend's versions: the endpoint is private and has two path
spellings in current source. Nothing was sent to either to find out.

**What it means for the design.** The refusal body is the one dependable
signal, because it is what loom already receives and it carries the reset time.
The headers are a free improvement if the route returns them, and the pool
works without them. A separate poll of `/wham/usage` is not proposed (section
4).

### Claude plans

Sources: `github.com/agentclientprotocol/claude-agent-acp` (the ACP adapter,
which pins `@anthropic-ai/claude-agent-sdk` 0.3.322, read from a shallow
clone) and `github.com/anthropics/claude-agent-sdk-typescript`
(`CHANGELOG.md` only; the repository holds no source). The SDK package itself
was not installed in the environment, so its minified source was not read.

**Observable, with the SDK marking part of it experimental.**

1. *`/usage`.* The adapter answers `/usage` by calling
   `query.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()` and
   validating the result (`src/usage-markdown.ts`, `src/v1/acp-agent.ts`). The
   validated shape includes `subscription_type`, `rate_limits_available` and
   `rate_limits` with `five_hour`, `seven_day`, `seven_day_opus`,
   `seven_day_sonnet` and a `model_scoped` array, each window being
   `utilization` (0 to 100) and `resets_at` (a string), plus `extra_usage`.
   The SDK changelog calls the method "experimental" and records the
   `model_scoped` addition (`CHANGELOG.md`, 0.3.x entries). It is a control
   request on a running Claude Code process holding the credential, so it
   gauges that credential only.
2. *`rate_limit_event`.* The SDK emits a stream message of this type
   (`SDKRateLimitInfo`) with a `status` (`allowed`, `allowed_warning`,
   `rejected`), `resetsAt` and `rateLimitType` (including
   `seven_day_overage_included`), and overage fields. The changelog records
   that it is emitted as a usage-limit wait begins and "re-emit[ted] during an
   exceeded window on repeat 429s (about once per 30 seconds per limit
   window)". The ACP adapter reads only `status` (`src/idle-compaction.ts`).
3. *The refusal.* A usage-limit failure arrives as a synthetic assistant
   message (model `<synthetic>`) whose text begins with one of the SDK's
   exported `USAGE_LIMIT_ERROR_PREFIXES`, an `@alpha` export
   (`CHANGELOG.md`, "rate-limit message prefix buckets"). The adapter maps it
   to its `quota_exhausted` failure (`src/session-failure-extension.ts`,
   `providerFailureCategory`). A real model answer afterward is how it decides
   the account recovered (`activeUsageLimitMessage`).

**Documented.** The plan limits themselves: "Pro and Max plans have a
five-hour session limit and a weekly limit", shared across Claude and Claude
Code (`https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan`).
No page read documents the usage call or the event.

**Not established.** The HTTP endpoint behind `/usage`, or the OAuth scope it
requires, so whether a long-lived inference-only token can read it. The exact
prefix list, which lives in the SDK package. Whether `utilization` is stable
across SDK versions; the adapter validates it at runtime because the SDK says
it may change.

**What it means for the design.** Claude's gauge exists only inside a Claude
Code process, never as something a gateway can read from a response. That
settles section 6.

## 4. Selection

Three rules, against what the gauge can tell.

| rule | state | what it needs from the gauge | what it costs |
| --- | --- | --- | --- |
| Priority order: first available, rotate on refusal | per member: `Available`, `Exhausted(until)`, `Unusable` | nothing, but it uses a reading if there is one | a switch costs one refused request unless the bridge retries within the attempt |
| Most headroom | the above plus a fresh reading per member | a reading for every member, kept fresh | a poll or a request per idle seat; a stale reading picks the wrong seat |
| Round-robin | a cursor | nothing | spreads load that does not need spreading and ignores exhaustion until refused |

Most headroom needs a reading for every member, but a response carries only
the reading of the seat that served it, and an unused seat has the oldest
reading. Polling fixes that by calling a private endpoint (Codex) or by
spawning a process per credential (Claude), both of which section 3 could not
establish as available to loom. It also gains nothing in capacity: the total
allowance across seats is the same however it is spent, and spreading it makes
every seat reach its weekly limit at the same time, where priority order keeps
the later seats full as a reserve. Round-robin spreads load in the same way and
ignores exhaustion until a refusal.

**Recommendation: priority order.** It is the rule loom's routing already uses
(head first, every time) applied one level down, it needs no gauge, and it makes
the stated failure unreachable: a request fails for allowance only when every
configured member is simultaneously `Exhausted` or `Unusable`, in which case
the consumer receives the same usage-limit refusal it receives today, with the
earliest return time known. Headers, when present, close a member one request
early and are the only use of the gauge.

**State, and a restart.** The ledger is per process, in the owner actor. It is
not persisted. After a restart every member is `Available`; the first request
to a spent seat is refused, which costs a round trip and no allowance, and the
refusal puts the member back to rest with the provider's own reset time. A
file would add a second source of truth for a fact the provider restates on
every refusal, and a stale file would be worse than an empty one. A daemon that
serves several nodes shares the pool only if the node holding the credentials
also holds the pool, which is where `client/codex/profile` already keeps the
grant.

**One refusal per switch.** Without more, the request that discovers
exhaustion fails. The bridge can avoid that, because a usage-limit 429 arrives
before any inference runs and before any byte is forwarded: it can buffer the
bounded non-200 body, record the refusal, and repeat with the next member,
at most once per member. This needs the bridge to interpose a private event
subject so it sees the status and headers before the gateway does. It is the
second slice, not the first, because it touches the custody of the inference
owner that `transport.prepare_with` and `weft.adopt` guard (each failed owner
must be cancelled and drained before another is adopted). The pool is correct
without it.

## 5. Sessions in flight

Loom owns the conversation. A Responses request carries reconstructed history
with `store: false` and no `previous_response_id`
(`provider/CLAUDE.md`, "Responses has one local conversation owner"), and the
adapter keeps the history in the session store, not at the provider. So a
long session is not bound to a seat. Each request picks a member
independently, a turn that makes twenty requests can cross seats between any
two of them, and nothing needs to be resumed: the next request replays the same
history under the next member's bearer. A refusal fails the request in flight
only when no member remains, exactly as today.

Two things this does not claim. A request already streaming is not moved: a
usage-limit refusal comes before the stream, but a seat whose window closes
mid-stream finishes the turn it began, which the provider decides. And
encrypted reasoning items are replayed as opaque data (`provider/CLAUDE.md`,
"Responses replay is bounded metadata"); whether the provider accepts one
produced under a different account was not established, so the first live use
should replay a reasoning-bearing history across a seat change before relying
on rotation inside a turn. No new machinery is needed to try it.

## 6. The Claude route

Loom has no Claude plan route, so a pool "in loom" for it would first need a
Claude subscription provider, which is a different project from this one and
would run into the terms below. What exists is a Claude Code process spawned by
the consumer, one credential per process. Choosing among credentials there is a
small change in the consumer: pick a credential before spawning the process,
mark it spent when a session fails with the usage-limit message, and read
`/usage` or `rate_limit_event` from the session it already holds for the
gauge. The ledger in `provider/pool.gleam` is generic over labels and could be
shared by a consumer that wants it, because it is pure and depends only on
`gleam_stdlib`; the owner and the bridge are not, and need not be.

What loom would need for a shared Claude route: a provider that sends Claude
Code's own requests with a plan credential, which Anthropic's published
conditions (below) do not describe as available to third parties. This note
does not propose it.

## 7. Terms

The design must rotate only among seats the organisation holds and may use this
way. This section reads each provider's published terms for that question.
Quotations are verbatim from the pages as fetched on 2026-11-11, with the
limits on what could be read stated for each.

### Anthropic

Sources: `https://www.anthropic.com/legal/consumer-terms` (Free, Pro, Max and
Ultra; the page text was returned through a summarizing fetch, so the quoted
fragments are exact but the surrounding sentences should be read on the live
page), `https://code.claude.com/docs/en/legal-and-compliance`, and
`https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan`.
The Commercial Terms (Team, Enterprise, API) were not read.

- Credentials, Consumer Terms section 2: "You may not share your Account login
  information, Anthropic API key, or Account credentials with anyone else."
- Automation, Consumer Terms section 3, item 7: the Terms bar accessing the
  Services "through automated or non-human means, whether through a bot,
  script, or otherwise", except where access is through an API key or "where
  Anthropic otherwise explicitly permits it".
- Protective measures, Consumer Terms section 3: users "must not abuse, harm,
  interfere with, or disrupt our Services", including by "bypassing any of our
  systems or protective measures". The Terms say nothing about usage limits
  or multiple accounts by name.
- Plan limits and use, Claude Code legal page: "Advertised usage limits for Pro,
  Max, and Ultra plans assume ordinary, individual usage of Claude Code and the
  Agent SDK."
- Authentication, same page: "Developers building products or services that
  interact with Claude's capabilities, including those using the Agent SDK,
  should use API key authentication through Claude Console or a supported cloud
  provider. Anthropic does not permit third-party developers to offer
  Claude.ai login into their own applications, or to route requests through
  Free, Pro, Max, or Ultra plan credentials on behalf of their users."
- The carve-out, same page: the restriction does not prevent "an end user from
  signing in to the unmodified Claude Code binary with their own Claude
  subscription".
- Agent SDK on a plan, support article: "when you're signed in with your Claude
  plan, the Claude Agent SDK and claude -p still draw from your subscription
  limits", and the changes announced earlier were "paused" (June 15, 2026
  note).

*Permitted.* A person using their own seat in the unmodified Claude Code
binary, including the Agent SDK and `claude -p`, drawing on that seat's limits.
*Forbidden.* Sharing a seat's credentials with anyone else; routing requests
through plan credentials on behalf of other users; offering plan sign-in in
one's own product. *Unclear.* An organisation running many automated sessions
on several seats it holds, and rotating among them when one is spent. The
"ordinary, individual usage" sentence and the protective-measures sentence both
bear on it, and neither names it. Anthropic's stated path for automation is an
API key billed to the key holder. The Claude pool is therefore not
recommended for build until Anthropic confirms it in writing; the page offers
a sales contact for exactly this question.

### OpenAI

Sources read: `https://learn.chatgpt.com/docs/auth`,
`https://learn.chatgpt.com/docs/pricing`, and the Sign in with ChatGPT pages
under `https://developers.openai.com/siwc/`. **OpenAI's Terms of Use and Usage
Policies could not be read**: `openai.com/policies/*` returned HTTP 403 to
the fetch tool, and an alternative mirror was not used. No sentence from them
is quoted here. A search-engine summary says the consumer terms bar sharing
credentials and getting around rate limits, and that the business services
agreement bars "configuring the services to avoid usage limits"; that is an
unverified lead, not a source, and the owner should read the live terms before
relying on either direction.

- Automation, `learn.chatgpt.com/docs/auth`: "Use API key authentication for
  programmatic Codex CLI workflows, such as CI/CD jobs." and "API keys are
  still the recommended default for automation." Against that, "Access tokens
  are intended for trusted scripts, schedulers, and private CI runners."
- Credentials, same page: "Treat `~/.codex/auth.json` like a password: it
  contains access tokens." and "Don't commit it, paste it into tickets, or
  share it in chat."
- Plan use by other apps, siwc profiles page: "the five-hour usage limit is
  shared across all apps where they use their ChatGPT plan", and apps should
  let "users choose an existing ChatGPT account or add another".
- Pricing page: it does not say whether limits apply per account and does not
  address holding several accounts; it names an API key as the option "great
  for automation in shared environments like CI".

*Permitted, by what was read.* One person's seat used by scripts in a trusted,
private environment; a user holding and choosing among several of their own
accounts in an app. *Forbidden.* Nothing read forbids rotation, and nothing
read permits using several accounts to extend a limit. *Unclear.* Whether an
organisation's automated rotation among seats it holds is within the terms,
which is the governing question and is in the part that could not be read.

### What the design does about it

Rotation is a mechanical choice among profiles the operator listed, so it adds
no seat and discovers none. It ships off: nothing changes for a profile that no
pool names. It cannot tell failover from circumvention, and a provider may not
either; the note does not argue that the difference protects anyone. The
design neither shares a credential between people nor serves a request for a
person other than the seat's holder. If the owner decides a mode is forbidden
or not worth the risk, the alternative that the documents above describe as
supported for automation is a usage-billed API key as the overflow credential
(`openai-responses`, which exists). That is a different feature: a chain of
entries across billing arrangements, and it runs into the walk limitation in
section 2.

## 8. Observability and safety

The owner exposes and logs, per member label:

- `standing` (`available`, `exhausted`, `unusable`), and for an exhausted member
  its return time;
- the last refusal's time and kind (`usage_limit`, `unauthorized`);
- the live gauge reading, `used_percent` and reset, when a response supplied
  one, shown as absent once its window has reset (`pool.report`);
- a count of picks, refusals and returns.

A log line or error carries a configured label, a kind drawn from a closed set
and a time. It never carries a bearer, a refresh token, a header value, an
account or workspace identifier, a plan name or an email. The labels are
profile names, whose alphabet (`client/codex/credentials.valid_profile`: ASCII
letters, digits, underscore and hyphen) cannot spell an email address, but an
operator can still choose an identifying name, so the documentation says to
choose a name that identifies the seat's role, not its holder. The ledger
receives only labels, integers and a closed refusal type, so a credential
cannot reach it by construction; the call site decodes the 429 body and the
headers into those integers and drops the rest, as the gateway already scrubs
remote error text before it leaves.

## 9. What the first slice contains

`provider/pool.gleam` and `provider/test/provider/pool_test.gleam`: the ledger
only. It is pure, holds no `@external`, adds no dependency and is called by
nothing. It exists so the selection rule and the exhaustion rule are a checked
fact (a transition table gated by R14, tests for each row) before anything
depends on them. It changes no request path, no configuration key and no frozen
interface.

## 10. Cut list

- No request routing change in this proposal's first slice; the bridge, the
  owner actor and the configuration key are described and not built.
- No polling of any usage endpoint, and no spawn of a process to read `/usage`.
- No persistence of the ledger.
- No headroom-based or round-robin selection.
- No Claude subscription provider in loom, and no pooling of Claude seats until
  the terms question in section 7 is answered by Anthropic.
- No use of reset credits, extra-usage purchases or any spend.
- No change to `retry.classify`, so `usage_limit_reached` stays terminal for the
  role-chain walk. A usage-limit refusal that walks to a different provider's
  entry is a separate decision.
- No discovery or creation of accounts, and no login on behalf of a seat.
- No mid-stream migration of a request.
