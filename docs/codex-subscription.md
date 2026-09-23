# Codex subscription sign-in (experimental)

Loom can sign in to a ChatGPT account and send model requests through a
separate Codex subscription provider. This route is distinct from the public
OpenAI Responses API, which uses a Platform API key and usage-based billing.
The subscription provider uses a private Codex backend and has not yet been
verified with a live, entitled model request in this project. Treat this as an
experimental feature rather than a supported way to consume a subscription.

## Sign in

Install a build that includes `loomd codex`, then sign in **before** starting
the daemon with a subscription model:

```sh
loomd codex login --profile personal
```

Open the URL printed by the command in a browser on the same computer. The
browser flow returns to `localhost:1455`, so that port must be available.
If the browser flow is unavailable, try the device flow:

```sh
loomd codex login --device --profile personal
```

The command prints a URL and code to enter there. Device authorization may
need to be enabled in your ChatGPT account or workspace. The profile name is
local to Loom; it can contain 1–64 ASCII letters, digits, underscores, or
hyphens and must start with a letter or digit. Omit `--profile` to use
`default`.

Check the sign-in and ask the account which models it currently offers:

```sh
loomd codex status --profile personal
loomd codex models --profile personal
```

The models command prints JSON with model IDs, reported context windows, and
reasoning levels. Availability depends on the account and can change. Use an
ID from this output in the catalogue; a name seen in another product does not
prove this profile can use it. Loom's sign-in is separate from `codex login`;
it does not read the Codex CLI's saved credentials.

## Configure Loom

Create `~/.loom/loom.toml` with a subscription entry and a role route. The
following values are examples: replace `MODEL_ID_FROM_CODEX_MODELS` with an
exact ID returned by `loomd codex models`, and choose limits appropriate to
that model. `context_window` is Loom's configured context budget; if the
models command reports a nonzero window, do not set it higher. The output
limit below is a local per-turn ceiling.

```toml
[models.codex-personal]
dialect = "codex-subscription"
auth = "codex"
profile = "personal"
model_id = "MODEL_ID_FROM_CODEX_MODELS"
context_window = 128000
max_output_tokens = 8192
thinking = "off"

[roles]
main = ["codex-personal"]
subagent = ["codex-personal"]
```

Then run `loom` in your project. `/model` selects among your configured
catalogue entries. A second entry can point at the same profile with a
different model ID, such as a Sol or Astra model **if that ID appears in your
account's model list**. The entry name (`codex-personal` here) is Loom's
durable provider identity, so keep it stable for existing sessions. The
catalogue accepts one active Codex profile per daemon process.

Subscription entries do not take `api_key_env`, `base_url`, or custom
headers. For the public OpenAI API, use the `openai-responses` dialect with
`auth = "api-key"` instead; it does not spend subscription allowance.

## Manage the profile

```sh
loomd codex status --profile personal
loomd codex logout --profile personal
```

After the daemon makes its first request with a profile, its helper keeps an
exclusive lock on that profile. Stop the daemon before running separate
`loomd codex status`, `models`, `login`, or `logout` commands for it. In the
default local setup, `loom` reconnects to the shared daemon, so closing the
terminal alone may not release the lock. Do not copy or paste saved tokens
into the catalogue or environment variables.

The private backend can reject a model even if the catalogue parses. An
authentication error, account limit, or model availability error is reported
at dispatch. This branch does not yet have a live authenticated Sol or Astra
smoke test or a public third-party support contract from OpenAI.

OpenAI's [Codex authentication guide](https://learn.chatgpt.com/docs/auth)
describes subscription sign-in and device authorization. Its
[API quickstart](https://developers.openai.com/api/docs/quickstart) covers the
separate Platform API-key path.
